# CLAUDE.md — Vanguard order form

Read this before changing `index.html`. It records what was learned the expensive way.

## What this is

A single self-contained HTML page: catalog, cart, shipping, PO numbers, and payment
handoff, with all 26 vial images embedded as base64 JPEG. No build, no framework, no
server. Around 500 KB, which is deliberate — it has to survive being emailed.

## Verify every change before handing it over

Never report a change as working without running the browser tests. The suite lives
outside the repo but is easy to recreate: drive the page with Playwright in Chromium and
assert the whole cart path — add, remove, size variants, bac-water add-on, promo code
accept and reject, drawer open and close by button, Escape and overlay, search, price
edit, reload persistence, clear, shipping versus will call, PO format and uniqueness, and
that no product name leaks into a payment memo. The bar is 70/70 with zero JS errors.

Also test with elements deleted, with `localStorage` throwing, and with
`crypto.getRandomValues` blocked. A sandboxed frame does all three.

Test in more than one engine. Playwright's Firefox and WebKit downloads are blocked by
network policy in the Claude sandbox, but `apt-get install webkit2gtk-driver xvfb` plus
`pip install selenium` gives a real WebKit (Safari's engine family) that Selenium can
drive under `xvfb-run`. Run the cart path there too. Then hand the file to a fresh
sub-agent with no knowledge of your changes and tell it to break the page - the blind
critic found two real problems the author's own suite had missed.

## Bugs that already cost real time

**The overlay above the drawer.** The upgrade stylesheet put `.overlay` at z-index 70 and
left `.drawer` at 51, so the dimmed layer covered the open cart and swallowed every tap
inside it. The cart looked fine and did nothing. Drawer must sit above overlay.

**One throw kills the whole repaint.** `refreshCartUI()` runs on every `+` press and used
to hold fourteen unguarded `getElementById(...).property` calls. Any one failing killed
the function partway, and because `addToCart` increments before calling it, the quantity
never repainted — the button looked dead. Every DOM write now goes through null-safe
helpers, and `safeRefresh()` catches anything downstream. Keep it that way.

**A dead payment URL hardcoded in markup.** `account.venmo.com/u/<handle>` sat in the HTML
as a fallback href and 404'd when tapped. Payment links are built by script from one
constant; do not reintroduce a hardcoded href.

**Lazy-loaded inline images.** The vial art is embedded `data:` URIs, and with
`loading="lazy"` Chromium left 21 of 26 undecoded until scrolled - a catalog with almost no
art on first paint. There is no network to save, so the images are eager. Keep them eager.

**iPad reported as a Mac.** The `sms:` link separator was chosen by a UA regex for
iPhone/iPad/iPod; iPadOS Safari identifies as Macintosh, so iPads got the Android form.
`isAppleTouchDevice()` also checks `MacIntel` plus `maxTouchPoints`.

**A PO that never rotated.** The order number only regenerated on "Clear order", which
nobody taps, so a returning customer carried their previous cart and previous PO. An order
is now marked sent, and the next visit starts fresh while keeping name and address.

## Platform limits — do not promise around these

An HTML file opened from Files, Mail, or Messages on iPhone renders in Quick Look, which
**never runs JavaScript**. Buttons will be dead and no code can change that. Send a link,
not a file. The page shows a warning banner when it detects scripts are off.

Zelle has no deep link. Early Warning Services publishes no URL scheme, the standalone app
was retired in 2025, and no bank prefills a payment from the web. Copy-to-clipboard is the
honest ceiling.

Cash App resolves a `$cashtag` only, never a phone number, and cannot prefill a note.
Venmo does prefill amount and note via `venmo.com/?txn=pay&recipients=…`.

Card processors — Stripe, Square, PayPal — prohibit research peptides. That is why this
page uses peer-to-peer payment. Do not wire up a card processor without saying so plainly.

## Live data

`catalog.json` and `config.json` in the repo are fetched on load from `./` first (same
origin on GitHub Pages) and then from the raw GitHub URL. Every field is validated in
`validCatalog()` / `applyConfig()`; anything off falls back to `EMBEDDED_CATALOG` and the
footnote turns amber. Cart keys are `category||name||size` (size, not the price-bearing
label) so a price change does not orphan a saved cart; `repriceCart()` re-prices saved
lines and drops discontinued ones with a toast. On `file:` the fetch is skipped outright.
The claude.ai artifact host blocks outbound fetch, so the artifact copy always shows the
built-in list - only the hosted page is live. When adding a setting, add it to
`config.json`, to `applyConfig()` with a validator, and to the README.

## Removed on purpose

The original file shipped an "Edit prices" toggle that turned every price into a text
box for anyone viewing the page. A customer could type their own prices and text a
legitimate-looking order. It is gone. Prices live in the `CATALOG` array near the top of
the script, one line per vial; change them there.

## Testing gotcha

The page sets `html{scroll-behavior:smooth}`. Any WebDriver-style harness that scrolls an
element into view and clicks immediately will click mid-animation and hit a neighbouring
button, which looks exactly like a page bug. Inject `scroll-behavior:auto` for tests and
hit-test with `elementFromPoint` before clicking. Playwright waits for stability on its
own; Selenium does not.

## Conventions

Money is handled in dollars with `toFixed(2)` at the edges. Payment memos carry name, PO
number, and amount, and never product names — a Venmo note is public and a bank memo lands
on a statement. The discount code is stored as an FNV-1a fingerprint, never as plaintext,
so viewing source does not reveal it. The build stamp above the footnote must be bumped on
every change; it is how the owner tells builds apart.

## The open gap

Nothing submits on its own. A customer can pay and never send the order. Fixing it needs a
backend the page can POST to — a Google Apps Script web app, a Cloudflare Worker, or
Formspree are all fine — writing straight into the order sheet. This only works once the
page is hosted, not from an emailed file. The owner set the trigger for this at roughly
15 orders a week.
