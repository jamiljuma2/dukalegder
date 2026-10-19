-- Supabase commonly installs pgcrypto in `extensions`, not `public`.
-- Include both schemas so token generation and hashing work across projects.
alter function public.create_business_invite(uuid,text,public.member_role)
  set search_path=public,extensions;
alter function public.accept_business_invite(text)
  set search_path=public,extensions;
