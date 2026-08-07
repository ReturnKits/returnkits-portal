-- ============================================================================
-- Phase 1 fix: accept_invite() calls digest() (from pgcrypto) but its
-- search_path was `public` only. Supabase installs pgcrypto into the
-- `extensions` schema by convention, not `public`, so digest() was
-- unresolvable — both concurrent calls in the race test failed identically
-- with a function-not-found error rather than exercising the actual race.
-- ============================================================================

create or replace function public.accept_invite(invite_token text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  matched_invite public.invites;
  caller_id uuid := auth.uid();
  caller_email text;
begin
  if caller_id is null then
    raise exception 'Must be authenticated';
  end if;

  if exists (select 1 from public.users where id = caller_id) then
    raise exception 'User already belongs to a company';
  end if;

  select email into caller_email from auth.users where id = caller_id;

  update public.invites
  set accepted_at = now()
  where token_hash = encode(digest(invite_token, 'sha256'), 'hex')
    and revoked = false
    and accepted_at is null
    and expires_at > now()
  returning * into matched_invite;

  if matched_invite is null then
    raise exception 'Invite is invalid, expired, or already used';
  end if;

  insert into public.users (id, company_id, email, role, status)
  values (caller_id, matched_invite.company_id, caller_email, matched_invite.role, 'active');

  perform public.log_audit(caller_id, 'invite.accept', 'invites', matched_invite.id, null,
    jsonb_build_object('company_id', matched_invite.company_id, 'role', matched_invite.role));

  return matched_invite.company_id;
end;
$$;
