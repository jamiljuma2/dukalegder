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
  v_amount:=case p_plan when 'starter' then 500 else 1200 end;
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
