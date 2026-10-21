-- Platform admins use scoped admin RPCs; they cannot inspect tenant dashboards or data.

drop policy if exists "super admins read all profiles" on public.profiles;
drop policy if exists "super admins read all businesses" on public.businesses;
drop policy if exists "super admins read all business memberships" on public.business_members;
drop policy if exists "super admins manage all businesses" on public.businesses;
drop policy if exists "super admins manage all memberships" on public.business_members;
drop policy if exists "super admins manage all invitations" on public.business_invitations;
drop policy if exists "super admins manage all products" on public.products;
drop policy if exists "super admins manage all customers" on public.customers;
drop policy if exists "super admins manage all sales" on public.sales;
drop policy if exists "super admins manage all sale items" on public.sale_items;
drop policy if exists "super admins manage all customer payments" on public.payments;
drop policy if exists "super admins manage all inventory movements" on public.inventory_movements;
drop policy if exists "super admins manage all expenses" on public.expenses;
drop policy if exists "super admins manage all subscriptions" on public.subscriptions;
drop policy if exists "super admins manage all subscription payments" on public.subscription_payments;
drop policy if exists "super admins manage all audit logs" on public.audit_logs;
drop policy if exists "super admins update all profile details" on public.profiles;

-- Restore membership-only predicates. Admin RPCs remain available and perform
-- their own explicit super-admin checks without exposing tenant table access.
create or replace function public.is_business_member(bid uuid)
returns boolean language sql stable security definer set search_path=public
as $$
  select exists(
    select 1 from public.business_members m
    left join public.subscriptions s on s.business_id=m.business_id
    where m.business_id=bid and m.user_id=auth.uid()
      and (m.role='owner' or (s.plan='plus' and s.status='active' and s.period_ends_at>now()))
  )
$$;

create or replace function public.is_business_owner(bid uuid)
returns boolean language sql stable security definer set search_path=public
as $$
  select exists(
    select 1 from public.business_members m
    where m.business_id=bid and m.user_id=auth.uid() and m.role='owner'
  )
$$;

create or replace function public.has_business_role(p_business uuid,p_roles public.member_role[])
returns boolean language sql stable security definer set search_path=public
as $$
  select exists(
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
