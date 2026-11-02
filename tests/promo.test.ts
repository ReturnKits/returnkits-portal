// Free first laptop return -- sign-up promo (20261102). See
// supabase/migrations/20261102120000_signup_promo_free_laptop_return.sql
// for the design and the scope decisions confirmed with the user.
//
// Every company here signs up through the real create_company_and_admin()
// RPC with a real magic-link session, because that's where the grant
// happens. Each signup uses its own random work domain so the
// one-per-domain rule never collides between tests.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import crypto from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  adminClient,
  anonClient,
  clientAsUser,
  createAuthUser,
  createProfile,
  deleteAuthUserByEmail,
  uniqueEmail,
} from "./helpers";

const PROMO_ID = "first_laptop_free";

const emails: string[] = [];
const companyIds: string[] = [];
let staffId: string;
const staffEmail = uniqueEmail("promo-staff");

function workDomain() {
  return `promo-${crypto.randomUUID().slice(0, 8)}.co.uk`;
}

type SignUp = { email: string; userId: string; companyId: string; returnAddressId: string; client: SupabaseClient };

async function signUp(domain: string, companyName = "Promo Test Co"): Promise<SignUp> {
  const email = `admin-${crypto.randomUUID().slice(0, 8)}@${domain}`;
  emails.push(email);
  const user = await createAuthUser(email);
  const signupClient = await clientAsUser(email);
  const { data: companyId, error } = await signupClient.rpc("create_company_and_admin", { company_name: companyName });
  if (error) throw error;
  companyIds.push(companyId as string);
  // Return orders require a return address (orders_return_needs_address).
  const { data: addr, error: addrError } = await adminClient
    .from("addresses")
    .insert({
      company_id: companyId,
      label: "HQ",
      address_line1: `${crypto.randomUUID().slice(0, 6)} Head Office Road`,
      city: "London",
      postcode: "EC1A 1BB",
      country: "GB",
      is_default_return: true,
    })
    .select()
    .single();
  if (addrError) throw addrError;
  // Fresh session so the JWT carries the new company claim.
  return {
    email,
    userId: user.id,
    companyId: companyId as string,
    returnAddressId: addr.id as string,
    client: await clientAsUser(email),
  };
}

async function addEmployee(companyId: string, overrides: Record<string, unknown> = {}) {
  const { data, error } = await adminClient
    .from("employees")
    .insert({
      company_id: companyId,
      full_name: "Promo Leaver",
      email: `leaver-${crypto.randomUUID().slice(0, 8)}@example.com`,
      address_line1: `${Math.floor(Math.random() * 900) + 1} Promo Street`,
      city: "London",
      postcode: "E1 6AN",
      country: "GB",
      ...overrides,
    })
    .select()
    .single();
  if (error) throw error;
  return data as { id: string };
}

async function grantFor(companyId: string) {
  const { data, error } = await adminClient
    .from("promotion_grants")
    .select("*")
    .eq("company_id", companyId)
    .maybeSingle();
  if (error) throw error;
  return data;
}

async function lastNotGrantedReason(companyId: string) {
  const { data, error } = await adminClient
    .from("audit_log")
    .select("after")
    .eq("action", "promo.not_granted")
    .eq("target_id", companyId)
    .maybeSingle();
  if (error) throw error;
  return (data?.after as { reason?: string } | null)?.reason;
}

async function purchasedBalance(companyId: string) {
  const { data, error } = await adminClient
    .from("credit_ledger")
    .select("direction, quantity")
    .eq("company_id", companyId)
    .eq("kit_type_id", "laptop")
    .is("promotion_id", null);
  if (error) throw error;
  return (data ?? []).reduce((sum, r) => sum + (r.direction === "credit" ? r.quantity : -r.quantity), 0);
}

async function buyLaptopCredits(companyId: string, quantity: number) {
  const id = crypto.randomUUID();
  const { error } = await adminClient.rpc("record_credit_purchase", {
    p_event_id: `evt_promo_${id}`,
    p_event_type: "checkout.session.completed",
    p_checkout_session_id: `cs_promo_${id}`,
    p_payment_intent_id: `pi_promo_${id}`,
    p_company_id: companyId,
    p_kit_type_id: "laptop",
    p_quantity: quantity,
    p_subtotal_ex_vat_pence: 6500 * quantity,
    p_vat_pence: 0,
    p_total_inc_vat_pence: 6500 * quantity,
  });
  if (error) throw error;
}

function laptopReturn(s: SignUp, employeeId: string, extra: Record<string, unknown> = {}) {
  return s.client.rpc("create_order", {
    p_kit_type_id: "laptop",
    p_service_type: "return",
    p_employee_id: employeeId,
    p_return_address_id: s.returnAddressId,
    p_pay_with_credit: true,
    ...extra,
  });
}

async function setPromo(values: Record<string, unknown>) {
  const { error } = await adminClient.from("promotions").update(values).eq("id", PROMO_ID);
  if (error) throw error;
}

beforeAll(async () => {
  const staff = await createAuthUser(staffEmail);
  staffId = staff.id;
  await createProfile(staff.id, null, staffEmail, "internal_ops");
  // No cap (the live setting since 20261102130000); the cap test sets one explicitly.
  await setPromo({ enabled: true, max_grants: null });
});

afterAll(async () => {
  await setPromo({ enabled: false, max_grants: null, first_enabled_at: null });
  if (companyIds.length) {
    await adminClient.from("promotion_grants").delete().in("company_id", companyIds);
    await adminClient.from("orders").delete().in("company_id", companyIds);
    await adminClient.from("credit_ledger").delete().in("company_id", companyIds);
    await adminClient.from("invoices").delete().in("company_id", companyIds);
    await adminClient.from("employees").delete().in("company_id", companyIds);
    await adminClient.from("addresses").delete().in("company_id", companyIds);
  }
  for (const email of [...emails, staffEmail]) {
    await deleteAuthUserByEmail(email);
  }
  if (companyIds.length) {
    await adminClient.from("users").delete().in("company_id", companyIds);
    await adminClient.from("companies").delete().in("id", companyIds);
  }
});

describe("Sign-up promo: granting at company setup", () => {
  it("✓ a work-email signup gets one laptop credit, valid 60 days, tagged as promo", async () => {
    const s = await signUp(workDomain());

    const grant = await grantFor(s.companyId);
    expect(grant?.status).toBe("issued");
    const days = (new Date(grant!.expires_at).getTime() - Date.now()) / 86_400_000;
    expect(days).toBeGreaterThan(59.9);
    expect(days).toBeLessThanOrEqual(60);

    const { data: ledger } = await adminClient
      .from("credit_ledger")
      .select("transaction_type, direction, quantity, promotion_id, expires_at")
      .eq("company_id", s.companyId);
    expect(ledger).toHaveLength(1);
    expect(ledger![0]).toMatchObject({ transaction_type: "adjustment", direction: "credit", quantity: 1, promotion_id: PROMO_ID });
    expect(ledger![0].expires_at).not.toBeNull();

    // Purchased balance is untouched by the grant.
    expect(await purchasedBalance(s.companyId)).toBe(0);
  });

  it("✓ the company can read its own grant (dashboard banner) and ✗ another company cannot", async () => {
    const a = await signUp(workDomain());
    const b = await signUp(workDomain());

    const own = await a.client.from("promotion_grants").select("status, expires_at").eq("company_id", a.companyId);
    expect(own.error).toBeNull();
    expect(own.data).toHaveLength(1);

    const other = await b.client.from("promotion_grants").select("*").eq("company_id", a.companyId);
    expect(other.error).toBeNull();
    expect(other.data).toEqual([]);
  });

  it("✗ a client cannot write grants or promo ledger rows directly", async () => {
    const s = await signUp(workDomain());
    const grant = await s.client.from("promotion_grants").update({ status: "issued" }).eq("company_id", s.companyId).select();
    expect(grant.data ?? []).toEqual([]);

    const forged = await s.client.from("credit_ledger").insert({
      company_id: s.companyId, kit_type_id: "laptop", transaction_type: "adjustment",
      direction: "credit", quantity: 5, balance_after: 5, promotion_id: PROMO_ID,
    });
    expect(forged.error).not.toBeNull();
  });

  it("✗ free-mail and disposable addresses don't qualify, but signup still succeeds", async () => {
    for (const domain of ["gmail.com", "mailinator.com"]) {
      const s = await signUp(domain);
      expect(s.companyId).toBeTruthy();
      expect(await grantFor(s.companyId)).toBeNull();
      expect(await lastNotGrantedReason(s.companyId)).toBe("not_a_work_email");
    }
  });

  it("✗ a second company on the same email domain gets nothing (one per business)", async () => {
    const domain = workDomain();
    const first = await signUp(domain);
    const second = await signUp(domain);
    expect(await grantFor(first.companyId)).not.toBeNull();
    expect(await grantFor(second.companyId)).toBeNull();
    expect(await lastNotGrantedReason(second.companyId)).toBe("email_domain_already_claimed");
  });

  it("✗ concurrent signups on one domain produce exactly one grant", async () => {
    const domain = workDomain();
    const results = await Promise.all([signUp(domain), signUp(domain), signUp(domain)]);
    const grants = await Promise.all(results.map((r) => grantFor(r.companyId)));
    expect(grants.filter(Boolean)).toHaveLength(1);
  });

  it("✓ with no cap (max_grants null) a qualifying signup still gets the credit", async () => {
    const s = await signUp(workDomain());
    expect(await grantFor(s.companyId)).not.toBeNull();
  });

  it("✗ no grant once a cap is set and reached (a cap can still be reintroduced)", async () => {
    const { count } = await adminClient
      .from("promotion_grants")
      .select("*", { count: "exact", head: true })
      .eq("promotion_id", PROMO_ID);
    await setPromo({ max_grants: count ?? 0 });
    try {
      const s = await signUp(workDomain());
      expect(await grantFor(s.companyId)).toBeNull();
      expect(await lastNotGrantedReason(s.companyId)).toBe("promotion_cap_reached");
    } finally {
      await setPromo({ max_grants: null });
    }
  });

  it("✗ no grant while the promotion is switched off", async () => {
    await setPromo({ enabled: false });
    try {
      const s = await signUp(workDomain());
      expect(await grantFor(s.companyId)).toBeNull();
      expect(await lastNotGrantedReason(s.companyId)).toBe("promotion_disabled");
    } finally {
      await setPromo({ enabled: true });
    }
  });
});

describe("Sign-up promo: redemption", () => {
  it("✓ a UK laptop drop-off return paid with credit uses the free credit", async () => {
    const s = await signUp(workDomain());
    const emp = await addEmployee(s.companyId);

    const { data: orderId, error } = await laptopReturn(s, emp.id);
    expect(error).toBeNull();

    const { data: order } = await adminClient
      .from("orders")
      .select("payment_status, paid_with_credit, credit_transaction_id, cover_tier_id")
      .eq("id", orderId as string)
      .single();
    expect(order).toMatchObject({ payment_status: "paid", paid_with_credit: true, cover_tier_id: null });

    const { data: debit } = await adminClient
      .from("credit_ledger")
      .select("transaction_type, direction, promotion_id, order_id")
      .eq("id", order!.credit_transaction_id)
      .single();
    expect(debit).toMatchObject({ transaction_type: "redemption", direction: "debit", promotion_id: PROMO_ID, order_id: orderId });

    const grant = await grantFor(s.companyId);
    expect(grant).toMatchObject({ status: "redeemed", redeemed_order_id: orderId, address_flagged: false });
  });

  it("✗ the same credit can't be redeemed twice", async () => {
    const s = await signUp(workDomain());
    const emp = await addEmployee(s.companyId);
    expect((await laptopReturn(s, emp.id)).error).toBeNull();
    const second = await laptopReturn(s, emp.id);
    expect(second.error).not.toBeNull();
  });

  it("✗ two concurrent redemptions of the one free credit: exactly one succeeds", async () => {
    const s = await signUp(workDomain());
    const emp = await addEmployee(s.companyId);
    const results = await Promise.all([laptopReturn(s, emp.id), laptopReturn(s, emp.id)]);
    expect(results.filter((r) => r.error === null)).toHaveLength(1);
  });

  it("✗ doesn't apply to a ship-to-new-employee order, and says why", async () => {
    const s = await signUp(workDomain());
    const emp = await addEmployee(s.companyId);
    const { error } = await s.client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "ship_to_new_employee",
      p_employee_id: emp.id,
      p_pay_with_credit: true,
    });
    expect(error?.message).toMatch(/free laptop return credit can only be used/);
    expect((await grantFor(s.companyId))?.status).toBe("issued");
  });

  it("✗ doesn't apply when the recipient is outside the UK", async () => {
    const s = await signUp(workDomain());
    const emp = await addEmployee(s.companyId, { country: "FR", postcode: "75001", city: "Paris" });
    const { error } = await laptopReturn(s, emp.id);
    expect(error).not.toBeNull();
    expect((await grantFor(s.companyId))?.status).toBe("issued");
  });

  it("✗ doesn't apply when the return address is outside the UK", async () => {
    const s = await signUp(workDomain());
    const emp = await addEmployee(s.companyId);
    const { data: addr, error: addrError } = await adminClient
      .from("addresses")
      .insert({ company_id: s.companyId, label: "Dublin office", address_line1: "1 Grafton St", city: "Dublin", postcode: "D02", country: "IE" })
      .select()
      .single();
    if (addrError) throw addrError;
    const { error } = await laptopReturn(s, emp.id, { p_return_address_id: addr.id });
    expect(error).not.toBeNull();
    expect((await grantFor(s.companyId))?.status).toBe("issued");
  });

  it("✓ purchased credits are untouched: promo is spent first on a qualifying return, purchased on everything else", async () => {
    const s = await signUp(workDomain());
    const emp = await addEmployee(s.companyId);
    await buyLaptopCredits(s.companyId, 2);
    expect(await purchasedBalance(s.companyId)).toBe(2);

    expect((await laptopReturn(s, emp.id)).error).toBeNull();
    expect((await grantFor(s.companyId))?.status).toBe("redeemed");
    expect(await purchasedBalance(s.companyId)).toBe(2);

    const { data: shipId, error } = await s.client.rpc("create_order", {
      p_kit_type_id: "laptop",
      p_service_type: "ship_to_new_employee",
      p_employee_id: emp.id,
      p_pay_with_credit: true,
    });
    expect(error).toBeNull();
    expect(await purchasedBalance(s.companyId)).toBe(1);

    const { data: debit } = await adminClient
      .from("credit_ledger")
      .select("promotion_id, balance_after")
      .eq("order_id", shipId as string)
      .single();
    expect(debit).toMatchObject({ promotion_id: null, balance_after: 1 });
  });

  it("✓ a later credit purchase's balance_after ignores the promo credit", async () => {
    const s = await signUp(workDomain());
    await buyLaptopCredits(s.companyId, 3);
    const { data } = await adminClient
      .from("credit_ledger")
      .select("balance_after")
      .eq("company_id", s.companyId)
      .eq("transaction_type", "purchase")
      .single();
    expect(data?.balance_after).toBe(3);
  });

  it("✓ volume-discount companies don't get bundled free cover on the promo order", async () => {
    const s = await signUp(workDomain());
    await adminClient.from("companies").update({ volume_discounts_enabled: true }).eq("id", s.companyId);
    const emp = await addEmployee(s.companyId);
    const { data: orderId, error } = await laptopReturn(s, emp.id);
    expect(error).toBeNull();
    const { data: order } = await adminClient.from("orders").select("cover_tier_id").eq("id", orderId as string).single();
    expect(order?.cover_tier_id).toBeNull();
  });

  it("✓ Enhanced Cover stays chargeable: the paid-cover webhook path redeems the promo credit and invoices the cover", async () => {
    const s = await signUp(workDomain());
    const emp = await addEmployee(s.companyId);
    const id = crypto.randomUUID();
    const { data: orderId, error } = await adminClient.rpc("create_credit_order_with_paid_cover", {
      p_event_id: `evt_promo_cover_${id}`,
      p_event_type: "checkout.session.completed",
      p_checkout_session_id: `cs_promo_cover_${id}`,
      p_payment_intent_id: `pi_promo_cover_${id}`,
      p_company_id: s.companyId,
      p_created_by: s.userId,
      p_kit_type_id: "laptop",
      p_service_type: "return",
      p_cover_tier_id: "up_to_1000",
      p_cover_subtotal_ex_vat_pence: 1000,
      p_cover_vat_pence: 0,
      p_cover_total_inc_vat_pence: 1000,
      p_employee_id: emp.id,
      p_return_address_id: s.returnAddressId,
    });
    expect(error).toBeNull();
    const { data: order } = await adminClient
      .from("orders")
      .select("invoice_id, cover_tier_id, cover_paid_separately")
      .eq("id", orderId as string)
      .single();
    expect(order).toMatchObject({ cover_tier_id: "up_to_1000", cover_paid_separately: true });
    expect(order?.invoice_id).not.toBeNull();
    expect((await grantFor(s.companyId))?.status).toBe("redeemed");
  });

  it("⚑ flags (doesn't block) a promo return to an address another company already used", async () => {
    const shared = { address_line1: "42 Shared Road", postcode: "sw1a 1aa" };
    const a = await signUp(workDomain());
    const b = await signUp(workDomain());
    const empA = await addEmployee(a.companyId, shared);
    const empB = await addEmployee(b.companyId, { address_line1: "42  shared road ", postcode: "SW1A1AA" });

    expect((await laptopReturn(a, empA.id)).error).toBeNull();
    expect((await laptopReturn(b, empB.id)).error).toBeNull();

    expect((await grantFor(a.companyId))?.address_flagged).toBe(false);
    const flagged = await grantFor(b.companyId);
    expect(flagged?.address_flagged).toBe(true);
    expect(JSON.stringify(flagged?.address_flag_detail)).toContain(a.companyId);
  });
});

describe("Sign-up promo: cancellation and expiry", () => {
  it("✓ cancelling a promo order gives the credit back with its original expiry", async () => {
    const s = await signUp(workDomain());
    const emp = await addEmployee(s.companyId);
    const originalExpiry = (await grantFor(s.companyId))!.expires_at;

    const { data: orderId } = await laptopReturn(s, emp.id);
    const { error } = await adminClient.rpc("cancel_order", { p_order_id: orderId, p_actor_id: staffId, p_reason: "promo cancel test" });
    expect(error).toBeNull();

    const grant = await grantFor(s.companyId);
    expect(grant).toMatchObject({ status: "issued", redeemed_order_id: null });
    expect(new Date(grant!.expires_at).getTime()).toBe(new Date(originalExpiry).getTime());

    const { data: restore } = await adminClient
      .from("credit_ledger")
      .select("direction, promotion_id, expires_at")
      .eq("order_id", orderId as string)
      .eq("transaction_type", "adjustment")
      .single();
    expect(restore?.direction).toBe("credit");
    expect(restore?.promotion_id).toBe(PROMO_ID);
    expect(new Date(restore!.expires_at).getTime()).toBe(new Date(originalExpiry).getTime());
    expect(await purchasedBalance(s.companyId)).toBe(0);

    // And it can be used again.
    expect((await laptopReturn(s, emp.id)).error).toBeNull();
  });

  it("✓ cancelling a purchased-credit order still restores a purchased credit exactly as before", async () => {
    const s = await signUp("gmail.com"); // no promo
    const emp = await addEmployee(s.companyId);
    await buyLaptopCredits(s.companyId, 1);
    const { data: orderId, error } = await laptopReturn(s, emp.id);
    expect(error).toBeNull();
    expect(await purchasedBalance(s.companyId)).toBe(0);
    await adminClient.rpc("cancel_order", { p_order_id: orderId, p_actor_id: staffId });
    expect(await purchasedBalance(s.companyId)).toBe(1);
  });

  it("✓ cancelling after the credit has expired marks it expired instead of giving it back", async () => {
    const s = await signUp(workDomain());
    const emp = await addEmployee(s.companyId);
    const { data: orderId } = await laptopReturn(s, emp.id);
    await adminClient
      .from("promotion_grants")
      .update({ expires_at: new Date(Date.now() - 60_000).toISOString() })
      .eq("company_id", s.companyId);

    await adminClient.rpc("cancel_order", { p_order_id: orderId, p_actor_id: staffId });
    const grant = await grantFor(s.companyId);
    expect(grant?.status).toBe("expired");
    const { count } = await adminClient
      .from("credit_ledger")
      .select("*", { count: "exact", head: true })
      .eq("order_id", orderId as string)
      .eq("transaction_type", "adjustment");
    expect(count).toBe(0);
  });

  it("✗ an expired credit can't be redeemed, and the daily job writes it off", async () => {
    const s = await signUp(workDomain());
    const emp = await addEmployee(s.companyId);
    await adminClient
      .from("promotion_grants")
      .update({ expires_at: new Date(Date.now() - 60_000).toISOString() })
      .eq("company_id", s.companyId);

    expect((await laptopReturn(s, emp.id)).error).not.toBeNull();

    const { data: expiredCount, error } = await adminClient.rpc("expire_promo_credits");
    expect(error).toBeNull();
    expect(expiredCount as number).toBeGreaterThanOrEqual(1);

    expect((await grantFor(s.companyId))?.status).toBe("expired");
    const { data: debit } = await adminClient
      .from("credit_ledger")
      .select("transaction_type, direction, promotion_id")
      .eq("company_id", s.companyId)
      .eq("direction", "debit")
      .single();
    expect(debit).toMatchObject({ transaction_type: "adjustment", promotion_id: PROMO_ID });
    expect(await purchasedBalance(s.companyId)).toBe(0);
  });

  it("✓ switching the promotion off keeps honouring credits already issued", async () => {
    const s = await signUp(workDomain());
    const emp = await addEmployee(s.companyId);
    await setPromo({ enabled: false });
    try {
      expect((await laptopReturn(s, emp.id)).error).toBeNull();
    } finally {
      await setPromo({ enabled: true });
    }
  });
});

describe("Sign-up promo: admin switch, reporting, and lock-down", () => {
  it("✗ a customer can't call the switch or the expiry job", async () => {
    const s = await signUp(workDomain());
    const toggle = await s.client.rpc("set_promotion_enabled", { p_promotion_id: PROMO_ID, p_actor_id: s.userId, p_enabled: false });
    expect(toggle.error).not.toBeNull();
    const expire = await s.client.rpc("expire_promo_credits");
    expect(expire.error).not.toBeNull();
    const { data: promo } = await adminClient.from("promotions").select("enabled").eq("id", PROMO_ID).single();
    expect(promo?.enabled).toBe(true);
  });

  it("✓ staff toggle through set_promotion_enabled, which stamps first_enabled_at once", async () => {
    await setPromo({ enabled: false, first_enabled_at: null });
    const on = await adminClient.rpc("set_promotion_enabled", { p_promotion_id: PROMO_ID, p_actor_id: staffId, p_enabled: true });
    expect(on.error).toBeNull();
    const { data: first } = await adminClient.from("promotions").select("enabled, first_enabled_at").eq("id", PROMO_ID).single();
    expect(first?.enabled).toBe(true);
    expect(first?.first_enabled_at).not.toBeNull();

    await adminClient.rpc("set_promotion_enabled", { p_promotion_id: PROMO_ID, p_actor_id: staffId, p_enabled: false });
    await adminClient.rpc("set_promotion_enabled", { p_promotion_id: PROMO_ID, p_actor_id: staffId, p_enabled: true });
    const { data: again } = await adminClient.from("promotions").select("first_enabled_at").eq("id", PROMO_ID).single();
    expect(again?.first_enabled_at).toBe(first?.first_enabled_at);
  });

  it("✗ a non-staff actor can't toggle it even via service_role", async () => {
    const s = await signUp(workDomain());
    const { error } = await adminClient.rpc("set_promotion_enabled", { p_promotion_id: PROMO_ID, p_actor_id: s.userId, p_enabled: false });
    expect(error).not.toBeNull();
  });

  it("✓ the report shows conversion: credits bought and revenue after the grant", async () => {
    const s = await signUp(workDomain());
    await buyLaptopCredits(s.companyId, 2);
    const { data, error } = await adminClient
      .from("promotion_grant_report")
      .select("credits_purchased_after, revenue_pence_after, became_paying_customer")
      .eq("company_id", s.companyId)
      .single();
    expect(error).toBeNull();
    expect(data).toMatchObject({ credits_purchased_after: 2, revenue_pence_after: 13000, became_paying_customer: true });

    const summary = await adminClient.from("promotion_summary").select("*").eq("promotion_id", PROMO_ID).single();
    expect(summary.error).toBeNull();
    expect(summary.data?.credits_issued).toBeGreaterThan(0);
  });

  it("✗ the report views and promotion tables are closed to customers and anon", async () => {
    const s = await signUp(workDomain());
    for (const client of [anonClient, s.client]) {
      const report = await client.from("promotion_summary").select("*");
      expect(report.data ?? []).toEqual([]);
      const promos = await client.from("promotions").select("*");
      expect(promos.data ?? []).toEqual([]);
      const blocked = await client.from("blocked_email_domains").select("*");
      expect(blocked.data ?? []).toEqual([]);
    }
  });
});
