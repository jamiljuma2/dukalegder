-- Super admins can operate across every shop through the existing app RPCs
-- and tenant tables, without joining or impersonating a business account.

create or replace function public.is_business_member(bid uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select public.is_super_admin() or exists(
    select 1 from public.business_members m
    left join public.subscriptions s on s.business_id=m.business_id
    where m.business_id=bid and m.user_id=auth.uid()
      and (m.role='owner' or (s.plan='plus' and s.status='active' and s.period_ends_at>now()))
  )
$$;

create or replace function public.is_business_owner(bid uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select public.is_super_admin() or exists(
    select 1 from public.business_members m
    where m.business_id=bid and m.user_id=auth.uid() and m.role='owner'
  )
$$;

create or replace function public.has_business_role(p_business uuid,p_roles public.member_role[])
returns boolean
language sql stable security definer set search_path=public
as $$
  select public.is_super_admin() or exists(
    select 1 from public.business_members m
    left join public.subscriptions s on s.business_id=m.business_id
    where m.business_id=p_business and m.user_id=auth.uid() and m.role=any(p_roles)
      and (m.role='owner' or (s.plan='plus' and s.status='active' and s.period_ends_at>now()))
  )
$$;

revoke all on function public.is_business_member(uuid) from public;
revoke all on function public.is_business_owner(uuid) from public;
revoke all on function public.has_business_role(uuid,public.member_role[]) from public;
grant execute on function public.is_business_member(uuid) to authenticated;
grant execute on function public.is_business_owner(uuid) to authenticated;
grant execute on function public.has_business_role(uuid,public.member_role[]) to authenticated;

create or replace function public.create_product(
  p_business uuid,p_name text,p_sku text,p_category text,p_buying_price numeric,
  p_selling_price numeric,p_quantity integer,p_threshold integer,p_description text default null
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare pid uuid; plan_name text; max_products integer;
begin
  if not public.is_business_member(p_business) then raise exception 'Not authorized'; end if;
  perform 1 from public.businesses where id=p_business for update;
  select s.plan into plan_name from public.subscriptions s where s.business_id=p_business;
  max_products:=public.active_product_limit(coalesce(plan_name,'free'));
  if not public.is_super_admin() and max_products is not null
     and (select count(*) from public.products where business_id=p_business and archived_at is null)>=max_products then
    raise exception 'Your Free plan supports up to % active products. Archive an item or upgrade your plan.',max_products;
  end if;
  insert into public.products(business_id,name,sku,category,buying_price,selling_price,quantity,low_stock_threshold,description)
    values(p_business,trim(p_name),nullif(trim(p_sku),''),coalesce(nullif(trim(p_category),''),'General'),p_buying_price,p_selling_price,p_quantity,p_threshold,p_description)
    returning id into pid;
  return pid;
end
$$;

create or replace function public.require_plus_plan_for_invite()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_super_admin() and not exists(
    select 1 from public.subscriptions s where s.business_id=new.business_id
      and s.plan='plus' and s.status='active' and s.period_ends_at>now()
  ) then
    raise exception 'Staff accounts require an active Plus plan';
  end if;
  return new;
end
$$;
revoke all on function public.require_plus_plan_for_invite() from public;

-- These policies are permissive only for authenticated super admins. The
-- existing member and manager policies continue to determine ordinary access.
create policy "super admins manage all businesses" on public.businesses
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "super admins manage all memberships" on public.business_members
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "super admins manage all invitations" on public.business_invitations
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "super admins manage all products" on public.products
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "super admins manage all customers" on public.customers
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "super admins manage all sales" on public.sales
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "super admins manage all sale items" on public.sale_items
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "super admins manage all customer payments" on public.payments
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "super admins manage all inventory movements" on public.inventory_movements
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "super admins manage all expenses" on public.expenses
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "super admins manage all subscriptions" on public.subscriptions
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "super admins manage all subscription payments" on public.subscription_payments
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "super admins manage all audit logs" on public.audit_logs
  for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());

-- Keep global_role changes behind admin_set_global_role. Super admins can
-- update profile details, but no authenticated client receives global_role
-- column privileges through this migration.
create policy "super admins update all profile details" on public.profiles
  for update to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
grant update(full_name,phone) on public.profiles to authenticated;

-- Keep existing column-scoped table grants intact. Super-admin writes that
-- require elevated columns continue through the SECURITY DEFINER app RPCs.

