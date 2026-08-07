// Test helpers for the RLS suite. Uses a real Supabase Auth flow (magic-link
// generation + OTP verification) to get genuine per-user JWTs, so these
// tests exercise the custom_access_token_hook too, not just the RLS
// policies in isolation. See docs/returnkits-portal-architecture.md §9.3.
//
// Requires a running local Supabase stack (`supabase start`) and the local
// project's URL/keys in env — see .env.test.local.example.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const SUPABASE_URL = process.env.SUPABASE_URL ?? "http://127.0.0.1:54321";
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const ANON_KEY = process.env.SUPABASE_ANON_KEY;

if (!SERVICE_ROLE_KEY || !ANON_KEY) {
  throw new Error(
    "SUPABASE_SERVICE_ROLE_KEY and SUPABASE_ANON_KEY must be set to run the RLS suite. " +
      "Run `npx supabase status` (with the local stack running) and copy the values into " +
      ".env.test.local — see .env.test.local.example."
  );
}

// Bypasses RLS entirely — used only to arrange test fixtures, never to
// assert anything about access control itself.
export const adminClient: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

export async function createCompany(name: string) {
  const { data, error } = await adminClient.from("companies").insert({ name }).select().single();
  if (error) throw error;
  return data as { id: string; name: string };
}

export async function createAuthUser(email: string) {
  const { data, error } = await adminClient.auth.admin.createUser({
    email,
    email_confirm: true,
  });
  if (error) throw error;
  return data.user!;
}

export async function createProfile(id: string, companyId: string | null, email: string, role: string) {
  const { error } = await adminClient.from("users").insert({ id, company_id: companyId, email, role });
  if (error) throw error;
}

export async function deleteAuthUserByEmail(email: string) {
  // listUsers is paginated; test fixtures are few enough that one page is fine.
  const { data, error } = await adminClient.auth.admin.listUsers();
  if (error) throw error;
  const match = data.users.find((u) => u.email === email);
  if (match) await adminClient.auth.admin.deleteUser(match.id);
}

// Returns a Supabase client authenticated as `email`, via a real magic-link
// verify — this is what makes the custom access token hook actually run.
export async function clientAsUser(email: string): Promise<SupabaseClient> {
  const { data: linkData, error: linkError } = await adminClient.auth.admin.generateLink({
    type: "magiclink",
    email,
  });
  if (linkError) throw linkError;

  const client = createClient(SUPABASE_URL, ANON_KEY!, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { error: verifyError } = await client.auth.verifyOtp({
    token_hash: linkData.properties.hashed_token,
    type: "magiclink",
  });
  if (verifyError) throw verifyError;

  return client;
}

export function uniqueEmail(label: string) {
  return `${label}-${Date.now()}-${Math.floor(Math.random() * 1e6)}@test.returnkits.invalid`;
}
