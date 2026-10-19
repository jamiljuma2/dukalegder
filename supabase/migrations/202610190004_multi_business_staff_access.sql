-- Membership-backed multi-business access, owner-managed invitations and RBAC.
create or replace function public.has_business_role(p_business uuid,p_roles public.member_role[])
returns boolean language sql stable security definer set search_path=public
as $$
  select exists(select 1 from public.business_members m
    where m.business_id=p_business and m.user_id=auth.uid() and m.role=any(p_roles))
$$;

create table if not exists public.business_invitations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  email text not null check(email=lower(trim(email))),
  role public.member_role not null check(role in ('manager','staff')),
  token_hash text not null unique,
  invited_by uuid not null references auth.users(id),
  expires_at timestamptz not null,
  accepted_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists business_invitations_business_idx
  on public.business_invitations(business_id,created_at desc);
create unique index if not exists business_invitations_pending_email_uidx
  on public.business_invitations(business_id,email)
  where accepted_at is null and revoked_at is null;
alter table public.business_invitations enable row level security;
revoke all on public.business_invitations from anon,authenticated;

-- The membership row is the tenant boundary; each user may belong to many businesses.
drop policy if exists "member list own memberships" on public.business_members;
create policy "members read own memberships" on public.business_members
  for select using (user_id=auth.uid());
drop policy if exists "owner manage memberships" on public.business_members;

-- Read access is shared across active members. Mutations are restricted by role.
drop policy if exists "owner business update" on public.businesses;
create policy "owner business update" on public.businesses
  for update using (public.has_business_role(id,array['owner']::public.member_role[]))
  with check (public.has_business_role(id,array['owner']::public.member_role[]));
revoke update on public.businesses from authenticated;
grant update(name,category) on public.businesses to authenticated;

drop policy if exists "member update products" on public.products;
create policy "managers update products" on public.products
  for update using (public.has_business_role(business_id,array['owner','manager']::public.member_role[]))
  with check (public.has_business_role(business_id,array['owner','manager']::public.member_role[]));
revoke update on public.products from authenticated;
grant update(name,sku,category,buying_price,selling_price,low_stock_threshold,description,archived_at)
  on public.products to authenticated;

drop policy if exists "member add customers" on public.customers;
create policy "managers add customers" on public.customers
  for insert with check (public.has_business_role(business_id,array['owner','manager']::public.member_role[]));
drop policy if exists "member update customers" on public.customers;
create policy "managers update customers" on public.customers
  for update using (public.has_business_role(business_id,array['owner','manager']::public.member_role[]))
  with check (public.has_business_role(business_id,array['owner','manager']::public.member_role[]));
revoke update on public.customers from authenticated;
grant update(full_name,phone,notes) on public.customers to authenticated;

drop policy if exists "member read sale items" on public.sale_items;
create policy "managers read sale items" on public.sale_items
  for select using (public.has_business_role(business_id,array['owner','manager']::public.member_role[]));
drop policy if exists "member read payments" on public.payments;
create policy "managers read payments" on public.payments
  for select using (public.has_business_role(business_id,array['owner','manager']::public.member_role[]));
drop policy if exists "member read movements" on public.inventory_movements;
create policy "managers read movements" on public.inventory_movements
  for select using (public.has_business_role(business_id,array['owner','manager']::public.member_role[]));

drop policy if exists "member read expenses" on public.expenses;
create policy "managers read expenses" on public.expenses
  for select using (public.has_business_role(business_id,array['owner','manager']::public.member_role[]));
drop policy if exists "member add expenses" on public.expenses;
create policy "managers add expenses" on public.expenses
  for insert with check (
    public.has_business_role(business_id,array['owner','manager']::public.member_role[])
    and created_by=auth.uid()
  );
drop policy if exists "member update expenses" on public.expenses;
create policy "managers update expenses" on public.expenses
  for update using (public.has_business_role(business_id,array['owner','manager']::public.member_role[]))
  with check (public.has_business_role(business_id,array['owner','manager']::public.member_role[]));
revoke update on public.expenses from authenticated;
grant update(description,category,amount,spent_on,method,notes) on public.expenses to authenticated;

drop policy if exists "member read audit" on public.audit_logs;
create policy "managers read audit" on public.audit_logs
  for select using (public.has_business_role(business_id,array['owner','manager']::public.member_role[]));

create or replace function public.create_business_invite(p_business uuid,p_email text,p_role public.member_role)
returns text language plpgsql security definer set search_path=public,extensions
as $$
declare invite_email text:=lower(trim(coalesce(p_email,''))); token text; invited_user uuid;
begin
  if not public.has_business_role(p_business,array['owner']::public.member_role[]) then raise exception 'Only an owner can invite team members'; end if;
  if p_role not in ('manager','staff') then raise exception 'Choose Manager or Staff'; end if;
  if invite_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'Enter a valid email address'; end if;
  select id into invited_user from auth.users where lower(email)=invite_email limit 1;
  if invited_user is not null and exists(select 1 from public.business_members where business_id=p_business and user_id=invited_user) then
    raise exception 'This person is already a member of the business';
  end if;
  update public.business_invitations set revoked_at=now()
    where business_id=p_business and email=invite_email and accepted_at is null and revoked_at is null;
  token:=encode(gen_random_bytes(32),'hex');
  insert into public.business_invitations(business_id,email,role,token_hash,invited_by,expires_at)
    values(p_business,invite_email,p_role,encode(digest(token,'sha256'),'hex'),auth.uid(),now()+interval '7 days');
  insert into public.audit_logs(business_id,actor_id,action,entity_type,details)
    values(p_business,auth.uid(),'member_invited','business_member',jsonb_build_object('email',invite_email,'role',p_role));
  return token;
end
$$;

create or replace function public.accept_business_invite(p_token text)
returns uuid language plpgsql security definer set search_path=public,extensions
as $$
declare invite public.business_invitations%rowtype; invitee_email text:=lower(trim(coalesce(auth.jwt()->>'email','')));
begin
  if auth.uid() is null then raise exception 'Sign in before accepting an invitation'; end if;
  if p_token is null or length(p_token)<32 then raise exception 'Invitation link is invalid'; end if;
  select * into invite from public.business_invitations
    where token_hash=encode(digest(p_token,'sha256'),'hex') for update;
  if not found or invite.revoked_at is not null or invite.accepted_at is not null or invite.expires_at<=now() then
    raise exception 'Invitation is invalid, expired, or already used';
  end if;
  if invite.email<>invitee_email then raise exception 'Sign in with the email address this invitation was sent to'; end if;
  if exists(select 1 from public.business_members where business_id=invite.business_id and user_id=auth.uid()) then
    raise exception 'You already belong to this business';
  end if;
  insert into public.business_members(business_id,user_id,role)
    values(invite.business_id,auth.uid(),invite.role);
  update public.business_invitations set accepted_at=now() where id=invite.id;
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
    values(invite.business_id,auth.uid(),'member_joined','business_member',auth.uid(),jsonb_build_object('role',invite.role));
  return invite.business_id;
end
$$;

create or replace function public.list_business_members(p_business uuid)
returns table(user_id uuid,email text,full_name text,role public.member_role,joined_at timestamptz)
language plpgsql security definer set search_path=public
as $$ begin
  if not public.has_business_role(p_business,array['owner']::public.member_role[]) then raise exception 'Only an owner can manage team members'; end if;
  return query
    select m.user_id,u.email::text,coalesce(p.full_name,''),m.role,m.created_at
    from public.business_members m
    join auth.users u on u.id=m.user_id
    left join public.profiles p on p.id=m.user_id
    where m.business_id=p_business
    order by case m.role when 'owner' then 0 when 'manager' then 1 else 2 end,m.created_at;
end $$;

create or replace function public.change_business_member_role(p_business uuid,p_user uuid,p_role public.member_role)
returns void language plpgsql security definer set search_path=public
as $$ declare previous_role public.member_role; begin
  if not public.has_business_role(p_business,array['owner']::public.member_role[]) then raise exception 'Only an owner can manage team members'; end if;
  if p_role not in ('manager','staff') then raise exception 'A member role must be Manager or Staff'; end if;
  select role into previous_role from public.business_members where business_id=p_business and user_id=p_user for update;
  if not found or previous_role='owner' then raise exception 'Owner roles cannot be changed here'; end if;
  update public.business_members set role=p_role where business_id=p_business and user_id=p_user;
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
    values(p_business,auth.uid(),'member_role_changed','business_member',p_user,jsonb_build_object('from',previous_role,'to',p_role));
end $$;

create or replace function public.remove_business_member(p_business uuid,p_user uuid)
returns void language plpgsql security definer set search_path=public
as $$ declare target_role public.member_role; begin
  if not public.has_business_role(p_business,array['owner']::public.member_role[]) then raise exception 'Only an owner can remove team members'; end if;
  if p_user=auth.uid() then raise exception 'Transfer ownership before removing yourself'; end if;
  select role into target_role from public.business_members where business_id=p_business and user_id=p_user for update;
  if not found or target_role='owner' then raise exception 'The owner cannot be removed'; end if;
  delete from public.business_members where business_id=p_business and user_id=p_user;
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
    values(p_business,auth.uid(),'member_removed','business_member',p_user,jsonb_build_object('role',target_role));
end $$;

-- The following operations are restricted independently of client-side controls.
create or replace function public.create_product(p_business uuid,p_name text,p_sku text,p_category text,p_buying_price numeric,
  p_selling_price numeric,p_quantity integer,p_threshold integer,p_description text default null) returns uuid
language plpgsql security definer set search_path=public
as $$ declare pid uuid; plan_name text; max_products integer; begin
  if not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized to manage products'; end if;
  perform 1 from public.businesses where id=p_business for update;
  select s.plan into plan_name from public.subscriptions s where s.business_id=p_business;
  max_products:=public.active_product_limit(coalesce(plan_name,'free'));
  if max_products is not null and (select count(*) from public.products where business_id=p_business and archived_at is null)>=max_products then
    raise exception 'Your Free plan supports up to % active products. Archive an item or upgrade your plan.',max_products;
  end if;
  insert into public.products(business_id,name,sku,category,buying_price,selling_price,quantity,low_stock_threshold,description)
    values(p_business,trim(p_name),nullif(trim(p_sku),''),coalesce(nullif(trim(p_category),''),'General'),p_buying_price,p_selling_price,p_quantity,p_threshold,p_description)
    returning id into pid;
  return pid;
end $$;

create or replace function public.adjust_stock(p_business uuid,p_product uuid,p_delta integer,p_reason text,p_kind text default 'adjustment') returns void
language plpgsql security definer set search_path=public
as $$ declare current_qty integer; begin
  if not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized to adjust stock'; end if;
  if p_delta=0 or length(trim(coalesce(p_reason,'')))=0 then raise exception 'A stock change and reason are required'; end if;
  select quantity into current_qty from public.products where id=p_product and business_id=p_business and archived_at is null for update;
  if not found then raise exception 'Product not found'; end if;
  if current_qty+p_delta<0 then raise exception 'Stock cannot be negative'; end if;
  update public.products set quantity=quantity+p_delta,updated_at=now() where id=p_product;
  insert into public.inventory_movements(business_id,product_id,kind,quantity_delta,reason,created_by)
    values(p_business,p_product,p_kind,p_delta,trim(p_reason),auth.uid());
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
    values(p_business,auth.uid(),'stock_adjusted','product',p_product,jsonb_build_object('delta',p_delta,'reason',p_reason));
end $$;

create or replace function public.record_repayment(p_business uuid,p_request_key uuid,p_customer uuid,p_amount numeric,p_method public.payment_method,p_note text default null) returns uuid
language plpgsql security definer set search_path=public
as $$ declare pid uuid; owing numeric(12,2); begin
  if not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized to record debt repayments'; end if;
  if p_request_key is null then raise exception 'A request key is required'; end if;
  select id into pid from public.payments where business_id=p_business and request_key=p_request_key and kind='debt_repayment';
  if found then return pid; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Repayment must be greater than zero'; end if;
  perform 1 from public.customers where id=p_customer and business_id=p_business for update;
  if not found then raise exception 'Customer not found'; end if;
  select greatest(coalesce((select sum(total-amount_paid) from public.sales where business_id=p_business and customer_id=p_customer and status='completed'),0)
    - coalesce((select sum(amount) from public.payments where business_id=p_business and customer_id=p_customer and kind='debt_repayment'),0),0) into owing;
  if p_amount>owing then raise exception 'Repayment exceeds outstanding balance'; end if;
  insert into public.payments(business_id,customer_id,request_key,kind,method,amount,note,created_by)
    values(p_business,p_customer,p_request_key,'debt_repayment',p_method,p_amount,p_note,auth.uid()) returning id into pid;
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
    values(p_business,auth.uid(),'debt_repayment','customer',p_customer,jsonb_build_object('amount',p_amount,'payment_id',pid));
  return pid;
end $$;

create or replace function public.customer_balances(p_business uuid)
returns table(customer_id uuid,outstanding numeric)
language plpgsql stable security definer set search_path=public
as $$ begin
  if not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized to view customer balances'; end if;
  return query select c.id::uuid,
    greatest(coalesce(sum(s.total-s.amount_paid),0)-coalesce((select sum(p.amount) from public.payments p where p.business_id=c.business_id and p.customer_id=c.id and p.kind='debt_repayment'),0),0)::numeric
    from public.customers c left join public.sales s on s.customer_id=c.id and s.business_id=c.business_id and s.status='completed'
    where c.business_id=p_business group by c.id,c.business_id;
end $$;

revoke all on function public.create_business_invite(uuid,text,public.member_role) from public;
revoke all on function public.accept_business_invite(text) from public;
revoke all on function public.list_business_members(uuid) from public;
revoke all on function public.change_business_member_role(uuid,uuid,public.member_role) from public;
revoke all on function public.remove_business_member(uuid,uuid) from public;
grant execute on function public.create_business_invite(uuid,text,public.member_role) to authenticated;
grant execute on function public.accept_business_invite(text) to authenticated;
grant execute on function public.list_business_members(uuid) to authenticated;
grant execute on function public.change_business_member_role(uuid,uuid,public.member_role) to authenticated;
grant execute on function public.remove_business_member(uuid,uuid) to authenticated;
grant execute on function public.create_product(uuid,text,text,text,numeric,numeric,integer,integer,text) to authenticated;
grant execute on function public.adjust_stock(uuid,uuid,integer,text,text) to authenticated;
grant execute on function public.record_repayment(uuid,uuid,uuid,numeric,public.payment_method,text) to authenticated;
grant execute on function public.customer_balances(uuid) to authenticated;
revoke all on function public.has_business_role(uuid,public.member_role[]) from public;
grant execute on function public.has_business_role(uuid,public.member_role[]) to authenticated;
