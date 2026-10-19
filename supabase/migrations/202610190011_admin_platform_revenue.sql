create or replace function public.admin_platform_revenue()
returns jsonb
language plpgsql stable security definer set search_path=public
as $$
begin
  if not public.is_super_admin() then raise exception 'Super admin access required'; end if;
  return (
    select jsonb_build_object(
      'gross_revenue',coalesce(sum(sp.amount),0),
      'verified_payments',count(*)
    )
    from public.subscription_payments sp
    where sp.status='paid'
  );
end
$$;

revoke all on function public.admin_platform_revenue() from public;
grant execute on function public.admin_platform_revenue() to authenticated;
