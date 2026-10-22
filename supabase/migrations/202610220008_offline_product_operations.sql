create table if not exists public.offline_operation_receipts(
  business_id uuid not null references public.businesses(id) on delete cascade,
  request_key uuid not null,
  operation_type text not null,
  entity_id uuid not null,
  created_at timestamptz not null default now(),
  primary key(business_id,request_key)
);
alter table public.offline_operation_receipts enable row level security;
revoke all on public.offline_operation_receipts from anon,authenticated,public;
grant select on public.offline_operation_receipts to authenticated;
drop policy if exists "members inspect operation receipts" on public.offline_operation_receipts;
create policy "members inspect operation receipts" on public.offline_operation_receipts for select to authenticated
using (public.is_business_member(business_id));

create or replace function public.offline_save_product(
  p_business uuid,p_product uuid,p_request_key uuid,p_expected_updated_at timestamptz,p_values jsonb
) returns uuid language plpgsql security definer set search_path=public as $$
declare existing_id uuid; product_row public.products%rowtype; plan_name text; max_products integer;
begin
  if not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized to manage products'; end if;
  if p_product is null or p_request_key is null then raise exception 'Product and request identifiers are required'; end if;
  if jsonb_typeof(p_values) is distinct from 'object' then raise exception 'Product details are invalid'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business::text||p_request_key::text,0));
  select entity_id into existing_id from public.offline_operation_receipts where business_id=p_business and request_key=p_request_key;
  if found then return existing_id; end if;
  if p_expected_updated_at is null then
    perform 1 from public.businesses where id=p_business for update;
    select s.plan into plan_name from public.subscriptions s where s.business_id=p_business;
    max_products:=public.active_product_limit(coalesce(plan_name,'free'));
    if max_products is not null and (select count(*) from public.products where business_id=p_business and archived_at is null)>=max_products then
      raise exception 'Your Free plan supports up to % active products. Archive an item or upgrade your plan.',max_products;
    end if;
    insert into public.products(id,business_id,name,sku,category,buying_price,selling_price,quantity,low_stock_threshold,description)
    values(p_product,p_business,trim(p_values->>'name'),nullif(trim(p_values->>'sku'),''),coalesce(nullif(trim(p_values->>'category'),''),'General'),
      coalesce((p_values->>'buying_price')::numeric,0),(p_values->>'selling_price')::numeric,coalesce((p_values->>'quantity')::integer,0),
      coalesce((p_values->>'low_stock_threshold')::integer,5),nullif(p_values->>'description',''));
    existing_id:=p_product;
  else
    select * into product_row from public.products where id=p_product and business_id=p_business and archived_at is null for update;
    if not found then raise exception 'Product was removed or is no longer active'; end if;
    if product_row.updated_at is distinct from p_expected_updated_at then raise exception 'Product changed on another device. Reload it and review your changes before saving.'; end if;
    update public.products set name=trim(p_values->>'name'),sku=nullif(trim(p_values->>'sku'),''),category=coalesce(nullif(trim(p_values->>'category'),''),'General'),
      buying_price=(p_values->>'buying_price')::numeric,selling_price=(p_values->>'selling_price')::numeric,
      low_stock_threshold=(p_values->>'low_stock_threshold')::integer,description=nullif(p_values->>'description','')
      where id=p_product and business_id=p_business;
    existing_id:=p_product;
  end if;
  insert into public.offline_operation_receipts(business_id,request_key,operation_type,entity_id)
  values(p_business,p_request_key,'product_save',existing_id);
  return existing_id;
end $$;

create or replace function public.offline_link_product_image(p_business uuid,p_product uuid,p_request_key uuid,p_path text,p_url text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized to update product images'; end if;
  if not exists(select 1 from public.offline_operation_receipts where business_id=p_business and request_key=p_request_key and entity_id=p_product and operation_type='product_save') then
    raise exception 'Product save must complete before linking its image';
  end if;
  if p_path not like p_business::text||'/'||p_product::text||'/%' then raise exception 'Image path does not match this product'; end if;
  update public.products set image_path=p_path,image_url=p_url where id=p_product and business_id=p_business and archived_at is null;
  if not found then raise exception 'Product not found'; end if;
end $$;
revoke all on function public.offline_save_product(uuid,uuid,uuid,timestamptz,jsonb) from public, anon;
revoke all on function public.offline_link_product_image(uuid,uuid,uuid,text,text) from public, anon;
grant execute on function public.offline_save_product(uuid,uuid,uuid,timestamptz,jsonb) to authenticated;
grant execute on function public.offline_link_product_image(uuid,uuid,uuid,text,text) to authenticated;
