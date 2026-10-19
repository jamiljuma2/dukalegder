-- Align existing databases with the current credit sale and repayment RPCs.
alter table public.sales add column if not exists request_key uuid;
update public.sales set request_key=gen_random_uuid() where request_key is null;
alter table public.sales alter column request_key set default gen_random_uuid();
alter table public.sales alter column request_key set not null;
create unique index if not exists sales_business_id_request_key_key on public.sales(business_id,request_key);

alter table public.payments add column if not exists request_key uuid;
create unique index if not exists payments_request_key_uidx on public.payments(business_id,request_key) where request_key is not null;

-- Remove pre-idempotency overloads so PostgREST has one supported RPC signature.
drop function if exists public.create_sale(uuid,jsonb,public.payment_method,numeric,uuid,numeric);
drop function if exists public.record_repayment(uuid,uuid,numeric,public.payment_method,text);

create or replace function public.create_sale(
  p_business uuid,
  p_request_key uuid,
  p_items jsonb,
  p_method public.payment_method,
  p_amount_paid numeric default null,
  p_customer uuid default null,
  p_discount numeric default 0
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  sid uuid;
  ref text;
  it jsonb;
  prod public.products%rowtype;
  qty integer;
  sub numeric(12,2):=0;
  total_due numeric(12,2);
  line numeric(12,2);
begin
  if not public.is_business_member(p_business) then raise exception 'Not authorized'; end if;
  if p_request_key is null then raise exception 'A request key is required'; end if;
  select id into sid from public.sales where business_id=p_business and request_key=p_request_key;
  if found then return sid; end if;
  sid:=gen_random_uuid();
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one item'; end if;
  if p_discount<0 or p_amount_paid<0 then raise exception 'Amounts cannot be negative'; end if;

  for it in select value from jsonb_array_elements(p_items) loop
    qty:=(it->>'quantity')::integer;
    if qty<=0 then raise exception 'Quantity must be positive'; end if;
    select * into prod from public.products
      where id=(it->>'product_id')::uuid and business_id=p_business and archived_at is null for update;
    if not found then raise exception 'Product not found'; end if;
    if prod.quantity<qty then raise exception 'Insufficient stock for %',prod.name; end if;
    sub:=sub+prod.selling_price*qty;
  end loop;

  if p_discount>sub then raise exception 'Discount cannot exceed subtotal'; end if;
  total_due:=sub-p_discount;
  if p_amount_paid is null then p_amount_paid:=case when p_method='credit' then 0 else total_due end; end if;
  if p_amount_paid>total_due then raise exception 'Amount paid cannot exceed sale total'; end if;
  if total_due>p_amount_paid and (p_customer is null or not exists(
    select 1 from public.customers where id=p_customer and business_id=p_business
  )) then raise exception 'Select a customer for an unpaid balance'; end if;
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

  if p_amount_paid>0 then
    insert into public.payments(business_id,customer_id,sale_id,kind,method,amount,created_by)
      values(p_business,p_customer,sid,'sale_payment',p_method,p_amount_paid,auth.uid());
  end if;
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
    values(p_business,auth.uid(),'sale_created','sale',sid,jsonb_build_object('reference',ref,'total',total_due));
  return sid;
end
$$;

create or replace function public.record_repayment(
  p_business uuid,
  p_request_key uuid,
  p_customer uuid,
  p_amount numeric,
  p_method public.payment_method,
  p_note text default null
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  pid uuid;
  owing numeric(12,2);
begin
  if not public.is_business_member(p_business) then raise exception 'Not authorized'; end if;
  if p_request_key is null then raise exception 'A request key is required'; end if;
  select id into pid from public.payments
    where business_id=p_business and request_key=p_request_key and kind='debt_repayment';
  if found then return pid; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Repayment must be greater than zero'; end if;

  -- Serializing on the customer row prevents simultaneous repayments from exceeding the balance.
  perform 1 from public.customers where id=p_customer and business_id=p_business for update;
  if not found then raise exception 'Customer not found'; end if;
  select greatest(
    coalesce((select sum(total-amount_paid) from public.sales
      where business_id=p_business and customer_id=p_customer and status='completed'),0)
    - coalesce((select sum(amount) from public.payments
      where business_id=p_business and customer_id=p_customer and kind='debt_repayment'),0),
    0
  ) into owing;
  if p_amount>owing then raise exception 'Repayment exceeds outstanding balance'; end if;

  insert into public.payments(business_id,customer_id,request_key,kind,method,amount,note,created_by)
    values(p_business,p_customer,p_request_key,'debt_repayment',p_method,p_amount,p_note,auth.uid()) returning id into pid;
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
    values(p_business,auth.uid(),'debt_repayment','customer',p_customer,jsonb_build_object('amount',p_amount,'payment_id',pid));
  return pid;
end
$$;

create or replace function public.customer_balances(p_business uuid)
returns table(customer_id uuid,outstanding numeric)
language sql stable security definer set search_path=public
as $$
  select c.id,
    greatest(coalesce(sum(s.total-s.amount_paid),0)-coalesce((
      select sum(p.amount) from public.payments p
      where p.business_id=c.business_id and p.customer_id=c.id and p.kind='debt_repayment'
    ),0),0)
  from public.customers c
  left join public.sales s on s.customer_id=c.id and s.business_id=c.business_id and s.status='completed'
  where c.business_id=p_business and public.is_business_member(p_business)
  group by c.id,c.business_id
$$;

revoke all on function public.create_sale(uuid,uuid,jsonb,public.payment_method,numeric,uuid,numeric) from public;
revoke all on function public.record_repayment(uuid,uuid,uuid,numeric,public.payment_method,text) from public;
grant execute on function public.create_sale(uuid,uuid,jsonb,public.payment_method,numeric,uuid,numeric) to authenticated;
grant execute on function public.record_repayment(uuid,uuid,uuid,numeric,public.payment_method,text) to authenticated;
grant execute on function public.customer_balances(uuid) to authenticated;
