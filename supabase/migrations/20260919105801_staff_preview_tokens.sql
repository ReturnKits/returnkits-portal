-- Signed, short-lived, single-purpose links staff can generate to preview
-- exactly what a company sees in the real Lovable portal, read-only, with
-- no customer login ever created. Direct follow-on from the Retool "View
-- as" feature (see CLAUDE.md, 20260919): that page recreates the same data
-- inside Retool's own UI; this table backs a second, narrower mechanism
-- that renders the data inside the ACTUAL portal's design, reached via a
-- real portal URL, for when staff need to show/see it exactly as the
-- customer would. Deliberately NOT a real Supabase Auth session for that
-- company -- the only thing that grants access is possession of the
-- unguessable token, which expires in 1 hour and can be looked up/revoked
-- independently of any customer's own login state.

create table public.staff_preview_tokens (
  id uuid primary key default gen_random_uuid(),
  token text not null unique,
  company_id uuid not null references public.companies(id),
  created_by uuid not null references public.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_used_at timestamptz
);

create index staff_preview_tokens_token_idx on public.staff_preview_tokens (token);
create index staff_preview_tokens_company_id_idx on public.staff_preview_tokens (company_id);

-- Same fully-hardened shape as sendcloud_carrier_map / sendcloud_poll_status_map:
-- RLS enabled with zero policies (unreachable via PostgREST regardless of
-- grants), plus an explicit revoke/grant so only service_role can touch it
-- directly. The token itself is the only real credential -- this table is
-- never queried by anything holding just the anon/authenticated key.
alter table public.staff_preview_tokens enable row level security;

revoke all on public.staff_preview_tokens from public, anon, authenticated;
grant select, insert, update on public.staff_preview_tokens to service_role;

-- Staff-only, service_role-gated RPC that mints a token. Mirrors
-- archive_order()'s exact hardening shape (service_role-only body check +
-- assert_internal_actor + log_audit), read directly from pg_get_functiondef
-- before writing this one, per this project's own standing discipline of
-- copying a live, already-hardened function rather than free-handing a new
-- staff-only RPC's auth shape.
create or replace function public.create_staff_preview_token(p_company_id uuid, p_actor_id uuid)
returns table(token text, expires_at timestamptz)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_token text;
  v_expires_at timestamptz;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'create_staff_preview_token can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  if not exists (select 1 from public.companies where id = p_company_id) then
    raise exception 'Company % not found', p_company_id;
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_expires_at := now() + interval '1 hour';

  insert into public.staff_preview_tokens (token, company_id, created_by, expires_at)
  values (v_token, p_company_id, p_actor_id, v_expires_at);

  perform public.log_audit(
    p_actor_id, 'company.staff_preview_link_created', 'companies', p_company_id,
    null, jsonb_build_object('expires_at', v_expires_at)
  );

  return query select v_token, v_expires_at;
end;
$function$;

revoke all on function public.create_staff_preview_token(uuid, uuid) from public, anon, authenticated;
grant execute on function public.create_staff_preview_token(uuid, uuid) to service_role;
