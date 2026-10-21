-- Evaluate image ownership checks outside products-table RLS while preserving
-- the business role and exact business/product folder boundaries.
create or replace function public.can_manage_product_image(p_business text, p_product text)
returns boolean
language sql stable security definer set search_path=public,pg_temp
as $$
  select exists (
    select 1
    from public.products p
  join public.business_members m
    on m.business_id = p.business_id
   and m.user_id = auth.uid()
  left join public.subscriptions s
    on s.business_id = p.business_id
    where p.business_id::text = p_business
      and p.id::text = p_product
    and m.role in ('owner', 'manager')
    and (
      m.role = 'owner'
      or (s.plan = 'plus' and s.status = 'active' and s.period_ends_at > now())
    )
  )
$$;

revoke all on function public.can_manage_product_image(text,text) from public;
grant execute on function public.can_manage_product_image(text,text) to authenticated;

drop policy if exists "business managers upload product images" on storage.objects;
create policy "business managers upload product images"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'product-images'
  and array_length(storage.foldername(name), 1) = 2
  and public.can_manage_product_image(
    (storage.foldername(name))[1],
    (storage.foldername(name))[2]
  )
);

drop policy if exists "business managers update product images" on storage.objects;
create policy "business managers update product images"
on storage.objects for update to authenticated
using (
  bucket_id = 'product-images'
  and array_length(storage.foldername(name), 1) = 2
  and public.can_manage_product_image(
    (storage.foldername(name))[1],
    (storage.foldername(name))[2]
  )
)
with check (
  bucket_id = 'product-images'
  and array_length(storage.foldername(name), 1) = 2
  and public.can_manage_product_image(
    (storage.foldername(name))[1],
    (storage.foldername(name))[2]
  )
);

drop policy if exists "business managers delete product images" on storage.objects;
create policy "business managers delete product images"
on storage.objects for delete to authenticated
using (
  bucket_id = 'product-images'
  and array_length(storage.foldername(name), 1) = 2
  and public.can_manage_product_image(
    (storage.foldername(name))[1],
    (storage.foldername(name))[2]
  )
);
