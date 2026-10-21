-- Keep product photos lightweight, scoped to the owning shop/product, and safely addressable.
alter table public.products add column if not exists image_path text;

-- Backfill paths for existing DukaLedger public image URLs. If the same URL is
-- referenced by multiple products, leave image_path unset so cleanup cannot
-- delete an object still in use.
update public.products p
set image_path = split_part(regexp_replace(p.image_url, '^.*?/storage/v1/object/public/product-images/', ''), '?', 1)
where p.image_path is null
  and p.image_url like '%/storage/v1/object/public/product-images/%'
  and split_part(regexp_replace(p.image_url, '^.*?/storage/v1/object/public/product-images/', ''), '?', 1)
      ~ ('^' || p.business_id::text || '/' || p.id::text || '/[^/]+$')
  and (select count(*) from public.products same_url where same_url.image_url=p.image_url)=1;

alter table public.products
  add constraint products_image_path_scope_check
  check (image_path is null or image_path ~ ('^' || business_id::text || '/' || id::text || '/[^/]+$'));

alter table public.products
  add constraint products_image_url_path_check
  check (
    image_path is null
    or right(image_url, length('/storage/v1/object/public/product-images/' || image_path))
       = '/storage/v1/object/public/product-images/' || image_path
  );

create unique index if not exists products_image_path_unique
  on public.products(image_path) where image_path is not null;
grant update (image_path, image_url) on public.products to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'product-images',
  'product-images',
  true,
  2097152,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "business managers upload product images" on storage.objects;
drop policy if exists "business managers update product images" on storage.objects;
drop policy if exists "business managers delete product images" on storage.objects;

create policy "business managers upload product images"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'product-images'
  and array_length(storage.foldername(name), 1) = 2
  and exists (
    select 1 from public.products p
    where p.business_id::text = (storage.foldername(name))[1]
      and p.id::text = (storage.foldername(name))[2]
      and public.has_business_role(p.business_id, array['owner', 'manager']::public.member_role[])
  )
);

create policy "business managers update product images"
on storage.objects for update to authenticated
using (
  bucket_id = 'product-images'
  and array_length(storage.foldername(name), 1) = 2
  and exists (
    select 1 from public.products p
    where p.business_id::text = (storage.foldername(name))[1]
      and p.id::text = (storage.foldername(name))[2]
      and public.has_business_role(p.business_id, array['owner', 'manager']::public.member_role[])
  )
)
with check (
  bucket_id = 'product-images'
  and array_length(storage.foldername(name), 1) = 2
  and exists (
    select 1 from public.products p
    where p.business_id::text = (storage.foldername(name))[1]
      and p.id::text = (storage.foldername(name))[2]
      and public.has_business_role(p.business_id, array['owner', 'manager']::public.member_role[])
  )
);

create policy "business managers delete product images"
on storage.objects for delete to authenticated
using (
  bucket_id = 'product-images'
  and array_length(storage.foldername(name), 1) = 2
  and exists (
    select 1 from public.products p
    where p.business_id::text = (storage.foldername(name))[1]
      and p.id::text = (storage.foldername(name))[2]
      and public.has_business_role(p.business_id, array['owner', 'manager']::public.member_role[])
  )
);
