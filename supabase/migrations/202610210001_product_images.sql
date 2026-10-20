alter table public.products add column image_url text;

-- Products are readable by authenticated users; allow managers and owners to
-- save the image URL using the same column-level update access as product edits.
grant update (image_url) on public.products to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'product-images',
  'product-images',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "business managers upload product images"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'product-images'
  and public.has_business_role(
    ((storage.foldername(name))[1])::uuid,
    array['owner', 'manager']::public.member_role[]
  )
);

create policy "business managers update product images"
on storage.objects for update to authenticated
using (
  bucket_id = 'product-images'
  and public.has_business_role(
    ((storage.foldername(name))[1])::uuid,
    array['owner', 'manager']::public.member_role[]
  )
)
with check (
  bucket_id = 'product-images'
  and public.has_business_role(
    ((storage.foldername(name))[1])::uuid,
    array['owner', 'manager']::public.member_role[]
  )
);

create policy "business managers delete product images"
on storage.objects for delete to authenticated
using (
  bucket_id = 'product-images'
  and public.has_business_role(
    ((storage.foldername(name))[1])::uuid,
    array['owner', 'manager']::public.member_role[]
  )
);
