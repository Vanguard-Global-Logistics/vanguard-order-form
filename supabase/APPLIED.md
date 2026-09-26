# Schema status

Applied to `vanguard-performance-labs` (project `gzkzmoqvepcxvzxkeytb`) on 2026-09-26.

The database shares its Supabase project with an existing, unrelated site that already
had its own `orders`, `inquiries`, `specialty_requests`, `newsletter_subscribers`, and
`articles` tables — a different shape, already in use, RLS already on. `001_orders.sql`
was written assuming an empty database and would have silently skipped the real
`orders` table via `create table if not exists`, then written into the wrong columns.

`002_vpl_orders.sql` is what actually ran: the same design, renamed to `vpl_orders`,
`vpl_order_items`, `vpl_reps`, and `submit_vpl_order()` so it can never collide with
that table again. `001_orders.sql` is kept for the record but was never applied as-is;
002 is the source of truth for what's live.

Verified after applying, then cleaned back to zero rows:
- a full order (2 line items, a rep at 10%) inserts and totals correctly
- resubmitting the same order_number does not duplicate the order or its items
- an order_number that isn't shaped like VPL-######-XXXX is refused
- an empty cart is refused
- a rep_code that doesn't exist earns nothing (order still saves, unattributed)
- a deactivated rep earns nothing
- the anon key — the one the public page will carry — cannot read `vpl_orders` or
  `vpl_reps` even when a real row exists; its only door in is `submit_vpl_order()`

`supabase get_advisors` flags "RLS enabled, no policy" on the vpl_ tables and "anon
can execute a SECURITY DEFINER function" on `submit_vpl_order` — both are the intended
design (deny-by-default RLS; one narrow write path), not issues to fix.

Not yet wired: the order form doesn't call `submit_vpl_order()` yet, and `vpl_reps`
has no rows. Needs the commission rate and whether reps get their own view before
that's built.
