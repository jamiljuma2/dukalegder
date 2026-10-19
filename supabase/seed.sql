-- Fictional development data. Replace the UUID below with a business you own.
-- Run only in a development Supabase project using the SQL editor or psql.
begin;
do $$ begin
  if not exists (select 1 from public.businesses where id = '00000000-0000-0000-0000-000000000000'::uuid) then
    raise exception 'Replace the example business UUID in supabase/seed.sql first';
  end if;
end $$;

insert into public.products(business_id,name,sku,category,buying_price,selling_price,quantity,low_stock_threshold)
values
 ('00000000-0000-0000-0000-000000000000','Maize flour 2kg','DEMO-MF2','Groceries',145,175,18,5),
 ('00000000-0000-0000-0000-000000000000','Tea leaves 250g','DEMO-TEA','Groceries',95,125,3,6),
 ('00000000-0000-0000-0000-000000000000','Laundry soap bar','DEMO-SOAP','Household',48,65,24,8)
on conflict (business_id,sku) do nothing;

insert into public.customers(business_id,full_name,phone,notes)
select '00000000-0000-0000-0000-000000000000','Demo Customer','0700000000','Fictional development customer'
where not exists (select 1 from public.customers where business_id='00000000-0000-0000-0000-000000000000'::uuid and full_name='Demo Customer');
commit;
