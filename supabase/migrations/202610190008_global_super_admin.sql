-- Global platform administration is separate from shop membership roles.
alter table public.profiles
  add column if not exists global_role text not null default 'user'
  check (global_role in ('user', 'super_admin'));

-- A user's profile update grant must never let them promote themselves.
revoke update on public.profiles from authenticated, anon;

create or replace function public.is_super_admin()
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id=auth.uid() and p.global_role='super_admin'
  )
$$;

create or replace function public.get_my_global_role()
returns text
language sql stable security definer set search_path=public
as $$
  select coalesce((select p.global_role from public.profiles p where p.id=auth.uid()),'user')
$$;

revoke all on function public.is_super_admin() from public;
revoke all on function public.get_my_global_role() from public;
grant execute on function public.is_super_admin() to authenticated;
grant execute on function public.get_my_global_role() to authenticated;

create or replace function public.reject_super_admin_business_membership()
returns trigger
language plpgsql security definer set search_path=public
as $$
begin
  if exists(select 1 from public.profiles p where p.id=new.user_id and p.global_role='super_admin') then
    raise exception 'Super admins cannot belong to businesses';
  end if;
  return new;
end
$$;

drop trigger if exists prevent_super_admin_business_membership on public.business_members;
create trigger prevent_super_admin_business_membership
  before insert or update of user_id on public.business_members
  for each row execute function public.reject_super_admin_business_membership();
revoke all on function public.reject_super_admin_business_membership() from public;

-- Super admins may inspect every tenant, while existing tenant policies still
-- govern normal users. Mutations of shop data remain on the normal business RPCs.
drop policy if exists "super admins read all profiles" on public.profiles;
create policy "super admins read all profiles" on public.profiles
  for select using (public.is_super_admin());
drop policy if exists "super admins read all businesses" on public.businesses;
create policy "super admins read all businesses" on public.businesses
  for select using (public.is_super_admin());
drop policy if exists "super admins read all business memberships" on public.business_members;
create policy "super admins read all business memberships" on public.business_members
  for select using (public.is_super_admin());
drop policy if exists "super admins read all products" on public.products;
create policy "super admins read all products" on public.products
  for select using (public.is_super_admin());
drop policy if exists "super admins read all customers" on public.customers;
create policy "super admins read all customers" on public.customers
  for select using (public.is_super_admin());
drop policy if exists "super admins read all sales" on public.sales;
create policy "super admins read all sales" on public.sales
  for select using (public.is_super_admin());
drop policy if exists "super admins read all sale items" on public.sale_items;
create policy "super admins read all sale items" on public.sale_items
  for select using (public.is_super_admin());
drop policy if exists "super admins read all payments" on public.payments;
create policy "super admins read all payments" on public.payments
  for select using (public.is_super_admin());
drop policy if exists "super admins read all inventory movements" on public.inventory_movements;
create policy "super admins read all inventory movements" on public.inventory_movements
  for select using (public.is_super_admin());
drop policy if exists "super admins read all expenses" on public.expenses;
create policy "super admins read all expenses" on public.expenses
  for select using (public.is_super_admin());
drop policy if exists "super admins read all subscriptions" on public.subscriptions;
create policy "super admins read all subscriptions" on public.subscriptions
  for select using (public.is_super_admin());
drop policy if exists "super admins read all audit logs" on public.audit_logs;
create policy "super admins read all audit logs" on public.audit_logs
  for select using (public.is_super_admin());

create or replace function public.admin_list_users()
returns table(user_id uuid,email text,full_name text,global_role text,business_count bigint,created_at timestamptz)
language plpgsql stable security definer set search_path=public,auth
as $$
begin
  if not public.is_super_admin() then raise exception 'Super admin access required'; end if;
  return query
    select u.id,u.email::text,coalesce(p.full_name,''),coalesce(p.global_role,'user'),
      count(distinct m.business_id),u.created_at
    from auth.users u
    left join public.profiles p on p.id=u.id
    left join public.business_members m on m.user_id=u.id
    group by u.id,u.email,p.full_name,p.global_role,u.created_at
    order by u.created_at desc;
end
$$;

create or replace function public.admin_list_businesses()
returns table(business_id uuid,name text,category text,created_at timestamptz,member_count bigint,owner_email text,plan text,subscription_status text)
language plpgsql stable security definer set search_path=public,auth
as $$
begin
  if not public.is_super_admin() then raise exception 'Super admin access required'; end if;
  return query
    select b.id,b.name,b.category,b.created_at,
      count(distinct m.user_id),max(u.email::text) filter (where m.role='owner'),
      coalesce(s.plan,'free'),coalesce(s.status,'active')
    from public.businesses b
    left join public.business_members m on m.business_id=b.id
    left join auth.users u on u.id=m.user_id
    left join public.subscriptions s on s.business_id=b.id
    group by b.id,b.name,b.category,b.created_at,s.plan,s.status
    order by b.created_at desc;
end
$$;

create or replace function public.admin_set_global_role(p_user uuid,p_role text)
returns void
language plpgsql security definer set search_path=public
as $$
declare admin_count bigint;
begin
  if not public.is_super_admin() then raise exception 'Super admin access required'; end if;
  if p_role not in ('user','super_admin') then raise exception 'Invalid global role'; end if;
  if p_user=auth.uid() and p_role='user' then
    select count(*) into admin_count from public.profiles where global_role='super_admin';
    if admin_count<=1 then raise exception 'Cannot remove the final super admin'; end if;
  end if;
  update public.profiles set global_role=p_role where id=p_user;
  if not found then raise exception 'User profile not found'; end if;
  if p_role='super_admin' then
    delete from public.business_members where user_id=p_user;
  end if;
end
$$;

revoke all on function public.admin_list_users() from public;
revoke all on function public.admin_list_businesses() from public;
revoke all on function public.admin_set_global_role(uuid,text) from public;
grant execute on function public.admin_list_users() to authenticated;
grant execute on function public.admin_list_businesses() to authenticated;
grant execute on function public.admin_set_global_role(uuid,text) to authenticated;

-- Promote the requested account if it already exists when this migration runs.
-- If it is created later, run the one-time UPDATE documented in README.md.
update public.profiles p
set global_role='super_admin',full_name='Jamil Juma'
from auth.users u
where u.id=p.id and lower(u.email)='jumajamil314@gmail.com'
  and u.email_confirmed_at is not null;

-- A platform super admin has no tenant membership; business records are kept.
delete from public.business_members m
using public.profiles p
where p.id=m.user_id and p.global_role='super_admin';
