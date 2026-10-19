create or replace function public.admin_dashboard_metrics()
returns jsonb
language plpgsql stable security definer set search_path=public,auth
as $$
declare
  sales_months jsonb;
  customer_months jsonb;
  product_categories jsonb;
  plan_counts jsonb;
begin
  if not public.is_super_admin() then raise exception 'Super admin access required'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'month',to_char(month_start,'Mon'),
    'sales',sales_total,
    'orders',order_count
  ) order by month_start),'[]'::jsonb)
  into sales_months
  from (
    select months.month_start,
      coalesce(sum(s.total),0)::numeric as sales_total,
      count(s.id)::bigint as order_count
    from generate_series(date_trunc('month',now())-interval '5 months',date_trunc('month',now()),interval '1 month') months(month_start)
    left join public.sales s on s.status='completed'
      and s.created_at>=months.month_start
      and s.created_at<months.month_start+interval '1 month'
    group by months.month_start
  ) monthly;

  select coalesce(jsonb_agg(jsonb_build_object('month',to_char(month_start,'Mon'),'customers',customer_count) order by month_start),'[]'::jsonb)
  into customer_months
  from (
    select months.month_start,count(c.id)::bigint as customer_count
    from generate_series(date_trunc('month',now())-interval '5 months',date_trunc('month',now()),interval '1 month') months(month_start)
    left join public.customers c on c.created_at>=months.month_start
      and c.created_at<months.month_start+interval '1 month'
    group by months.month_start
  ) monthly;

  select coalesce(jsonb_agg(jsonb_build_object('category',category,'products',product_count) order by product_count desc),'[]'::jsonb)
  into product_categories
  from (
    select coalesce(nullif(trim(p.category),''),'Other') category,count(*)::bigint product_count
    from public.products p
    where p.archived_at is null
    group by coalesce(nullif(trim(p.category),''),'Other')
    order by count(*) desc
    limit 5
  ) categories;

  select coalesce(jsonb_agg(jsonb_build_object('plan',plan,'businesses',business_count) order by business_count desc),'[]'::jsonb)
  into plan_counts
  from (
    select coalesce(s.plan,'free') plan,count(*)::bigint business_count
    from public.businesses b
    left join public.subscriptions s on s.business_id=b.id
    group by coalesce(s.plan,'free')
  ) plans;

  return jsonb_build_object(
    'total_sales',(select coalesce(sum(s.total),0) from public.sales s where s.status='completed'),
    'total_orders',(select count(*) from public.sales s where s.status='completed'),
    'products_sold',(select coalesce(sum(i.quantity),0) from public.sale_items i join public.sales s on s.id=i.sale_id where s.status='completed'),
    'total_products',(select count(*) from public.products p where p.archived_at is null),
    'total_customers',(select count(*) from public.customers),
    'total_businesses',(select count(*) from public.businesses),
    'total_users',(select count(*) from auth.users),
    'sales_by_month',sales_months,
    'customers_by_month',customer_months,
    'products_by_category',product_categories,
    'businesses_by_plan',plan_counts
  );
end
$$;

revoke all on function public.admin_dashboard_metrics() from public;
grant execute on function public.admin_dashboard_metrics() to authenticated;
