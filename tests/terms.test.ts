// Terms of Service acceptance at company setup (20261105). See
// supabase/migrations/20261105120000_terms_acceptance_at_signup.sql.
//
// Signs up through the real create_company_and_admin() RPC with a real
// session, the same way the portal's "Create your company" step does.

import { afterAll, describe, expect, it } from "vitest";
import crypto from "node:crypto";
import { adminClient, anonClient, clientAsUser, createAuthUser, deleteAuthUserByEmail } from "./helpers";

const emails: string[] = [];
const companyIds: string[] = [];

async function signUp(args: Record<string, unknown>) {
  const email = `terms-${crypto.randomUUID().slice(0, 8)}@terms-${crypto.randomUUID().slice(0, 8)}.co.uk`;
  emails.push(email);
  const user = await createAuthUser(email);
  const client = await clientAsUser(email);
  const { data: companyId, error } = await client.rpc("create_company_and_admin", {
    company_name: "Terms Test Co",
    ...args,
  });
  if (error) throw error;
  companyIds.push(companyId as string);
  const { data: company, error: readError } = await adminClient
    .from("companies")
    .select("terms_accepted_at, terms_accepted_by, terms_version")
    .eq("id", companyId)
    .single();
  if (readError) throw readError;
  return { userId: user.id as string, companyId: companyId as string, company };
}

afterAll(async () => {
  if (companyIds.length) {
    await adminClient.from("promotion_grants").delete().in("company_id", companyIds);
    await adminClient.from("credit_ledger").delete().in("company_id", companyIds);
  }
  for (const email of emails) {
    await deleteAuthUserByEmail(email);
  }
});

describe("terms acceptance at company setup", () => {
  it("records who accepted, when and which version", async () => {
    const before = Date.now();
    const { userId, company } = await signUp({ terms_version: "2026-11" });
    expect(company.terms_version).toBe("2026-11");
    expect(company.terms_accepted_by).toBe(userId);
    expect(new Date(company.terms_accepted_at).getTime()).toBeGreaterThanOrEqual(before - 60_000);
  });

  it("writes the terms version to the audit log", async () => {
    const { companyId } = await signUp({ terms_version: "2026-11" });
    const { data, error } = await adminClient
      .from("audit_log")
      .select("action, after")
      .eq("target_id", companyId)
      .eq("action", "company.create_self_serve")
      .single();
    expect(error).toBeNull();
    expect(data?.after?.terms_version).toBe("2026-11");
  });

  it("still creates the company without a terms version (portal tab opened before the change)", async () => {
    const { company } = await signUp({});
    expect(company.terms_version).toBeNull();
    expect(company.terms_accepted_at).toBeNull();
    expect(company.terms_accepted_by).toBeNull();
  });

  it("treats a blank terms version as not accepted", async () => {
    const { company } = await signUp({ terms_version: "   " });
    expect(company.terms_accepted_at).toBeNull();
  });

  it("anon cannot call it", async () => {
    const { error } = await anonClient.rpc("create_company_and_admin", {
      company_name: "Anon Co",
      terms_version: "2026-11",
    });
    expect(error).not.toBeNull();
  });

  it("leaves no leaked grants", async () => {
    const { data, error } = await adminClient.from("internal_function_grant_leaks").select("*");
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });
});
