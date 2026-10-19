-- Existing projects need this migration because the initial expenses table
-- required created_by but did not provide a default for browser inserts.
alter table public.expenses
  alter column created_by set default auth.uid();

drop policy if exists "member add expenses" on public.expenses;
create policy "member add expenses" on public.expenses
  for insert
  with check (public.is_business_member(business_id) and created_by=auth.uid());

drop policy if exists "member update expenses" on public.expenses;
create policy "member update expenses" on public.expenses
  for update
  using (public.is_business_member(business_id) and created_by=auth.uid())
  with check (public.is_business_member(business_id) and created_by=auth.uid());
