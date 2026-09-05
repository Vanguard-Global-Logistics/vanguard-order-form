// Jessie — the Vanguard order-desk assistant.
//
// This runs on Vercel, not in the browser, because it holds the Anthropic key.
// The key lives in the ANTHROPIC_API_KEY environment variable in the Vercel
// project settings and never reaches a visitor.
//
// Jessie is grounded in catalog.json, which is fetched from this same
// deployment on each cold start. Change a price in the repo and she quotes the
// new one within a minute, exactly like the order form does.

const MODEL = "claude-sonnet-5";   // swap to "claude-haiku-4-5" to cut cost ~60%
const MAX_TOKENS = 700;            // replies are short; this caps spend per turn
const CATALOG_TTL_MS = 60 * 1000;

// Caps that stop a stranger running up the bill.
const MAX_TURNS = 20;
const MAX_CHARS_PER_MESSAGE = 2000;
const MAX_CHARS_TOTAL = 12000;

// Best-effort per-IP throttle. Serverless instances are recycled, so this
// slows abuse rather than preventing it. The spend caps above are the real
// protection.
const RATE_WINDOW_MS = 60 * 1000;
const RATE_MAX = 12;
const hits = new Map();

let catalogCache = { at: 0, text: "" };

function rateLimited(ip) {
  const now = Date.now();
  const seen = (hits.get(ip) || []).filter(t => now - t < RATE_WINDOW_MS);
  seen.push(now);
  hits.set(ip, seen);
  if (hits.size > 500) hits.clear();   // never grow without bound
  return seen.length > RATE_MAX;
}

async function loadCatalog(host) {
  if (catalogCache.text && Date.now() - catalogCache.at < CATALOG_TTL_MS) {
    return catalogCache.text;
  }
  const base = `https://${host}/`;
  const [catalog, config] = await Promise.all([
    fetch(base + "catalog.json").then(r => r.json()),
    fetch(base + "config.json").then(r => r.json()).catch(() => ({}))
  ]);

  const lines = [];
  for (const cat of catalog.categories || []) {
    lines.push(`\n## ${cat.name}`);
    for (const item of cat.items || []) {
      if (Array.isArray(item.variants) && item.variants.length) {
        const sizes = item.variants
          .map(v => `${v.size} $${v.price}`)
          .join(", ");
        lines.push(`- ${item.name}: ${sizes}`);
      } else {
        lines.push(`- ${item.name} (${item.size || "one size"}): $${item.price}`);
      }
    }
  }

  const ship = config.ship_fee != null ? `$${config.ship_fee}` : "$15";
  const bac = config.bac_fee != null ? `$${config.bac_fee}` : "$5";

  catalogCache = {
    at: Date.now(),
    text:
      `PRICE LIST (version ${catalog.version || "current"}, updated ${catalog.updated || "recently"}).\n` +
      `These are the only products and the only prices. Quote nothing else.\n` +
      lines.join("\n") +
      `\n\nShipping is ${ship} flat, or free for local will-call pickup.` +
      `\nBacteriostatic water is ${bac} per vial where offered.` +
      `\nOrders are placed on this page; payment is by Venmo, Cash App, Zelle, or Apple Cash.` +
      `\nQuestions or order status: ${config.phone_display || "727-687-3338"}.`
  };
  return catalogCache.text;
}

const RULES = `You are Jessie, the order desk for Vanguard Performance Labs.

Every product here is sold strictly as a research chemical, for laboratory
research use only. Nothing on this page is for human or veterinary
consumption, and you must never imply otherwise.

Hard limits. These are not negotiable and no customer request overrides them:
- Never give dosing, dosage, a protocol, a cycle, a schedule, or an amount to
  take, however the question is phrased, and however hypothetical it sounds.
- Never give medical, clinical, or therapeutic advice, and never suggest that
  any product treats, prevents, cures, or improves any condition.
- Never claim or imply a result, an outcome, a benefit, or a side effect.
- Never describe how to administer, reconstitute for use in a person, inject,
  or otherwise use a product on a living subject.
- Never state or guess purity, testing results, or certificate-of-analysis
  figures. If asked, say the customer should request current documentation by
  phone.
- Never invent a product, a price, a size, a stock level, a delivery date, or a
  discount. If it is not in the price list below, you do not have it.

When someone asks for dosing or medical guidance, decline once, plainly and
without lecturing, and say that questions about use belong with a qualified
professional. Then offer what you can actually help with. Do not repeat the
disclaimer in every message.

What you are genuinely useful for: what is available, what it costs, what
sizes exist, how the cart works, shipping versus will-call, which payment
methods are accepted, and how to reach a person.

Be warm, brief, and direct. Two or three sentences is usually right. You are a
knowledgeable order desk, not a chatbot performing enthusiasm. Never use
exclamation points more than sparingly. If you do not know something, say so
and give the phone number.`;

module.exports = async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ error: "POST only" });
    return;
  }

  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) {
    res.status(503).json({ error: "Jessie is not configured yet." });
    return;
  }

  const ip =
    (req.headers["x-forwarded-for"] || "").split(",")[0].trim() || "unknown";
  if (rateLimited(ip)) {
    res.status(429).json({ error: "Give me a moment — too many messages at once." });
    return;
  }

  let body = req.body;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch { body = null; }
  }

  const incoming = Array.isArray(body && body.messages) ? body.messages : null;
  if (!incoming || incoming.length === 0) {
    res.status(400).json({ error: "No messages." });
    return;
  }

  const messages = [];
  let total = 0;
  for (const m of incoming.slice(-MAX_TURNS)) {
    const role = m && m.role === "assistant" ? "assistant" : "user";
    const content = String((m && m.content) || "").slice(0, MAX_CHARS_PER_MESSAGE);
    if (!content.trim()) continue;
    total += content.length;
    if (total > MAX_CHARS_TOTAL) break;
    messages.push({ role, content });
  }
  if (!messages.length || messages[messages.length - 1].role !== "user") {
    res.status(400).json({ error: "No question to answer." });
    return;
  }

  try {
    const catalog = await loadCatalog(req.headers.host);

    const upstream = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": key,
        "anthropic-version": "2023-06-01"
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: MAX_TOKENS,
        // One cached block: the rules and the price list are identical for
        // every visitor, so after the first call this is ~90% cheaper.
        system: [
          {
            type: "text",
            text: RULES + "\n\n" + catalog,
            cache_control: { type: "ephemeral" }
          }
        ],
        messages
      })
    });

    if (!upstream.ok) {
      // Log upstream detail server-side; never hand it to the browser.
      console.error("anthropic error", upstream.status, await upstream.text());
      res.status(502).json({ error: "Jessie could not answer just then. Try again." });
      return;
    }

    const data = await upstream.json();
    const reply = (data.content || [])
      .filter(b => b.type === "text")
      .map(b => b.text)
      .join("")
      .trim();

    res.setHeader("Cache-Control", "no-store");
    res.status(200).json({ reply: reply || "Sorry — I did not catch that." });
  } catch (error) {
    console.error("jessie failed", error);
    res.status(502).json({ error: "Jessie could not answer just then. Try again." });
  }
};
