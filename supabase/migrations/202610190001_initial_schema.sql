create extension if not exists pgcrypto;

create type public.member_role as enum ('owner','manager','staff');
create type public.payment_method as enum ('cash','mpesa','credit','other');
create type public.sale_status as enum ('completed','reversed');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.businesses (
  id uuid primary key default gen_random_uuid(), name text not null check (length(trim(name)) between 1 and 120),
  category text not null default 'General shop', currency text not null default 'KES' check(currency='KES'),
  timezone text not null default 'Africa/Nairobi', created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.business_members (
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.member_role not null default 'owner', created_at timestamptz not null default now(),
  primary key (business_id,user_id)
);
create table public.products (
  id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null check(length(trim(name)) between 1 and 160), sku text, category text not null default 'General',
  buying_price numeric(12,2) not null default 0 check(buying_price>=0), selling_price numeric(12,2) not null check(selling_price>=0),
  quantity integer not null default 0 check(quantity>=0), low_stock_threshold integer not null default 5 check(low_stock_threshold>=0),
  description text, archived_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(business_id,sku)
);
create index products_business_name_idx on public.products(business_id,name) where archived_at is null;
create table public.customers (
  id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
  full_name text not null check(length(trim(full_name)) between 1 and 160), phone text, notes text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index customers_business_name_idx on public.customers(business_id,full_name);
create table public.sales (
  id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
  request_key uuid not null default gen_random_uuid(),
  customer_id uuid references public.customers(id) on delete set null, reference text not null,
  status public.sale_status not null default 'completed', payment_method public.payment_method not null,
  subtotal numeric(12,2) not null check(subtotal>=0), discount numeric(12,2) not null default 0 check(discount>=0),
  total numeric(12,2) not null check(total>=0), amount_paid numeric(12,2) not null default 0 check(amount_paid>=0),
  created_by uuid not null references auth.users(id), created_at timestamptz not null default now(), reversed_at timestamptz,
  unique(business_id,reference), unique(business_id,request_key), check(amount_paid<=total)
);
create index sales_business_created_idx on public.sales(business_id,created_at desc);
create table public.sale_items (
  id uuid primary key default gen_random_uuid(), sale_id uuid not null references public.sales(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete cascade, product_id uuid references public.products(id) on delete set null,
  product_name text not null, sku text, quantity integer not null check(quantity>0),
  selling_price numeric(12,2) not null check(selling_price>=0), cost_price numeric(12,2) not null check(cost_price>=0),
  line_total numeric(12,2) not null check(line_total>=0)
);
create index sale_items_business_sale_idx on public.sale_items(business_id,sale_id);
create table public.payments (
  id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null, sale_id uuid references public.sales(id) on delete restrict,
  request_key uuid, kind text not null check(kind in ('sale_payment','debt_repayment')), method public.payment_method not null,
  amount numeric(12,2) not null check(amount>0), note text, created_by uuid not null references auth.users(id), created_at timestamptz not null default now()
);
create unique index payments_request_key_uidx on public.payments(business_id,request_key) where request_key is not null;
create index payments_business_customer_idx on public.payments(business_id,customer_id,created_at desc);
create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict, kind text not null check(kind in ('received','sold','adjustment','return','reversal')),
  quantity_delta integer not null check(quantity_delta<>0), reason text, sale_id uuid references public.sales(id) on delete restrict,
  created_by uuid not null references auth.users(id), created_at timestamptz not null default now()
);
create index inventory_business_created_idx on public.inventory_movements(business_id,created_at desc);
create table public.expenses (
  id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
  description text not null check(length(trim(description)) between 1 and 200), category text not null default 'Other',
  amount numeric(12,2) not null check(amount>0), spent_on date not null default (now() at time zone 'Africa/Nairobi')::date,
  method public.payment_method not null default 'cash', notes text, created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index expenses_business_date_idx on public.expenses(business_id,spent_on desc);
create table public.subscriptions (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  plan text not null default 'free' check(plan in ('free','starter','plus')),
  status text not null default 'active' check(status in ('active','trialing','past_due','cancelled')),
  trial_ends_at timestamptz, period_ends_at timestamptz, updated_at timestamptz not null default now()
);
create table public.audit_logs (
  id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
  actor_id uuid not null references auth.users(id), action text not null, entity_type text not null, entity_id uuid,
  details jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);

create function public.touch_updated_at() returns trigger language plpgsql set search_path=public
as $$ begin new.updated_at:=now(); return new; end $$;
create trigger profiles_touch_updated_at before update on public.profiles for each row execute procedure public.touch_updated_at();
create trigger businesses_touch_updated_at before update on public.businesses for each row execute procedure public.touch_updated_at();
create trigger products_touch_updated_at before update on public.products for each row execute procedure public.touch_updated_at();
create trigger customers_touch_updated_at before update on public.customers for each row execute procedure public.touch_updated_at();
create trigger expenses_touch_updated_at before update on public.expenses for each row execute procedure public.touch_updated_at();
create trigger subscriptions_touch_updated_at before update on public.subscriptions for each row execute procedure public.touch_updated_at();

-- Keep opening stock movements in the ledger; later stock changes must use adjust_stock/create_sale.
create function public.log_opening_stock() returns trigger language plpgsql security definer set search_path=public
as $$ begin
  if new.quantity>0 then
    insert into public.inventory_movements(business_id,product_id,kind,quantity_delta,reason,created_by)
      values(new.business_id,new.id,'received',new.quantity,'Opening stock',coalesce(auth.uid(),(select user_id from public.business_members where business_id=new.business_id and role='owner' limit 1)));
  end if;
  return new;
end $$;
create trigger products_log_opening_stock after insert on public.products for each row execute procedure public.log_opening_stock();

create function public.audit_expense_changes() returns trigger language plpgsql security definer set search_path=public
as $$ declare bid uuid; eid uuid; action_name text; details jsonb; begin
  if tg_op='DELETE' then bid:=old.business_id; eid:=old.id; action_name:='expense_deleted'; details:=to_jsonb(old); else
    bid:=new.business_id; eid:=new.id; action_name:=case when tg_op='INSERT' then 'expense_created' else 'expense_updated' end;
    details:=case when tg_op='INSERT' then to_jsonb(new) else jsonb_build_object('before',to_jsonb(old),'after',to_jsonb(new)) end;
  end if;
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
    values(bid,coalesce(auth.uid(),(select user_id from public.business_members where business_id=bid and role='owner' limit 1)),action_name,'expense',eid,details);
  if tg_op='DELETE' then return old; else return new; end if;
end $$;
create trigger expenses_audit after insert or update or delete on public.expenses for each row execute procedure public.audit_expense_changes();

create function public.is_business_member(bid uuid) returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.business_members m where m.business_id=bid and m.user_id=auth.uid()) $$;
create function public.is_business_owner(bid uuid) returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.business_members m where m.business_id=bid and m.user_id=auth.uid() and m.role='owner') $$;
create function public.active_product_limit(plan_name text) returns integer language sql immutable
as $$ select case when plan_name='free' then 20 else null end $$;

create function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public
as $$ begin insert into public.profiles(id,full_name) values(new.id,coalesce(new.raw_user_meta_data->>'full_name','')); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

create function public.create_business(p_name text,p_category text,p_phone text default null) returns uuid
language plpgsql security definer set search_path=public
as $$ declare bid uuid; begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if length(trim(coalesce(p_name,'')))=0 then raise exception 'Shop name is required'; end if;
  update public.profiles set phone=nullif(trim(p_phone),''),updated_at=now() where id=auth.uid();
  insert into public.businesses(name,category) values(trim(p_name),coalesce(nullif(trim(p_category),''),'General shop')) returning id into bid;
  insert into public.business_members(business_id,user_id,role) values(bid,auth.uid(),'owner');
  insert into public.subscriptions(business_id) values(bid);
  return bid;
end $$;

create function public.adjust_stock(p_business uuid,p_product uuid,p_delta integer,p_reason text,p_kind text default 'adjustment') returns void
language plpgsql security definer set search_path=public
as $$ declare current_qty integer; begin
  if not public.is_business_member(p_business) then raise exception 'Not authorized'; end if;
  if p_delta=0 or length(trim(coalesce(p_reason,'')))=0 then raise exception 'A stock change and reason are required'; end if;
  select quantity into current_qty from public.products where id=p_product and business_id=p_business and archived_at is null for update;
  if not found then raise exception 'Product not found'; end if;
  if current_qty+p_delta<0 then raise exception 'Stock cannot be negative'; end if;
  update public.products set quantity=quantity+p_delta,updated_at=now() where id=p_product;
  insert into public.inventory_movements(business_id,product_id,kind,quantity_delta,reason,created_by)
    values(p_business,p_product,p_kind,p_delta,trim(p_reason),auth.uid());
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
    values(p_business,auth.uid(),'stock_adjusted','product',p_product,jsonb_build_object('delta',p_delta,'reason',p_reason));
end $$;

create function public.create_product(p_business uuid,p_name text,p_sku text,p_category text,p_buying_price numeric,
  p_selling_price numeric,p_quantity integer,p_threshold integer,p_description text default null) returns uuid
language plpgsql security definer set search_path=public
as $$ declare pid uuid; plan_name text; max_products integer; begin
  if not public.is_business_member(p_business) then raise exception 'Not authorized'; end if;
  perform 1 from public.businesses where id=p_business for update;
  select s.plan into plan_name from public.subscriptions s where s.business_id=p_business;
  max_products:=public.active_product_limit(coalesce(plan_name,'free'));
  if max_products is not null and (select count(*) from public.products where business_id=p_business and archived_at is null)>=max_products then
    raise exception 'Your Free plan supports up to % active products. Archive an item or upgrade your plan.',max_products;
  end if;
  insert into public.products(business_id,name,sku,category,buying_price,selling_price,quantity,low_stock_threshold,description)
    values(p_business,trim(p_name),nullif(trim(p_sku),''),coalesce(nullif(trim(p_category),''),'General'),p_buying_price,p_selling_price,p_quantity,p_threshold,p_description)
    returning id into pid;
  return pid;
end $$;

create function public.create_sale(p_business uuid,p_request_key uuid,p_items jsonb,p_method public.payment_method,p_amount_paid numeric default null,
  p_customer uuid default null,p_discount numeric default 0) returns uuid
language plpgsql security definer set search_path=public
as $$
declare sid uuid:=gen_random_uuid(); ref text; it jsonb; prod public.products%rowtype; qty integer; sub numeric(12,2):=0; total_due numeric(12,2); line numeric(12,2);
begin
  if not public.is_business_member(p_business) then raise exception 'Not authorized'; end if;
  select id into sid from public.sales where business_id=p_business and request_key=p_request_key;
  if found then return sid; end if;
  sid:=gen_random_uuid();
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one item'; end if;
  if p_discount<0 or p_amount_paid<0 then raise exception 'Amounts cannot be negative'; end if;
  for it in select value from jsonb_array_elements(p_items) loop
    qty:=(it->>'quantity')::integer;
    if qty<=0 then raise exception 'Quantity must be positive'; end if;
    select * into prod from public.products where id=(it->>'product_id')::uuid and business_id=p_business and archived_at is null for update;
    if not found then raise exception 'Product not found'; end if;
    if prod.quantity<qty then raise exception 'Insufficient stock for %',prod.name; end if;
    sub:=sub+prod.selling_price*qty;
  end loop;
  if p_discount>sub then raise exception 'Discount cannot exceed subtotal'; end if;
  total_due:=sub-p_discount;
  if p_amount_paid is null then p_amount_paid:=case when p_method='credit' then 0 else total_due end; end if;
  if p_amount_paid>total_due then raise exception 'Amount paid cannot exceed sale total'; end if;
  if total_due>p_amount_paid and (p_customer is null or not exists(select 1 from public.customers where id=p_customer and business_id=p_business)) then
    raise exception 'Select a customer for an unpaid balance';
  end if;
  if p_method='credit' and p_customer is null then raise exception 'Select a customer for a credit sale'; end if;
  ref:='DL-'||upper(substr(replace(sid::text,'-',''),1,10));
  insert into public.sales(id,business_id,request_key,customer_id,reference,payment_method,subtotal,discount,total,amount_paid,created_by)
    values(sid,p_business,p_request_key,p_customer,ref,p_method,sub,p_discount,total_due,p_amount_paid,auth.uid());
  for it in select value from jsonb_array_elements(p_items) loop
    qty:=(it->>'quantity')::integer;
    select * into prod from public.products where id=(it->>'product_id')::uuid and business_id=p_business for update;
    line:=prod.selling_price*qty;
    insert into public.sale_items(sale_id,business_id,product_id,product_name,sku,quantity,selling_price,cost_price,line_total)
      values(sid,p_business,prod.id,prod.name,prod.sku,qty,prod.selling_price,prod.buying_price,line);
    update public.products set quantity=quantity-qty,updated_at=now() where id=prod.id;
    insert into public.inventory_movements(business_id,product_id,kind,quantity_delta,reason,sale_id,created_by)
      values(p_business,prod.id,'sold',-qty,'Sale '||ref,sid,auth.uid());
  end loop;
  if p_amount_paid>0 then insert into public.payments(business_id,customer_id,sale_id,kind,method,amount,created_by)
    values(p_business,p_customer,sid,'sale_payment',p_method,p_amount_paid,auth.uid()); end if;
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
    values(p_business,auth.uid(),'sale_created','sale',sid,jsonb_build_object('reference',ref,'total',total_due));
  return sid;
end $$;

create function public.record_repayment(p_business uuid,p_request_key uuid,p_customer uuid,p_amount numeric,p_method public.payment_method,p_note text default null) returns uuid
language plpgsql security definer set search_path=public
as $$ declare pid uuid; owing numeric(12,2); begin
  if not public.is_business_member(p_business) then raise exception 'Not authorized'; end if;
  select id into pid from public.payments where business_id=p_business and request_key=p_request_key;
  if found then return pid; end if;
  if p_amount<=0 then raise exception 'Repayment must be greater than zero'; end if;
  perform 1 from public.customers where id=p_customer and business_id=p_business for update;
  if not found then raise exception 'Customer not found'; end if;
  select greatest(coalesce((select sum(total-amount_paid) from public.sales where business_id=p_business and customer_id=p_customer and status='completed'),0)
    - coalesce((select sum(amount) from public.payments where business_id=p_business and customer_id=p_customer and kind='debt_repayment'),0),0)
    into owing;
  if p_amount>owing then raise exception 'Repayment exceeds outstanding balance'; end if;
  insert into public.payments(business_id,customer_id,request_key,kind,method,amount,note,created_by)
    values(p_business,p_customer,p_request_key,'debt_repayment',p_method,p_amount,p_note,auth.uid()) returning id into pid;
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
    values(p_business,auth.uid(),'debt_repayment','customer',p_customer,jsonb_build_object('amount',p_amount,'payment_id',pid));
  return pid;
end $$;

-- Debt is derived from sale balances and explicit repayments through the helper below.
create function public.customer_balances(p_business uuid) returns table(customer_id uuid,outstanding numeric)
language sql stable security definer set search_path=public
as $$ select c.id, greatest(coalesce(sum(s.total-s.amount_paid),0)-coalesce((select sum(p.amount) from public.payments p where p.business_id=c.business_id and p.customer_id=c.id and p.kind='debt_repayment'),0),0)
 from public.customers c left join public.sales s on s.customer_id=c.id and s.business_id=c.business_id and s.status='completed'
 where c.business_id=p_business and public.is_business_member(p_business) group by c.id,c.business_id $$;

alter table public.profiles enable row level security;
alter table public.businesses enable row level security;
alter table public.business_members enable row level security;
alter table public.products enable row level security;
alter table public.customers enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.payments enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.expenses enable row level security;
alter table public.subscriptions enable row level security;
alter table public.audit_logs enable row level security;

revoke all on public.profiles,public.businesses,public.business_members,public.products,public.customers,
  public.sales,public.sale_items,public.payments,public.inventory_movements,public.expenses,public.subscriptions,public.audit_logs
  from anon;
grant select,update on public.profiles to authenticated;
grant select,update on public.businesses to authenticated;
grant select on public.business_members to authenticated;
grant select,update on public.products to authenticated;
grant select,insert,update on public.customers to authenticated;
grant select on public.sales,public.sale_items,public.payments,public.inventory_movements,public.subscriptions,public.audit_logs to authenticated;
grant select,insert,update on public.expenses to authenticated;
grant usage on type public.member_role,public.payment_method,public.sale_status to authenticated;

create policy "profile owner read" on public.profiles for select using (id=auth.uid());
create policy "profile owner update" on public.profiles for update using (id=auth.uid()) with check (id=auth.uid());
create policy "member business read" on public.businesses for select using (public.is_business_member(id));
create policy "owner business update" on public.businesses for update using (public.is_business_owner(id)) with check (public.is_business_owner(id));
create policy "member list own memberships" on public.business_members for select using (user_id=auth.uid() or public.is_business_member(business_id));
create policy "member read products" on public.products for select using (public.is_business_member(business_id));
create policy "member update products" on public.products for update using (public.is_business_member(business_id)) with check (public.is_business_member(business_id));
create policy "member read customers" on public.customers for select using (public.is_business_member(business_id));
create policy "member add customers" on public.customers for insert with check (public.is_business_member(business_id));
create policy "member update customers" on public.customers for update using (public.is_business_member(business_id)) with check (public.is_business_member(business_id));
create policy "member read sales" on public.sales for select using (public.is_business_member(business_id));
create policy "member read sale items" on public.sale_items for select using (public.is_business_member(business_id));
create policy "member read payments" on public.payments for select using (public.is_business_member(business_id));
create policy "member read movements" on public.inventory_movements for select using (public.is_business_member(business_id));
create policy "member read expenses" on public.expenses for select using (public.is_business_member(business_id));
create policy "member add expenses" on public.expenses for insert with check (public.is_business_member(business_id) and created_by=auth.uid());
create policy "member update expenses" on public.expenses for update using (public.is_business_member(business_id) and created_by=auth.uid()) with check (public.is_business_member(business_id) and created_by=auth.uid());
create policy "member read subscription" on public.subscriptions for select using (public.is_business_member(business_id));
create policy "member read audit" on public.audit_logs for select using (public.is_business_member(business_id));

-- Stock quantities are changed only by the audited stock RPCs and atomic sale function.
revoke update on public.products from authenticated, anon;
grant update(name,sku,category,buying_price,selling_price,low_stock_threshold,description,archived_at)
  on public.products to authenticated;

revoke all on function public.create_business(text,text,text) from public;
revoke all on function public.create_sale(uuid,uuid,jsonb,public.payment_method,numeric,uuid,numeric) from public;
revoke all on function public.record_repayment(uuid,uuid,uuid,numeric,public.payment_method,text) from public;
revoke all on function public.adjust_stock(uuid,uuid,integer,text,text) from public;
revoke all on function public.create_product(uuid,text,text,text,numeric,numeric,integer,integer,text) from public;
grant execute on function public.create_business(text,text,text) to authenticated;
grant execute on function public.create_sale(uuid,uuid,jsonb,public.payment_method,numeric,uuid,numeric) to authenticated;
grant execute on function public.record_repayment(uuid,uuid,uuid,numeric,public.payment_method,text) to authenticated;
grant execute on function public.adjust_stock(uuid,uuid,integer,text,text) to authenticated;
grant execute on function public.create_product(uuid,text,text,text,numeric,numeric,integer,integer,text) to authenticated;
grant execute on function public.customer_balances(uuid) to authenticated;

revoke insert on public.products from authenticated, anon;
