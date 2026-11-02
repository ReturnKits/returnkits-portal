-- Free first laptop return: remove the 20-company cap (user decision
-- 20261102, same day as 20261102120000_signup_promo_free_laptop_return.sql).
-- Every qualifying signup now gets the credit, still valid 60 days. The
-- other safeguards are unchanged: verified work email, one per company,
-- one per email domain, admin on/off switch.
--
-- promotions.max_grants becomes nullable, NULL meaning "no cap", rather
-- than being set to an arbitrary large number -- the cap logic stays in
-- place so a limit can be reintroduced later with a plain UPDATE.

alter table public.promotions alter column max_grants drop not null;

update public.promotions set max_grants = null, updated_at = now() where id = 'first_laptop_free';

create or replace function public.grant_signup_promo(p_company_id uuid, p_user_id uuid)
returns text
language plpgsql
set search_path to 'public'
as $$
declare
  v_promo public.promotions%rowtype;
  v_email text;
  v_confirmed timestamptz;
  v_domain text;
  v_issued integer;
  v_expires timestamptz;
  v_ledger_id uuid;
  v_grant_id uuid;
  v_reason text;
begin
  -- Row lock serialises every concurrent signup's claim, so the cap, the
  -- per-company rule and the per-domain rule can't be raced. The unique
  -- constraints on promotion_grants are the backstop.
  select * into v_promo from public.promotions where id = 'first_laptop_free' for update;

  if not found or not v_promo.enabled then
    v_reason := 'promotion_disabled';
  else
    select email, email_confirmed_at into v_email, v_confirmed
    from auth.users where id = p_user_id;

    v_domain := lower(split_part(coalesce(v_email, ''), '@', 2));

    if v_confirmed is null then
      v_reason := 'email_not_verified';
    elsif v_domain = '' then
      v_reason := 'no_email_domain';
    elsif exists (select 1 from public.blocked_email_domains where domain = v_domain) then
      v_reason := 'not_a_work_email';
    elsif exists (select 1 from public.promotion_grants where promotion_id = v_promo.id and company_id = p_company_id) then
      v_reason := 'already_granted';
    elsif exists (select 1 from public.promotion_grants where promotion_id = v_promo.id and email_domain = v_domain) then
      v_reason := 'email_domain_already_claimed';
    elsif v_promo.max_grants is not null then
      select count(*) into v_issued from public.promotion_grants where promotion_id = v_promo.id;
      if v_issued >= v_promo.max_grants then
        v_reason := 'promotion_cap_reached';
      end if;
    end if;
  end if;

  if v_reason is not null then
    perform public.log_audit(p_user_id, 'promo.not_granted', 'companies', p_company_id, null,
      jsonb_build_object('promotion_id', 'first_laptop_free', 'reason', v_reason, 'email_domain', v_domain));
    return v_reason;
  end if;

  v_expires := now() + make_interval(days => v_promo.validity_days);

  insert into public.credit_ledger (
    company_id, kit_type_id, transaction_type, direction, quantity,
    balance_after, actor_id, reason, promotion_id, expires_at
  ) values (
    p_company_id, v_promo.kit_type_id, 'adjustment', 'credit', 1,
    1, p_user_id, 'Free first laptop return (sign-up offer)', v_promo.id, v_expires
  )
  returning id into v_ledger_id;

  insert into public.promotion_grants (promotion_id, company_id, email_domain, expires_at, grant_ledger_id)
  values (v_promo.id, p_company_id, v_domain, v_expires, v_ledger_id)
  returning id into v_grant_id;

  perform public.log_audit(p_user_id, 'promo.granted', 'promotion_grants', v_grant_id, null,
    jsonb_build_object('promotion_id', v_promo.id, 'company_id', p_company_id,
                       'email_domain', v_domain, 'expires_at', v_expires));

  return 'granted';
end;
$$;

revoke all on function public.grant_signup_promo(uuid, uuid) from public, anon, authenticated;
