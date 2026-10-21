-- Remove accounts that lose their final business membership during admin deletion.
-- Accounts shared with another business and super-admin accounts are retained.
create or replace function public.admin_delete_business(p_business uuid,p_confirmation text)
returns void
language plpgsql security definer set search_path=public,auth
as $$
declare
  target_name text;
  member_user_ids uuid[];
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

  select coalesce(array_agg(m.user_id), '{}'::uuid[])
    into member_user_ids
    from public.business_members m
    where m.business_id=p_business;

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

  -- Deleting auth.users cascades to profiles and ends any active sessions.
  -- Preserve accounts that still belong to a business or have platform access.
  delete from auth.users u
  where u.id = any(member_user_ids)
    and not exists (
      select 1 from public.business_members m where m.user_id=u.id
    )
    and not exists (
      select 1 from public.profiles p where p.id=u.id and p.global_role='super_admin'
    )
    -- Retain an identity if historical records in another tenant still reference it.
    and not exists (select 1 from public.sales x where x.created_by=u.id)
    and not exists (select 1 from public.payments x where x.created_by=u.id)
    and not exists (select 1 from public.inventory_movements x where x.created_by=u.id)
    and not exists (select 1 from public.expenses x where x.created_by=u.id)
    and not exists (select 1 from public.audit_logs x where x.actor_id=u.id)
    and not exists (select 1 from public.subscription_payments x where x.requested_by=u.id)
    and not exists (select 1 from public.cash_reconciliations x where x.recorded_by=u.id)
    and not exists (select 1 from public.supplier_purchases x where x.created_by=u.id)
    and not exists (select 1 from public.supplier_payments x where x.recorded_by=u.id);
end
$$;

revoke all on function public.admin_delete_business(uuid,text) from public;
grant execute on function public.admin_delete_business(uuid,text) to authenticated;
