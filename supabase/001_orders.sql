-- Vanguard Performance Labs — order capture with rep attribution
-- Apply once against the vanguard-performance-labs project.
--
-- Design notes:
--   * Money is integer cents everywhere. Never floats.
--   * The public order form holds only the anon key. It cannot read or write
--     these tables directly — it may only call submit_order(). Everything
--     else requires the service role, which never leaves the server.
--   * commission_rate is copied onto the order at the time it is placed, so
--     changing a rep's rate later never rewrites what they already earned.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- reps

create table if not exists public.reps (
  code            text primary key,          -- short code used in ?rep=DM
  name            text not null,
  email           text,
  phone           text,
  commission_rate numeric(5,4) not null default 0.1000,
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);

comment on column public.reps.commission_rate is
  'Fraction of the order subtotal, e.g. 0.1000 = 10%. Set per rep.';

-- -------------------------------------------------------------- orders

create table if not exists public.orders (
  id               uuid primary key default gen_random_uuid(),
  order_number     text unique not null,     -- VPL-260904-K7M2
  placed_at        timestamptz not null default now(),

  customer_name    text not null,
  customer_email   text,
  customer_phone   text,

  delivery_method  text not null default 'ship'
                     check (delivery_method in ('ship','willcall')),
  street           text,
  unit             text,
  city             text,
  state            text,
  zip              text,

  subtotal_cents   integer not null check (subtotal_cents >= 0),
  discount_cents   integer not null default 0 check (discount_cents >= 0),
  shipping_cents   integer not null default 0 check (shipping_cents >= 0),
  total_cents      integer not null check (total_cents >= 0),

  rep_code         text references public.reps(code) on delete set null,
  commission_rate  numeric(5,4) not null default 0,
  commission_cents integer not null default 0 check (commission_cents >= 0),

  payment_method   text check (payment_method in
                     ('venmo','cashapp','zelle','applecash','other')),
  status           text not null default 'new'
                     check (status in ('new','paid','shipped','cancelled')),
  paid_at          timestamptz,
  shipped_at       timestamptz,

  notes            text,
  user_agent       text
);

create index if not exists orders_placed_at_idx on public.orders (placed_at desc);
create index if not exists orders_rep_code_idx  on public.orders (rep_code);
create index if not exists orders_status_idx    on public.orders (status);

-- --------------------------------------------------------- order_items

create table if not exists public.order_items (
  id               uuid primary key default gen_random_uuid(),
  order_id         uuid not null references public.orders(id) on delete cascade,
  sku              text,
  name             text not null,
  unit_price_cents integer not null check (unit_price_cents >= 0),
  qty              integer not null check (qty > 0),
  line_total_cents integer not null check (line_total_cents >= 0)
);

create index if not exists order_items_order_id_idx on public.order_items (order_id);

-- ------------------------------------------------------------------ RLS
-- Deny by default. No policies are created, so the anon and authenticated
-- roles can do nothing at all to these tables. The service role bypasses
-- RLS and is the only way to read orders.

alter table public.reps        enable row level security;
alter table public.orders      enable row level security;
alter table public.order_items enable row level security;

-- --------------------------------------------------------- submit_order
-- The single entry point the public page is allowed to call. Runs as the
-- definer so it can write through RLS, but returns only the order number —
-- a caller can never read anyone else's order back out of it.

create or replace function public.submit_order(payload jsonb)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_order_id  uuid;
  v_number    text;
  v_rep       text;
  v_rate      numeric(5,4) := 0;
  v_subtotal  integer;
  v_item      jsonb;
  v_count     integer;
begin
  v_number := nullif(trim(payload->>'order_number'), '');
  if v_number is null or v_number !~ '^VPL-[0-9]{6}-[0-9A-Z]{4}$' then
    raise exception 'bad order_number';
  end if;

  if nullif(trim(payload->>'customer_name'), '') is null then
    raise exception 'customer_name required';
  end if;

  -- Reject an empty or absurd cart outright.
  v_count := jsonb_array_length(coalesce(payload->'items', '[]'::jsonb));
  if v_count = 0 or v_count > 100 then
    raise exception 'bad item count';
  end if;

  -- Only attribute to a rep code that actually exists and is active.
  v_rep := upper(nullif(trim(payload->>'rep_code'), ''));
  if v_rep is not null then
    select commission_rate into v_rate
      from public.reps where code = v_rep and active;
    if not found then
      v_rep  := null;
      v_rate := 0;
    end if;
  end if;

  v_subtotal := greatest((payload->>'subtotal_cents')::integer, 0);

  insert into public.orders (
    order_number, customer_name, customer_email, customer_phone,
    delivery_method, street, unit, city, state, zip,
    subtotal_cents, discount_cents, shipping_cents, total_cents,
    rep_code, commission_rate, commission_cents,
    payment_method, notes, user_agent
  ) values (
    v_number,
    trim(payload->>'customer_name'),
    nullif(trim(payload->>'customer_email'), ''),
    nullif(trim(payload->>'customer_phone'), ''),
    coalesce(nullif(trim(payload->>'delivery_method'), ''), 'ship'),
    nullif(trim(payload->>'street'), ''),
    nullif(trim(payload->>'unit'), ''),
    nullif(trim(payload->>'city'), ''),
    nullif(trim(payload->>'state'), ''),
    nullif(trim(payload->>'zip'), ''),
    v_subtotal,
    greatest(coalesce((payload->>'discount_cents')::integer, 0), 0),
    greatest(coalesce((payload->>'shipping_cents')::integer, 0), 0),
    greatest((payload->>'total_cents')::integer, 0),
    v_rep,
    v_rate,
    round(v_subtotal * v_rate)::integer,
    nullif(trim(payload->>'payment_method'), ''),
    nullif(trim(payload->>'notes'), ''),
    nullif(trim(payload->>'user_agent'), '')
  )
  on conflict (order_number) do nothing
  returning id into v_order_id;

  -- A repeated submission of the same order number is a no-op, not an error.
  if v_order_id is null then
    return v_number;
  end if;

  for v_item in select * from jsonb_array_elements(payload->'items') loop
    insert into public.order_items (
      order_id, sku, name, unit_price_cents, qty, line_total_cents
    ) values (
      v_order_id,
      nullif(trim(v_item->>'sku'), ''),
      coalesce(nullif(trim(v_item->>'name'), ''), 'item'),
      greatest((v_item->>'unit_price_cents')::integer, 0),
      greatest((v_item->>'qty')::integer, 1),
      greatest((v_item->>'line_total_cents')::integer, 0)
    );
  end loop;

  return v_number;
end;
$fn$;

revoke all on function public.submit_order(jsonb) from public;
grant execute on function public.submit_order(jsonb) to anon, authenticated;

-- ------------------------------------------------------- rep_totals view
-- For your dashboard only — reachable with the service role, never anon.

create or replace view public.rep_totals as
select
  r.code,
  r.name,
  r.commission_rate,
  count(o.id)                                   as orders,
  coalesce(sum(o.subtotal_cents), 0)            as subtotal_cents,
  coalesce(sum(o.commission_cents), 0)          as commission_cents,
  coalesce(sum(o.commission_cents)
    filter (where o.status in ('paid','shipped')), 0) as earned_cents
from public.reps r
left join public.orders o
  on o.rep_code = r.code and o.status <> 'cancelled'
group by r.code, r.name, r.commission_rate;

revoke all on public.rep_totals from anon, authenticated;
