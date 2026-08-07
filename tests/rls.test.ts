// The RLS test suite. Run against a real local Postgres (`supabase start`
// + `supabase db reset`), never mocked — see architecture §9.3.
//
// "If this suite is red, nothing ships."

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import crypto from "node:crypto";
import {
  adminClient,
  clientAsUser,
  createAuthUser,
  createCompany,
  createProfile,
  deleteAuthUserByEmail,
  uniqueEmail,
} from "./helpers";

describe("RLS: public.users — the four required directions (architecture §9.3)", () => {
  let companyA: { id: string };
  let companyB: { id: string };

  const a1Email = uniqueEmail("a1");
  const a2Email = uniqueEmail("a2");
  const bEmail = uniqueEmail("b1");
  const internalEmail = uniqueEmail("staff");
  const noProfileEmail = uniqueEmail("noprofile");

  const allEmails = [a1Email, a2Email, bEmail, internalEmail, noProfileEmail];

  beforeAll(async () => {
    companyA = await createCompany("RLS Test Co A");
    companyB = await createCompany("RLS Test Co B");

    const a1 = await createAuthUser(a1Email);
    const a2 = await createAuthUser(a2Email);
    const b1 = await createAuthUser(bEmail);
    const staff = await createAuthUser(internalEmail);
    await createAuthUser(noProfileEmail); // auth user exists, but no public.users row — no company claim at all

    await createProfile(a1.id, companyA.id, a1Email, "company_admin");
    await createProfile(a2.id, companyA.id, a2Email, "company_member");
    await createProfile(b1.id, companyB.id, bEmail, "company_admin");
    await createProfile(staff.id, null, internalEmail, "internal_ops");
  });

  afterAll(async () => {
    // Delete auth users first — cascades to their public.users row. Only
    // then is it safe to delete the companies (company_id is ON DELETE
    // RESTRICT, deliberately, so a company can't vanish out from under a
    // still-referenced user by accident).
    for (const email of allEmails) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().in("id", [companyA.id, companyB.id]);
  });

  it("✗ isolation: a user in company A cannot read company B's rows", async () => {
    const client = await clientAsUser(a1Email);
    const { data, error } = await client.from("users").select("*").eq("company_id", companyB.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("✓ collaboration: user 2 in company A CAN read user 1's row (and their own)", async () => {
    const client = await clientAsUser(a2Email);
    const { data, error } = await client.from("users").select("email").eq("company_id", companyA.id);
    expect(error).toBeNull();
    const emails = (data ?? []).map((row) => row.email);
    expect(emails).toContain(a1Email);
    expect(emails).toContain(a2Email);
  });

  it("✓ admin override: internal_ops reads across companies", async () => {
    const client = await clientAsUser(internalEmail);
    const { data, error } = await client
      .from("users")
      .select("company_id")
      .in("company_id", [companyA.id, companyB.id]);
    expect(error).toBeNull();
    const seenCompanies = new Set((data ?? []).map((row) => row.company_id));
    expect(seenCompanies.has(companyA.id)).toBe(true);
    expect(seenCompanies.has(companyB.id)).toBe(true);
  });

  it("✗ null-claim guard: a user with no company profile reads zero rows, not every row", async () => {
    const client = await clientAsUser(noProfileEmail);
    const { data, error } = await client.from("users").select("*");
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });
});

describe("RLS: public.invites — isolation and collaboration", () => {
  let companyA: { id: string };
  let companyB: { id: string };
  const adminEmail = uniqueEmail("inv-admin");
  const memberEmail = uniqueEmail("inv-member");
  const otherCompanyEmail = uniqueEmail("inv-other");

  beforeAll(async () => {
    companyA = await createCompany("Invite Test Co A");
    companyB = await createCompany("Invite Test Co B");

    const admin = await createAuthUser(adminEmail);
    const member = await createAuthUser(memberEmail);
    const other = await createAuthUser(otherCompanyEmail);

    await createProfile(admin.id, companyA.id, adminEmail, "company_admin");
    await createProfile(member.id, companyA.id, memberEmail, "company_member");
    await createProfile(other.id, companyB.id, otherCompanyEmail, "company_admin");

    await adminClient.from("invites").insert({
      company_id: companyA.id,
      email: "invitee@example.com",
      role: "company_member",
      token_hash: crypto.randomBytes(16).toString("hex"),
      invited_by: admin.id,
    });
  });

  afterAll(async () => {
    for (const email of [adminEmail, memberEmail, otherCompanyEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().in("id", [companyA.id, companyB.id]);
  });

  it("✓ collaboration: a member in company A can see an invite company A's admin created", async () => {
    const client = await clientAsUser(memberEmail);
    const { data, error } = await client.from("invites").select("*").eq("company_id", companyA.id);
    expect(error).toBeNull();
    expect((data ?? []).length).toBeGreaterThan(0);
  });

  it("✗ isolation: a user in company B cannot see company A's invites", async () => {
    const client = await clientAsUser(otherCompanyEmail);
    const { data, error } = await client.from("invites").select("*").eq("company_id", companyA.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });
});

describe("Database constraints reject bad data (architecture §9.7)", () => {
  it("rejects an invalid companies.status value", async () => {
    const company = await createCompany("Enum Test Co");
    const { error } = await adminClient
      .from("companies")
      .update({ status: "not_a_real_status" })
      .eq("id", company.id);
    expect(error).not.toBeNull();
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("rejects a users row referencing an unknown role", async () => {
    const company = await createCompany("Role Test Co");
    const authUser = await createAuthUser(uniqueEmail("badrole"));
    const { error } = await adminClient.from("users").insert({
      id: authUser.id,
      company_id: company.id,
      email: authUser.email,
      role: "super_admin_hacker",
    });
    expect(error).not.toBeNull();
    await deleteAuthUserByEmail(authUser.email!);
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("rejects a company-scoped role with no company_id", async () => {
    const authUser = await createAuthUser(uniqueEmail("orphan"));
    const { error } = await adminClient.from("users").insert({
      id: authUser.id,
      company_id: null,
      email: authUser.email,
      role: "company_admin",
    });
    expect(error).not.toBeNull();
    await deleteAuthUserByEmail(authUser.email!);
  });

  it("rejects an internal role that has a company_id", async () => {
    const company = await createCompany("Internal Scope Test Co");
    const authUser = await createAuthUser(uniqueEmail("badinternal"));
    const { error } = await adminClient.from("users").insert({
      id: authUser.id,
      company_id: company.id,
      email: authUser.email,
      role: "internal_ops",
    });
    expect(error).not.toBeNull();
    await deleteAuthUserByEmail(authUser.email!);
    await adminClient.from("companies").delete().eq("id", company.id);
  });
});

describe("RLS: public.addresses — isolation and collaboration", () => {
  let companyA: { id: string };
  let companyB: { id: string };
  const a1Email = uniqueEmail("addr-a1");
  const a2Email = uniqueEmail("addr-a2");
  const bEmail = uniqueEmail("addr-b1");
  let addressA: { id: string };

  beforeAll(async () => {
    companyA = await createCompany("Address Test Co A");
    companyB = await createCompany("Address Test Co B");

    const a1 = await createAuthUser(a1Email);
    const a2 = await createAuthUser(a2Email);
    const b1 = await createAuthUser(bEmail);

    await createProfile(a1.id, companyA.id, a1Email, "company_admin");
    await createProfile(a2.id, companyA.id, a2Email, "company_member");
    await createProfile(b1.id, companyB.id, bEmail, "company_admin");

    const { data, error } = await adminClient
      .from("addresses")
      .insert({
        company_id: companyA.id,
        label: "Warehouse",
        address_line1: "1 Test Street",
        city: "London",
        postcode: "E1 6AN",
      })
      .select()
      .single();
    if (error) throw error;
    addressA = data as { id: string };
  });

  afterAll(async () => {
    for (const email of [a1Email, a2Email, bEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().in("id", [companyA.id, companyB.id]);
  });

  it("✓ collaboration: a colleague in the same company can see the address", async () => {
    const client = await clientAsUser(a2Email);
    const { data, error } = await client.from("addresses").select("*").eq("id", addressA.id);
    expect(error).toBeNull();
    expect(data?.length).toBe(1);
  });

  it("✗ isolation: a user in company B cannot see company A's address", async () => {
    const client = await clientAsUser(bEmail);
    const { data, error } = await client.from("addresses").select("*").eq("id", addressA.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("a company_member can insert an address scoped to their own company", async () => {
    const client = await clientAsUser(a2Email);
    const { data, error } = await client
      .from("addresses")
      .insert({ company_id: companyA.id, label: "IT Office", address_line1: "2 Test Street", city: "London", postcode: "E1 6AN" })
      .select()
      .single();
    expect(error).toBeNull();
    expect(data?.company_id).toBe(companyA.id);
  });

  it("✗ cannot insert an address for a different company", async () => {
    const client = await clientAsUser(a2Email);
    const { error } = await client
      .from("addresses")
      .insert({ company_id: companyB.id, label: "Sneaky", address_line1: "3 Test Street", city: "London", postcode: "E1 6AN" });
    expect(error).not.toBeNull();
  });
});

describe("RLS: public.employees — isolation and collaboration", () => {
  let companyA: { id: string };
  let companyB: { id: string };
  const a1Email = uniqueEmail("emp-a1");
  const a2Email = uniqueEmail("emp-a2");
  const bEmail = uniqueEmail("emp-b1");
  let employeeA: { id: string };

  beforeAll(async () => {
    companyA = await createCompany("Employee Test Co A");
    companyB = await createCompany("Employee Test Co B");

    const a1 = await createAuthUser(a1Email);
    const a2 = await createAuthUser(a2Email);
    const b1 = await createAuthUser(bEmail);

    await createProfile(a1.id, companyA.id, a1Email, "company_admin");
    await createProfile(a2.id, companyA.id, a2Email, "company_member");
    await createProfile(b1.id, companyB.id, bEmail, "company_admin");

    const { data, error } = await adminClient
      .from("employees")
      .insert({ company_id: companyA.id, full_name: "Alex Leaver", email: "alex@example.com" })
      .select()
      .single();
    if (error) throw error;
    employeeA = data as { id: string };
  });

  afterAll(async () => {
    for (const email of [a1Email, a2Email, bEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().in("id", [companyA.id, companyB.id]);
  });

  it("✓ collaboration: a colleague in the same company can see the employee", async () => {
    const client = await clientAsUser(a2Email);
    const { data, error } = await client.from("employees").select("*").eq("id", employeeA.id);
    expect(error).toBeNull();
    expect(data?.length).toBe(1);
  });

  it("✗ isolation: a user in company B cannot see company A's employee", async () => {
    const client = await clientAsUser(bEmail);
    const { data, error } = await client.from("employees").select("*").eq("id", employeeA.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });
});

describe("RLS: public.orders — isolation, collaboration, and create_order()", () => {
  let companyA: { id: string };
  let companyB: { id: string };
  const a1Email = uniqueEmail("ord-a1");
  const a2Email = uniqueEmail("ord-a2");
  const bEmail = uniqueEmail("ord-b1");
  let employeeA: { id: string };
  let orderAId: string;
  let orderAReference: string;

  beforeAll(async () => {
    companyA = await createCompany("Order Test Co A");
    companyB = await createCompany("Order Test Co B");

    const a1 = await createAuthUser(a1Email);
    const a2 = await createAuthUser(a2Email);
    const b1 = await createAuthUser(bEmail);

    await createProfile(a1.id, companyA.id, a1Email, "company_admin");
    await createProfile(a2.id, companyA.id, a2Email, "company_member");
    await createProfile(b1.id, companyB.id, bEmail, "company_admin");

    const { data: emp, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: companyA.id, full_name: "Jo Joiner", email: "jo@example.com" })
      .select()
      .single();
    if (empError) throw empError;
    employeeA = emp as { id: string };

    const client = await clientAsUser(a1Email);
    const { data: orderId, error: rpcError } = await client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employeeA.id,
    });
    if (rpcError) throw rpcError;
    orderAId = orderId as string;

    const { data: orderRow, error: readError } = await adminClient
      .from("orders")
      .select("reference")
      .eq("id", orderAId)
      .single();
    if (readError) throw readError;
    orderAReference = orderRow!.reference;
  });

  afterAll(async () => {
    // orders.created_by references users(id) with no cascade (deliberately —
    // an order shouldn't silently lose its creator), so every order placed
    // in this block must be deleted before the placing user, same ordering
    // constraint as users-before-companies elsewhere in this file.
    await adminClient.from("orders").delete().eq("company_id", companyA.id);
    for (const email of [a1Email, a2Email, bEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().in("id", [companyA.id, companyB.id]);
  });

  it("issues a well-formed, immutable reference (RKL-YYMMDD-NNN)", () => {
    expect(orderAReference).toMatch(/^RKL-\d{6}-\d{3,}$/);
  });

  it("✓ collaboration: user 2 in company A CAN see the order user 1 placed", async () => {
    const client = await clientAsUser(a2Email);
    const { data, error } = await client.from("orders").select("id, reference").eq("id", orderAId);
    expect(error).toBeNull();
    expect(data?.length).toBe(1);
    expect(data?.[0].reference).toBe(orderAReference);
  });

  it("✗ isolation: a user in company B cannot see company A's order", async () => {
    const client = await clientAsUser(bEmail);
    const { data, error } = await client.from("orders").select("*").eq("id", orderAId);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("✗ orders cannot be created without company_id: a profile-less user is refused", async () => {
    const noProfileEmail = uniqueEmail("ord-noprofile");
    await createAuthUser(noProfileEmail);
    const client = await clientAsUser(noProfileEmail);
    const { error } = await client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employeeA.id,
    });
    expect(error).not.toBeNull();
    await deleteAuthUserByEmail(noProfileEmail);
  });

  it("the reference is immutable once issued — even a direct update is rejected", async () => {
    const { error } = await adminClient.from("orders").update({ reference: "RKL-260807-999" }).eq("id", orderAId);
    expect(error).not.toBeNull();
  });

  it("✗ database constraint: a 'return' order with no return_address_id is rejected", async () => {
    const client = await clientAsUser(a1Email);
    const { error } = await client.rpc("create_order", {
      p_kit_type_id: "phone",
      p_service_type: "return",
      p_employee_id: employeeA.id,
    });
    expect(error).not.toBeNull();
  });

  it("two concurrent create_order() calls for the same kit type get different references (architecture §21)", async () => {
    const client = await clientAsUser(a1Email);
    const [first, second] = await Promise.all([
      client.rpc("create_order", {
        p_kit_type_id: "monitor",
        p_service_type: "ship_to_new_employee",
        p_employee_id: employeeA.id,
      }),
      client.rpc("create_order", {
        p_kit_type_id: "monitor",
        p_service_type: "ship_to_new_employee",
        p_employee_id: employeeA.id,
      }),
    ]);
    expect(first.error).toBeNull();
    expect(second.error).toBeNull();

    const { data: rows, error } = await adminClient
      .from("orders")
      .select("reference")
      .in("id", [first.data as string, second.data as string]);
    expect(error).toBeNull();
    const refs = (rows ?? []).map((r) => r.reference);
    expect(refs.length).toBe(2);
    expect(new Set(refs).size).toBe(2);
  });
});

describe("accept_invite() is race-safe (Base44 gotcha: atomic claim)", () => {
  it("two concurrent accepts of the same invite grant exactly one user row", async () => {
    const company = await createCompany("Race Test Co");
    const admin = await createAuthUser(uniqueEmail("race-admin"));
    await createProfile(admin.id, company.id, admin.email!, "company_admin");

    const rawToken = crypto.randomBytes(24).toString("hex");
    const tokenHash = crypto.createHash("sha256").update(rawToken).digest("hex");

    await adminClient.from("invites").insert({
      company_id: company.id,
      email: "racer@example.com",
      role: "company_member",
      token_hash: tokenHash,
      invited_by: admin.id,
    });

    const racerEmail = uniqueEmail("racer");
    await createAuthUser(racerEmail);
    const racerClient = await clientAsUser(racerEmail);

    const [first, second] = await Promise.all([
      racerClient.rpc("accept_invite", { invite_token: rawToken }),
      racerClient.rpc("accept_invite", { invite_token: rawToken }),
    ]);

    const successes = [first, second].filter((r) => r.error === null);
    const failures = [first, second].filter((r) => r.error !== null);
    expect(successes.length).toBe(1);
    expect(failures.length).toBe(1);

    const { data: profileRows } = await adminClient.from("users").select("id").eq("email", racerEmail);
    expect(profileRows?.length).toBe(1);

    await deleteAuthUserByEmail(admin.email!);
    await deleteAuthUserByEmail(racerEmail);
    await adminClient.from("companies").delete().eq("id", company.id);
  });
});
