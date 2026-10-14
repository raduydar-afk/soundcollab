-- SoundCollab MVP schema for Supabase. Run in the Supabase SQL editor.
begin;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  roles text[] not null default array['client']::text[],
  bio text not null default '',
  city text not null default '',
  portfolio jsonb not null default '[]'::jsonb,
  is_admin boolean not null default false,
  privacy_accepted_at timestamptz not null default now(),
  privacy_policy_version text not null default '2026-10-15',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_roles_valid check (
    cardinality(roles) > 0 and roles <@ array['client', 'performer']::text[]
  ),
  constraint profiles_portfolio_array check (jsonb_typeof(portfolio) = 'array')
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id),
  performer_id uuid references public.profiles(id),
  service text not null,
  title text not null,
  description text not null,
  budget numeric(12, 2) not null check (budget >= 0),
  currency text not null default 'UAH' check (currency = 'UAH'),
  format text not null check (format in ('remote', 'in_person')),
  deadline date,
  status text not null default 'draft' check (status in (
    'draft', 'requested', 'accepted', 'declined', 'in_progress',
    'delivered', 'completed', 'cancelled', 'disputed'
  )),
  dispute_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint orders_distinct_participants check (
    performer_id is null or performer_id <> client_id
  )
);

create table if not exists public.order_events (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  event_type text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  sender_id uuid not null references public.profiles(id),
  body text not null check (char_length(body) between 1 and 5000),
  created_at timestamptz not null default now()
);

create table if not exists public.meetings (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  proposer_id uuid not null references public.profiles(id),
  meeting_type text not null check (meeting_type in ('remote', 'in_person')),
  scheduled_at timestamptz not null,
  meeting_url text,
  location text,
  map_url text,
  status text not null default 'proposed' check (
    status in ('proposed', 'confirmed', 'declined', 'rescheduled')
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint meeting_location_by_type check (
    (meeting_type = 'remote' and meeting_url is not null)
    or (meeting_type = 'in_person' and location is not null)
  )
);

create table if not exists public.order_disputes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  opened_by uuid not null references public.profiles(id),
  reason text not null,
  resolution text,
  resolved_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create table if not exists public.order_deliverables (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  submitted_by uuid not null references public.profiles(id),
  link_url text,
  file_path text,
  note text not null default '',
  created_at timestamptz not null default now(),
  constraint deliverable_has_content check (link_url is not null or file_path is not null),
  constraint deliverable_link_https check (link_url is null or link_url ~ '^https?://')
);

create index if not exists orders_client_created_idx on public.orders(client_id, created_at desc);
create index if not exists orders_performer_created_idx on public.orders(performer_id, created_at desc);
create index if not exists orders_status_idx on public.orders(status);
create index if not exists events_order_created_idx on public.order_events(order_id, created_at);
create index if not exists messages_order_created_idx on public.messages(order_id, created_at);
create index if not exists meetings_order_created_idx on public.meetings(order_id, created_at desc);
create unique index if not exists order_disputes_one_open_idx
  on public.order_disputes(order_id) where resolved_at is null;

create or replace function public.is_soundcollab_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.is_admin
  );
$$;

create or replace function public.has_soundcollab_role(wanted_role text)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and wanted_role = any(p.roles)
  );
$$;

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

create or replace function public.handle_new_soundcollab_user()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  requested_roles text[];
begin
  if new.raw_user_meta_data ->> 'privacy_consent' is distinct from 'true' then
    raise exception 'Privacy policy consent is required to create an account';
  end if;
  select coalesce(array_agg(distinct role_name), array['client']::text[])
    into requested_roles
  from jsonb_array_elements_text(
    case
      when jsonb_typeof(new.raw_user_meta_data -> 'roles') = 'array'
        then new.raw_user_meta_data -> 'roles'
      else '["client"]'::jsonb
    end
  ) as roles(role_name)
  where role_name in ('client', 'performer');

  if cardinality(requested_roles) = 0 then
    requested_roles := array['client']::text[];
  end if;

  insert into public.profiles (
    id, display_name, roles, is_admin, privacy_accepted_at, privacy_policy_version
  )
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), split_part(new.email, '@', 1)),
    requested_roles,
    false,
    now(),
    '2026-10-15'
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_soundcollab on auth.users;
create trigger on_auth_user_created_soundcollab
  after insert on auth.users
  for each row execute function public.handle_new_soundcollab_user();

insert into public.profiles (
  id, display_name, roles, is_admin, privacy_accepted_at, privacy_policy_version
)
select
  u.id,
  coalesce(nullif(trim(u.raw_user_meta_data ->> 'display_name'), ''), split_part(u.email, '@', 1)),
  role_data.roles,
  false,
  coalesce(u.created_at, now()),
  coalesce(nullif(u.raw_user_meta_data ->> 'privacy_policy_version', ''), '2026-10-15')
from auth.users u
cross join lateral (
  select coalesce(array_agg(distinct role_name), array['client']::text[]) as roles
  from jsonb_array_elements_text(
    case
      when jsonb_typeof(u.raw_user_meta_data -> 'roles') = 'array'
        then u.raw_user_meta_data -> 'roles'
      else '["client"]'::jsonb
    end
  ) as requested(role_name)
  where role_name in ('client', 'performer')
) as role_data
where u.raw_user_meta_data ->> 'privacy_consent' = 'true'
on conflict (id) do nothing;

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

drop trigger if exists profiles_guard_update on public.profiles;
create trigger profiles_guard_update
  before update on public.profiles
  for each row execute function public.guard_profile_update();

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

drop trigger if exists orders_guard_mutation on public.orders;
create trigger orders_guard_mutation
  before insert or update on public.orders
  for each row execute function public.guard_order_mutation();

create or replace function public.log_order_change()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.order_events(order_id, actor_id, event_type, details)
    values (new.id, (select auth.uid()), 'order_created', jsonb_build_object('status', new.status));
    return new;
  end if;
  if new.status is distinct from old.status then
    insert into public.order_events(order_id, actor_id, event_type, details)
    values (
      new.id, (select auth.uid()), 'status_changed',
      jsonb_build_object('from', old.status, 'to', new.status, 'reason', new.dispute_reason)
    );
    if new.status = 'disputed' then
      insert into public.order_disputes(order_id, opened_by, reason)
      values (new.id, (select auth.uid()), new.dispute_reason);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists orders_log_change on public.orders;
create trigger orders_log_change
  after insert or update on public.orders
  for each row execute function public.log_order_change();

create or replace function public.transition_order(target_order uuid, target_status text, reason text default null)
returns public.orders
language plpgsql security definer
set search_path = public
as $$
declare
  changed public.orders;
begin
  if target_status not in ('requested', 'accepted', 'declined', 'in_progress',
      'delivered', 'completed', 'cancelled', 'disputed') then
    raise exception 'Unsupported target status';
  end if;
  update public.orders
     set status = target_status,
         dispute_reason = case when target_status = 'disputed' then trim(reason) else dispute_reason end
   where id = target_order
   returning * into changed;
  if changed.id is null then
    raise exception 'Order not found or transition not permitted';
  end if;
  return changed;
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

drop trigger if exists messages_guard_insert on public.messages;
create trigger messages_guard_insert before insert on public.messages
  for each row execute function public.guard_message_insert();

create or replace function public.log_meeting_change()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.order_events(order_id, actor_id, event_type, details)
    values (new.order_id, new.proposer_id, 'meeting_proposed',
      jsonb_build_object('meeting_id', new.id, 'meeting_type', new.meeting_type, 'scheduled_at', new.scheduled_at));
  else
    new.updated_at := now();
    if new.status is distinct from old.status or new.scheduled_at is distinct from old.scheduled_at then
      insert into public.order_events(order_id, actor_id, event_type, details)
      values (new.order_id, (select auth.uid()), 'meeting_updated',
        jsonb_build_object('meeting_id', new.id, 'status', new.status, 'scheduled_at', new.scheduled_at));
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists meetings_log_change on public.meetings;
create trigger meetings_log_change after insert or update on public.meetings
  for each row execute function public.log_meeting_change();

create or replace function public.create_meeting(
  target_order uuid, meeting_kind text, starts_at timestamptz,
  place text default null, map_link text default null, video_link text default null
)
returns public.meetings
language plpgsql security definer
set search_path = public
as $$
declare
  created public.meetings;
begin
  if not public.is_order_participant(target_order) or public.is_soundcollab_admin() then
    raise exception 'Only order participants can propose a meeting';
  end if;
  if meeting_kind not in ('remote', 'in_person') or starts_at <= now() then
    raise exception 'Meeting type or date is invalid';
  end if;
  if meeting_kind = 'remote' and coalesce(video_link, '') !~ '^https://(meet\.jit\.si|zoom\.us|[A-Za-z0-9.-]+\.zoom\.us|meet\.google\.com|teams\.microsoft\.com)/' then
    raise exception 'Use a supported HTTPS video meeting link';
  end if;
  if meeting_kind = 'remote' and (place is not null or map_link is not null) then
    raise exception 'Remote meetings cannot include an in-person place';
  end if;
  if meeting_kind = 'in_person' and (length(trim(coalesce(place, ''))) < 3 or video_link is not null) then
    raise exception 'A meeting place is required';
  end if;
  if map_link is not null and map_link !~ '^https?://' then
    raise exception 'Map links must use HTTP or HTTPS';
  end if;
  if not exists (
    select 1 from public.orders o where o.id = target_order and o.status in ('accepted', 'in_progress')
  ) then
    raise exception 'Meetings are available after an order is accepted';
  end if;
  insert into public.meetings(order_id, proposer_id, meeting_type, scheduled_at, location, map_url, meeting_url)
  values (target_order, (select auth.uid()), meeting_kind, starts_at, nullif(trim(place), ''), nullif(trim(map_link), ''), nullif(trim(video_link), ''))
  returning * into created;
  return created;
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

create or replace function public.guard_meeting_insert()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.proposer_id <> (select auth.uid()) or not public.is_order_participant(new.order_id)
     or public.is_soundcollab_admin() or new.status <> 'proposed' then
    raise exception 'Meeting proposal is not authorized';
  end if;
  return new;
end;
$$;

drop trigger if exists meetings_guard_insert on public.meetings;
create trigger meetings_guard_insert before insert on public.meetings
  for each row execute function public.guard_meeting_insert();

create or replace function public.prevent_meeting_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('postgres', 'supabase_admin', 'service_role') then
    new.updated_at := now();
    return new;
  end if;
  raise exception 'Meeting responses must use respond_to_meeting';
end;
$$;

create or replace function public.guard_deliverable_insert()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.submitted_by <> (select auth.uid()) or not exists (
    select 1 from public.orders o
    where o.id = new.order_id and o.performer_id = (select auth.uid()) and o.status = 'in_progress'
  ) then
    raise exception 'Only the assigned performer can submit work in progress';
  end if;
  if new.file_path is not null and split_part(new.file_path, '/', 1) <> new.order_id::text then
    raise exception 'Deliverable files must be stored in their order folder';
  end if;
  return new;
end;
$$;

drop trigger if exists deliverables_guard_insert on public.order_deliverables;
create trigger deliverables_guard_insert before insert on public.order_deliverables
  for each row execute function public.guard_deliverable_insert();

drop trigger if exists meetings_prevent_direct_update on public.meetings;
create trigger meetings_prevent_direct_update before update on public.meetings
  for each row execute function public.prevent_meeting_update();

alter table public.profiles enable row level security;
alter table public.orders enable row level security;
alter table public.order_events enable row level security;
alter table public.messages enable row level security;
alter table public.meetings enable row level security;
alter table public.order_disputes enable row level security;
alter table public.order_deliverables enable row level security;

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
drop policy if exists "Users update their own profile" on public.profiles;
create policy "Users update their own profile" on public.profiles
  for update to authenticated using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

drop policy if exists "Order participants and admins read orders" on public.orders;
create policy "Order participants and admins read orders" on public.orders
  for select to authenticated using (
    client_id = (select auth.uid())
    or (performer_id = (select auth.uid()) and status <> 'draft')
    or (public.is_soundcollab_admin() and status = 'disputed')
    or (performer_id is null and status = 'requested' and public.has_soundcollab_role('performer'))
  );
drop policy if exists "Clients create own draft orders" on public.orders;
create policy "Clients create own draft orders" on public.orders
  for insert to authenticated with check (client_id = (select auth.uid()) and status = 'draft');
drop policy if exists "Participants update through guarded transitions" on public.orders;
create policy "Participants update through guarded transitions" on public.orders
  for update to authenticated using (
    client_id = (select auth.uid()) or (performer_id = (select auth.uid()) and status <> 'draft')
    or (public.is_soundcollab_admin() and status = 'disputed')
    or (performer_id is null and status = 'requested' and public.has_soundcollab_role('performer'))
  ) with check (
    client_id = (select auth.uid()) or performer_id = (select auth.uid())
    or public.is_soundcollab_admin()
    or (performer_id is null and status in ('requested', 'declined') and public.has_soundcollab_role('performer'))
  );

drop policy if exists "Participants and admins read order events" on public.order_events;
create policy "Participants and admins read order events" on public.order_events
  for select to authenticated using (public.is_order_participant(order_id));
drop policy if exists "Participants read order messages" on public.messages;
create policy "Participants read order messages" on public.messages
  for select to authenticated using (public.is_order_participant(order_id));
drop policy if exists "Participants send order messages" on public.messages;
create policy "Participants send order messages" on public.messages
  for insert to authenticated with check (sender_id = (select auth.uid()) and public.is_order_participant(order_id));

drop policy if exists "Participants read meetings" on public.meetings;
create policy "Participants read meetings" on public.meetings
  for select to authenticated using (public.is_order_participant(order_id));
drop policy if exists "Participants and admins read disputes" on public.order_disputes;
create policy "Participants and admins read disputes" on public.order_disputes
  for select to authenticated using (public.is_order_participant(order_id));
drop policy if exists "Participants read deliverables" on public.order_deliverables;
create policy "Participants read deliverables" on public.order_deliverables
  for select to authenticated using (public.is_order_participant(order_id));
drop policy if exists "Assigned performer submits deliverables" on public.order_deliverables;
create policy "Assigned performer submits deliverables" on public.order_deliverables
  for insert to authenticated with check (
    submitted_by = (select auth.uid()) and public.is_order_participant(order_id)
  );

revoke all on public.profiles, public.orders, public.order_events, public.messages, public.meetings,
  public.order_disputes, public.order_deliverables from anon, authenticated;
grant select, insert, update on public.profiles, public.orders, public.order_events, public.messages,
  public.meetings, public.order_disputes, public.order_deliverables to postgres, supabase_admin, service_role;
grant select (id, display_name, roles, bio, city, portfolio, created_at, updated_at),
  update (display_name, roles, bio, city, portfolio) on public.profiles to authenticated;
grant select, insert, update on public.orders to authenticated;
grant select on public.order_events, public.meetings, public.order_disputes, public.order_deliverables to authenticated;
grant select, insert on public.messages to authenticated;
grant select, insert on public.order_deliverables to authenticated;

revoke all on function public.is_soundcollab_admin() from public, anon;
revoke all on function public.has_soundcollab_role(text) from public, anon;
revoke all on function public.is_order_participant(uuid) from public, anon;
revoke all on function public.transition_order(uuid, text, text) from public, anon;
revoke all on function public.resolve_order_dispute(uuid, text, text) from public, anon;
revoke all on function public.create_meeting(uuid, text, timestamptz, text, text, text) from public, anon;
revoke all on function public.respond_to_meeting(uuid, text, timestamptz) from public, anon;
grant execute on function public.is_soundcollab_admin(), public.has_soundcollab_role(text),
  public.is_order_participant(uuid), public.transition_order(uuid, text, text),
  public.resolve_order_dispute(uuid, text, text),
  public.create_meeting(uuid, text, timestamptz, text, text, text),
  public.respond_to_meeting(uuid, text, timestamptz) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit)
values ('order-files', 'order-files', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = 52428800;

drop policy if exists "Order participants read private order files" on storage.objects;
create policy "Order participants read private order files" on storage.objects
  for select to authenticated using (
    bucket_id = 'order-files'
    and public.is_order_participant((storage.foldername(name))[1]::uuid)
  );
drop policy if exists "Order participants upload private order files" on storage.objects;
create policy "Order participants upload private order files" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'order-files'
    and not public.is_soundcollab_admin()
    and public.is_order_participant((storage.foldername(name))[1]::uuid)
  );

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end
$$;

commit;
