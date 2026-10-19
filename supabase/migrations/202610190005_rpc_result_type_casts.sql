-- Make PL/pgSQL RETURN QUERY result types explicit for PostgREST RPCs.
create or replace function public.list_business_members(p_business uuid)
returns table(user_id uuid,email text,full_name text,role public.member_role,joined_at timestamptz)
language plpgsql security definer set search_path=public
as $$ begin
  if not public.has_business_role(p_business,array['owner']::public.member_role[]) then
    raise exception 'Only an owner can manage team members';
  end if;
  return query
    select m.user_id,u.email::text,coalesce(p.full_name,''),m.role,m.created_at
    from public.business_members m
    join auth.users u on u.id=m.user_id
    left join public.profiles p on p.id=m.user_id
    where m.business_id=p_business
    order by case m.role when 'owner' then 0 when 'manager' then 1 else 2 end,m.created_at;
end $$;

create or replace function public.customer_balances(p_business uuid)
returns table(customer_id uuid,outstanding numeric)
language plpgsql stable security definer set search_path=public
as $$ begin
  if not public.has_business_role(p_business,array['owner','manager']::public.member_role[]) then
    raise exception 'Not authorized to view customer balances';
  end if;
  return query
    select c.id::uuid,
      greatest(
        coalesce(sum(s.total-s.amount_paid),0)
          - coalesce((select sum(p.amount) from public.payments p
            where p.business_id=c.business_id and p.customer_id=c.id and p.kind='debt_repayment'),0),
        0
      )::numeric
    from public.customers c
    left join public.sales s on s.customer_id=c.id and s.business_id=c.business_id and s.status='completed'
    where c.business_id=p_business
    group by c.id,c.business_id;
end $$;
