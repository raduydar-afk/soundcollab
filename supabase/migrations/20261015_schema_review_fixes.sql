begin;

alter table public.orders
  add column if not exists currency text not null default 'UAH';

do $$
begin
  if exists (
    select 1 from public.orders
    where performer_id is not null and performer_id = client_id
  ) then
    raise exception 'Cannot add participant constraint: self-assigned orders exist';
  end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.orders'::regclass
      and conname = 'orders_distinct_participants'
  ) then
    alter table public.orders add constraint orders_distinct_participants
      check (performer_id is null or performer_id <> client_id);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.orders'::regclass
      and conname = 'orders_currency_uah_check'
  ) then
    alter table public.orders add constraint orders_currency_uah_check
      check (currency = 'UAH');
  end if;
end
$$;

create unique index if not exists order_disputes_one_open_idx
  on public.order_disputes(order_id) where resolved_at is null;

create or replace function public.is_order_participant(target_order uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.orders o
    where o.id = target_order
      and (o.client_id = (select auth.uid()) or o.performer_id = (select auth.uid()))
  ) or (
    public.is_soundcollab_admin()
    and exists (
      select 1 from public.orders o
      where o.id = target_order and o.status = 'disputed'
    )
  );
$$;

create or replace function public.guard_profile_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.id is distinct from old.id or new.created_at is distinct from old.created_at then
    raise exception 'Profile identity and creation timestamp are immutable';
  end if;
  if new.is_admin is distinct from old.is_admin
     and current_user not in ('postgres', 'supabase_admin', 'service_role') then
    raise exception 'Only a database administrator can change admin access';
  end if;
  if (new.privacy_accepted_at, new.privacy_policy_version)
     is distinct from (old.privacy_accepted_at, old.privacy_policy_version)
     and current_user not in ('postgres', 'supabase_admin', 'service_role') then
    raise exception 'Privacy consent records cannot be edited by the account owner';
  end if;
  if 'admin' = any(new.roles) then
    raise exception 'Admin is not a self-assignable profile role';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.guard_order_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  actor uuid := (select auth.uid());
  is_admin_actor boolean := public.is_soundcollab_admin();
  status_changed boolean;
begin
  if tg_op = 'INSERT' then
    if actor is null or new.client_id <> actor or new.status <> 'draft' then
      raise exception 'Clients can create only their own draft orders';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(actor::text, 0));
    if (
      select count(*) from public.orders o
      where o.client_id = actor and o.created_at > now() - interval '10 minutes'
    ) >= 5 then
      raise exception 'Order rate limit exceeded; try again later';
    end if;
    if new.performer_id is not null and not exists (
      select 1 from public.profiles p
      where p.id = new.performer_id and 'performer' = any(p.roles)
    ) then
      raise exception 'Selected account is not a performer';
    end if;
    if new.performer_id = new.client_id then
      raise exception 'A client cannot assign their own account as the performer';
    end if;
    return new;
  end if;

  status_changed := new.status is distinct from old.status;
  new.updated_at := now();

  if not status_changed then
    if actor = old.client_id and old.status = 'draft'
       and new.id = old.id
       and new.client_id = old.client_id
       and new.status = old.status
       and new.dispute_reason is not distinct from old.dispute_reason
       and new.created_at = old.created_at
       and (new.performer_id is null or new.performer_id <> new.client_id)
       and (new.performer_id is null or exists (
         select 1 from public.profiles p
         where p.id = new.performer_id and 'performer' = any(p.roles)
       )) then
      return new;
    end if;
    if not is_admin_actor then
      raise exception 'Only the client can edit a draft order';
    end if;
    if (to_jsonb(new) - 'updated_at') = (to_jsonb(old) - 'updated_at') then
      return new;
    end if;
    raise exception 'Administrators cannot edit order fields';
  end if;

  if (to_jsonb(new) - array['status', 'updated_at', 'performer_id', 'dispute_reason'])
      is distinct from
     (to_jsonb(old) - array['status', 'updated_at', 'performer_id', 'dispute_reason']) then
    raise exception 'Order details cannot be changed during a status transition';
  end if;

  if not is_admin_actor then
    if new.performer_id is distinct from old.performer_id
       and not (new.status = 'requested' and old.status = 'draft' and actor = old.client_id) then
      raise exception 'Performer can only be selected when requesting a draft';
    end if;
    if new.performer_id is not null and new.performer_id is distinct from old.performer_id
       and not exists (
         select 1 from public.profiles p
         where p.id = new.performer_id and 'performer' = any(p.roles)
       ) then
      raise exception 'Selected account is not a performer';
    end if;
    if new.performer_id = new.client_id then
      raise exception 'A client cannot assign their own account as the performer';
    end if;
    if new.status = 'requested' then
      if actor <> old.client_id or old.status <> 'draft' then
        raise exception 'Only the client can request a draft order';
      end if;
    elsif new.status in ('accepted', 'declined') then
      if not public.has_soundcollab_role('performer')
         or (old.performer_id is not null and old.performer_id <> actor)
         or old.status <> 'requested' then
        raise exception 'Only the selected performer can respond to a request';
      end if;
      if new.status = 'declined' and old.performer_id is null then
        raise exception 'An unassigned open request cannot be declined by one performer';
      end if;
      if new.status = 'accepted' and old.performer_id is null then
        new.performer_id := actor;
      end if;
      if new.status = 'declined' and new.performer_id is distinct from old.performer_id then
        raise exception 'Performer assignment cannot change when declining';
      end if;
    elsif new.status in ('in_progress', 'delivered') then
      if actor <> old.performer_id
         or (new.status = 'in_progress' and old.status <> 'accepted')
         or (new.status = 'delivered' and old.status <> 'in_progress') then
        raise exception 'Only the assigned performer can advance this order';
      end if;
      if new.status = 'delivered' and not exists (
        select 1 from public.order_deliverables d where d.order_id = old.id
      ) then
        raise exception 'A deliverable link or file is required before marking work delivered';
      end if;
    elsif new.status = 'completed' then
      if actor <> old.client_id or old.status <> 'delivered' then
        raise exception 'Only the client can complete a delivered order';
      end if;
    elsif new.status = 'cancelled' then
      if (actor is distinct from old.client_id and actor is distinct from old.performer_id)
         or old.status not in ('draft', 'requested', 'accepted', 'in_progress') then
        raise exception 'This order cannot be cancelled by this account';
      end if;
    elsif new.status = 'disputed' then
      if (actor is distinct from old.client_id and actor is distinct from old.performer_id)
         or old.status not in ('requested', 'accepted', 'in_progress', 'delivered')
         or length(trim(coalesce(new.dispute_reason, ''))) < 5 then
        raise exception 'A participant and a reason are required to open a dispute';
      end if;
    else
      raise exception 'Unsupported order transition';
    end if;
  else
    if old.status <> 'disputed'
       or new.status not in ('requested', 'accepted', 'in_progress', 'completed', 'cancelled')
       or new.performer_id is distinct from old.performer_id
       or new.dispute_reason is distinct from old.dispute_reason
       or current_setting('soundcollab.resolve_order_id', true) is distinct from old.id::text then
      raise exception 'Administrators can only resolve an open dispute through resolve_order_dispute';
    end if;
  end if;

  if new.status = 'disputed' and length(trim(coalesce(new.dispute_reason, ''))) < 5 then
    raise exception 'A dispute reason of at least five characters is required';
  end if;
  if new.status <> 'disputed' and new.dispute_reason is distinct from old.dispute_reason then
    raise exception 'Dispute reason can only be set when opening a dispute';
  end if;
  return new;
end;
$$;

create or replace function public.resolve_order_dispute(
  target_order uuid, decision text, resolution_text text
)
returns public.orders
language plpgsql security definer
set search_path = public
as $$
declare
  changed public.orders;
  active_dispute public.order_disputes;
begin
  if not public.is_soundcollab_admin() then
    raise exception 'Only an administrator can resolve disputes';
  end if;
  if decision not in ('requested', 'accepted', 'in_progress', 'completed', 'cancelled')
     or length(trim(coalesce(resolution_text, ''))) < 5 then
    raise exception 'Choose a valid outcome and provide a resolution of at least five characters';
  end if;

  select * into active_dispute
  from public.order_disputes
  where order_id = target_order and resolved_at is null
  for update;
  if active_dispute.id is null then
    raise exception 'No open dispute exists for this order';
  end if;
  if decision in ('accepted', 'in_progress') and not exists (
    select 1 from public.orders o where o.id = target_order and o.performer_id is not null
  ) then
    raise exception 'An order without an assigned performer cannot be resumed';
  end if;

  perform set_config('soundcollab.resolve_order_id', target_order::text, true);
  update public.orders set status = decision
  where id = target_order and status = 'disputed'
  returning * into changed;
  if changed.id is null then
    raise exception 'Order is no longer disputed';
  end if;

  update public.order_disputes
     set resolution = trim(resolution_text),
         resolved_by = (select auth.uid()),
         resolved_at = now()
   where id = active_dispute.id;

  insert into public.order_events(order_id, actor_id, event_type, details)
  values (
    target_order, (select auth.uid()), 'dispute_resolved',
    jsonb_build_object('decision', decision, 'resolution', trim(resolution_text))
  );
  return changed;
end;
$$;

create or replace function public.respond_to_meeting(
  target_meeting uuid, response text, new_starts_at timestamptz default null
)
returns public.meetings
language plpgsql security definer
set search_path = public
as $$
declare
  existing public.meetings;
  changed public.meetings;
begin
  select * into existing from public.meetings where id = target_meeting for update;
  if existing.id is null or not public.is_order_participant(existing.order_id)
     or public.is_soundcollab_admin() or existing.proposer_id = (select auth.uid())
     or existing.status <> 'proposed' then
    raise exception 'Only the other order participant can respond to a proposed meeting';
  end if;
  if response not in ('confirmed', 'declined', 'rescheduled') then
    raise exception 'Unsupported meeting response';
  end if;
  if response = 'rescheduled' then
    if new_starts_at is null or new_starts_at <= now() then
      raise exception 'A future replacement date is required';
    end if;
    update public.meetings
      set status = 'proposed', scheduled_at = new_starts_at,
          proposer_id = (select auth.uid()), updated_at = now()
     where id = target_meeting returning * into changed;
  else
    update public.meetings set status = response, updated_at = now()
     where id = target_meeting returning * into changed;
  end if;
  return changed;
end;
$$;

create or replace function public.guard_message_insert()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.sender_id <> (select auth.uid()) or public.is_soundcollab_admin()
     or not public.is_order_participant(new.order_id) then
    raise exception 'Only order participants can send messages';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(new.sender_id::text, 0));
  if (
    select count(*) from public.messages m
    where m.sender_id = new.sender_id and m.created_at > now() - interval '1 minute'
  ) >= 30 then
    raise exception 'Message rate limit exceeded; try again later';
  end if;
  return new;
end;
$$;

drop policy if exists "Profiles visible to authenticated users" on public.profiles;
create policy "Profiles visible to authenticated users" on public.profiles
  for select to authenticated using (
    id = (select auth.uid())
    or 'performer' = any(roles)
    or exists (
      select 1 from public.orders o
      where public.profiles.id in (o.client_id, o.performer_id)
        and public.is_order_participant(o.id)
    )
  );

drop policy if exists "Order participants and admins read orders" on public.orders;
create policy "Order participants and admins read orders" on public.orders
  for select to authenticated using (
    client_id = (select auth.uid())
    or (performer_id = (select auth.uid()) and status <> 'draft')
    or (public.is_soundcollab_admin() and status = 'disputed')
    or (performer_id is null and status = 'requested' and public.has_soundcollab_role('performer'))
  );

drop policy if exists "Participants update through guarded transitions" on public.orders;
create policy "Participants update through guarded transitions" on public.orders
  for update to authenticated using (
    client_id = (select auth.uid())
    or (performer_id = (select auth.uid()) and status <> 'draft')
    or (public.is_soundcollab_admin() and status = 'disputed')
    or (performer_id is null and status = 'requested' and public.has_soundcollab_role('performer'))
  ) with check (
    client_id = (select auth.uid())
    or performer_id = (select auth.uid())
    or public.is_soundcollab_admin()
    or (performer_id is null and status in ('requested', 'declined') and public.has_soundcollab_role('performer'))
  );

revoke all on public.profiles from anon, authenticated;
grant select (id, display_name, roles, bio, city, portfolio, created_at, updated_at),
  update (display_name, roles, bio, city, portfolio) on public.profiles to authenticated;
revoke all on function public.resolve_order_dispute(uuid, text, text) from public, anon;
grant execute on function public.resolve_order_dispute(uuid, text, text) to authenticated;
revoke all on function public.is_order_participant(uuid) from public, anon;
grant execute on function public.is_order_participant(uuid) to authenticated;
revoke all on function public.respond_to_meeting(uuid, text, timestamptz) from public, anon;
grant execute on function public.respond_to_meeting(uuid, text, timestamptz) to authenticated;

update storage.buckets
set file_size_limit = 52428800, public = false
where id = 'order-files';

drop policy if exists "Order participants upload private order files" on storage.objects;
create policy "Order participants upload private order files" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'order-files'
    and not public.is_soundcollab_admin()
    and public.is_order_participant((storage.foldername(name))[1]::uuid)
  );

commit;
