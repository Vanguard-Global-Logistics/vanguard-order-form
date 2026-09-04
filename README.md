# Vanguard Performance Labs — order form

One self-contained HTML page. No build step, no dependencies, no server. `index.html`
carries its own styles, scripts, and every image as embedded data, so it works from a
web address, from a hard drive, or as an email attachment.

## Putting it online

GitHub Pages serves this repository as a website. A workflow in `.github/workflows`
publishes every push to `main` and turns Pages on the first time it runs. If the first run
fails on the Pages step, open **Settings → Pages**, set the source to **GitHub Actions**,
and re-run the workflow from the Actions tab. The form is then live at
`https://vanguard-global-logistics.github.io/vanguard-order-form/`.

To serve it from your own domain instead, add `vanguardperformancelabs.com` as the custom
domain on that same settings page and point a CNAME record at GitHub. The `.nojekyll` file
is here to stop GitHub from trying to process the page as a blog.

## Changing prices, products, and payment details

You never edit `index.html` for these. Two small files beside it are read by every copy of
the form each time it loads, and changing them is done in the browser on GitHub: open the
file, click the pencil, edit, click **Commit changes**. Customers see the change within
about ten minutes, which is how long GitHub caches the file.

`catalog.json` is the price list. Each product has a `name`, a `size`, and either a
`price` or a `variants` list of sizes with their own prices. Add `"bacWater": false` to a
product that should not offer the bacteriostatic-water row. Add `"image"` with a
`https://` address to give a new product a picture; the 26 original vials already have
theirs built into the page. Bump `version` and `updated` when you change anything - the
form prints them at the bottom so you can tell which list a customer is looking at.

`config.json` holds the phone number, order email, Venmo recipient, Cash App cashtag,
shipping fee, bac-water fee, and discount rate. The `discount_fingerprint` is a hash of the
discount code, not the code itself, so nobody reading the repository learns the code; ask
for a new fingerprint when you change the code.

The form checks every value before using it. A typo that breaks the JSON, or a price that
is not a number, makes the form ignore the file and fall back to the list built into the
page, and the footnote says so in amber. If the footnote reads "Showing built-in prices",
open the JSON file on GitHub and look for the mistake; a missing comma is the usual one.

A customer who added items under an older price list has their cart re-priced from the
current one when they return, and any product you have removed is taken out of their cart
with a message saying so.

The Venmo QR code and the Cash App QR code are pictures baked into the page. If you change
the Venmo recipient or the cashtag in `config.json`, the buttons and links follow, but the
QR pictures will still point at the old accounts until they are replaced in `index.html`.

## How an order reaches you

The customer builds a cart, picks shipping or will call, and enters a name and address.
The page issues a PO number like `VPL-260904-K7M2` — dated so it sorts, with a random tail
so no two orders collide. They then either text or email the order to you, and pay through
Venmo, Cash App, Apple Cash, or Zelle. Every payment memo carries their name, the PO
number, and the amount, and never what they bought.

Emailed orders arrive with a tab-separated row at the bottom. Paste it into
`Vanguard-Order-Tracker.xlsx` and it fills all 18 columns. The Summary tab totals what is
outstanding, what is paid, and what still needs shipping.

## What this page cannot do

The live price list works only on the hosted page. Opened from a hard drive or an email
attachment, the form cannot fetch anything and shows its built-in prices, and says so.

Nothing sends by itself. There is no server, so "Email order" opens the customer's mail
app and they still have to press send. A customer can pay without ever sending the order,
leaving you a payment whose PO number you have never seen. Closing that gap needs a real
backend — see the notes in CLAUDE.md.
