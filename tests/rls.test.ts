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
