-- Business deletion is deliberately limited to authenticated super admins.
-- The confirmation must exactly match the current business name.
create or replace function public.admin_delete_business(p_business uuid,p_confirmation text)
returns void
language plpgsql security definer set search_path=public,auth
as $$
declare target_name text;
begin
  if not public.is_super_admin() then raise exception 'Super admin access required'; end if;

  select b.name into target_name
  from public.businesses b
  where b.id=p_business
  for update;
  if not found then raise exception 'Business not found'; end if;
  if p_confirmation is distinct from target_name then
    raise exception 'Business name confirmation does not match';
  end if;

  -- Clear restrictive foreign-key dependents before deleting the tenant.
  delete from public.business_invitations where business_id=p_business;
  delete from public.subscription_payments where business_id=p_business;
  delete from public.inventory_movements where business_id=p_business;
  delete from public.payments where business_id=p_business;
  delete from public.sale_items where business_id=p_business;
  delete from public.sales where business_id=p_business;
  delete from public.products where business_id=p_business;
  delete from public.customers where business_id=p_business;
  delete from public.expenses where business_id=p_business;
  delete from public.subscriptions where business_id=p_business;
  delete from public.audit_logs where business_id=p_business;
  delete from public.business_members where business_id=p_business;
  delete from public.businesses where id=p_business;
end
$$;

revoke all on function public.admin_delete_business(uuid,text) from public;
grant execute on function public.admin_delete_business(uuid,text) to authenticated;
