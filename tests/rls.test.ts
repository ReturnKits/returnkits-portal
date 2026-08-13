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

  it("✓ self-read: a user can read their own row even on a JWT issued before their profile existed", async () => {
    // Reproduces a real bug: create_company_and_admin() creates the profile,
    // but the onboarding flow's "do I have a company yet?" check
    // (select id from users where id = auth.uid()) runs on whatever session
    // is already live in the browser. Before this fix, users_select relied
    // entirely on company_id = current_company() -- which reads the
    // company_id JWT claim -- so a session that authenticated before the
    // profile existed (claim: null) could never see its own freshly-created
    // row without an explicit token refresh, sending users back to the
    // company-creation form in a loop even though their company existed.
    const email = uniqueEmail("self-read");
    const user = await createAuthUser(email);

    // Get a client session BEFORE any public.users row exists for this
    // user -- the custom access token hook has nothing to inject yet, so
    // this JWT's company_id claim is null, same as noProfileEmail above.
    const client = await clientAsUser(email);

    // Now create the profile out-of-band (mirrors what
    // create_company_and_admin does), without the client refreshing its
    // token or re-authenticating.
    const company = await createCompany("Self-Read Test Co");
    await createProfile(user.id, company.id, email, "company_admin");

    try {
      const { data, error } = await client.from("users").select("id").eq("id", user.id).maybeSingle();
      expect(error).toBeNull();
      expect(data?.id).toBe(user.id);
    } finally {
      await deleteAuthUserByEmail(email);
      await adminClient.from("companies").delete().eq("id", company.id);
    }
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

  it("✓ set_company_id_from_session trigger: company_id is set server-side even if omitted (Phase 3 bug fix)", async () => {
    // Fixes "No company on your session yet" — the client no longer needs
    // to know/send its own company_id at all. Using `as never` because the
    // generated types still mark company_id required; the DB doesn't.
    const client = await clientAsUser(a2Email);
    const { data, error } = await client
      .from("addresses")
      .insert({ label: "No company_id sent", address_line1: "4 Test Street", city: "London", postcode: "E1 6AN" } as never)
      .select()
      .single();
    expect(error).toBeNull();
    expect(data?.company_id).toBe(companyA.id);
  });

  it("✓ a client-supplied company_id for a DIFFERENT company is silently overridden, not merely rejected", async () => {
    // Stronger than the old behaviour (which just made the WITH CHECK
    // policy reject a mismatched company_id): now there's no value the
    // client could send that results in a cross-tenant row at all — the
    // trigger fires before the RLS check ever sees the client's input.
    const client = await clientAsUser(a2Email);
    const { data, error } = await client
      .from("addresses")
      .insert({ company_id: companyB.id, label: "Sneaky", address_line1: "3 Test Street", city: "London", postcode: "E1 6AN" })
      .select()
      .single();
    expect(error).toBeNull();
    expect(data?.company_id).toBe(companyA.id);
    expect(data?.company_id).not.toBe(companyB.id);
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

  it("✓ set_company_id_from_session trigger: company_id is set server-side even if omitted (Phase 3 bug fix)", async () => {
    const client = await clientAsUser(a2Email);
    const { data, error } = await client
      .from("employees")
      .insert({ full_name: "No company_id sent" } as never)
      .select()
      .single();
    expect(error).toBeNull();
    expect(data?.company_id).toBe(companyA.id);
  });

  it("✓ a client-supplied company_id for a DIFFERENT company is silently overridden, not merely rejected", async () => {
    const client = await clientAsUser(a2Email);
    const { data, error } = await client
      .from("employees")
      .insert({ company_id: companyB.id, full_name: "Sneaky" })
      .select()
      .single();
    expect(error).toBeNull();
    expect(data?.company_id).toBe(companyA.id);
    expect(data?.company_id).not.toBe(companyB.id);
  });

  it("✗ the trigger refuses a profile-less user with its own clear error", async () => {
    const noProfileEmail = uniqueEmail("emp-noprofile");
    await createAuthUser(noProfileEmail);
    const client = await clientAsUser(noProfileEmail);
    const { error } = await client.from("employees").insert({ full_name: "Orphan" } as never);
    expect(error).not.toBeNull();
    expect(error?.message).toMatch(/not attached to a company/i);
    await deleteAuthUserByEmail(noProfileEmail);
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

  it("✗ a company_admin cannot set their own order's payment_status directly (Phase 3)", async () => {
    // orders_update_admin_or_internal permits a company_admin to update rows
    // in their own company -- that policy governs row visibility, not which
    // columns. Without the trigger, a client could PATCH payment_status to
    // "paid" without ever paying. This is the trigger added alongside the
    // invoices table in Phase 3 (enforce_orders_payment_fields_immutable_by_client).
    const client = await clientAsUser(a1Email);
    const { error } = await client.from("orders").update({ payment_status: "paid" }).eq("id", orderAId);
    expect(error).not.toBeNull();
  });

  it("✓ service_role (the webhook handler's identity) CAN set payment_status", async () => {
    // adminClient uses the service_role key, same trust level the Stripe
    // webhook Edge Function runs as -- confirms the trigger only blocks the
    // client role, not the one path that's actually supposed to write this.
    const { error } = await adminClient.from("orders").update({ payment_status: "paid" }).eq("id", orderAId);
    expect(error).toBeNull();
    // Reset for any later test in this block that assumes 'pending'.
    await adminClient.from("orders").update({ payment_status: "pending" }).eq("id", orderAId);
  });
});

describe("RLS: public.invoices — isolation, collaboration, and client write protection (Phase 3)", () => {
  let companyA: { id: string };
  let companyB: { id: string };
  const a1Email = uniqueEmail("inv-a1");
  const a2Email = uniqueEmail("inv-a2");
  const bEmail = uniqueEmail("inv-b1");
  let employeeA: { id: string };
  let orderAId: string;
  let invoiceAId: string;

  beforeAll(async () => {
    companyA = await createCompany("Invoice Test Co A");
    companyB = await createCompany("Invoice Test Co B");

    const a1 = await createAuthUser(a1Email);
    const a2 = await createAuthUser(a2Email);
    const b1 = await createAuthUser(bEmail);

    await createProfile(a1.id, companyA.id, a1Email, "company_admin");
    await createProfile(a2.id, companyA.id, a2Email, "company_member");
    await createProfile(b1.id, companyB.id, bEmail, "company_admin");

    const { data: emp, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: companyA.id, full_name: "Pat Payee", email: "pat@example.com" })
      .select()
      .single();
    if (empError) throw empError;
    employeeA = emp as { id: string };

    const client = await clientAsUser(a1Email);
    const { data: orderId, error: orderError } = await client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employeeA.id,
    });
    if (orderError) throw orderError;
    orderAId = orderId as string;

    // Simulate what the webhook handler does, as service_role: create the
    // invoice, mark the order paid. Real invoice_number values come from
    // invoice_number_seq (nextval() inside the webhook handler, never in
    // tests) -- nothing in the schema ties a specific row's number to the
    // sequence, only uniqueness, so a fixture-local unique int is enough
    // here and avoids burning real sequence values on every test run.
    const invoiceNumber = Date.now() % 2_000_000_000;

    const { data: invoice, error: invoiceError } = await adminClient
      .from("invoices")
      .insert({
        company_id: companyA.id,
        invoice_number: invoiceNumber,
        stripe_checkout_session_id: `cs_test_${invoiceNumber}`,
        subtotal_ex_vat_pence: 6500,
        vat_pence: 1300,
        total_inc_vat_pence: 7800,
      })
      .select()
      .single();
    if (invoiceError) throw invoiceError;
    invoiceAId = invoice!.id;

    const { error: updateError } = await adminClient
      .from("orders")
      .update({ payment_status: "paid", invoice_id: invoiceAId })
      .eq("id", orderAId);
    if (updateError) throw updateError;
  });

  afterAll(async () => {
    // orders/invoices before users/companies -- same FK ordering constraint
    // as every other describe block in this file.
    await adminClient.from("orders").delete().eq("company_id", companyA.id);
    await adminClient.from("invoices").delete().eq("company_id", companyA.id);
    for (const email of [a1Email, a2Email, bEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().in("id", [companyA.id, companyB.id]);
  });

  it("✓ collaboration: user 2 in company A CAN see the invoice user 1's order generated", async () => {
    const client = await clientAsUser(a2Email);
    const { data, error } = await client.from("invoices").select("id, invoice_number").eq("id", invoiceAId);
    expect(error).toBeNull();
    expect(data?.length).toBe(1);
  });

  it("✗ isolation: a user in company B cannot see company A's invoice", async () => {
    const client = await clientAsUser(bEmail);
    const { data, error } = await client.from("invoices").select("*").eq("id", invoiceAId);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("✗ a client cannot INSERT an invoice directly — only the webhook handler (service_role) can", async () => {
    const client = await clientAsUser(a1Email);
    const { error } = await client.from("invoices").insert({
      company_id: companyA.id,
      invoice_number: 999999,
      stripe_checkout_session_id: "cs_test_forged",
      subtotal_ex_vat_pence: 100,
      vat_pence: 20,
      total_inc_vat_pence: 120,
    });
    expect(error).not.toBeNull();
  });

  it("invoice arithmetic: total is always subtotal + VAT (DB constraint, not just app logic)", async () => {
    const { error } = await adminClient.from("invoices").insert({
      company_id: companyA.id,
      invoice_number: 999998,
      stripe_checkout_session_id: "cs_test_bad_math",
      subtotal_ex_vat_pence: 6500,
      vat_pence: 1300,
      total_inc_vat_pence: 7799, // off by a penny
    });
    expect(error).not.toBeNull();
    await adminClient.from("invoices").delete().eq("invoice_number", 999998);
  });
});

describe("record_stripe_payment() — atomicity and idempotency (Phase 3)", () => {
  // Signature verification itself lives in the Deno webhook Edge Function,
  // not the database, so it isn't exercised here (the plan's "wrongly-signed
  // webhook rejected" exit criterion is a manual/curl check against the
  // deployed function). What IS testable at this layer, and is arguably the
  // more dangerous half: given a validly-authenticated call, does the write
  // path behave atomically and idempotently? That's this block.
  let company: { id: string };
  const ownerEmail = uniqueEmail("pay-owner");
  let employee: { id: string };
  let orderId: string;

  beforeAll(async () => {
    company = await createCompany("Payment Test Co");
    const owner = await createAuthUser(ownerEmail);
    await createProfile(owner.id, company.id, ownerEmail, "company_admin");

    const { data: emp, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: company.id, full_name: "Sam Sender", email: "sam@example.com" })
      .select()
      .single();
    if (empError) throw empError;
    employee = emp as { id: string };

    const client = await clientAsUser(ownerEmail);
    const { data: orderIdData, error: orderError } = await client.rpc("create_order", {
      p_kit_type_id: "phone",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
    });
    if (orderError) throw orderError;
    orderId = orderIdData as string;
  });

  afterAll(async () => {
    await adminClient.from("orders").delete().eq("company_id", company.id);
    await adminClient.from("invoices").delete().eq("company_id", company.id);
    await deleteAuthUserByEmail(ownerEmail);
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("✗ an authenticated client cannot call record_stripe_payment directly", async () => {
    // The advisor caught this project's default EXECUTE-to-authenticated
    // grant on this exact function the first time it was created (see
    // 20260807230100_lock_down_record_stripe_payment.sql) -- without that
    // fix, any signed-in customer could mint their own "paid" invoice.
    const client = await clientAsUser(ownerEmail);
    const { error } = await client.rpc("record_stripe_payment", {
      p_event_id: `evt_forged_${Date.now()}`,
      p_event_type: "checkout.session.completed",
      p_checkout_session_id: `cs_forged_${Date.now()}`,
      p_payment_intent_id: null,
      p_company_id: company.id,
      p_order_ids: [orderId],
      p_subtotal_ex_vat_pence: 4000,
      p_vat_pence: 800,
      p_total_inc_vat_pence: 4800,
    });
    expect(error).not.toBeNull();
  });

  it("✓ service_role: marks the order paid and issues a gapless invoice number", async () => {
    const eventId = `evt_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
    const sessionId = `cs_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;

    const { data: invoiceId, error } = await adminClient.rpc("record_stripe_payment", {
      p_event_id: eventId,
      p_event_type: "checkout.session.completed",
      p_checkout_session_id: sessionId,
      p_payment_intent_id: `pi_${sessionId}`,
      p_company_id: company.id,
      p_order_ids: [orderId],
      p_subtotal_ex_vat_pence: 4000,
      p_vat_pence: 800,
      p_total_inc_vat_pence: 4800,
    });
    expect(error).toBeNull();
    expect(invoiceId).not.toBeNull();

    const { data: order } = await adminClient
      .from("orders")
      .select("payment_status, invoice_id")
      .eq("id", orderId)
      .single();
    expect(order?.payment_status).toBe("paid");
    expect(order?.invoice_id).toBe(invoiceId);

    const { data: invoice } = await adminClient
      .from("invoices")
      .select("invoice_number, total_inc_vat_pence")
      .eq("id", invoiceId)
      .single();
    expect(invoice?.total_inc_vat_pence).toBe(4800);
    expect(Number.isInteger(invoice?.invoice_number)).toBe(true);
  });

  it("✓ replaying the same event id twice changes nothing (exit criterion, architecture §9.7)", async () => {
    const eventId = `evt_replay_${Date.now()}`;
    const sessionId = `cs_replay_${Date.now()}`;
    const args = {
      p_event_id: eventId,
      p_event_type: "checkout.session.completed",
      p_checkout_session_id: sessionId,
      p_payment_intent_id: `pi_${sessionId}`,
      p_company_id: company.id,
      p_order_ids: [orderId],
      p_subtotal_ex_vat_pence: 4000,
      p_vat_pence: 800,
      p_total_inc_vat_pence: 4800,
    };

    // This order was already marked paid by the previous test, so on a
    // *first* delivery record_stripe_payment would now correctly refuse it
    // (order set no longer 'pending') -- but replaying the SAME event id
    // must short-circuit on the idempotency check before that logic ever
    // runs, and return null rather than raising.
    const first = await adminClient.rpc("record_stripe_payment", args);
    expect(first.error).toBeNull();
    expect(first.data).toBeNull();

    const { count: invoiceCountBefore } = await adminClient
      .from("invoices")
      .select("id", { count: "exact", head: true })
      .eq("stripe_checkout_session_id", sessionId);
    expect(invoiceCountBefore).toBe(0);

    const second = await adminClient.rpc("record_stripe_payment", args);
    expect(second.error).toBeNull();
    expect(second.data).toBeNull();

    const { count: eventCount } = await adminClient
      .from("stripe_webhook_events")
      .select("event_id", { count: "exact", head: true })
      .eq("event_id", eventId);
    expect(eventCount).toBe(1);
  });

  it("✗ refuses to pay an order that's no longer pending, and rolls back the event record with it", async () => {
    // orderId is already 'paid' from the earlier test. A genuinely new
    // event trying to pay it again (not a replay -- a fresh event_id) must
    // be rejected, and critically must not leave a stripe_webhook_events row
    // behind for it either -- otherwise a legitimate retry with a
    // *corrected* payload would be silently swallowed as "already
    // processed" by an event that actually failed.
    const eventId = `evt_reject_${Date.now()}`;
    const { error } = await adminClient.rpc("record_stripe_payment", {
      p_event_id: eventId,
      p_event_type: "checkout.session.completed",
      p_checkout_session_id: `cs_reject_${Date.now()}`,
      p_payment_intent_id: null,
      p_company_id: company.id,
      p_order_ids: [orderId],
      p_subtotal_ex_vat_pence: 4000,
      p_vat_pence: 800,
      p_total_inc_vat_pence: 4800,
    });
    expect(error).not.toBeNull();

    const { count } = await adminClient
      .from("stripe_webhook_events")
      .select("event_id", { count: "exact", head: true })
      .eq("event_id", eventId);
    expect(count).toBe(0);
  });
});

describe("mark_order_dispatched() / create_internal_order() — the Retool write API (Phase 4)", () => {
  // Auth model confirmed with the user: Retool holds ONE privileged
  // (service_role) connection, not per-staff pass-through auth. So the real
  // gate here isn't "is this caller internal_ops" (that's meaningless for a
  // service_role call, which carries no app_role claim) -- it's "is this
  // caller service_role at all", checked explicitly inside the function.
  let company: { id: string };
  const staffEmail = uniqueEmail("p4-staff");
  const customerEmail = uniqueEmail("p4-cust");
  let staffId: string;
  let employee: { id: string };
  let orderId: string;

  beforeAll(async () => {
    company = await createCompany("Phase4 Dispatch Test Co");
    const staff = await createAuthUser(staffEmail);
    const customer = await createAuthUser(customerEmail);
    staffId = staff.id;
    await createProfile(staff.id, null, staffEmail, "internal_ops");
    await createProfile(customer.id, company.id, customerEmail, "company_admin");

    const { data: emp, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: company.id, full_name: "Dispatch Test", email: "dispatch@example.com" })
      .select()
      .single();
    if (empError) throw empError;
    employee = emp as { id: string };

    const client = await clientAsUser(customerEmail);
    const { data: orderIdData, error: orderError } = await client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
    });
    if (orderError) throw orderError;
    orderId = orderIdData as string;
  });

  afterAll(async () => {
    await adminClient.from("orders").delete().eq("company_id", company.id);
    for (const email of [staffEmail, customerEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("✗ a regular authenticated customer cannot call mark_order_dispatched", async () => {
    const client = await clientAsUser(customerEmail);
    const { error } = await client.rpc("mark_order_dispatched", {
      p_order_id: orderId,
      p_actor_id: staffId,
      p_courier: "DPD",
      p_tracking_number: "DPD123",
    });
    expect(error).not.toBeNull();
  });

  it("✗ even a genuine internal_ops user calling with their OWN session (not service_role) is rejected", async () => {
    // Deliberate: the design is service_role-only, not role-based. A real
    // internal_ops human logged in normally still isn't service_role.
    const client = await clientAsUser(staffEmail);
    const { error } = await client.rpc("mark_order_dispatched", {
      p_order_id: orderId,
      p_actor_id: staffId,
      p_courier: "DPD",
      p_tracking_number: "DPD123",
    });
    expect(error).not.toBeNull();
  });

  it("✗ service_role call with a non-internal actor_id is rejected by assert_internal_actor", async () => {
    const client = await clientAsUser(customerEmail);
    const { data: customerUser } = await client.auth.getUser();
    const { error } = await adminClient.rpc("mark_order_dispatched", {
      p_order_id: orderId,
      p_actor_id: customerUser.user!.id, // a company_admin, not internal staff
      p_courier: "DPD",
      p_tracking_number: "DPD123",
    });
    expect(error).not.toBeNull();
  });

  it("✗ mark_order_dispatched refuses an unpaid order (payment gate, added 20260811)", async () => {
    // Fixture order defaults to payment_status = 'pending' -- confirm the
    // gate blocks dispatch before the fixture is marked paid below.
    const { data: order } = await adminClient.from("orders").select("payment_status").eq("id", orderId).single();
    expect(order?.payment_status).toBe("pending");

    const { error } = await adminClient.rpc("mark_order_dispatched", {
      p_order_id: orderId,
      p_actor_id: staffId,
      p_courier: "DPD",
      p_tracking_number: "DPD123",
    });
    expect(error).not.toBeNull();
  });

  it("✗ mark_order_paid rejects a non-service_role caller", async () => {
    const client = await clientAsUser(customerEmail);
    const { error } = await client.rpc("mark_order_paid", { p_order_id: orderId, p_actor_id: staffId });
    expect(error).not.toBeNull();
  });

  it("✗ mark_order_paid rejects a non-internal actor_id", async () => {
    const client = await clientAsUser(customerEmail);
    const { data: customerUser } = await client.auth.getUser();
    const { error } = await adminClient.rpc("mark_order_paid", {
      p_order_id: orderId,
      p_actor_id: customerUser.user!.id,
    });
    expect(error).not.toBeNull();
  });

  it("✓ mark_order_paid marks a pending order as paid and logs it", async () => {
    const { error } = await adminClient.rpc("mark_order_paid", { p_order_id: orderId, p_actor_id: staffId });
    expect(error).toBeNull();

    const { data: order } = await adminClient.from("orders").select("payment_status").eq("id", orderId).single();
    expect(order?.payment_status).toBe("paid");

    const { data: auditRows } = await adminClient
      .from("audit_log")
      .select("action, actor_id")
      .eq("target_id", orderId)
      .eq("action", "order.mark_paid");
    expect(auditRows?.length).toBe(1);
    expect(auditRows?.[0].actor_id).toBe(staffId);
  });

  it("✗ mark_order_paid refuses an order that's already paid (state guard)", async () => {
    const { error } = await adminClient.rpc("mark_order_paid", { p_order_id: orderId, p_actor_id: staffId });
    expect(error).not.toBeNull();
  });

  it("✓ service_role with a valid internal actor dispatches the now-paid order, sets outbound_* and fulfilment_log", async () => {
    const { error } = await adminClient.rpc("mark_order_dispatched", {
      p_order_id: orderId,
      p_actor_id: staffId,
      p_courier: "DPD",
      p_tracking_number: "DPD123456",
      p_tracking_url: "https://example.com/track/DPD123456",
    });
    expect(error).toBeNull();

    const { data: order } = await adminClient
      .from("orders")
      .select("fulfilment_status, outbound_courier, outbound_tracking_number, fulfilment_log")
      .eq("id", orderId)
      .single();
    expect(order?.fulfilment_status).toBe("dispatched");
    expect(order?.outbound_courier).toBe("DPD");
    expect(order?.outbound_tracking_number).toBe("DPD123456");
    expect(Array.isArray(order?.fulfilment_log)).toBe(true);
    expect((order?.fulfilment_log as unknown[]).length).toBe(1);

    const { data: auditRows } = await adminClient
      .from("audit_log")
      .select("action, actor_id")
      .eq("target_id", orderId)
      .eq("action", "order.dispatch");
    expect(auditRows?.length).toBe(1);
    expect(auditRows?.[0].actor_id).toBe(staffId);
  });

  it("✗ dispatching an order that's already dispatched is refused (state guard)", async () => {
    const { error } = await adminClient.rpc("mark_order_dispatched", {
      p_order_id: orderId,
      p_actor_id: staffId,
      p_courier: "DPD",
      p_tracking_number: "DPD999",
    });
    expect(error).not.toBeNull();
  });

  it("✗ create_internal_order rejects a non-service_role caller", async () => {
    const client = await clientAsUser(customerEmail);
    const { error } = await client.rpc("create_internal_order", {
      p_company_id: company.id,
      p_actor_id: staffId,
      p_kit_type_id: "phone",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
    });
    expect(error).not.toBeNull();
  });

  it("✓ create_internal_order via service_role creates a source='internal_staff' order", async () => {
    const { data: newOrderId, error } = await adminClient.rpc("create_internal_order", {
      p_company_id: company.id,
      p_actor_id: staffId,
      p_kit_type_id: "phone",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
    });
    expect(error).toBeNull();

    const { data: order } = await adminClient
      .from("orders")
      .select("source, created_by, reference")
      .eq("id", newOrderId as string)
      .single();
    expect(order?.source).toBe("internal_staff");
    expect(order?.created_by).toBe(staffId);
    expect(order?.reference).toMatch(/^RKP-\d{6}-\d{3,}$/);
  });
});

describe("update_order_tracking() — staff correction of either tracking leg (Phase 4)", () => {
  // Separate from mark_order_dispatched (a state-transition function): this
  // one lets staff set/correct outbound or return tracking independently of
  // fulfilment_status, e.g. a customer phones in a return tracking number
  // instead of using Confirm Sent. Same service_role + assert_internal_actor
  // gate as the rest of the Retool write API.
  let company: { id: string };
  const staffEmail = uniqueEmail("p4-track-staff");
  const customerEmail = uniqueEmail("p4-track-cust");
  let staffId: string;
  let employee: { id: string };
  let orderId: string;

  beforeAll(async () => {
    company = await createCompany("Phase4 Tracking Test Co");
    const staff = await createAuthUser(staffEmail);
    const customer = await createAuthUser(customerEmail);
    staffId = staff.id;
    await createProfile(staff.id, null, staffEmail, "internal_ops");
    await createProfile(customer.id, company.id, customerEmail, "company_admin");

    const { data: emp, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: company.id, full_name: "Tracking Test", email: "tracking@example.com" })
      .select()
      .single();
    if (empError) throw empError;
    employee = emp as { id: string };

    const client = await clientAsUser(customerEmail);
    const { data: orderIdData, error: orderError } = await client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
    });
    if (orderError) throw orderError;
    orderId = orderIdData as string;
  });

  afterAll(async () => {
    await adminClient.from("orders").delete().eq("company_id", company.id);
    for (const email of [staffEmail, customerEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("✗ a regular authenticated customer cannot call update_order_tracking", async () => {
    const client = await clientAsUser(customerEmail);
    const { error } = await client.rpc("update_order_tracking", {
      p_order_id: orderId,
      p_actor_id: staffId,
      p_outbound_courier: "DPD",
    });
    expect(error).not.toBeNull();
  });

  it("✗ service_role call with a non-internal actor_id is rejected", async () => {
    const client = await clientAsUser(customerEmail);
    const { data: customerUser } = await client.auth.getUser();
    const { error } = await adminClient.rpc("update_order_tracking", {
      p_order_id: orderId,
      p_actor_id: customerUser.user!.id,
      p_outbound_courier: "DPD",
    });
    expect(error).not.toBeNull();
  });

  it("✗ calling with no tracking fields at all is refused", async () => {
    const { error } = await adminClient.rpc("update_order_tracking", {
      p_order_id: orderId,
      p_actor_id: staffId,
    });
    expect(error).not.toBeNull();
  });

  it("✓ sets outbound tracking independently of fulfilment_status (no dispatch required first)", async () => {
    const { data: before } = await adminClient
      .from("orders")
      .select("fulfilment_status")
      .eq("id", orderId)
      .single();
    expect(before?.fulfilment_status).toBe("awaiting_dispatch"); // proves no state transition needed

    const { error } = await adminClient.rpc("update_order_tracking", {
      p_order_id: orderId,
      p_actor_id: staffId,
      p_outbound_courier: "Royal Mail",
      p_outbound_tracking_number: "RM111",
    });
    expect(error).toBeNull();

    const { data: order } = await adminClient
      .from("orders")
      .select("fulfilment_status, outbound_courier, outbound_tracking_number, return_tracking_number")
      .eq("id", orderId)
      .single();
    expect(order?.fulfilment_status).toBe("awaiting_dispatch"); // unchanged
    expect(order?.outbound_courier).toBe("Royal Mail");
    expect(order?.outbound_tracking_number).toBe("RM111");
    expect(order?.return_tracking_number).toBeNull(); // untouched
  });

  it("✓ a later call setting only return tracking leaves outbound tracking untouched", async () => {
    const { error } = await adminClient.rpc("update_order_tracking", {
      p_order_id: orderId,
      p_actor_id: staffId,
      p_return_tracking_number: "RET999",
    });
    expect(error).toBeNull();

    const { data: order } = await adminClient
      .from("orders")
      .select("outbound_courier, outbound_tracking_number, return_tracking_number")
      .eq("id", orderId)
      .single();
    expect(order?.outbound_courier).toBe("Royal Mail"); // still there from the previous call
    expect(order?.outbound_tracking_number).toBe("RM111");
    expect(order?.return_tracking_number).toBe("RET999");

    const { data: auditRows } = await adminClient
      .from("audit_log")
      .select("action, actor_id")
      .eq("target_id", orderId)
      .eq("action", "order.tracking_updated");
    expect(auditRows?.length).toBe(2); // one per call above
    expect(auditRows?.every((r) => r.actor_id === staffId)).toBe(true);
  });
});

describe("confirm_received() — customer-facing (Phase 4)", () => {
  let companyA: { id: string };
  const a1Email = uniqueEmail("p4-conf-a1");
  let employeeA: { id: string };
  let returnOrderId: string;
  let shipOrderId: string;

  beforeAll(async () => {
    companyA = await createCompany("Phase4 Confirm Test Co A");

    const a1 = await createAuthUser(a1Email);
    await createProfile(a1.id, companyA.id, a1Email, "company_admin");

    const { data: emp, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: companyA.id, full_name: "Confirm Test", email: "confirm@example.com" })
      .select()
      .single();
    if (empError) throw empError;
    employeeA = emp as { id: string };

    const { data: addr, error: addrError } = await adminClient
      .from("addresses")
      .insert({ company_id: companyA.id, label: "HQ", address_line1: "1 Test St", city: "London", postcode: "E1 6AN" })
      .select()
      .single();
    if (addrError) throw addrError;

    const client = await clientAsUser(a1Email);

    const { data: returnId, error: returnError } = await client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "return",
      p_employee_id: employeeA.id,
      p_return_address_id: (addr as { id: string }).id,
    });
    if (returnError) throw returnError;
    returnOrderId = returnId as string;

    const { data: shipId, error: shipError } = await client.rpc("create_order", {
      p_kit_type_id: "phone",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employeeA.id,
    });
    if (shipError) throw shipError;
    shipOrderId = shipId as string;

    // Fixture setup only -- fast-forward both orders to 'dispatched' by
    // direct admin update rather than exercising mark_order_dispatched
    // again here (already covered by the describe block above).
    await adminClient.from("orders").update({ fulfilment_status: "dispatched" }).in("id", [returnOrderId, shipOrderId]);
  });

  afterAll(async () => {
    await adminClient.from("orders").delete().eq("company_id", companyA.id);
    await deleteAuthUserByEmail(a1Email);
    await adminClient.from("companies").delete().eq("id", companyA.id);
  });

  it("✗ confirm_sent no longer exists as an RPC (removed 20260811090000)", async () => {
    const client = await clientAsUser(a1Email);
    const { error } = await client.rpc("confirm_sent", { p_order_id: returnOrderId });
    expect(error).not.toBeNull();
  });

  it("✗ confirm_received refuses a return order", async () => {
    const client = await clientAsUser(a1Email);
    const { error } = await client.rpc("confirm_received", { p_order_id: returnOrderId });
    expect(error).not.toBeNull();
  });

  it("✓ confirm_received on the owning company's ship-to-new-employee order completes it", async () => {
    const client = await clientAsUser(a1Email);
    const { data: user } = await client.auth.getUser();
    const { error } = await client.rpc("confirm_received", { p_order_id: shipOrderId });
    expect(error).toBeNull();

    const { data: order } = await adminClient
      .from("orders")
      .select("fulfilment_status, confirmed_received_at, confirmed_received_by")
      .eq("id", shipOrderId)
      .single();
    expect(order?.fulfilment_status).toBe("completed");
    expect(order?.confirmed_received_at).not.toBeNull();
    expect(order?.confirmed_received_by).toBe(user.user!.id);
  });

  it("✗ confirming an already-completed order again is refused (state guard)", async () => {
    const client = await clientAsUser(a1Email);
    const { error } = await client.rpc("confirm_received", { p_order_id: shipOrderId });
    expect(error).not.toBeNull();
  });
});

describe("apply_sendcloud_tracking_event() / in_transit status (Phase 6 tracking)", () => {
  // Tracking-only Phase 6 -- no label automation, per the user's explicit
  // scope narrowing (20260811: "I will do labels manually but we need
  // tracking in the portal"). This function is the single write path the
  // sendcloud-webhook Edge Function calls after signature verification.
  //
  // Fixture fast-forwards both orders straight to 'dispatched' with real
  // tracking numbers set by direct admin update, same shortcut the
  // confirm_received block above uses -- mark_order_dispatched's own
  // column-setting behaviour is already covered there.
  let company: { id: string };
  const custEmail = uniqueEmail("p6-track-cust");
  const staffEmail = uniqueEmail("p6-track-staff");
  let staffId: string;
  let employee: { id: string };
  let returnOrderId: string;
  let shipOrderId: string;
  const returnTracking = `RET-${Date.now()}`;
  const outboundTracking = `OUT-${Date.now()}`;

  beforeAll(async () => {
    company = await createCompany("Phase6 Tracking Test Co");
    const staff = await createAuthUser(staffEmail);
    staffId = staff.id;
    await createProfile(staff.id, null, staffEmail, "internal_ops");

    const cust = await createAuthUser(custEmail);
    await createProfile(cust.id, company.id, custEmail, "company_admin");

    const { data: emp, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: company.id, full_name: "Tracking Test", email: "tracking@example.com" })
      .select()
      .single();
    if (empError) throw empError;
    employee = emp as { id: string };

    const { data: addr, error: addrError } = await adminClient
      .from("addresses")
      .insert({ company_id: company.id, label: "HQ", address_line1: "1 Test St", city: "London", postcode: "E1 6AN" })
      .select()
      .single();
    if (addrError) throw addrError;

    const client = await clientAsUser(custEmail);

    const { data: returnId, error: returnError } = await client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "return",
      p_employee_id: employee.id,
      p_return_address_id: (addr as { id: string }).id,
    });
    if (returnError) throw returnError;
    returnOrderId = returnId as string;

    const { data: shipId, error: shipError } = await client.rpc("create_order", {
      p_kit_type_id: "phone",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
    });
    if (shipError) throw shipError;
    shipOrderId = shipId as string;

    await adminClient
      .from("orders")
      .update({ fulfilment_status: "dispatched", return_tracking_number: returnTracking })
      .eq("id", returnOrderId);
    await adminClient
      .from("orders")
      .update({ fulfilment_status: "dispatched", outbound_tracking_number: outboundTracking })
      .eq("id", shipOrderId);
  });

  afterAll(async () => {
    await adminClient.from("orders").delete().eq("company_id", company.id);
    for (const email of [custEmail, staffEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("✗ a regular authenticated customer cannot call apply_sendcloud_tracking_event", async () => {
    const client = await clientAsUser(custEmail);
    const { error } = await client.rpc("apply_sendcloud_tracking_event", {
      p_tracking_number: outboundTracking,
      p_carrier_code: "dpd",
      p_status_code: "accepted",
      p_status_description: "Parcel has been accepted by the carrier.",
      p_event_at: new Date().toISOString(),
    });
    expect(error).not.toBeNull();
  });

  it("✓ an unrecognised tracking number is acknowledged as unmatched, not an error", async () => {
    const { data, error } = await adminClient.rpc("apply_sendcloud_tracking_event", {
      p_tracking_number: "NO-SUCH-TRACKING-NUMBER",
      p_carrier_code: "dpd",
      p_status_code: "accepted",
      p_status_description: "Parcel has been accepted by the carrier.",
      p_event_at: new Date().toISOString(),
    });
    expect(error).toBeNull();
    expect(data?.matched).toBe(false);
  });

  it("✓ an unmapped status_code is a no-op, not an error (unverified vocabulary stays safe)", async () => {
    const { data, error } = await adminClient.rpc("apply_sendcloud_tracking_event", {
      p_tracking_number: outboundTracking,
      p_carrier_code: "dpd",
      p_status_code: "some_totally_unknown_code",
      p_status_description: "Unrecognised",
      p_event_at: new Date().toISOString(),
    });
    expect(error).toBeNull();
    expect(data?.matched).toBe(true);
    expect(data?.applied).toBe(false);

    const { data: order } = await adminClient.from("orders").select("fulfilment_status").eq("id", shipOrderId).single();
    expect(order?.fulfilment_status).toBe("dispatched"); // unchanged
  });

  it("✓ a mapped 'accepted' event transitions the outbound leg dispatched -> in_transit", async () => {
    const { data, error } = await adminClient.rpc("apply_sendcloud_tracking_event", {
      p_tracking_number: outboundTracking,
      p_carrier_code: "dpd",
      p_status_code: "accepted",
      p_status_description: "Parcel has been accepted by the carrier.",
      p_event_at: new Date().toISOString(),
    });
    expect(error).toBeNull();
    expect(data?.applied).toBe(true);
    expect(data?.leg).toBe("outbound");
    expect(data?.new_status).toBe("in_transit");

    const { data: order } = await adminClient
      .from("orders")
      .select("fulfilment_status, fulfilment_log")
      .eq("id", shipOrderId)
      .single();
    expect(order?.fulfilment_status).toBe("in_transit");
    const log = order?.fulfilment_log as Array<{ action: string }>;
    expect(log.some((entry) => entry.action === "in_transit")).toBe(true);
  });

  it("✓ the same event applied again is a no-op (idempotent via the state guard, not just the dedup log)", async () => {
    const { data, error } = await adminClient.rpc("apply_sendcloud_tracking_event", {
      p_tracking_number: outboundTracking,
      p_carrier_code: "dpd",
      p_status_code: "accepted",
      p_status_description: "Parcel has been accepted by the carrier.",
      p_event_at: new Date().toISOString(),
    });
    expect(error).toBeNull();
    expect(data?.applied).toBe(false); // already in_transit, no eligible transition
  });

  it("✓ a mapped event transitions the return leg dispatched -> in_transit, matched by return_tracking_number", async () => {
    const { data, error } = await adminClient.rpc("apply_sendcloud_tracking_event", {
      p_tracking_number: returnTracking,
      p_carrier_code: "royal_mail",
      p_status_code: "accepted",
      p_status_description: "Parcel has been accepted by the carrier.",
      p_event_at: new Date().toISOString(),
    });
    expect(error).toBeNull();
    expect(data?.applied).toBe(true);
    expect(data?.leg).toBe("return");

    const { data: order } = await adminClient.from("orders").select("fulfilment_status").eq("id", returnOrderId).single();
    expect(order?.fulfilment_status).toBe("in_transit");
  });

  it("✓ confirm_received still works from 'in_transit', not just 'dispatched' (widened guard)", async () => {
    const client = await clientAsUser(custEmail);
    const { error } = await client.rpc("confirm_received", { p_order_id: shipOrderId });
    expect(error).toBeNull();

    const { data: order } = await adminClient.from("orders").select("fulfilment_status").eq("id", shipOrderId).single();
    expect(order?.fulfilment_status).toBe("completed");
  });

  it("✓ mark_return_completed still works from 'in_transit', not just 'dispatched' (widened guard)", async () => {
    const { error } = await adminClient.rpc("mark_return_completed", {
      p_order_id: returnOrderId,
      p_actor_id: staffId,
    });
    expect(error).toBeNull();

    const { data: order } = await adminClient.from("orders").select("fulfilment_status").eq("id", returnOrderId).single();
    expect(order?.fulfilment_status).toBe("completed");
  });
});

describe("apply_sendcloud_tracking_event() / delivered -> completed (20260813)", () => {
  // Extends the same RPC with a second real transition: a mapped
  // 'delivered' status_code now auto-closes the order out, the same
  // terminal state confirm_received/mark_return_completed already produce
  // manually -- clarified with the user that return orders ship back to
  // the company's own HQ/IT address (never a ReturnKits warehouse), so
  // "delivered" is a legitimate completion signal on either leg, not just
  // the outbound one.
  let company: { id: string };
  const custEmail = uniqueEmail("p6-delivered-cust");
  const staffEmail = uniqueEmail("p6-delivered-staff");
  let staffId: string;
  let employee: { id: string };
  let shipFromDispatchedId: string;
  let shipFromInTransitId: string;
  let returnOrderId: string;
  let cancelledOrderId: string;
  const shipFromDispatchedTracking = `SFD-${Date.now()}`;
  const shipFromInTransitTracking = `SFT-${Date.now()}`;
  const returnTracking = `RETD-${Date.now()}`;
  const cancelledTracking = `CXL-${Date.now()}`;

  beforeAll(async () => {
    company = await createCompany("Phase6 Delivered Test Co");
    const staff = await createAuthUser(staffEmail);
    staffId = staff.id;
    await createProfile(staff.id, null, staffEmail, "internal_ops");

    const cust = await createAuthUser(custEmail);
    await createProfile(cust.id, company.id, custEmail, "company_admin");

    const { data: emp, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: company.id, full_name: "Delivered Test", email: "delivered@example.com" })
      .select()
      .single();
    if (empError) throw empError;
    employee = emp as { id: string };

    const { data: addr, error: addrError } = await adminClient
      .from("addresses")
      .insert({ company_id: company.id, label: "HQ", address_line1: "1 Test St", city: "London", postcode: "E1 6AN" })
      .select()
      .single();
    if (addrError) throw addrError;

    const client = await clientAsUser(custEmail);

    const makeShipOrder = async () => {
      const { data, error } = await client.rpc("create_order", {
        p_kit_type_id: "phone",
        p_service_type: "ship_to_new_employee",
        p_employee_id: employee.id,
      });
      if (error) throw error;
      return data as string;
    };

    shipFromDispatchedId = await makeShipOrder();
    shipFromInTransitId = await makeShipOrder();
    cancelledOrderId = await makeShipOrder();

    const { data: returnId, error: returnError } = await client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "return",
      p_employee_id: employee.id,
      p_return_address_id: (addr as { id: string }).id,
    });
    if (returnError) throw returnError;
    returnOrderId = returnId as string;

    await adminClient
      .from("orders")
      .update({ fulfilment_status: "dispatched", outbound_tracking_number: shipFromDispatchedTracking })
      .eq("id", shipFromDispatchedId);
    await adminClient
      .from("orders")
      .update({ fulfilment_status: "in_transit", outbound_tracking_number: shipFromInTransitTracking })
      .eq("id", shipFromInTransitId);
    await adminClient
      .from("orders")
      .update({ fulfilment_status: "dispatched", return_tracking_number: returnTracking })
      .eq("id", returnOrderId);
    await adminClient
      .from("orders")
      .update({ fulfilment_status: "cancelled", outbound_tracking_number: cancelledTracking })
      .eq("id", cancelledOrderId);
  });

  afterAll(async () => {
    await adminClient.from("orders").delete().eq("company_id", company.id);
    for (const email of [custEmail, staffEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("✓ a mapped 'delivered' event completes a ship_to_new_employee order from 'dispatched' and stamps confirmed_received_at", async () => {
    const eventAt = new Date().toISOString();
    const { data, error } = await adminClient.rpc("apply_sendcloud_tracking_event", {
      p_tracking_number: shipFromDispatchedTracking,
      p_carrier_code: "dpd",
      p_status_code: "delivered",
      p_status_description: "Parcel has been delivered.",
      p_event_at: eventAt,
    });
    expect(error).toBeNull();
    expect(data?.applied).toBe(true);
    expect(data?.leg).toBe("outbound");
    expect(data?.new_status).toBe("completed");

    const { data: order } = await adminClient
      .from("orders")
      .select("fulfilment_status, confirmed_received_at, fulfilment_log")
      .eq("id", shipFromDispatchedId)
      .single();
    expect(order?.fulfilment_status).toBe("completed");
    expect(order?.confirmed_received_at).not.toBeNull();
    const log = order?.fulfilment_log as Array<{ action: string }>;
    expect(log.some((entry) => entry.action === "delivered")).toBe(true);
  });

  it("✓ a mapped 'delivered' event completes a ship_to_new_employee order from 'in_transit' too (widened guard)", async () => {
    const { data, error } = await adminClient.rpc("apply_sendcloud_tracking_event", {
      p_tracking_number: shipFromInTransitTracking,
      p_carrier_code: "dpd",
      p_status_code: "delivered",
      p_status_description: "Parcel has been delivered.",
      p_event_at: new Date().toISOString(),
    });
    expect(error).toBeNull();
    expect(data?.applied).toBe(true);
    expect(data?.new_status).toBe("completed");

    const { data: order } = await adminClient.from("orders").select("fulfilment_status").eq("id", shipFromInTransitId).single();
    expect(order?.fulfilment_status).toBe("completed");
  });

  it("✓ a mapped 'delivered' event completes a return order too, matched by return_tracking_number, without stamping confirmed_received_at", async () => {
    const { data, error } = await adminClient.rpc("apply_sendcloud_tracking_event", {
      p_tracking_number: returnTracking,
      p_carrier_code: "royal_mail",
      p_status_code: "delivered",
      p_status_description: "Parcel has been delivered.",
      p_event_at: new Date().toISOString(),
    });
    expect(error).toBeNull();
    expect(data?.applied).toBe(true);
    expect(data?.leg).toBe("return");
    expect(data?.new_status).toBe("completed");

    const { data: order } = await adminClient
      .from("orders")
      .select("fulfilment_status, confirmed_received_at")
      .eq("id", returnOrderId)
      .single();
    expect(order?.fulfilment_status).toBe("completed");
    expect(order?.confirmed_received_at).toBeNull(); // that field belongs to the ship_to_new_employee/confirm_received flow only
  });

  it("✓ the same delivered event applied again is a no-op (idempotent via the state guard)", async () => {
    const { data, error } = await adminClient.rpc("apply_sendcloud_tracking_event", {
      p_tracking_number: shipFromDispatchedTracking,
      p_carrier_code: "dpd",
      p_status_code: "delivered",
      p_status_description: "Parcel has been delivered.",
      p_event_at: new Date().toISOString(),
    });
    expect(error).toBeNull();
    expect(data?.applied).toBe(false); // already completed, no eligible transition
  });

  it("✓ a delivered event on a cancelled order is a no-op, not an error", async () => {
    const { data, error } = await adminClient.rpc("apply_sendcloud_tracking_event", {
      p_tracking_number: cancelledTracking,
      p_carrier_code: "dpd",
      p_status_code: "delivered",
      p_status_description: "Parcel has been delivered.",
      p_event_at: new Date().toISOString(),
    });
    expect(error).toBeNull();
    expect(data?.matched).toBe(true);
    expect(data?.applied).toBe(false);

    const { data: order } = await adminClient.from("orders").select("fulfilment_status").eq("id", cancelledOrderId).single();
    expect(order?.fulfilment_status).toBe("cancelled"); // unchanged
  });
});

describe("mark_return_completed() — staff-facing close-out for return orders (Phase 4 gap, closed 20260811)", () => {
  // Covers the function itself in isolation (service_role gate, actor
  // validation, service_type/state guards) -- the describe block above only
  // exercises the "already in_transit" success path as a side effect of
  // testing the tracking widening.
  let company: { id: string };
  const custEmail = uniqueEmail("p4-mrc-cust");
  const staffEmail = uniqueEmail("p4-mrc-staff");
  let staffId: string;
  let employee: { id: string };
  let returnOrderId: string;
  let shipOrderId: string;

  beforeAll(async () => {
    company = await createCompany("Phase4 MarkReturnCompleted Test Co");
    const staff = await createAuthUser(staffEmail);
    staffId = staff.id;
    await createProfile(staff.id, null, staffEmail, "internal_ops");

    const cust = await createAuthUser(custEmail);
    await createProfile(cust.id, company.id, custEmail, "company_admin");

    const { data: emp, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: company.id, full_name: "MRC Test", email: "mrc@example.com" })
      .select()
      .single();
    if (empError) throw empError;
    employee = emp as { id: string };

    const { data: addr, error: addrError } = await adminClient
      .from("addresses")
      .insert({ company_id: company.id, label: "HQ", address_line1: "1 Test St", city: "London", postcode: "E1 6AN" })
      .select()
      .single();
    if (addrError) throw addrError;

    const client = await clientAsUser(custEmail);

    const { data: returnId, error: returnError } = await client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "return",
      p_employee_id: employee.id,
      p_return_address_id: (addr as { id: string }).id,
    });
    if (returnError) throw returnError;
    returnOrderId = returnId as string;

    const { data: shipId, error: shipError } = await client.rpc("create_order", {
      p_kit_type_id: "phone",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
    });
    if (shipError) throw shipError;
    shipOrderId = shipId as string;

    await adminClient.from("orders").update({ fulfilment_status: "dispatched" }).in("id", [returnOrderId, shipOrderId]);
  });

  afterAll(async () => {
    await adminClient.from("orders").delete().eq("company_id", company.id);
    for (const email of [custEmail, staffEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("✗ a regular authenticated customer cannot call mark_return_completed", async () => {
    const client = await clientAsUser(custEmail);
    const { error } = await client.rpc("mark_return_completed", { p_order_id: returnOrderId, p_actor_id: staffId });
    expect(error).not.toBeNull();
  });

  it("✗ service_role call with a non-internal actor_id is rejected by assert_internal_actor", async () => {
    const client = await clientAsUser(custEmail);
    const { data: customerUser } = await client.auth.getUser();
    const { error } = await adminClient.rpc("mark_return_completed", {
      p_order_id: returnOrderId,
      p_actor_id: customerUser.user!.id,
    });
    expect(error).not.toBeNull();
  });

  it("✗ mark_return_completed refuses a ship_to_new_employee order", async () => {
    const { error } = await adminClient.rpc("mark_return_completed", { p_order_id: shipOrderId, p_actor_id: staffId });
    expect(error).not.toBeNull();
  });

  it("✓ service_role with a valid internal actor completes the return order and logs both trails", async () => {
    const { error } = await adminClient.rpc("mark_return_completed", { p_order_id: returnOrderId, p_actor_id: staffId });
    expect(error).toBeNull();

    const { data: order } = await adminClient
      .from("orders")
      .select("fulfilment_status, fulfilment_log")
      .eq("id", returnOrderId)
      .single();
    expect(order?.fulfilment_status).toBe("completed");
    const log = order?.fulfilment_log as Array<{ action: string }>;
    expect(log.some((entry) => entry.action === "return_received")).toBe(true);

    const { data: auditRows } = await adminClient
      .from("audit_log")
      .select("action, actor_id")
      .eq("target_id", returnOrderId)
      .eq("action", "order.mark_return_completed");
    expect(auditRows?.length).toBe(1);
    expect(auditRows?.[0].actor_id).toBe(staffId);
  });

  it("✗ completing an already-completed return order again is refused (state guard)", async () => {
    const { error } = await adminClient.rpc("mark_return_completed", { p_order_id: returnOrderId, p_actor_id: staffId });
    expect(error).not.toBeNull();
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

describe("RLS: public.communication_log — customer-visible, service_role-written only (Phase 5)", () => {
  let companyA: { id: string };
  let companyB: { id: string };
  let orderA: { id: string };

  const a1Email = uniqueEmail("comlog-a1");
  const a2Email = uniqueEmail("comlog-a2");
  const bEmail = uniqueEmail("comlog-b1");

  beforeAll(async () => {
    companyA = await createCompany("Comm Log Test Co A");
    companyB = await createCompany("Comm Log Test Co B");

    const a1 = await createAuthUser(a1Email);
    const a2 = await createAuthUser(a2Email);
    const b1 = await createAuthUser(bEmail);
    await createProfile(a1.id, companyA.id, a1Email, "company_admin");
    await createProfile(a2.id, companyA.id, a2Email, "company_member");
    await createProfile(b1.id, companyB.id, bEmail, "company_admin");

    const { data: employee, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: companyA.id, full_name: "Comm Log Test Employee", email: "commlog-emp@example.com" })
      .select()
      .single();
    if (empError) throw empError;

    const a1Client = await clientAsUser(a1Email);
    const { data: newOrderId, error: orderError } = await a1Client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "return",
      p_employee_id: employee!.id,
    });
    if (orderError) throw orderError;
    orderA = { id: newOrderId as string };

    await adminClient.from("communication_log").insert({
      order_id: orderA.id,
      company_id: companyA.id,
      channel: "email",
      type: "order_confirmation",
      audience: "customer",
      recipient: a1Email,
      subject: "Order confirmed — TEST",
      status: "sent",
      provider_message_id: `test-${Date.now()}`,
    });
  });

  afterAll(async () => {
    await deleteAuthUserByEmail(a1Email);
    await deleteAuthUserByEmail(a2Email);
    await deleteAuthUserByEmail(bEmail);
    await adminClient.from("orders").delete().eq("id", orderA.id);
    await adminClient.from("companies").delete().in("id", [companyA.id, companyB.id]);
  });

  it("✗ isolation: company B cannot read company A's communication_log rows", async () => {
    const client = await clientAsUser(bEmail);
    const { data, error } = await client.from("communication_log").select("*").eq("company_id", companyA.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("✓ collaboration: user 2 in company A CAN read the confirmation email sent for user 1's order", async () => {
    const client = await clientAsUser(a2Email);
    const { data, error } = await client.from("communication_log").select("*").eq("order_id", orderA.id);
    expect(error).toBeNull();
    expect(data?.length).toBe(1);
    expect(data?.[0].recipient).toBe(a1Email);
  });

  it("✗ clients cannot insert communication_log rows directly — service_role only", async () => {
    const client = await clientAsUser(a1Email);
    const { error } = await client.from("communication_log").insert({
      order_id: orderA.id,
      company_id: companyA.id,
      channel: "email",
      type: "dispatched",
      audience: "customer",
      recipient: a1Email,
      subject: "forged",
      status: "sent",
    });
    expect(error).not.toBeNull();
  });

  it("✗ clients cannot update communication_log status directly (e.g. faking a 'delivered' row)", async () => {
    const client = await clientAsUser(a1Email);
    const { error } = await client
      .from("communication_log")
      .update({ status: "delivered" })
      .eq("order_id", orderA.id);
    // Either an explicit RLS error, or a silent no-op (0 rows affected) —
    // assert on the row's actual state, which is what matters.
    void error;
    const { data } = await adminClient.from("communication_log").select("status").eq("order_id", orderA.id).single();
    expect(data?.status).toBe("sent");
  });
});

describe("RLS: public.notification_preferences — read + toggle own company only (Phase 5)", () => {
  let companyA: { id: string };
  let companyB: { id: string };
  const a1Email = uniqueEmail("notifpref-a1");
  const bEmail = uniqueEmail("notifpref-b1");

  beforeAll(async () => {
    companyA = await createCompany("Notif Pref Test Co A");
    companyB = await createCompany("Notif Pref Test Co B");
    const a1 = await createAuthUser(a1Email);
    const b1 = await createAuthUser(bEmail);
    await createProfile(a1.id, companyA.id, a1Email, "company_admin");
    await createProfile(b1.id, companyB.id, bEmail, "company_admin");
  });

  afterAll(async () => {
    await deleteAuthUserByEmail(a1Email);
    await deleteAuthUserByEmail(bEmail);
    await adminClient.from("companies").delete().in("id", [companyA.id, companyB.id]);
  });

  it("✓ seed_default_notification_preferences fires on company creation — all 4 event types, enabled by default", async () => {
    const { data, error } = await adminClient
      .from("notification_preferences")
      .select("event_type, enabled")
      .eq("company_id", companyA.id);
    expect(error).toBeNull();
    expect(data?.length).toBe(4);
    expect(data?.every((row) => row.enabled === true)).toBe(true);
  });

  it("✗ isolation: company B cannot read company A's notification preferences", async () => {
    const client = await clientAsUser(bEmail);
    const { data, error } = await client.from("notification_preferences").select("*").eq("company_id", companyA.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("✓ a company admin can mute one event type for their own company", async () => {
    const client = await clientAsUser(a1Email);
    const { error } = await client
      .from("notification_preferences")
      .update({ enabled: false })
      .eq("company_id", companyA.id)
      .eq("event_type", "checkin_sent");
    expect(error).toBeNull();

    const { data } = await adminClient
      .from("notification_preferences")
      .select("enabled")
      .eq("company_id", companyA.id)
      .eq("event_type", "checkin_sent")
      .single();
    expect(data?.enabled).toBe(false);

    const { data: viaHelper } = await adminClient.rpc("notification_enabled", {
      p_company_id: companyA.id,
      p_event_type: "checkin_sent",
    });
    expect(viaHelper).toBe(false);
  });

  it("✗ company B cannot mute company A's notifications", async () => {
    const client = await clientAsUser(bEmail);
    const { error } = await client
      .from("notification_preferences")
      .update({ enabled: false })
      .eq("company_id", companyA.id)
      .eq("event_type", "dispatched");
    // RLS silently drops rows outside the USING clause rather than erroring.
    void error;
    const { data } = await adminClient
      .from("notification_preferences")
      .select("enabled")
      .eq("company_id", companyA.id)
      .eq("event_type", "dispatched")
      .single();
    expect(data?.enabled).toBe(true);
  });

  it("✓ notification_enabled() defaults true for an event_type with no row (pre-Phase-5 company)", async () => {
    // Simulates a company created before this migration existed — no seeded
    // row for it, and the helper must not silently drop sends for
    // pre-existing tenants.
    const { data } = await adminClient.rpc("notification_enabled", {
      p_company_id: companyA.id,
      p_event_type: "nonexistent_event_type_for_test",
    });
    expect(data).toBe(true);
  });
});

describe("RLS: suppressed_recipients / resend_webhook_events — internal-only, default deny (Phase 5)", () => {
  it("✗ authenticated clients cannot read suppressed_recipients", async () => {
    const email = uniqueEmail("suppress-read");
    await createAuthUser(email);
    const client = await clientAsUser(email);
    const { data, error } = await client.from("suppressed_recipients").select("*");
    expect(error).toBeNull();
    expect(data).toEqual([]);
    await deleteAuthUserByEmail(email);
  });

  it("✗ authenticated clients cannot insert into suppressed_recipients (client can't forge their own exemption or someone else's suppression)", async () => {
    const email = uniqueEmail("suppress-write");
    await createAuthUser(email);
    const client = await clientAsUser(email);
    const { error } = await client
      .from("suppressed_recipients")
      .insert({ email: "forged@test.returnkits.invalid", reason: "hard_bounce" });
    expect(error).not.toBeNull();
    await deleteAuthUserByEmail(email);
  });

  it("✗ authenticated clients cannot read resend_webhook_events", async () => {
    const email = uniqueEmail("webhookevt-read");
    await createAuthUser(email);
    const client = await clientAsUser(email);
    const { data, error } = await client.from("resend_webhook_events").select("*");
    expect(error).toBeNull();
    expect(data).toEqual([]);
    await deleteAuthUserByEmail(email);
  });

  it("✓ service_role (webhook handler's identity) can read and write both tables", async () => {
    const testEmail = `suppress-admin-${Date.now()}@test.returnkits.invalid`;
    const { error: insertError } = await adminClient
      .from("suppressed_recipients")
      .insert({ email: testEmail, reason: "complaint" });
    expect(insertError).toBeNull();

    const { data } = await adminClient.from("suppressed_recipients").select("*").eq("email", testEmail).single();
    expect(data?.reason).toBe("complaint");

    await adminClient.from("suppressed_recipients").delete().eq("email", testEmail);
  });
});

describe("get_resend_webhook_secret() / order_dispatched_at() / orders_needing_checkin() — locked to service_role (Phase 5)", () => {
  it("✗ authenticated clients cannot call get_resend_webhook_secret", async () => {
    const email = uniqueEmail("webhooksecret");
    await createAuthUser(email);
    const client = await clientAsUser(email);
    const { error } = await client.rpc("get_resend_webhook_secret");
    expect(error).not.toBeNull();
    await deleteAuthUserByEmail(email);
  });

  it("✗ authenticated clients cannot call orders_needing_checkin", async () => {
    const email = uniqueEmail("needcheckin");
    await createAuthUser(email);
    const client = await clientAsUser(email);
    const { error } = await client.rpc("orders_needing_checkin");
    expect(error).not.toBeNull();
    await deleteAuthUserByEmail(email);
  });

  it("✓ service_role can call orders_needing_checkin and get a well-shaped result", async () => {
    const { data, error } = await adminClient.rpc("orders_needing_checkin");
    expect(error).toBeNull();
    expect(Array.isArray(data)).toBe(true);
  });
});

describe("Working-day / sending-hours helpers (Phase 5)", () => {
  // Fixed against the real 2026/2027 England & Wales bank holiday calendar
  // seeded in the working_days_helpers migration — see gov.uk/bank-holidays.
  it("✓ a seeded bank holiday is not a working day", async () => {
    const { data } = await adminClient.rpc("is_uk_working_day", { p_date: "2026-08-31" }); // Summer bank holiday
    expect(data).toBe(false);
  });

  it("✓ a weekday that isn't a bank holiday is a working day", async () => {
    const { data } = await adminClient.rpc("is_uk_working_day", { p_date: "2026-08-10" }); // Monday
    expect(data).toBe(true);
  });

  it("✓ a Saturday is not a working day", async () => {
    const { data } = await adminClient.rpc("is_uk_working_day", { p_date: "2026-08-08" });
    expect(data).toBe(false);
  });

  it("✓ add_working_days skips both the weekend and the bank holiday in between", async () => {
    // Fri 28 Aug 2026 + 1 working day should land on Tue 1 Sep 2026,
    // skipping Sat 29, Sun 30, and Mon 31 (Summer bank holiday).
    const { data } = await adminClient.rpc("add_working_days", { p_start: "2026-08-28", p_n: 1 });
    expect(data).toBe("2026-09-01");
  });

  it("✓ add_working_days(d, 1) never returns d itself, even when d is a working day", async () => {
    const { data } = await adminClient.rpc("add_working_days", { p_start: "2026-08-10", p_n: 1 });
    expect(data).toBe("2026-08-11");
  });

  it("✗ add_working_days rejects a negative n rather than silently going backwards", async () => {
    const { error } = await adminClient.rpc("add_working_days", { p_start: "2026-08-10", p_n: -1 });
    expect(error).not.toBeNull();
  });

  it("✓ next_working_day returns the same date when it's already a working day", async () => {
    const { data } = await adminClient.rpc("next_working_day", { p_date: "2026-08-10" });
    expect(data).toBe("2026-08-10");
  });

  it("✓ next_working_day rolls a bank holiday forward to the next real working day", async () => {
    const { data } = await adminClient.rpc("next_working_day", { p_date: "2026-08-31" });
    expect(data).toBe("2026-09-01");
  });

  it("✓ within_sending_hours: true for a weekday morning in London time", async () => {
    const { data } = await adminClient.rpc("within_sending_hours", { p_ts: "2026-08-10T09:00:00+01:00" });
    expect(data).toBe(true);
  });

  it("✗ within_sending_hours: false after 18:00 London time", async () => {
    const { data } = await adminClient.rpc("within_sending_hours", { p_ts: "2026-08-10T19:00:00+01:00" });
    expect(data).toBe(false);
  });

  it("✗ within_sending_hours: false on a bank holiday, even during business hours", async () => {
    const { data } = await adminClient.rpc("within_sending_hours", { p_ts: "2026-08-31T10:00:00+01:00" });
    expect(data).toBe(false);
  });

  it("✗ within_sending_hours: false on a Saturday", async () => {
    const { data } = await adminClient.rpc("within_sending_hours", { p_ts: "2026-08-08T10:00:00+01:00" });
    expect(data).toBe(false);
  });
});

describe("orders_needing_checkin() — dispatch-to-nudge SLA + re-nudge cooldown (Phase 5)", () => {
  let company: { id: string };
  let returnOrder: { id: string };
  const email = uniqueEmail("checkin-elig");

  beforeAll(async () => {
    company = await createCompany("Checkin Eligibility Test Co");
    const user = await createAuthUser(email);
    await createProfile(user.id, company.id, email, "company_admin");

    const { data: employee, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: company.id, full_name: "Checkin Eligibility Employee", email: "checkin-emp@example.com" })
      .select()
      .single();
    if (empError) throw empError;

    const client = await clientAsUser(email);
    const { data: newOrderId, error: orderError } = await client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "return",
      p_employee_id: employee!.id,
    });
    if (orderError) throw orderError;
    returnOrder = { id: newOrderId as string };

    // Backdate to a real dispatch, bypassing mark_order_dispatched (test
    // fixture arrangement via service_role, same pattern used elsewhere in
    // this suite) so the SLA threshold has genuinely elapsed.
    const { error: updateError } = await adminClient
      .from("orders")
      .update({
        fulfilment_status: "dispatched",
        fulfilment_log: [{ at: "2026-08-01T09:00:00+00:00", action: "dispatched", detail: {}, actor_id: user.id }],
      })
      .eq("id", returnOrder.id);
    if (updateError) throw updateError;
  });

  afterAll(async () => {
    await adminClient.from("orders").delete().eq("id", returnOrder.id);
    await deleteAuthUserByEmail(email);
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("✓ order_dispatched_at extracts the dispatched timestamp from fulfilment_log", async () => {
    const { data } = await adminClient.rpc("order_dispatched_at", { p_order_id: returnOrder.id });
    expect(data).not.toBeNull();
  });

  it("✓ a return order dispatched 5+ working days ago with no confirmation is due a checkin_sent nudge", async () => {
    const { data } = await adminClient.rpc("orders_needing_checkin");
    const match = (data as { order_id: string; checkin_type: string }[]).find((r) => r.order_id === returnOrder.id);
    expect(match?.checkin_type).toBe("checkin_sent");
  });

  it("✗ retrying the eligibility check immediately after a nudge was logged returns nothing further (dedupe/cooldown)", async () => {
    await adminClient.from("communication_log").insert({
      order_id: returnOrder.id,
      company_id: company.id,
      channel: "email",
      type: "checkin_sent",
      audience: "customer",
      recipient: email,
      subject: "Have you sent your kit back? — TEST",
      status: "sent",
    });

    const { data } = await adminClient.rpc("orders_needing_checkin");
    const match = (data as { order_id: string; checkin_type: string }[]).find((r) => r.order_id === returnOrder.id);
    expect(match).toBeUndefined();
  });

  it("✗ a ship-to-new-employee order that was just dispatched is not yet due a nudge", async () => {
    const shipEmail = uniqueEmail("checkin-elig-ship");
    const shipUser = await createAuthUser(shipEmail);
    await createProfile(shipUser.id, company.id, shipEmail, "company_admin");

    const { data: shipEmployee, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: company.id, full_name: "Ship Checkin Employee", email: "ship-checkin-emp@example.com" })
      .select()
      .single();
    if (empError) throw empError;

    const shipClient = await clientAsUser(shipEmail);
    const { data: newOrderId, error: orderError } = await shipClient.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "ship_to_new_employee",
      p_employee_id: shipEmployee!.id,
    });
    if (orderError) throw orderError;

    await adminClient
      .from("orders")
      .update({
        fulfilment_status: "dispatched",
        fulfilment_log: [{ at: new Date().toISOString(), action: "dispatched", detail: {}, actor_id: shipUser.id }],
      })
      .eq("id", newOrderId as string);

    const { data } = await adminClient.rpc("orders_needing_checkin");
    const match = (data as { order_id: string; checkin_type: string }[]).find((r) => r.order_id === newOrderId);
    expect(match).toBeUndefined();

    await adminClient.from("orders").delete().eq("id", newOrderId as string);
    await deleteAuthUserByEmail(shipEmail);
  });
});

// The blocks below close gaps found in a Launch Gate review: real,
// tenant-scoped RLS policies existed for these tables from Phase 2/3
// onward, but no test ever exercised either direction on them -- they were
// only ever touched via adminClient as fixture setup/teardown for other
// describe blocks, never as the thing under test.

describe("RLS: public.companies — isolation, collaboration, and admin-only update (gap closed post-Phase-5)", () => {
  let companyA: { id: string };
  let companyB: { id: string };
  const adminEmail = uniqueEmail("co-admin");
  const memberEmail = uniqueEmail("co-member");
  const bEmail = uniqueEmail("co-b");

  beforeAll(async () => {
    companyA = await createCompany("Company RLS Test Co A");
    companyB = await createCompany("Company RLS Test Co B");

    const admin = await createAuthUser(adminEmail);
    const member = await createAuthUser(memberEmail);
    const b1 = await createAuthUser(bEmail);

    await createProfile(admin.id, companyA.id, adminEmail, "company_admin");
    await createProfile(member.id, companyA.id, memberEmail, "company_member");
    await createProfile(b1.id, companyB.id, bEmail, "company_admin");
  });

  afterAll(async () => {
    for (const email of [adminEmail, memberEmail, bEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().in("id", [companyA.id, companyB.id]);
  });

  it("✓ collaboration: a company_member can read their own company's row", async () => {
    const client = await clientAsUser(memberEmail);
    const { data, error } = await client.from("companies").select("id, name").eq("id", companyA.id);
    expect(error).toBeNull();
    expect(data?.length).toBe(1);
  });

  it("✗ isolation: a user in company A cannot read company B's row", async () => {
    const client = await clientAsUser(adminEmail);
    const { data, error } = await client.from("companies").select("*").eq("id", companyB.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("✓ company_admin can update their own company (e.g. billing_email)", async () => {
    const client = await clientAsUser(adminEmail);
    const { error } = await client
      .from("companies")
      .update({ billing_email: "billing@company-a-test.invalid" })
      .eq("id", companyA.id);
    expect(error).toBeNull();
    const { data } = await adminClient.from("companies").select("billing_email").eq("id", companyA.id).single();
    expect(data?.billing_email).toBe("billing@company-a-test.invalid");
  });

  it("✗ a company_member (not admin) cannot update their own company", async () => {
    const client = await clientAsUser(memberEmail);
    const { error, count } = await client
      .from("companies")
      .update({ billing_email: "should-not-land@company-a-test.invalid" })
      .eq("id", companyA.id)
      .select("id", { count: "exact" });
    // RLS silently filters the row out of the UPDATE's WHERE match rather
    // than erroring -- zero rows affected is the assertion, same shape as
    // the client-supplied-company_id-override tests elsewhere in this file.
    expect(error).toBeNull();
    expect(count).toBe(0);
  });

  it("✗ a user in company B cannot update company A's row", async () => {
    const client = await clientAsUser(bEmail);
    const { error, count } = await client
      .from("companies")
      .update({ billing_email: "cross-tenant@company-a-test.invalid" })
      .eq("id", companyA.id)
      .select("id", { count: "exact" });
    expect(error).toBeNull();
    expect(count).toBe(0);
  });
});

describe("RLS: public.bundles — isolation and collaboration via create_bundle() (gap closed post-Phase-5)", () => {
  let companyA: { id: string };
  let companyB: { id: string };
  const a1Email = uniqueEmail("bnd-a1");
  const a2Email = uniqueEmail("bnd-a2");
  const bEmail = uniqueEmail("bnd-b1");
  let bundleAId: string;

  beforeAll(async () => {
    companyA = await createCompany("Bundle RLS Test Co A");
    companyB = await createCompany("Bundle RLS Test Co B");

    const a1 = await createAuthUser(a1Email);
    const a2 = await createAuthUser(a2Email);
    const b1 = await createAuthUser(bEmail);

    await createProfile(a1.id, companyA.id, a1Email, "company_admin");
    await createProfile(a2.id, companyA.id, a2Email, "company_member");
    await createProfile(b1.id, companyB.id, bEmail, "company_admin");

    const client = await clientAsUser(a1Email);
    const { data: bundleId, error } = await client.rpc("create_bundle");
    if (error) throw error;
    bundleAId = bundleId as string;
  });

  afterAll(async () => {
    await adminClient.from("bundles").delete().eq("id", bundleAId);
    for (const email of [a1Email, a2Email, bEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().in("id", [companyA.id, companyB.id]);
  });

  it("issues a well-formed bundle reference (BND-YYMMDD-NNN)", async () => {
    const { data } = await adminClient.from("bundles").select("reference").eq("id", bundleAId).single();
    expect(data?.reference).toMatch(/^BND-\d{6}-\d{3,}$/);
  });

  it("✓ collaboration: user 2 in company A CAN see the bundle user 1 created", async () => {
    const client = await clientAsUser(a2Email);
    const { data, error } = await client.from("bundles").select("id").eq("id", bundleAId);
    expect(error).toBeNull();
    expect(data?.length).toBe(1);
  });

  it("✗ isolation: a user in company B cannot see company A's bundle", async () => {
    const client = await clientAsUser(bEmail);
    const { data, error } = await client.from("bundles").select("*").eq("id", bundleAId);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("✗ create_bundle refuses a profile-less user, same as create_order", async () => {
    const noProfileEmail = uniqueEmail("bnd-noprofile");
    await createAuthUser(noProfileEmail);
    const client = await clientAsUser(noProfileEmail);
    const { error } = await client.rpc("create_bundle");
    expect(error).not.toBeNull();
    await deleteAuthUserByEmail(noProfileEmail);
  });
});

describe("RLS: public.audit_log — internal-staff-only, no customer visibility (gap closed post-Phase-5)", () => {
  let company: { id: string };
  const adminEmail = uniqueEmail("aud-admin");
  const internalEmail = uniqueEmail("aud-staff");
  let auditRowId: string;

  beforeAll(async () => {
    company = await createCompany("Audit Log RLS Test Co");
    const admin = await createAuthUser(adminEmail);
    const staff = await createAuthUser(internalEmail);
    await createProfile(admin.id, company.id, adminEmail, "company_admin");
    await createProfile(staff.id, null, internalEmail, "internal_ops");

    const { data, error } = await adminClient
      .from("audit_log")
      .insert({
        actor_id: admin.id,
        action: "test.audit_log_rls_probe",
        target_table: "companies",
        target_id: company.id,
        before: null,
        after: { probe: true },
      })
      .select("id")
      .single();
    if (error) throw error;
    auditRowId = data!.id as string;
  });

  afterAll(async () => {
    await adminClient.from("audit_log").delete().eq("id", auditRowId);
    await deleteAuthUserByEmail(adminEmail);
    await deleteAuthUserByEmail(internalEmail);
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("✗ a company_admin (customer, not staff) reads zero audit_log rows, even for their own company", async () => {
    const client = await clientAsUser(adminEmail);
    const { data, error } = await client.from("audit_log").select("*").eq("id", auditRowId);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("✓ internal_ops can read audit_log", async () => {
    const client = await clientAsUser(internalEmail);
    const { data, error } = await client.from("audit_log").select("id").eq("id", auditRowId);
    expect(error).toBeNull();
    expect(data?.length).toBe(1);
  });

  it("✗ a company_admin cannot insert audit_log rows directly", async () => {
    const client = await clientAsUser(adminEmail);
    const { error } = await client.from("audit_log").insert({
      actor_id: null,
      action: "test.forged",
      target_table: "companies",
      target_id: company.id,
      before: null,
      after: {},
    });
    expect(error).not.toBeNull();
  });
});

describe("RLS: internal-only tables default-deny for every client role (gap closed post-Phase-5)", () => {
  // reference_counters and stripe_webhook_events predate the Phase 5
  // suppressed_recipients/resend_webhook_events pattern (RLS enabled, zero
  // policies -- service_role bypasses RLS entirely, every other role gets
  // nothing) but never got the equivalent "prove the default-deny actually
  // holds" test those two got. Closing that gap here rather than
  // retro-fitting it into the Phase 2/3 describe blocks above.

  it("✗ authenticated clients cannot read reference_counters", async () => {
    const email = uniqueEmail("refcounter-deny");
    const company = await createCompany("Reference Counter Deny Test Co");
    const user = await createAuthUser(email);
    await createProfile(user.id, company.id, email, "company_admin");
    const client = await clientAsUser(email);

    const { data, error } = await client.from("reference_counters").select("*");
    expect(error).toBeNull();
    expect(data).toEqual([]);

    await deleteAuthUserByEmail(email);
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("✗ authenticated clients cannot read stripe_webhook_events", async () => {
    const email = uniqueEmail("stripeevt-deny");
    const company = await createCompany("Stripe Webhook Deny Test Co");
    const user = await createAuthUser(email);
    await createProfile(user.id, company.id, email, "company_admin");
    const client = await clientAsUser(email);

    const { data, error } = await client.from("stripe_webhook_events").select("*");
    expect(error).toBeNull();
    expect(data).toEqual([]);

    await deleteAuthUserByEmail(email);
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("✗ authenticated clients cannot write kit_types (world-readable pricing catalogue must stay read-only)", async () => {
    const email = uniqueEmail("kittypes-deny");
    const company = await createCompany("Kit Types Deny Test Co");
    const user = await createAuthUser(email);
    await createProfile(user.id, company.id, email, "company_admin");
    const client = await clientAsUser(email);

    const { error } = await client.from("kit_types").update({ price_ex_vat_pence: 1 }).eq("id", "laptop");
    expect(error).not.toBeNull();

    // Confirm the world-readable side still works -- this table SHOULD be
    // selectable by everyone, only writes should be blocked.
    const { data: readBack, error: readError } = await client.from("kit_types").select("id").eq("id", "laptop");
    expect(readError).toBeNull();
    expect(readBack?.length).toBe(1);

    await deleteAuthUserByEmail(email);
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("✗ authenticated clients cannot write cover_tiers (same world-readable-but-read-only shape as kit_types)", async () => {
    const email = uniqueEmail("covertiers-deny");
    const company = await createCompany("Cover Tiers Deny Test Co");
    const user = await createAuthUser(email);
    await createProfile(user.id, company.id, email, "company_admin");
    const client = await clientAsUser(email);

    const { error } = await client.from("cover_tiers").update({ price_ex_vat_pence: 1 }).eq("id", "up_to_500");
    expect(error).not.toBeNull();

    const { data: readBack, error: readError } = await client.from("cover_tiers").select("id").eq("id", "up_to_500");
    expect(readError).toBeNull();
    expect(readBack?.length).toBe(1);

    await deleteAuthUserByEmail(email);
    await adminClient.from("companies").delete().eq("id", company.id);
  });
});

describe("Enhanced Cover — cover_tiers, order snapshotting, and flag_cover_claim (20260812)", () => {
  // Built after the fact: the architecture doc (§20) fully designed Enhanced
  // Cover, but nothing was ever wired up -- no table, no UI, nothing live --
  // until enterprise pricing was quoted to a real prospect assuming it
  // existed. See CLAUDE.md's Enhanced Cover locked decision.
  let company: { id: string };
  const ownerEmail = uniqueEmail("cover-owner");
  const staffEmail = uniqueEmail("cover-staff");
  let staffId: string;
  let employee: { id: string };

  beforeAll(async () => {
    company = await createCompany("Enhanced Cover Test Co");
    const owner = await createAuthUser(ownerEmail);
    const staff = await createAuthUser(staffEmail);
    staffId = staff.id;
    await createProfile(owner.id, company.id, ownerEmail, "company_admin");
    await createProfile(staff.id, null, staffEmail, "internal_ops");

    const { data: emp, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: company.id, full_name: "Cover Test Employee", email: "cover-emp@example.com" })
      .select()
      .single();
    if (empError) throw empError;
    employee = emp as { id: string };
  });

  afterAll(async () => {
    await adminClient.from("orders").delete().eq("company_id", company.id);
    for (const email of [ownerEmail, staffEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().eq("id", company.id);
  });

  it("✓ create_order with no p_cover_tier_id leaves both cover columns null (cover stays optional)", async () => {
    const client = await clientAsUser(ownerEmail);
    const { data: orderId, error } = await client.rpc("create_order", {
      p_kit_type_id: "phone",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
    });
    expect(error).toBeNull();

    const { data: order } = await adminClient
      .from("orders")
      .select("cover_tier_id, cover_price_ex_vat_pence")
      .eq("id", orderId as string)
      .single();
    expect(order?.cover_tier_id).toBeNull();
    expect(order?.cover_price_ex_vat_pence).toBeNull();
  });

  it("✓ create_order with a cover tier snapshots the price onto the order", async () => {
    const client = await clientAsUser(ownerEmail);
    const { data: orderId, error } = await client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
      p_cover_tier_id: "up_to_1000",
    });
    expect(error).toBeNull();

    const { data: order } = await adminClient
      .from("orders")
      .select("cover_tier_id, cover_price_ex_vat_pence")
      .eq("id", orderId as string)
      .single();
    expect(order?.cover_tier_id).toBe("up_to_1000");
    expect(order?.cover_price_ex_vat_pence).toBe(1000);
  });

  it("✗ create_order rejects an unknown cover tier", async () => {
    const client = await clientAsUser(ownerEmail);
    const { error } = await client.rpc("create_order", {
      p_kit_type_id: "phone",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
      p_cover_tier_id: "not_a_real_tier",
    });
    expect(error).not.toBeNull();
  });

  it("✗ database constraint: cover_tier_id and cover_price_ex_vat_pence must both be null or both be set", async () => {
    // Direct write via the service_role client, bypassing create_order's own
    // validation -- this is what actually enforces the snapshot pairing, not
    // application code, so it needs to be tested at this layer too.
    const { data: emp } = await adminClient
      .from("employees")
      .select("id")
      .eq("id", employee.id)
      .single();
    const { error } = await adminClient.from("orders").insert({
      company_id: company.id,
      reference: `RKL-260812-${Math.floor(Math.random() * 900) + 100}`,
      kit_type_id: "laptop",
      service_type: "ship_to_new_employee",
      source: "internal_staff",
      created_by: staffId,
      employee_id: emp!.id,
      price_ex_vat_pence: 6500,
      cover_tier_id: "up_to_1000",
      cover_price_ex_vat_pence: null,
    } as never);
    expect(error).not.toBeNull();
  });

  it("✓ flag_cover_claim requires service_role, an internal actor, and an order that actually has cover", async () => {
    const client = await clientAsUser(ownerEmail);
    const { data: orderId, error: createError } = await client.rpc("create_order", {
      p_kit_type_id: "monitor",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
      p_cover_tier_id: "up_to_2000",
    });
    expect(createError).toBeNull();

    // Regular authenticated client, even the order's own owner, is refused.
    const directCall = await client.rpc("flag_cover_claim", {
      p_order_id: orderId as string,
      p_actor_id: staffId,
      p_notes: "Device lost in transit",
    });
    expect(directCall.error).not.toBeNull();

    // service_role with a non-internal actor is refused by assert_internal_actor.
    const { data: ownerUser } = await client.auth.getUser();
    const nonInternalCall = await adminClient.rpc("flag_cover_claim", {
      p_order_id: orderId as string,
      p_actor_id: ownerUser.user!.id,
      p_notes: "Device lost in transit",
    });
    expect(nonInternalCall.error).not.toBeNull();

    // A separately-created order with no cover on it is refused even for a
    // legitimate service_role + internal_ops call.
    const { data: noCoverOrderId } = await client.rpc("create_order", {
      p_kit_type_id: "phone",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
    });
    const noCoverCall = await adminClient.rpc("flag_cover_claim", {
      p_order_id: noCoverOrderId as string,
      p_actor_id: staffId,
      p_notes: "No cover on this order",
    });
    expect(noCoverCall.error).not.toBeNull();

    // The real, valid path: service_role + internal actor + an order with cover.
    const { error: validError } = await adminClient.rpc("flag_cover_claim", {
      p_order_id: orderId as string,
      p_actor_id: staffId,
      p_notes: "Device lost in transit",
    });
    expect(validError).toBeNull();

    const { data: order } = await adminClient
      .from("orders")
      .select("cover_claim_filed_at, fulfilment_log")
      .eq("id", orderId as string)
      .single();
    expect(order?.cover_claim_filed_at).not.toBeNull();
    const log = (order?.fulfilment_log ?? []) as Array<{ action: string }>;
    expect(log.some((entry) => entry.action === "cover_claim_flagged")).toBe(true);

    const { data: auditRows } = await adminClient
      .from("audit_log")
      .select("action, actor_id")
      .eq("target_id", orderId as string)
      .eq("action", "order.flag_cover_claim");
    expect(auditRows?.length).toBe(1);
    expect(auditRows?.[0].actor_id).toBe(staffId);

    // Filing a second claim on the same order is refused -- one claim record
    // per order, matching the state-guard pattern used elsewhere (e.g.
    // mark_order_paid refusing an already-paid order).
    const secondClaim = await adminClient.rpc("flag_cover_claim", {
      p_order_id: orderId as string,
      p_actor_id: staffId,
      p_notes: "Trying again",
    });
    expect(secondClaim.error).not.toBeNull();
  });

  it("✓ invoice arithmetic with a cover line is penny-accurate (mirrors record_stripe_payment's kit-only case)", async () => {
    // create-checkout-session (not exercised here -- that's Deno, not
    // Postgres) computes subtotal/VAT across kit + cover lines and hands
    // the totals to record_stripe_payment as plain integers, so this test
    // exercises the same arithmetic record_stripe_payment always has: given
    // a kit line (£65 ex VAT) and a cover line (£10 ex VAT) at 20% VAT
    // each, subtotal = 7500p, VAT = 1500p, total = 9000p.
    const client = await clientAsUser(ownerEmail);
    const { data: orderId, error: createError } = await client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "ship_to_new_employee",
      p_employee_id: employee.id,
      p_cover_tier_id: "up_to_1000",
    });
    expect(createError).toBeNull();

    const eventId = `evt_cover_${Date.now()}`;
    const sessionId = `cs_cover_${Date.now()}`;
    const { data: invoiceId, error } = await adminClient.rpc("record_stripe_payment", {
      p_event_id: eventId,
      p_event_type: "checkout.session.completed",
      p_checkout_session_id: sessionId,
      p_payment_intent_id: `pi_${sessionId}`,
      p_company_id: company.id,
      p_order_ids: [orderId as string],
      p_subtotal_ex_vat_pence: 7500, // 6500 (laptop) + 1000 (cover)
      p_vat_pence: 1500, // 1300 (laptop VAT) + 200 (cover VAT)
      p_total_inc_vat_pence: 9000,
    });
    expect(error).toBeNull();

    const { data: invoice } = await adminClient
      .from("invoices")
      .select("subtotal_ex_vat_pence, vat_pence, total_inc_vat_pence")
      .eq("id", invoiceId as string)
      .single();
    expect(invoice?.subtotal_ex_vat_pence).toBe(7500);
    expect(invoice?.vat_pence).toBe(1500);
    expect(invoice?.total_inc_vat_pence).toBe(9000);
    expect(invoice!.subtotal_ex_vat_pence + invoice!.vat_pence).toBe(invoice!.total_inc_vat_pence);
  });
});

describe("Prepaid credits — credit_ledger RLS, redemption, purchase, and restoration (20260812)", () => {
  // Scope confirmed with the user: prepaid credits only (no free-kit promo),
  // same per-unit price as self-serve kit_types, saved card for topping up
  // only. See CLAUDE.md's credits locked decision and
  // 20260812220000_credits_schema_and_rpcs.sql.
  let companyA: { id: string };
  let companyB: { id: string };
  const a1Email = uniqueEmail("credit-a1");
  const a2Email = uniqueEmail("credit-a2");
  const bEmail = uniqueEmail("credit-b1");
  const staffEmail = uniqueEmail("credit-staff");
  let staffId: string;
  let employeeA: { id: string };

  beforeAll(async () => {
    companyA = await createCompany("Credits Test Co A");
    companyB = await createCompany("Credits Test Co B");

    const a1 = await createAuthUser(a1Email);
    const a2 = await createAuthUser(a2Email);
    const b1 = await createAuthUser(bEmail);
    const staff = await createAuthUser(staffEmail);
    staffId = staff.id;

    await createProfile(a1.id, companyA.id, a1Email, "company_admin");
    await createProfile(a2.id, companyA.id, a2Email, "company_member");
    await createProfile(b1.id, companyB.id, bEmail, "company_admin");
    await createProfile(staff.id, null, staffEmail, "internal_ops");

    const { data: emp, error: empError } = await adminClient
      .from("employees")
      .insert({ company_id: companyA.id, full_name: "Credit Test Employee", email: "credit-emp@example.com" })
      .select()
      .single();
    if (empError) throw empError;
    employeeA = emp as { id: string };
  });

  afterAll(async () => {
    await adminClient.from("orders").delete().in("company_id", [companyA.id, companyB.id]);
    await adminClient.from("credit_ledger").delete().in("company_id", [companyA.id, companyB.id]);
    await adminClient.from("invoices").delete().in("company_id", [companyA.id, companyB.id]);
    for (const email of [a1Email, a2Email, bEmail, staffEmail]) {
      await deleteAuthUserByEmail(email);
    }
    await adminClient.from("companies").delete().in("id", [companyA.id, companyB.id]);
  });

  // Balance helper mirrors the SQL in create_order/record_credit_purchase/
  // cancel_order exactly: sum of credit quantities minus sum of debit
  // quantities for a given company + kit type.
  async function balanceFor(companyId: string, kitTypeId: string): Promise<number> {
    const { data, error } = await adminClient
      .from("credit_ledger")
      .select("direction, quantity")
      .eq("company_id", companyId)
      .eq("kit_type_id", kitTypeId);
    if (error) throw error;
    return (data ?? []).reduce((sum, row) => sum + (row.direction === "credit" ? row.quantity : -row.quantity), 0);
  }

  describe("RLS: public.credit_ledger — isolation, collaboration, and no client writes", () => {
    it("✗ isolation: a company B user cannot read company A's ledger rows", async () => {
      await adminClient.from("credit_ledger").insert({
        company_id: companyA.id,
        kit_type_id: "laptop",
        transaction_type: "purchase",
        direction: "credit",
        quantity: 5,
        balance_after: 5,
        reason: "seed for isolation test",
      });

      const client = await clientAsUser(bEmail);
      const { data, error } = await client.from("credit_ledger").select("*").eq("company_id", companyA.id);
      expect(error).toBeNull();
      expect(data).toEqual([]);
    });

    it("✓ collaboration: a second user in company A can read company A's ledger rows", async () => {
      const client = await clientAsUser(a2Email);
      const { data, error } = await client
        .from("credit_ledger")
        .select("kit_type_id")
        .eq("company_id", companyA.id);
      expect(error).toBeNull();
      expect((data ?? []).length).toBeGreaterThan(0);
    });

    it("✓ admin override: internal_ops reads ledger rows across companies", async () => {
      await adminClient.from("credit_ledger").insert({
        company_id: companyB.id,
        kit_type_id: "phone",
        transaction_type: "purchase",
        direction: "credit",
        quantity: 3,
        balance_after: 3,
        reason: "seed for admin override test",
      });

      const client = await clientAsUser(staffEmail);
      const { data, error } = await client
        .from("credit_ledger")
        .select("company_id")
        .in("company_id", [companyA.id, companyB.id]);
      expect(error).toBeNull();
      const seen = new Set((data ?? []).map((row) => row.company_id));
      expect(seen.has(companyA.id)).toBe(true);
      expect(seen.has(companyB.id)).toBe(true);
    });

    it("✗ append-only: an authenticated client cannot insert into credit_ledger directly", async () => {
      const client = await clientAsUser(a1Email);
      const { error } = await client.from("credit_ledger").insert({
        company_id: companyA.id,
        kit_type_id: "laptop",
        transaction_type: "adjustment",
        direction: "credit",
        quantity: 1000,
        balance_after: 1000,
        reason: "attempted forged credit",
      });
      expect(error).not.toBeNull();
    });
  });

  describe("create_order() credit redemption", () => {
    it("✗ refuses to redeem when the balance is zero", async () => {
      const client = await clientAsUser(a1Email);
      const { error } = await client.rpc("create_order", {
        p_kit_type_id: "monitor",
        p_service_type: "ship_to_new_employee",
        p_employee_id: employeeA.id,
        p_pay_with_credit: true,
      });
      expect(error).not.toBeNull();
    });

    it("✗ refuses to combine pay-with-credit and Enhanced Cover on the same order", async () => {
      // Grant a balance first so the rejection is provably about the
      // cover/credit combination, not insufficient funds.
      await adminClient.from("credit_ledger").insert({
        company_id: companyA.id,
        kit_type_id: "monitor",
        transaction_type: "purchase",
        direction: "credit",
        quantity: 1,
        balance_after: 1,
        reason: "seed for cover+credit rejection test",
      });

      const client = await clientAsUser(a1Email);
      const { error } = await client.rpc("create_order", {
        p_kit_type_id: "monitor",
        p_service_type: "ship_to_new_employee",
        p_employee_id: employeeA.id,
        p_cover_tier_id: "up_to_500",
        p_pay_with_credit: true,
      });
      expect(error).not.toBeNull();

      const balance = await balanceFor(companyA.id, "monitor");
      expect(balance).toBe(1); // untouched — the rejected call must not have debited anything
    });

    it("✓ redeems a credit: order is created paid, snapshotted to its ledger debit, and the balance drops by one", async () => {
      await adminClient.from("credit_ledger").insert({
        company_id: companyA.id,
        kit_type_id: "laptop",
        transaction_type: "purchase",
        direction: "credit",
        quantity: 2,
        balance_after: 2,
        reason: "seed for redemption test",
      });
      const balanceBefore = await balanceFor(companyA.id, "laptop");
      expect(balanceBefore).toBe(2);

      const client = await clientAsUser(a1Email);
      const { data: orderId, error } = await client.rpc("create_order", {
        p_kit_type_id: "laptop",
        p_service_type: "ship_to_new_employee",
        p_employee_id: employeeA.id,
        p_pay_with_credit: true,
      });
      expect(error).toBeNull();

      const { data: order } = await adminClient
        .from("orders")
        .select("payment_status, paid_with_credit, credit_transaction_id")
        .eq("id", orderId as string)
        .single();
      expect(order?.payment_status).toBe("paid");
      expect(order?.paid_with_credit).toBe(true);
      expect(order?.credit_transaction_id).not.toBeNull();

      const { data: ledgerRow } = await adminClient
        .from("credit_ledger")
        .select("direction, quantity, balance_after, order_id")
        .eq("id", order!.credit_transaction_id as string)
        .single();
      expect(ledgerRow?.direction).toBe("debit");
      expect(ledgerRow?.quantity).toBe(1);
      expect(ledgerRow?.order_id).toBe(orderId);
      expect(ledgerRow?.balance_after).toBe(1);

      const balanceAfter = await balanceFor(companyA.id, "laptop");
      expect(balanceAfter).toBe(1);
    });

    it("✗ database constraint: paid_with_credit and credit_transaction_id must agree (orders_credit_snapshot_consistent)", async () => {
      const { error } = await adminClient.from("orders").insert({
        company_id: companyA.id,
        reference: `RKL-260812-${Math.floor(Math.random() * 900) + 100}`,
        kit_type_id: "laptop",
        service_type: "ship_to_new_employee",
        source: "internal_staff",
        created_by: staffId,
        employee_id: employeeA.id,
        price_ex_vat_pence: 6500,
        payment_status: "paid",
        paid_with_credit: true,
        credit_transaction_id: null,
      } as never);
      expect(error).not.toBeNull();
    });

    it("✗ database constraint: a credit-paid order cannot also carry Enhanced Cover (orders_credit_excludes_cover)", async () => {
      // Needs a real credit_ledger row to satisfy the FK on
      // credit_transaction_id — this is testing the CHECK constraint
      // specifically, isolated from the FK and the snapshot-consistency
      // constraint (both satisfied here on purpose).
      const { data: ledgerRow, error: ledgerError } = await adminClient
        .from("credit_ledger")
        .insert({
          company_id: companyA.id,
          kit_type_id: "monitor",
          transaction_type: "redemption",
          direction: "debit",
          quantity: 1,
          balance_after: 0,
          reason: "seed for constraint isolation test",
        })
        .select()
        .single();
      if (ledgerError) throw ledgerError;

      const { error } = await adminClient.from("orders").insert({
        company_id: companyA.id,
        reference: `RKM-260812-${Math.floor(Math.random() * 900) + 100}`,
        kit_type_id: "monitor",
        service_type: "ship_to_new_employee",
        source: "internal_staff",
        created_by: staffId,
        employee_id: employeeA.id,
        price_ex_vat_pence: 8500,
        payment_status: "paid",
        paid_with_credit: true,
        credit_transaction_id: (ledgerRow as { id: string }).id,
        cover_tier_id: "up_to_500",
        cover_price_ex_vat_pence: 500,
      } as never);
      expect(error).not.toBeNull();
    });

    it("✓ race safety: two concurrent redemptions against a balance of one grant exactly one order", async () => {
      await adminClient.from("credit_ledger").insert({
        company_id: companyA.id,
        kit_type_id: "phone",
        transaction_type: "purchase",
        direction: "credit",
        quantity: 1,
        balance_after: 1,
        reason: "seed for race test",
      });

      const client = await clientAsUser(a1Email);
      const [first, second] = await Promise.all([
        client.rpc("create_order", {
          p_kit_type_id: "phone",
          p_service_type: "ship_to_new_employee",
          p_employee_id: employeeA.id,
          p_pay_with_credit: true,
        }),
        client.rpc("create_order", {
          p_kit_type_id: "phone",
          p_service_type: "ship_to_new_employee",
          p_employee_id: employeeA.id,
          p_pay_with_credit: true,
        }),
      ]);

      const successes = [first, second].filter((r) => r.error === null);
      const failures = [first, second].filter((r) => r.error !== null);
      expect(successes.length).toBe(1);
      expect(failures.length).toBe(1);

      const balance = await balanceFor(companyA.id, "phone");
      expect(balance).toBe(0); // exactly one debit landed, not zero and not two
    });
  });

  describe("record_credit_purchase() — webhook-only, atomic, idempotent", () => {
    it("✗ an authenticated client cannot call record_credit_purchase directly", async () => {
      const client = await clientAsUser(a1Email);
      const { error } = await client.rpc("record_credit_purchase", {
        p_event_id: `evt_forged_credit_${Date.now()}`,
        p_event_type: "checkout.session.completed",
        p_checkout_session_id: `cs_forged_credit_${Date.now()}`,
        p_payment_intent_id: null,
        p_company_id: companyA.id,
        p_kit_type_id: "laptop",
        p_quantity: 100,
        p_subtotal_ex_vat_pence: 650000,
        p_vat_pence: 130000,
        p_total_inc_vat_pence: 780000,
      });
      expect(error).not.toBeNull();
    });

    it("✓ service_role: issues an invoice, credits the ledger, and the balance goes up by the purchased quantity", async () => {
      const balanceBefore = await balanceFor(companyA.id, "tablet");
      const eventId = `evt_credit_${Date.now()}`;
      const sessionId = `cs_credit_${Date.now()}`;

      const { data: invoiceId, error } = await adminClient.rpc("record_credit_purchase", {
        p_event_id: eventId,
        p_event_type: "checkout.session.completed",
        p_checkout_session_id: sessionId,
        p_payment_intent_id: `pi_${sessionId}`,
        p_company_id: companyA.id,
        p_kit_type_id: "tablet",
        p_quantity: 5,
        p_subtotal_ex_vat_pence: 5000,
        p_vat_pence: 1000,
        p_total_inc_vat_pence: 6000,
      });
      expect(error).toBeNull();
      expect(invoiceId).not.toBeNull();

      const { data: invoice } = await adminClient
        .from("invoices")
        .select("total_inc_vat_pence, invoice_number")
        .eq("id", invoiceId as string)
        .single();
      expect(invoice?.total_inc_vat_pence).toBe(6000);
      expect(Number.isInteger(invoice?.invoice_number)).toBe(true);

      const balanceAfter = await balanceFor(companyA.id, "tablet");
      expect(balanceAfter).toBe(balanceBefore + 5);
    });

    it("✓ replaying the same event id twice changes nothing", async () => {
      const balanceBefore = await balanceFor(companyA.id, "accessories");
      const eventId = `evt_credit_replay_${Date.now()}`;
      const args = {
        p_event_id: eventId,
        p_event_type: "checkout.session.completed",
        p_checkout_session_id: `cs_credit_replay_${Date.now()}`,
        p_payment_intent_id: null,
        p_company_id: companyA.id,
        p_kit_type_id: "accessories",
        p_quantity: 10,
        p_subtotal_ex_vat_pence: 1000,
        p_vat_pence: 200,
        p_total_inc_vat_pence: 1200,
      };

      const first = await adminClient.rpc("record_credit_purchase", args);
      expect(first.error).toBeNull();
      expect(first.data).not.toBeNull();

      const second = await adminClient.rpc("record_credit_purchase", args);
      expect(second.error).toBeNull();
      expect(second.data).toBeNull(); // idempotent replay short-circuits before crediting again

      const balanceAfter = await balanceFor(companyA.id, "accessories");
      expect(balanceAfter).toBe(balanceBefore + 10); // not +20

      const { count: invoiceCount } = await adminClient
        .from("invoices")
        .select("id", { count: "exact", head: true })
        .eq("stripe_checkout_session_id", args.p_checkout_session_id);
      expect(invoiceCount).toBe(1);
    });
  });

  describe("record_card_setup() — webhook-only", () => {
    it("✗ an authenticated client cannot call record_card_setup directly", async () => {
      const client = await clientAsUser(a1Email);
      const { error } = await client.rpc("record_card_setup", {
        p_company_id: companyA.id,
        p_stripe_payment_method_id: "pm_forged",
      });
      expect(error).not.toBeNull();
    });

    it("✓ service_role: caches the payment method id and logs to audit_log", async () => {
      const { error } = await adminClient.rpc("record_card_setup", {
        p_company_id: companyA.id,
        p_stripe_payment_method_id: "pm_test_saved_card",
      });
      expect(error).toBeNull();

      const { data: company } = await adminClient
        .from("companies")
        .select("stripe_payment_method_id")
        .eq("id", companyA.id)
        .single();
      expect(company?.stripe_payment_method_id).toBe("pm_test_saved_card");

      const { data: auditRows } = await adminClient
        .from("audit_log")
        .select("action, target_id")
        .eq("target_id", companyA.id)
        .eq("action", "company.card_setup");
      expect(auditRows?.length).toBeGreaterThan(0);
    });
  });

  describe("cancel_order() restores a redeemed credit", () => {
    it("✓ cancelling a credit-paid order (still awaiting dispatch) puts the credit back", async () => {
      await adminClient.from("credit_ledger").insert({
        company_id: companyA.id,
        kit_type_id: "monitor",
        transaction_type: "purchase",
        direction: "credit",
        quantity: 1,
        balance_after: 1,
        reason: "seed for cancel-restores-credit test",
      });
      const balanceBeforeRedeem = await balanceFor(companyA.id, "monitor");

      const client = await clientAsUser(a1Email);
      const { data: orderId, error: createError } = await client.rpc("create_order", {
        p_kit_type_id: "monitor",
        p_service_type: "ship_to_new_employee",
        p_employee_id: employeeA.id,
        p_pay_with_credit: true,
      });
      expect(createError).toBeNull();

      const balanceAfterRedeem = await balanceFor(companyA.id, "monitor");
      expect(balanceAfterRedeem).toBe(balanceBeforeRedeem - 1);

      const { error: cancelError } = await adminClient.rpc("cancel_order", {
        p_order_id: orderId as string,
        p_actor_id: staffId,
        p_reason: "Testing credit restoration",
      });
      expect(cancelError).toBeNull();

      const { data: order } = await adminClient
        .from("orders")
        .select("fulfilment_status, payment_status")
        .eq("id", orderId as string)
        .single();
      expect(order?.fulfilment_status).toBe("cancelled");
      expect(order?.payment_status).toBe("cancelled");

      const balanceAfterCancel = await balanceFor(companyA.id, "monitor");
      expect(balanceAfterCancel).toBe(balanceBeforeRedeem); // fully restored

      const { data: restorationRow } = await adminClient
        .from("credit_ledger")
        .select("transaction_type, direction, quantity, order_id")
        .eq("order_id", orderId as string)
        .eq("transaction_type", "adjustment")
        .maybeSingle();
      expect(restorationRow?.direction).toBe("credit");
      expect(restorationRow?.quantity).toBe(1);
    });
  });
});
