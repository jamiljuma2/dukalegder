-- Avoid a PL/pgSQL variable/column name collision in supplier purchase saves.
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

