-- record_stripe_payment must only ever be callable by the webhook Edge
-- Function using the service_role key. `revoke all ... from public` (in the
-- previous migration) turned out NOT to be sufficient on this project:
-- Supabase's default privileges grant EXECUTE on every new public-schema
-- function to anon and authenticated automatically, which the security
-- advisor caught immediately (anon_security_definer_function_executable /
-- authenticated_security_definer_function_executable) the moment the
-- previous migration was applied. Without this fix, any signed-in user --
-- or an unauthenticated caller with just the anon key -- could POST to
-- /rest/v1/rpc/record_stripe_payment and mint an arbitrary "paid" invoice
-- against any company_id/order_ids of their choosing. Revoke explicitly
-- from both roles; service_role is unaffected (Supabase grants it
-- separately and it isn't subject to this same default-privilege path).
--
-- Lesson for next time: any new SECURITY DEFINER function meant to be
-- internal-only needs get_advisors run against it immediately, not just
-- `revoke all from public` taken on faith from the next_reference_number()
-- precedent -- that one apparently predates whatever set these project
-- defaults, or was verified differently. Trust the advisor, not the pattern.
revoke execute on function public.record_stripe_payment(
  text, text, text, text, uuid, uuid[], integer, integer, integer
) from anon, authenticated;
