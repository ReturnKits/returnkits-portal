// supabase/functions/create-card-setup-session/index.ts
//
// REMOVED 20260820 -- see CLAUDE.md ("Saved card feature removed") and
// migration 20260820100000_remove_saved_card_feature.sql. Direct user
// feedback: "it doesnt make sense to have the saved card option in the
// portal, as this saved card can be used in the stripe checkout" -- correct,
// and confirmed by this codebase's own code: every Checkout Session this
// app creates already passes `customer: stripeCustomerId`, so Stripe
// Checkout's own hosted page already offers a "save this card" checkbox and
// automatically presents any previously-saved card as a one-click option on
// future sessions for the same customer, with zero application code. This
// dedicated mode:'setup' flow (plus record_card_setup and
// companies.stripe_payment_method_id) duplicated that for no benefit and
// has been removed.
//
// Left deployed as a 410 stub rather than deleted -- there is no Supabase
// MCP tool to delete an Edge Function outright. The Lovable "Save a card"
// button that called this has also been removed, so this should never be
// reached in normal use; the stub exists purely so a stale client (or a
// dangling bookmark) fails loudly and explains why, instead of erroring
// against the now-dropped record_card_setup RPC.

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve((req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  return new Response(
    JSON.stringify({
      error:
        "Saved-card setup has been removed. Tick \"save my payment details\" on the payment page next time you check out -- Stripe will offer it automatically on future purchases.",
    }),
    { status: 410, headers: { ...corsHeaders, "Content-Type": "application/json" } },
  );
});
