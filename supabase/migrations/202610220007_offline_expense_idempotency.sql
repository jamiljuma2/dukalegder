alter table public.expenses add column if not exists request_key uuid;
create unique index if not exists expenses_business_request_key_uidx
  on public.expenses(business_id, request_key) where request_key is not null;

create or replace function public.record_expense(
  p_business uuid, p_request_key uuid, p_description text, p_category text,
  p_amount numeric, p_spent_on date, p_method public.payment_method, p_notes text default null
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare expense_id uuid;
begin
  if not public.is_business_member(p_business) then raise exception 'Not authorized'; end if;
  if p_request_key is null then raise exception 'A request key is required'; end if;
  select id into expense_id from public.expenses where business_id=p_business and request_key=p_request_key;
  if found then return expense_id; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Expense amount must be greater than zero'; end if;
  insert into public.expenses(business_id,request_key,description,category,amount,spent_on,method,notes,created_by)
  values(p_business,p_request_key,trim(p_description),coalesce(nullif(trim(p_category),''),'Other'),p_amount,
    coalesce(p_spent_on,(now() at time zone 'Africa/Nairobi')::date),p_method,nullif(trim(p_notes),''),auth.uid())
  returning id into expense_id;
  return expense_id;
end
$$;
revoke all on function public.record_expense(uuid,uuid,text,text,numeric,date,public.payment_method,text) from public, anon;
grant execute on function public.record_expense(uuid,uuid,text,text,numeric,date,public.payment_method,text) to authenticated;

alter table public.customers add column if not exists request_key uuid;
create unique index if not exists customers_business_request_key_uidx
  on public.customers(business_id, request_key) where request_key is not null;
drop function if exists public.record_customer(uuid,uuid,text,text,text);
create or replace function public.record_customer(p_business uuid,p_request_key uuid,p_customer_id uuid,p_full_name text,p_phone text default null,p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare customer_id uuid;
begin
  if not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized to add customers'; end if;
  if p_request_key is null then raise exception 'A request key is required'; end if;
  select id into customer_id from public.customers where business_id=p_business and request_key=p_request_key;
  if found then return customer_id; end if;
  if p_customer_id is null then raise exception 'A customer identifier is required'; end if;
  insert into public.customers(id,business_id,request_key,full_name,phone,notes)
  values(p_customer_id,p_business,p_request_key,trim(p_full_name),nullif(trim(p_phone),''),nullif(trim(p_notes),'')) returning id into customer_id;
  return customer_id;
end $$;
revoke all on function public.record_customer(uuid,uuid,uuid,text,text,text) from public, anon;
grant execute on function public.record_customer(uuid,uuid,uuid,text,text,text) to authenticated;

alter table public.inventory_movements add column if not exists request_key uuid;
create unique index if not exists inventory_movements_business_request_key_uidx
  on public.inventory_movements(business_id,request_key) where request_key is not null;
create or replace function public.adjust_stock_idempotent(p_business uuid,p_product uuid,p_request_key uuid,p_delta integer,p_reason text,p_kind text default 'adjustment')
returns void language plpgsql security definer set search_path=public as $$
declare current_qty integer;
begin
  if not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized to adjust stock'; end if;
  if p_request_key is null then raise exception 'A request key is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business::text||p_request_key::text,0));
  if exists(select 1 from public.inventory_movements where business_id=p_business and request_key=p_request_key) then return; end if;
  if p_delta=0 or length(trim(coalesce(p_reason,'')))=0 then raise exception 'A stock change and reason are required'; end if;
  select quantity into current_qty from public.products where id=p_product and business_id=p_business and archived_at is null for update;
  if not found then raise exception 'Product not found'; end if;
  if current_qty+p_delta<0 then raise exception 'Stock cannot be negative'; end if;
  update public.products set quantity=quantity+p_delta,updated_at=now() where id=p_product;
  insert into public.inventory_movements(business_id,product_id,kind,quantity_delta,reason,request_key,created_by)
  values(p_business,p_product,p_kind,p_delta,trim(p_reason),p_request_key,auth.uid());
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business,auth.uid(),'stock_adjusted','product',p_product,jsonb_build_object('delta',p_delta,'reason',p_reason));
end $$;
revoke all on function public.adjust_stock_idempotent(uuid,uuid,uuid,integer,text,text) from public, anon;
grant execute on function public.adjust_stock_idempotent(uuid,uuid,uuid,integer,text,text) to authenticated;
