-- Server-side PostHog events for the free first laptop return promo
-- (20261102). Measures whether the offer turns signups into paying
-- customers: signups, promo credits issued / not granted / redeemed /
-- restored / expired, credit purchases, and every paid invoice.
--
-- Sent straight from the database via pg_net, the same async pattern as
-- trigger_sync_hubspot_signup(): nothing depends on the browser, ad
-- blockers, or the marketing site's cookie banner. Every event is a
-- company-level business event:
--   * distinct_id = 'company:<uuid>', `$process_person_profile: false`
--     (no person profiles are created), grouped under group type
--     `company` so insights can count companies.
--   * No email addresses, names of people, or email domains are sent.
--
-- The project API key (PostHog's public "phc_" ingestion key -- the same
-- one the marketing site ships in its HTML) is read from Vault secret
-- `posthog_project_api_key`. When it's absent (every local `db reset`, the
-- test suite) posthog_capture() does nothing, so tests never send events.
-- Every trigger swallows its own errors: tracking can never block or roll
-- back a signup, an order, a payment or a credit write.

create or replace function public.posthog_capture(p_event text, p_company_id uuid, p_properties jsonb default '{}'::jsonb)
returns void
language plpgsql
security definer
set search_path to 'public', 'vault', 'extensions'
as $$
declare
  v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'posthog_project_api_key';
  if v_key is null or p_company_id is null then
    return;
  end if;

  perform net.http_post(
    url := 'https://eu.i.posthog.com/i/v0/e/',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object(
      'api_key', v_key,
      'event', p_event,
      'distinct_id', 'company:' || p_company_id::text,
      'timestamp', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'properties', coalesce(p_properties, '{}'::jsonb) || jsonb_build_object(
        '$process_person_profile', false,
        '$groups', jsonb_build_object('company', p_company_id::text),
        'company_id', p_company_id::text,
        'source', 'portal_db'
      )
    )
  );
exception when others then
  raise warning 'posthog_capture(%) failed: %', p_event, sqlerrm;
end;
$$;

revoke all on function public.posthog_capture(text, uuid, jsonb) from public, anon, authenticated;

-- companies: signup, plus a $groupidentify so the company group has a name.
create or replace function public.trigger_posthog_company_signed_up()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public.posthog_capture('company_signed_up', new.id, '{}'::jsonb);
  perform public.posthog_capture('$groupidentify', new.id, jsonb_build_object(
    '$group_type', 'company',
    '$group_key', new.id::text,
    '$group_set', jsonb_build_object('name', new.name, 'created_at', new.created_at)
  ));
  return new;
exception when others then
  raise warning 'trigger_posthog_company_signed_up failed: %', sqlerrm;
  return new;
end;
$$;

-- audit_log: the grant / not-granted outcome at signup (the reason is the
-- only detail sent; email_domain deliberately is not).
create or replace function public.trigger_posthog_promo_outcome()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.action = 'promo.granted' then
    perform public.posthog_capture('promo_credit_issued', (new.after ->> 'company_id')::uuid, jsonb_build_object(
      'promotion_id', new.after ->> 'promotion_id',
      'expires_at', new.after ->> 'expires_at'
    ));
  elsif new.action = 'promo.not_granted' then
    perform public.posthog_capture('promo_credit_not_granted', new.target_id, jsonb_build_object(
      'promotion_id', new.after ->> 'promotion_id',
      'reason', new.after ->> 'reason'
    ));
  end if;
  return new;
exception when others then
  raise warning 'trigger_posthog_promo_outcome failed: %', sqlerrm;
  return new;
end;
$$;

-- promotion_grants: redeemed / restored (cancelled order) / expired.
create or replace function public.trigger_posthog_promo_status()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_event text;
begin
  if new.status = old.status then
    return new;
  end if;

  v_event := case
    when new.status = 'redeemed' then 'promo_credit_redeemed'
    when new.status = 'expired' then 'promo_credit_expired'
    when new.status = 'issued' and old.status = 'redeemed' then 'promo_credit_restored'
  end;

  if v_event is not null then
    perform public.posthog_capture(v_event, new.company_id, jsonb_build_object(
      'promotion_id', new.promotion_id,
      'order_id', coalesce(new.redeemed_order_id, old.redeemed_order_id),
      'address_flagged', new.address_flagged,
      'days_since_grant', round(extract(epoch from (now() - new.granted_at)) / 86400.0, 1)
    ));
  end if;
  return new;
exception when others then
  raise warning 'trigger_posthog_promo_status failed: %', sqlerrm;
  return new;
end;
$$;

-- credit_ledger: credit pack purchases only.
create or replace function public.trigger_posthog_credits_purchased()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.transaction_type = 'purchase' then
    perform public.posthog_capture('credits_purchased', new.company_id, jsonb_build_object(
      'kit_type_id', new.kit_type_id,
      'quantity', new.quantity,
      'had_promo_credit', exists (select 1 from public.promotion_grants g where g.company_id = new.company_id)
    ));
  end if;
  return new;
exception when others then
  raise warning 'trigger_posthog_credits_purchased failed: %', sqlerrm;
  return new;
end;
$$;

-- invoices: every paid invoice (order card payments, credit packs, paid
-- cover). `revenue` is in pounds for PostHog revenue analytics.
create or replace function public.trigger_posthog_invoice_paid()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public.posthog_capture('invoice_paid', new.company_id, jsonb_build_object(
    'invoice_id', new.id,
    'revenue', round(new.total_inc_vat_pence / 100.0, 2),
    'currency', 'GBP',
    'had_promo_credit', exists (select 1 from public.promotion_grants g where g.company_id = new.company_id)
  ));
  return new;
exception when others then
  raise warning 'trigger_posthog_invoice_paid failed: %', sqlerrm;
  return new;
end;
$$;

revoke all on function public.trigger_posthog_company_signed_up() from public, anon, authenticated;
revoke all on function public.trigger_posthog_promo_outcome() from public, anon, authenticated;
revoke all on function public.trigger_posthog_promo_status() from public, anon, authenticated;
revoke all on function public.trigger_posthog_credits_purchased() from public, anon, authenticated;
revoke all on function public.trigger_posthog_invoice_paid() from public, anon, authenticated;

create trigger companies_posthog_signed_up
  after insert on public.companies
  for each row execute function public.trigger_posthog_company_signed_up();

create trigger audit_log_posthog_promo_outcome
  after insert on public.audit_log
  for each row
  when (new.action in ('promo.granted', 'promo.not_granted'))
  execute function public.trigger_posthog_promo_outcome();

create trigger promotion_grants_posthog_status
  after update of status on public.promotion_grants
  for each row execute function public.trigger_posthog_promo_status();

create trigger credit_ledger_posthog_purchase
  after insert on public.credit_ledger
  for each row
  when (new.transaction_type = 'purchase')
  execute function public.trigger_posthog_credits_purchased();

create trigger invoices_posthog_paid
  after insert on public.invoices
  for each row execute function public.trigger_posthog_invoice_paid();
