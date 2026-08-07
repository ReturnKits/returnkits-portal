-- confirm_sent/confirm_received are meant for signed-in customers only --
-- `grant execute ... to authenticated` was applied, but (same lesson as
-- 20260807230100_lock_down_record_stripe_payment.sql) this project's
-- default privileges also grant EXECUTE to anon on every new function
-- unless explicitly revoked. Without this, an unauthenticated caller with
-- just the anon key could call /rest/v1/rpc/confirm_sent -- harmless in
-- practice here since current_company() is null for an anon caller and the
-- function raises immediately, but there's no reason to leave an
-- unauthenticated code path reachable at all. Explicit > implicit.
revoke execute on function public.confirm_sent(uuid, text) from anon;
revoke execute on function public.confirm_received(uuid) from anon;
