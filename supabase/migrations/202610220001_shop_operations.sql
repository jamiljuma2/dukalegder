-- Shop operations: reconciliation, supplier purchasing, expiry batches and restocking.
alter table public.products
  add column expiry_tracking_enabled boolean not null default false,
  add column expiry_warning_days integer not null default 30 check (expiry_warning_days between 0 and 365),
  add column supplier_lead_time_days integer not null default 2 check (supplier_lead_time_days between 0 and 365),
  add column desired_stock_days integer not null default 14 check (desired_stock_days between 1 and 365);

grant update (expiry_tracking_enabled, expiry_warning_days, supplier_lead_time_days, desired_stock_days)
  on public.products to authenticated;
grant update (expiry_tracking_enabled, expiry_warning_days, supplier_lead_time_days, desired_stock_days)
  on public.products to service_role;

create table public.cash_reconciliations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  business_date date not null,
  opening_cash numeric(12,2) not null check (opening_cash >= 0),
  cash_sales numeric(12,2) not null default 0 check (cash_sales >= 0),
  cash_expenses numeric(12,2) not null default 0 check (cash_expenses >= 0),
  cash_withdrawals numeric(12,2) not null default 0 check (cash_withdrawals >= 0),
  expected_closing_cash numeric(12,2) not null,
  closing_cash numeric(12,2) not null check (closing_cash >= 0),
  difference numeric(12,2) not null,
  notes text,
  recorded_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, business_date)
);
create index cash_reconciliations_business_date_idx on public.cash_reconciliations(business_id, business_date desc);

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 160),
  phone text,
  business_details text,
  notes text,
  payment_terms text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, name)
);
create index suppliers_business_name_idx on public.suppliers(business_id, name);

create table public.supplier_purchases (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  request_key uuid not null,
  supplier_id uuid references public.suppliers(id) on delete set null,
  invoice_reference text,
  purchased_on date not null default (now() at time zone 'Africa/Nairobi')::date,
  status text not null default 'draft' check (status in ('draft','received')),
  notes text,
  created_by uuid not null references auth.users(id),
  received_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, supplier_id, invoice_reference),
  unique (business_id, request_key),
  check ((status = 'received') = (received_at is not null))
);
create index supplier_purchases_business_date_idx on public.supplier_purchases(business_id, purchased_on desc);
create index supplier_purchases_supplier_idx on public.supplier_purchases(business_id, supplier_id, purchased_on desc);

create table public.supplier_purchase_items (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.supplier_purchases(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  unit_cost numeric(12,2) not null check (unit_cost >= 0),
  expiry_date date,
  created_at timestamptz not null default now()
);
create index supplier_purchase_items_purchase_idx on public.supplier_purchase_items(purchase_id);
create index supplier_purchase_items_product_idx on public.supplier_purchase_items(business_id, product_id);

create table public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  purchase_id uuid not null references public.supplier_purchases(id) on delete restrict,
  request_key uuid not null,
  amount numeric(12,2) not null check (amount > 0),
  method text not null check (method in ('cash','mpesa','bank','other')),
  note text,
  paid_on date not null default (now() at time zone 'Africa/Nairobi')::date,
  recorded_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique (business_id, request_key)
);
create index supplier_payments_purchase_idx on public.supplier_payments(purchase_id, paid_on desc);

create table public.product_batches (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  supplier_id uuid references public.suppliers(id) on delete set null,
  purchase_id uuid references public.supplier_purchases(id) on delete set null,
  received_quantity integer not null check (received_quantity > 0),
  remaining_quantity integer not null check (remaining_quantity >= 0 and remaining_quantity <= received_quantity),
  unit_cost numeric(12,2) not null check (unit_cost >= 0),
  expiry_date date not null,
  received_on date not null default (now() at time zone 'Africa/Nairobi')::date,
  created_at timestamptz not null default now()
);
create index product_batches_expiry_idx on public.product_batches(business_id, expiry_date, product_id) where remaining_quantity > 0;
create index product_batches_product_idx on public.product_batches(product_id, expiry_date) where remaining_quantity > 0;

create table public.product_batch_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  batch_id uuid not null references public.product_batches(id) on delete cascade,
  inventory_movement_id uuid references public.inventory_movements(id) on delete set null,
  quantity_delta integer not null check (quantity_delta <> 0),
  kind text not null,
  reason text,
  created_at timestamptz not null default now()
);
create index product_batch_movements_batch_idx on public.product_batch_movements(batch_id, created_at desc);
alter table public.inventory_movements add column batch_id uuid references public.product_batches(id) on delete set null;

alter table public.cash_reconciliations enable row level security;
alter table public.suppliers enable row level security;
alter table public.supplier_purchases enable row level security;
alter table public.supplier_purchase_items enable row level security;
alter table public.supplier_payments enable row level security;
alter table public.product_batches enable row level security;
alter table public.product_batch_movements enable row level security;
revoke all on public.cash_reconciliations, public.suppliers, public.supplier_purchases,
  public.supplier_purchase_items, public.supplier_payments, public.product_batches, public.product_batch_movements from anon, authenticated;
grant select on public.cash_reconciliations, public.suppliers, public.supplier_purchases,
  public.supplier_purchase_items, public.supplier_payments, public.product_batches, public.product_batch_movements to authenticated;
grant insert, update on public.suppliers to authenticated;
grant all on public.cash_reconciliations, public.suppliers, public.supplier_purchases,
  public.supplier_purchase_items, public.supplier_payments, public.product_batches,
  public.product_batch_movements to service_role;

create policy "managers read cash reconciliations" on public.cash_reconciliations for select to authenticated
  using (public.has_business_role(business_id, array['owner','manager']::public.member_role[]));
create policy "managers read suppliers" on public.suppliers for select to authenticated
  using (public.has_business_role(business_id, array['owner','manager']::public.member_role[]));
create policy "managers manage suppliers" on public.suppliers for all to authenticated
  using (public.has_business_role(business_id, array['owner','manager']::public.member_role[]))
  with check (public.has_business_role(business_id, array['owner','manager']::public.member_role[]));
create policy "managers read supplier purchases" on public.supplier_purchases for select to authenticated
  using (public.has_business_role(business_id, array['owner','manager']::public.member_role[]));
create policy "managers read purchase items" on public.supplier_purchase_items for select to authenticated
  using (public.has_business_role(business_id, array['owner','manager']::public.member_role[]));
create policy "managers read supplier payments" on public.supplier_payments for select to authenticated
  using (public.has_business_role(business_id, array['owner','manager']::public.member_role[]));
create policy "managers read product batches" on public.product_batches for select to authenticated
  using (public.has_business_role(business_id, array['owner','manager']::public.member_role[]));
create policy "managers read product batch movements" on public.product_batch_movements for select to authenticated
  using (public.has_business_role(business_id, array['owner','manager']::public.member_role[]));

-- All reductions (sales, damage, corrections) consume known expiry stock first,
-- using FEFO. Older stock without a known expiry remains untracked and usable.
alter table public.inventory_movements drop constraint if exists inventory_movements_kind_check;
alter table public.inventory_movements add constraint inventory_movements_kind_check
  check (kind in ('received','sold','adjustment','return','reversal','purchase','damage'));
create or replace function public.consume_product_batches_on_stock_out()
returns trigger language plpgsql security definer set search_path=public
as $$
declare remaining integer := abs(new.quantity_delta); batch record; take integer;
begin
  if new.quantity_delta >= 0 then return new; end if;
  if new.batch_id is not null then
    select id,remaining_quantity into batch from public.product_batches
      where id=new.batch_id and business_id=new.business_id and product_id=new.product_id for update;
    if not found or batch.remaining_quantity < remaining then raise exception 'Batch quantity is no longer available'; end if;
    update public.product_batches set remaining_quantity=remaining_quantity-remaining where id=batch.id;
    insert into public.product_batch_movements(business_id,batch_id,inventory_movement_id,quantity_delta,kind,reason)
      values(new.business_id,batch.id,new.id,-remaining,new.kind,new.reason);
    return new;
  end if;
  for batch in select id, remaining_quantity from public.product_batches
    where business_id=new.business_id and product_id=new.product_id and remaining_quantity > 0
    order by expiry_date, received_on, created_at for update
  loop
    exit when remaining <= 0;
    take := least(remaining, batch.remaining_quantity);
    update public.product_batches set remaining_quantity=remaining_quantity-take where id=batch.id;
    insert into public.product_batch_movements(business_id,batch_id,inventory_movement_id,quantity_delta,kind,reason)
      values(new.business_id,batch.id,new.id,-take,new.kind,new.reason);
    remaining := remaining-take;
  end loop;
  return new;
end $$;
create trigger inventory_movements_consume_batches after insert on public.inventory_movements
  for each row execute function public.consume_product_batches_on_stock_out();

create or replace function public.save_cash_reconciliation(
  p_business uuid, p_date date, p_opening_cash numeric, p_cash_withdrawals numeric,
  p_closing_cash numeric, p_notes text default null
) returns public.cash_reconciliations
language plpgsql security definer set search_path=public
as $$
declare sales_cash numeric(12,2); expenses_cash numeric(12,2); result_row public.cash_reconciliations%rowtype;
  day_start timestamptz := (p_date::timestamp at time zone 'Africa/Nairobi');
begin
  if auth.uid() is null or not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then
    raise exception 'Not authorized to reconcile this shop';
  end if;
  if p_date is null or p_date > (now() at time zone 'Africa/Nairobi')::date
     or p_opening_cash is null or p_cash_withdrawals is null or p_closing_cash is null
     or p_opening_cash < 0 or p_cash_withdrawals < 0 or p_closing_cash < 0 then
    raise exception 'Enter a date and non-negative cash amounts';
  end if;
  select coalesce(sum(amount_paid),0) + coalesce((select sum(p.amount) from public.payments p
      where p.business_id=p_business and p.kind='debt_repayment' and p.method='cash'
        and p.created_at >= day_start and p.created_at < day_start + interval '1 day'),0)
    into sales_cash from public.sales
    where business_id=p_business and status='completed' and payment_method='cash'
      and created_at >= day_start and created_at < day_start + interval '1 day';
  select coalesce(sum(amount),0) into expenses_cash from public.expenses
    where business_id=p_business and method='cash' and spent_on=p_date;
  insert into public.cash_reconciliations(business_id,business_date,opening_cash,cash_sales,cash_expenses,
      cash_withdrawals,expected_closing_cash,closing_cash,difference,notes,recorded_by)
    values(p_business,p_date,p_opening_cash,sales_cash,expenses_cash,p_cash_withdrawals,
      p_opening_cash+sales_cash-expenses_cash-p_cash_withdrawals,p_closing_cash,
      p_closing_cash-(p_opening_cash+sales_cash-expenses_cash-p_cash_withdrawals),nullif(trim(p_notes),''),auth.uid())
  on conflict (business_id,business_date) do update set
    opening_cash=excluded.opening_cash,cash_sales=excluded.cash_sales,cash_expenses=excluded.cash_expenses,
    cash_withdrawals=excluded.cash_withdrawals,expected_closing_cash=excluded.expected_closing_cash,
    closing_cash=excluded.closing_cash,difference=excluded.difference,notes=excluded.notes,
    recorded_by=excluded.recorded_by,updated_at=now()
  returning * into result_row;
  return result_row;
end $$;

create or replace function public.save_supplier_purchase(
  p_business uuid, p_purchase uuid, p_request_key uuid, p_supplier uuid, p_invoice_reference text,
  p_date date, p_notes text, p_items jsonb
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare v_purchase_id uuid:=coalesce(p_purchase,gen_random_uuid()); created_id uuid; item jsonb; product_id uuid; qty integer; cost numeric;
begin
  if auth.uid() is null or not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized'; end if;
  if p_request_key is null or p_date is null or p_items is null or jsonb_typeof(p_items) is distinct from 'array' then raise exception 'Add at least one product to the draft'; end if;
  if jsonb_array_length(p_items)=0 then raise exception 'Add at least one product to the draft'; end if;
  if p_supplier is not null and not exists(select 1 from public.suppliers where id=p_supplier and business_id=p_business) then raise exception 'Supplier not found'; end if;
  if p_purchase is null then
    insert into public.supplier_purchases(id,business_id,request_key,supplier_id,invoice_reference,purchased_on,notes,created_by)
      values(v_purchase_id,p_business,p_request_key,p_supplier,nullif(trim(p_invoice_reference),''),p_date,nullif(trim(p_notes),''),auth.uid())
      on conflict (business_id,request_key) do nothing returning id into created_id;
    if created_id is null then
      select id into v_purchase_id from public.supplier_purchases where business_id=p_business and request_key=p_request_key;
      return v_purchase_id;
    end if;
  else
    perform 1 from public.supplier_purchases where id=p_purchase and business_id=p_business and status='draft' for update;
    if not found then raise exception 'Only an existing draft purchase can be edited'; end if;
    update public.supplier_purchases set supplier_id=p_supplier,invoice_reference=nullif(trim(p_invoice_reference),''),
      purchased_on=p_date,notes=nullif(trim(p_notes),''),updated_at=now() where id=p_purchase;
    delete from public.supplier_purchase_items where purchase_id=p_purchase;
  end if;
  for item in select value from jsonb_array_elements(p_items) loop
    product_id:=(item->>'product_id')::uuid; qty:=(item->>'quantity')::integer; cost:=(item->>'unit_cost')::numeric;
    if qty<=0 or cost<0 or not exists(select 1 from public.products where id=product_id and business_id=p_business and archived_at is null) then raise exception 'Check the product, quantity and cost for every line'; end if;
    insert into public.supplier_purchase_items(purchase_id,business_id,product_id,quantity,unit_cost,expiry_date)
      values(v_purchase_id,p_business,product_id,qty,cost,nullif(item->>'expiry_date','')::date);
  end loop;
  return v_purchase_id;
end $$;

create or replace function public.confirm_supplier_purchase(p_purchase uuid)
returns text language plpgsql security definer set search_path=public
as $$
declare purchase_row public.supplier_purchases%rowtype; line record; product_row public.products%rowtype; batch_id uuid; movement_id uuid;
begin
  select * into purchase_row from public.supplier_purchases where id=p_purchase for update;
  if not found or not public.has_business_role(purchase_row.business_id,array['owner','manager']::public.member_role[]) then raise exception 'Purchase not found or not authorized'; end if;
  if purchase_row.status='received' then return 'received'; end if;
  if purchase_row.supplier_id is null then raise exception 'Choose a supplier before confirming this purchase'; end if;
  for line in select * from public.supplier_purchase_items where purchase_id=p_purchase order by id loop
    select * into product_row from public.products where id=line.product_id and business_id=purchase_row.business_id and archived_at is null for update;
    if not found then raise exception 'A product in this purchase is no longer active'; end if;
    if product_row.expiry_tracking_enabled and line.expiry_date is null then raise exception 'Add an expiry date for %',product_row.name; end if;
    update public.products set quantity=quantity+line.quantity,buying_price=line.unit_cost,updated_at=now() where id=line.product_id;
    if line.expiry_date is not null then
      batch_id:=gen_random_uuid();
      insert into public.product_batches(id,business_id,product_id,supplier_id,purchase_id,received_quantity,remaining_quantity,unit_cost,expiry_date)
        values(batch_id,purchase_row.business_id,line.product_id,purchase_row.supplier_id,p_purchase,line.quantity,line.quantity,line.unit_cost,line.expiry_date);
    end if;
    insert into public.inventory_movements(business_id,product_id,kind,quantity_delta,reason,created_by)
      values(purchase_row.business_id,line.product_id,'purchase',line.quantity,'Purchase '||coalesce(purchase_row.invoice_reference,p_purchase::text),auth.uid()) returning id into movement_id;
    if batch_id is not null then
      insert into public.product_batch_movements(business_id,batch_id,inventory_movement_id,quantity_delta,kind,reason)
        values(purchase_row.business_id,batch_id,movement_id,line.quantity,'purchase','Purchase received');
      batch_id:=null;
    end if;
  end loop;
  update public.supplier_purchases set status='received',received_at=now(),updated_at=now() where id=p_purchase;
  return 'received';
end $$;

create or replace function public.receive_product_batch(
  p_business uuid,p_product uuid,p_quantity integer,p_unit_cost numeric,p_expiry_date date,p_supplier uuid default null
) returns uuid language plpgsql security definer set search_path=public
as $$
declare product_row public.products%rowtype; batch_id uuid:=gen_random_uuid(); movement_id uuid;
begin
  if auth.uid() is null or not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized'; end if;
  if p_quantity<=0 or p_unit_cost<0 or p_expiry_date is null then raise exception 'Enter a valid quantity, cost and expiry date'; end if;
  if p_supplier is not null and not exists(select 1 from public.suppliers where id=p_supplier and business_id=p_business) then raise exception 'Supplier not found'; end if;
  select * into product_row from public.products where id=p_product and business_id=p_business and archived_at is null for update;
  if not found then raise exception 'Product not found'; end if;
  if not product_row.expiry_tracking_enabled then raise exception 'Enable expiry tracking for this product first'; end if;
  insert into public.product_batches(id,business_id,product_id,supplier_id,received_quantity,remaining_quantity,unit_cost,expiry_date)
    values(batch_id,p_business,p_product,p_supplier,p_quantity,p_quantity,p_unit_cost,p_expiry_date);
  update public.products set quantity=quantity+p_quantity,buying_price=p_unit_cost,updated_at=now() where id=p_product;
  insert into public.inventory_movements(business_id,product_id,kind,quantity_delta,reason,created_by)
    values(p_business,p_product,'received',p_quantity,'Expiry batch received',auth.uid()) returning id into movement_id;
  insert into public.product_batch_movements(business_id,batch_id,inventory_movement_id,quantity_delta,kind,reason)
    values(p_business,batch_id,movement_id,p_quantity,'received','Expiry batch received');
  return batch_id;
end $$;

create or replace function public.dispose_expired_product_batch(
  p_business uuid,p_batch uuid,p_quantity integer,p_reason text default 'Expired stock removed'
) returns void language plpgsql security definer set search_path=public
as $$
declare batch public.product_batches%rowtype; product_row public.products%rowtype;
begin
  if auth.uid() is null or not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized'; end if;
  if p_quantity<=0 or length(trim(coalesce(p_reason,'')))=0 then raise exception 'Enter a quantity and reason'; end if;
  select * into batch from public.product_batches where id=p_batch and business_id=p_business;
  if not found then raise exception 'Batch not found'; end if;
  select * into product_row from public.products where id=batch.product_id and business_id=p_business for update;
  if not found or product_row.quantity<p_quantity then raise exception 'Product stock is lower than the batch quantity'; end if;
  select * into batch from public.product_batches where id=p_batch and business_id=p_business for update;
  if batch.expiry_date >= (now() at time zone 'Africa/Nairobi')::date then raise exception 'Only expired batches can be removed here'; end if;
  if p_quantity>batch.remaining_quantity then raise exception 'Quantity exceeds the remaining batch stock'; end if;
  update public.products set quantity=quantity-p_quantity,updated_at=now() where id=batch.product_id;
  insert into public.inventory_movements(business_id,product_id,kind,quantity_delta,reason,created_by,batch_id)
    values(p_business,batch.product_id,'damage',-p_quantity,trim(p_reason),auth.uid(),batch.id);
end $$;

create or replace function public.record_supplier_payment(
  p_business uuid,p_purchase uuid,p_request_key uuid,p_amount numeric,p_method text,p_note text default null,p_paid_on date default null
) returns uuid language plpgsql security definer set search_path=public
as $$
declare purchase_row public.supplier_purchases%rowtype; total_due numeric(12,2); already_paid numeric(12,2); payment_id uuid;
begin
  if auth.uid() is null or not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized'; end if;
  select * into purchase_row from public.supplier_purchases where id=p_purchase and business_id=p_business for update;
  if not found or purchase_row.status<>'received' then raise exception 'Only a received purchase can be paid'; end if;
  if p_amount<=0 or p_method not in ('cash','mpesa','bank','other') then raise exception 'Enter a valid payment amount and method'; end if;
  select id into payment_id from public.supplier_payments where business_id=p_business and request_key=p_request_key;
  if payment_id is not null then return payment_id; end if;
  select coalesce(sum(quantity*unit_cost),0) into total_due from public.supplier_purchase_items where purchase_id=p_purchase;
  select coalesce(sum(amount),0) into already_paid from public.supplier_payments where purchase_id=p_purchase;
  if already_paid+p_amount>total_due then raise exception 'Payment exceeds the outstanding purchase balance'; end if;
  insert into public.supplier_payments(business_id,purchase_id,request_key,amount,method,note,paid_on,recorded_by)
    values(p_business,p_purchase,p_request_key,p_amount,p_method,nullif(trim(p_note),''),coalesce(p_paid_on,(now() at time zone 'Africa/Nairobi')::date),auth.uid())
    on conflict (business_id,request_key) do nothing returning id into payment_id;
  if payment_id is null then select id into payment_id from public.supplier_payments where business_id=p_business and request_key=p_request_key; end if;
  return payment_id;
end $$;

create or replace function public.smart_restock_suggestions(p_business uuid,p_history_days integer default 30)
returns table(product_id uuid,name text,category text,current_stock integer,minimum_stock integer,average_daily_sales numeric,
  days_until_stockout numeric,recommended_quantity integer,suggested_reorder_date date,supplier_lead_time_days integer,
  desired_stock_days integer,sales_units bigint,limited_history boolean,buying_price numeric)
language plpgsql stable security definer set search_path=public
as $$
begin
  if auth.uid() is null or not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized'; end if;
  if p_history_days<7 or p_history_days>365 then raise exception 'History period must be between 7 and 365 days'; end if;
  return query
  with demand as (
    select i.product_id,sum(i.quantity)::bigint units,count(distinct (s.created_at at time zone 'Africa/Nairobi')::date)::integer active_days
    from public.sale_items i join public.sales s on s.id=i.sale_id
    where s.business_id=p_business and s.status='completed'
      and s.created_at >= now()-make_interval(days=>p_history_days)
    group by i.product_id
  ), base as (
    select p.id,p.name,p.category,p.quantity,p.low_stock_threshold,p.supplier_lead_time_days,p.desired_stock_days,
      coalesce(d.units,0)::bigint units,coalesce(d.active_days,0)::integer active_days,
      coalesce(d.units,0)::numeric/p_history_days daily
    from public.products p left join demand d on d.product_id=p.id
    where p.business_id=p_business and p.archived_at is null
  )
  select b.id,b.name,b.category,b.quantity,b.low_stock_threshold,round(b.daily,2),
    case when b.daily>0 then round(b.quantity/b.daily,1) else null end,
    greatest(0,ceil(b.daily*b.desired_stock_days)::integer-b.quantity,
    case when b.quantity<=b.low_stock_threshold then b.low_stock_threshold-b.quantity else 0 end),
    ((now() at time zone 'Africa/Nairobi')::date + greatest(0,coalesce(floor(b.quantity/nullif(b.daily,0))::integer,0)-b.supplier_lead_time_days)),
    b.supplier_lead_time_days,b.desired_stock_days,b.units,(b.active_days<7),p.buying_price
  from base b join public.products p on p.id=b.id
  where b.quantity<=b.low_stock_threshold or (b.daily>0 and b.quantity/b.daily <= b.supplier_lead_time_days+b.desired_stock_days)
  order by (b.quantity<=b.low_stock_threshold) desc,
    (case when b.daily>0 then b.quantity/b.daily else 999999 end) asc,b.name;
end $$;

revoke all on function public.save_cash_reconciliation(uuid,date,numeric,numeric,numeric,text) from public;
revoke all on function public.save_supplier_purchase(uuid,uuid,uuid,uuid,text,date,text,jsonb) from public;
revoke all on function public.confirm_supplier_purchase(uuid) from public;
revoke all on function public.receive_product_batch(uuid,uuid,integer,numeric,date,uuid) from public;
revoke all on function public.dispose_expired_product_batch(uuid,uuid,integer,text) from public;
revoke all on function public.record_supplier_payment(uuid,uuid,uuid,numeric,text,text,date) from public;
revoke all on function public.smart_restock_suggestions(uuid,integer) from public;
grant execute on function public.save_cash_reconciliation(uuid,date,numeric,numeric,numeric,text) to authenticated;
grant execute on function public.save_supplier_purchase(uuid,uuid,uuid,uuid,text,date,text,jsonb) to authenticated;
grant execute on function public.confirm_supplier_purchase(uuid) to authenticated;
grant execute on function public.receive_product_batch(uuid,uuid,integer,numeric,date,uuid) to authenticated;
grant execute on function public.dispose_expired_product_batch(uuid,uuid,integer,text) to authenticated;
grant execute on function public.record_supplier_payment(uuid,uuid,uuid,numeric,text,text,date) to authenticated;
grant execute on function public.smart_restock_suggestions(uuid,integer) to authenticated;
