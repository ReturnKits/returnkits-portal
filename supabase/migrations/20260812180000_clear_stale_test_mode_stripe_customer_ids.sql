-- Live-mode cutover (20260812): companies.stripe_customer_id is a cache of
-- an external Stripe Customer reference, created by create-checkout-session
-- the first time a company checks out. Every customer ID cached so far was
-- created while STRIPE_SECRET_KEY was a test-mode key -- Stripe scopes
-- customer IDs to test/live separately, so a live-mode key correctly
-- rejects reusing a test-mode customer ID ("a similar object exists in test
-- mode, but a live mode key was used to make this request", surfaced by
-- Sentry from create-checkout-session on 20260812).
--
-- Fix: null out the cache. create-checkout-session already handles a null
-- stripe_customer_id by creating a fresh Stripe Customer and re-caching it
-- (see "if (!stripeCustomerId)" in the function) -- no code change needed,
-- this is purely clearing stale data so that lazy-create path runs again,
-- this time against the live key.
update public.companies
set stripe_customer_id = null
where stripe_customer_id is not null;
