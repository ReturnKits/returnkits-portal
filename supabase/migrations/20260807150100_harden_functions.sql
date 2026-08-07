-- ============================================================================
-- Phase 1 follow-up: close two findings from the Supabase security linter
-- after applying the initial schema.
--
-- 1. Several functions had a mutable search_path — a search_path hijack
--    vector (a malicious schema earlier in search_path could shadow an
--    unqualified function/table reference). Pin search_path on all of them.
-- 2. log_audit() was reachable via PostgREST RPC by anon/authenticated —
--    Supabase grants EXECUTE on all public-schema functions to those roles
--    by default at project creation, so `revoke ... from public` in the
--    original migration wasn't enough; anon/authenticated need an explicit
--    revoke. log_audit must only ever be called from inside other
--    SECURITY DEFINER functions, never directly by a client.
-- ============================================================================

alter function public.enforce_user_company_scope() set search_path = public;
alter function public.enforce_invite_role_scope() set search_path = public;
alter function public.set_updated_at() set search_path = public;
alter function public.current_company() set search_path = public;
alter function public.current_role() set search_path = public;
alter function public.is_internal() set search_path = public;
alter function public.custom_access_token_hook(jsonb) set search_path = public;

revoke execute on function public.log_audit(uuid, text, text, uuid, jsonb, jsonb) from anon, authenticated;
