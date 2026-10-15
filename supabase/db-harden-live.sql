-- Optional one-time hardening for the LIVE project (same revokes as harden-trigger-functions.patch,
-- plus the Supabase-created rls_auto_enable() event-trigger helper). Triggers keep working:
-- Postgres checks EXECUTE only when a trigger is created, not when it fires.
revoke all on function public.rls_auto_enable() from public, anon, authenticated;
revoke all on function public.handle_new_soundcollab_user() from public, anon, authenticated;
revoke all on function public.log_order_change() from public, anon, authenticated;
revoke all on function public.log_meeting_change() from public, anon, authenticated;
revoke all on function public.guard_profile_update() from public, anon, authenticated;
revoke all on function public.guard_order_mutation() from public, anon, authenticated;
revoke all on function public.guard_message_insert() from public, anon, authenticated;
revoke all on function public.guard_meeting_insert() from public, anon, authenticated;
revoke all on function public.prevent_meeting_update() from public, anon, authenticated;
revoke all on function public.guard_deliverable_insert() from public, anon, authenticated;
