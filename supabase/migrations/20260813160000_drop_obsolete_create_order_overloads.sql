-- Fix: PGRST203 "Could not choose the best candidate function" on create_order
-- and create_internal_order.
--
-- Root cause: `create or replace function` only replaces an existing function
-- when the new definition has the EXACT SAME parameter list (types, in
-- order). Every migration that extended create_order()/create_internal_order()
-- with new optional parameters -- enhanced_cover_schema_and_rpcs.sql,
-- credits_schema_and_rpcs.sql, notify_employee_order_flag.sql,
-- manual_employee_entry_on_order.sql -- silently CREATED A NEW OVERLOAD
-- alongside the previous version instead of replacing it, because Postgres
-- treats a different arg list as a different function identity. None of
-- those migrations ever DROPped the version they were superseding.
--
-- The result: five coexisting overloads of create_order (9, 10, 11, 12, and
-- 19 params) and four of create_internal_order (11, 12, 13, and 21 params)
-- all live in the schema simultaneously. PostgREST resolves an RPC call by
-- matching the JSON body's named keys against candidate function signatures;
-- when a caller supplies only the older, common subset of parameters (every
-- extra param in every overload has a default), MULTIPLE overloads match
-- equally well and PostgREST can't pick one -- hence PGRST203. This wasn't
-- caught until a genuinely clean db-reset test run exercised every call
-- shape (many test fixtures and Lovable's own older cached RPC calls only
-- ever pass the "classic" param subset).
--
-- Fix: drop every obsolete overload by its exact historical signature,
-- leaving only the current 19-param create_order and 21-param
-- create_internal_order (as defined in manual_employee_entry_on_order.sql,
-- the migration immediately before this one) in place. No new function
-- bodies are (re)created here -- the survivors already exist correctly.

-- create_order: drop the four superseded overloads (9, 10, 11, 12 params).
drop function if exists public.create_order(
  text, text, uuid, uuid, text, date, date, uuid, text
);
drop function if exists public.create_order(
  text, text, uuid, uuid, text, date, date, uuid, text, text
);
drop function if exists public.create_order(
  text, text, uuid, uuid, text, date, date, uuid, text, text, boolean
);
drop function if exists public.create_order(
  text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean
);

-- create_internal_order: drop the four superseded overloads (11, 12, 13, 14 params).
drop function if exists public.create_internal_order(
  uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text
);
drop function if exists public.create_internal_order(
  uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text, text
);
drop function if exists public.create_internal_order(
  uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text, text, boolean
);
drop function if exists public.create_internal_order(
  uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean
);
