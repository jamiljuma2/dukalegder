-- PayHero one-time monthly plan checkout, confirmed only by the server callback.
create table public.subscription_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  requested_by uuid not null references auth.users(id),
  plan text not null check(plan in ('starter','plus')),
  amount integer not null check(amount in (300,600)),
  phone_number text not null,
  external_reference text not null unique,
  payhero_reference text,
  checkout_request_id text,
  mpesa_receipt text,
  status text not null default 'pending' check(status in ('pending','paid','failed','expired')),
  failure_reason text,
  callback_payload jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  paid_at timestamptz,
  check((status='paid')=(paid_at is not null))
);
create index subscription_payments_business_created_idx
  on public.subscription_payments(business_id,created_at desc);
create unique index subscription_payments_receipt_uidx
  on public.subscription_payments(mpesa_receipt) where mpesa_receipt is not null;
create trigger subscription_payments_touch_updated_at before update on public.subscription_payments
  for each row execute procedure public.touch_updated_at();
alter table public.subscription_payments enable row level security;
revoke all on public.subscription_payments from anon,authenticated;
grant select on public.subscription_payments to authenticated;
grant all on public.subscription_payments to service_role;
create policy "owners read subscription payments" on public.subscription_payments
  for select using (public.is_business_owner(business_id));

create or replace function public.require_plus_plan_for_invite()
returns trigger language plpgsql security definer set search_path=public
as $$ begin
  if not exists(select 1 from public.subscriptions s where s.business_id=new.business_id
    and s.plan='plus' and s.status='active' and s.period_ends_at>now()) then
    raise exception 'Staff accounts require an active Plus plan';
  end if;
  return new;
end $$;
create trigger business_invites_require_plus before insert on public.business_invitations
  for each row execute procedure public.require_plus_plan_for_invite();
revoke all on function public.require_plus_plan_for_invite() from public;

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
grant execute on function public.is_business_member(uuid) to authenticated;
revoke all on function public.has_business_role(uuid,public.member_role[]) from public;
grant execute on function public.has_business_role(uuid,public.member_role[]) to authenticated;

-- Staff can still discover their workspace and subscription state after a Plus term expires,
-- while the business-data policies continue to deny access through is_business_member().
drop policy if exists "member business read" on public.businesses;
create policy "members read business identity" on public.businesses
  for select using (exists(select 1 from public.business_members m where m.business_id=id and m.user_id=auth.uid()));

create or replace function public.create_plan_payment(p_business uuid,p_plan text,p_phone text)
returns table(payment_id uuid,external_reference text,amount integer,phone text)
language plpgsql security definer set search_path=public
as $$
declare v_amount integer; v_phone text; v_id uuid:=gen_random_uuid(); v_reference text;
begin
  if auth.uid() is null or not public.is_business_owner(p_business) then
    raise exception 'Only a business owner can purchase a plan';
  end if;
  if p_plan not in ('starter','plus') then raise exception 'Choose Starter or Plus'; end if;
  v_amount:=case p_plan when 'starter' then 300 else 600 end;
  v_phone:=regexp_replace(coalesce(p_phone,''),'[^0-9]','','g');
  if v_phone ~ '^254[17][0-9]{8}$' then v_phone:='0'||right(v_phone,9);
  elsif v_phone ~ '^[17][0-9]{8}$' then v_phone:='0'||v_phone;
  end if;
  if v_phone !~ '^0[17][0-9]{8}$' then raise exception 'Enter a valid Kenyan M-Pesa number'; end if;
  update public.subscription_payments set status='expired',failure_reason='Payment request timed out; start a new checkout'
    where business_id=p_business and status='pending' and created_at<=now()-interval '15 minutes';
  if exists(select 1 from public.subscription_payments sp where sp.business_id=p_business and sp.status='pending') then
    raise exception 'A plan payment is already pending. Wait for its result before trying again.';
  end if;
  v_reference:='DL-'||upper(replace(gen_random_uuid()::text,'-',''));
  insert into public.subscription_payments(id,business_id,requested_by,plan,amount,phone_number,external_reference)
    values(v_id,p_business,auth.uid(),p_plan,v_amount,v_phone,v_reference);
  return query select v_id::uuid,v_reference::text,v_amount::integer,v_phone::text;
end $$;

create or replace function public.finalize_plan_payment(
  p_external_reference text,p_success boolean,p_amount integer,p_payhero_reference text,
  p_checkout_request_id text,p_receipt text,p_failure_reason text,p_callback_payload jsonb
) returns text language plpgsql security definer set search_path=public
as $$
declare payment_row public.subscription_payments%rowtype; next_period timestamptz;
begin
  select * into payment_row from public.subscription_payments
    where external_reference=p_external_reference for update;
  if not found then raise exception 'Subscription payment reference not found'; end if;
  if payment_row.status='paid' then return 'paid'; end if;
  if payment_row.status<>'pending' then return payment_row.status; end if;
  update public.subscription_payments set payhero_reference=coalesce(p_payhero_reference,payhero_reference),
    checkout_request_id=coalesce(p_checkout_request_id,checkout_request_id),callback_payload=p_callback_payload
    where id=payment_row.id;
  if p_success is distinct from true then
    update public.subscription_payments set status='failed',failure_reason=left(coalesce(p_failure_reason,'Payment was not completed'),500)
      where id=payment_row.id;
    return 'failed';
  end if;
  if p_amount is distinct from payment_row.amount then raise exception 'Payment amount does not match the requested plan'; end if;
  if p_receipt is not null and exists(select 1 from public.subscription_payments sp where sp.mpesa_receipt=p_receipt and sp.id<>payment_row.id) then
    raise exception 'M-Pesa receipt has already been applied';
  end if;
  update public.subscription_payments set status='paid',mpesa_receipt=p_receipt,paid_at=now(),failure_reason=null
    where id=payment_row.id;
  select case when s.plan=payment_row.plan and s.status='active' and s.period_ends_at>now()
    then s.period_ends_at+interval '1 month' else now()+interval '1 month' end
    into next_period from public.subscriptions s where s.business_id=payment_row.business_id;
  insert into public.subscriptions(business_id,plan,status,period_ends_at)
    values(payment_row.business_id,payment_row.plan,'active',coalesce(next_period,now()+interval '1 month'))
    on conflict(business_id) do update set plan=excluded.plan,status='active',period_ends_at=excluded.period_ends_at,updated_at=now();
  insert into public.audit_logs(business_id,actor_id,action,entity_type,entity_id,details)
    values(payment_row.business_id,payment_row.requested_by,'subscription_paid','subscription_payment',payment_row.id,
      jsonb_build_object('plan',payment_row.plan,'amount',payment_row.amount,'receipt',p_receipt));
  return 'paid';
end $$;

create or replace function public.create_product(p_business uuid,p_name text,p_sku text,p_category text,p_buying_price numeric,
  p_selling_price numeric,p_quantity integer,p_threshold integer,p_description text default null) returns uuid
language plpgsql security definer set search_path=public
as $$ declare pid uuid; plan_name text; max_products integer; begin
  if not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then raise exception 'Not authorized to manage products'; end if;
  perform 1 from public.businesses where id=p_business for update;
  select case when s.plan in ('starter','plus') and s.status='active' and s.period_ends_at>now() then s.plan else 'free' end
    into plan_name from public.subscriptions s where s.business_id=p_business;
  max_products:=public.active_product_limit(coalesce(plan_name,'free'));
  if max_products is not null and (select count(*) from public.products where business_id=p_business and archived_at is null)>=max_products then
    raise exception 'Your Free plan supports up to % active products. Archive an item or upgrade your plan.',max_products;
  end if;
  insert into public.products(business_id,name,sku,category,buying_price,selling_price,quantity,low_stock_threshold,description)
    values(p_business,trim(p_name),nullif(trim(p_sku),''),coalesce(nullif(trim(p_category),''),'General'),p_buying_price,p_selling_price,p_quantity,p_threshold,p_description)
    returning id into pid;
  return pid;
end $$;

revoke all on function public.create_plan_payment(uuid,text,text) from public;
revoke all on function public.finalize_plan_payment(text,boolean,integer,text,text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.create_plan_payment(uuid,text,text) to authenticated;
grant execute on function public.finalize_plan_payment(text,boolean,integer,text,text,text,text,jsonb) to service_role;
grant execute on function public.create_product(uuid,text,text,text,numeric,numeric,integer,integer,text) to authenticated;
