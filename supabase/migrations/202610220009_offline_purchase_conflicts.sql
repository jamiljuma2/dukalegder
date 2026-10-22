create or replace function public.offline_edit_supplier_purchase(
  p_business uuid,p_purchase uuid,p_request_key uuid,p_expected_updated_at timestamptz,
  p_supplier uuid,p_invoice_reference text,p_date date,p_notes text,p_items jsonb
) returns uuid language plpgsql security definer set search_path=public as $$
declare purchase_row public.supplier_purchases%rowtype; existing_id uuid;
begin
  if not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized to edit supplier purchases'; end if;
  if p_request_key is null or p_expected_updated_at is null then raise exception 'Request and version identifiers are required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business::text||p_request_key::text,0));
  select entity_id into existing_id from public.offline_operation_receipts where business_id=p_business and request_key=p_request_key;
  if found then return existing_id; end if;
  select * into purchase_row from public.supplier_purchases where id=p_purchase and business_id=p_business for update;
  if not found or purchase_row.status<>'draft' then raise exception 'Only an existing draft purchase can be edited'; end if;
  if purchase_row.updated_at is distinct from p_expected_updated_at then raise exception 'Purchase draft changed on another device. Reload it and review your changes before saving.'; end if;
  perform public.save_supplier_purchase(p_business,p_purchase,p_request_key,p_supplier,p_invoice_reference,p_date,p_notes,p_items);
  insert into public.offline_operation_receipts(business_id,request_key,operation_type,entity_id)
  values(p_business,p_request_key,'purchase_edit',p_purchase);
  return p_purchase;
end $$;
revoke all on function public.offline_edit_supplier_purchase(uuid,uuid,uuid,timestamptz,uuid,text,date,text,jsonb) from public, anon;
grant execute on function public.offline_edit_supplier_purchase(uuid,uuid,uuid,timestamptz,uuid,text,date,text,jsonb) to authenticated;
