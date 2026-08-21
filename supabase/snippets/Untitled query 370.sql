-- who owns the companies table (i.e. which role ran the migration that created it)
select tableowner from pg_tables where tablename = 'companies';

-- what default-privilege rules actually exist, and for which role
select
  defaclrole::regrole as applies_to_role_that_creates_objects,
  defaclnamespace::regnamespace as schema,
  defaclobjtype as object_type,   -- r = table, f = function
  defaclacl
from pg_default_acl;
