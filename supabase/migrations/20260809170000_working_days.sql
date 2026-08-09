-- ============================================================================
-- Phase 5: UK bank holidays + working-day / sending-hours helpers.
--
-- Architecture §21/§9: escalation and nudge thresholds count working days,
-- excluding weekends AND UK bank holidays -- "chase after 5 days" meaning
-- calendar days will fire over a bank holiday weekend and annoy people.
-- Nudges must also respect sending hours (08:00-18:00 Europe/London) rather
-- than firing whenever cron happens to run.
--
-- This is the first place in the codebase that actually needs this logic
-- (dispatch SLA is a locked decision but Phase 2-4 never had to compute a
-- working-day offset in code -- CLAUDE.md: "do not build ahead"). Built now
-- because the Phase 5 check-in cron job is the first real consumer.
--
-- Jurisdiction: England & Wales bank holidays (gov.uk's default calendar).
-- Not specified in the architecture doc; documented here as an assumption
-- rather than silently picked -- flag to the user if the business needs
-- Scotland/NI holidays instead (different Easter Monday/Boxing Day rules).
-- ============================================================================

create table public.uk_bank_holidays (
  holiday_date date primary key,
  name text not null
);

comment on table public.uk_bank_holidays is
  'England & Wales bank holidays. Seeded manually per calendar year -- there is no reliable long-term calculation for these (Spring/Summer bank holidays are fixed by government announcement, not a formula) so this needs a fresh INSERT batch each year. See gov.uk/bank-holidays.';

-- RLS: internal reference data, not tenant-scoped. Readable by any
-- authenticated user (needed if the portal UI ever wants to show "next
-- working day" client-side), never writable by anon/authenticated.
alter table public.uk_bank_holidays enable row level security;

create policy uk_bank_holidays_select_all
  on public.uk_bank_holidays for select
  to authenticated
  using (true);

insert into public.uk_bank_holidays (holiday_date, name) values
  -- Remainder of 2026
  ('2026-08-31', 'Summer bank holiday'),
  ('2026-12-25', 'Christmas Day'),
  ('2026-12-28', 'Boxing Day (substitute day)'),
  -- 2027
  ('2027-01-01', 'New Year''s Day'),
  ('2027-03-26', 'Good Friday'),
  ('2027-03-29', 'Easter Monday'),
  ('2027-05-03', 'Early May bank holiday'),
  ('2027-05-31', 'Spring bank holiday'),
  ('2027-08-30', 'Summer bank holiday'),
  ('2027-12-27', 'Christmas Day (substitute day)'),
  ('2027-12-28', 'Boxing Day (substitute day)')
on conflict (holiday_date) do nothing;

-- ---- Working-day helpers ---------------------------------------------

create or replace function public.is_uk_working_day(p_date date)
returns boolean
language sql
stable
set search_path = public
as $$
  select extract(isodow from p_date) < 6  -- 1=Mon .. 7=Sun; exclude Sat(6)/Sun(7)
    and not exists (select 1 from public.uk_bank_holidays where holiday_date = p_date);
$$;

comment on function public.is_uk_working_day(date) is
  'True for Mon-Fri that are not a seeded UK bank holiday. Returns false (not an error) past the seeded holiday range -- that is a data-freshness bug, not a runtime failure, and should surface via the yearly reseed process rather than breaking dispatch/nudge calculations.';

create or replace function public.add_working_days(p_start date, p_n int)
returns date
language plpgsql
stable
set search_path = public
as $$
declare
  v_date date := p_start;
  v_remaining int := p_n;
begin
  if p_n < 0 then
    raise exception 'add_working_days: negative n (%) not supported', p_n;
  end if;
  while v_remaining > 0 loop
    v_date := v_date + 1;
    if public.is_uk_working_day(v_date) then
      v_remaining := v_remaining - 1;
    end if;
  end loop;
  return v_date;
end;
$$;

comment on function public.add_working_days(date, int) is
  'Adds n working days to p_start, skipping weekends and UK bank holidays. add_working_days(d, 1) = "next working day after d" (never returns p_start itself, even if p_start is a working day) -- matches "dispatched within 1 working day of order" (architecture §21): a Monday order dispatches Tuesday, not Monday.';

create or replace function public.next_working_day(p_date date)
returns date
language sql
stable
set search_path = public
as $$
  select case when public.is_uk_working_day(p_date) then p_date else public.add_working_days(p_date, 1) end;
$$;

comment on function public.next_working_day(date) is
  'Smallest working day >= p_date. Unlike add_working_days(d, 1), returns p_date itself if it is already a working day.';

-- ---- Sending-hours window ----------------------------------------------

create or replace function public.within_sending_hours(p_ts timestamptz)
returns boolean
language sql
stable
set search_path = public
as $$
  select public.is_uk_working_day((p_ts at time zone 'Europe/London')::date)
    and (p_ts at time zone 'Europe/London')::time >= time '08:00'
    and (p_ts at time zone 'Europe/London')::time < time '18:00';
$$;

comment on function public.within_sending_hours(timestamptz) is
  'True if p_ts falls on a UK working day between 08:00 and 18:00 Europe/London (architecture §21 sending-hours window). Used to gate the check-in cron job so nudges never fire at 3am or on a bank holiday.';
