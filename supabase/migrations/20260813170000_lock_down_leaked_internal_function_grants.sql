-- SECURITY FIX: five SECURITY DEFINER functions meant to be internal/
-- webhook-only had EXECUTE granted to anon and/or authenticated on the live
-- database, via the same "revoke all from public" gap already documented
-- and fixed once before for record_stripe_payment
-- (20260807230100_lock_down_record_stripe_payment.sql): `revoke all ...
-- from public` does not remove Supabase's own default-privilege grant of
-- EXECUTE to anon/authenticated on every new public-schema function, so
-- every migration since that only did `revoke all ... from public` (never
-- also explicitly revoking from anon/authenticated) re-opened the same
-- hole. That migration's own lesson ("any new SECURITY DEFINER function
-- meant to be internal-only needs get_advisors run against it immediately,
-- not just revoke all from public taken on faith") went unheeded four more
-- times.
--
-- Confirmed empirically against pg_proc/information_schema.routine_privileges
-- on the hosted project before writing this migration -- these five were
-- the only ones with a leaked anon/authenticated grant across every
-- SECURITY DEFINER function in the schema:
--
--   get_sendcloud_webhook_secret()  -- anon, authenticated (!!) -- returns
--     the DECRYPTED Sendcloud webhook signing secret in plaintext with NO
--     internal role check in its body at all. Any caller with just the
--     public anon key could have retrieved it and forged valid HMAC-signed
--     Sendcloud webhook payloads. The single most severe finding here --
--     fixed as the very first statement below.
--   record_credit_purchase(...)     -- anon, authenticated, NO internal
--     role check -- any caller could have minted arbitrary "paid" invoices
--     and credited any company's credit_ledger with free kit credits.
--   record_card_setup(...)          -- anon, authenticated, NO internal
--     role check -- any caller could have overwritten any company's
--     stripe_payment_method_id.
--   apply_sendcloud_tracking_event(...) -- anon, authenticated, BUT this one
--     already has `if auth.role() is distinct from 'service_role' then
--     raise exception` in its body, so it was not actually exploitable --
--     fixing the grant anyway for defense-in-depth consistency.
--   create_internal_order(...)      -- anon, authenticated, BUT this one
--     already has the same auth.role() = 'service_role' guard, so it was
--     also not actually exploitable -- same defense-in-depth fix.
--   assert_internal_actor(...)      -- anon, authenticated -- a plain
--     role-membership check with no SECURITY DEFINER elevation and no
--     sensitive data returned; low-severity info-disclosure at most, fixed
--     for completeness/consistency with the pattern.
--
-- record_stripe_payment, mark_order_dispatched, mark_order_paid,
-- cancel_order, flag_cover_claim, mark_return_completed,
-- get_resend_webhook_secret, and every other internal-only function were
-- checked and confirmed already correctly locked down -- this migration
-- closes every remaining gap found, not a partial fix.

revoke execute on function public.get_sendcloud_webhook_secret()
  from anon, authenticated;

revoke execute on function public.record_credit_purchase(
  text, text, text, text, uuid, text, integer, integer, integer, integer
) from anon, authenticated;

revoke execute on function public.record_card_setup(uuid, text)
  from anon, authenticated;

revoke execute on function public.apply_sendcloud_tracking_event(
  text, text, text, text, timestamp with time zone
) from anon, authenticated;

revoke execute on function public.create_internal_order(
  uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean,
  text, text, text, text, text, text, text
) from anon, authenticated;

revoke execute on function public.assert_internal_actor(uuid)
  from anon, authenticated;

-- ----------------------------------------------------------------------------
-- Regression net: this exact class of bug (a new internal-only function
-- landing with `revoke all from public` alone, silently leaving the
-- Supabase-default anon/authenticated grant intact) has now recurred five
-- times across this project's history despite being documented once
-- already. A one-off manual pg_proc query caught it this time -- it needs
-- to be a permanent, automated check instead of something that only gets
-- run when someone happens to think of it.
--
-- PostgREST only exposes tables/views in the configured `public` schema,
-- not `information_schema` directly, so this view re-exposes exactly the
-- slice of information_schema.routine_privileges the RLS suite needs to
-- assert against, schema-qualified into `public` where PostgREST (and
-- therefore supabase-js's `.from(...)`) can reach it.
--
-- No SELECT is granted to anon/authenticated here -- service_role (the RLS
-- suite's adminClient) reads it via the usual RLS-bypass path, and nobody
-- else should be able to query it in the first place (matches the
-- default-deny shape used for reference_counters/stripe_webhook_events).
create view public.internal_function_grant_leaks as
select routine_name, grantee
from information_schema.routine_privileges
where routine_schema = 'public'
  and privilege_type = 'EXECUTE'
  and grantee in ('anon', 'authenticated');

revoke all on public.internal_function_grant_leaks from public, anon, authenticated;
