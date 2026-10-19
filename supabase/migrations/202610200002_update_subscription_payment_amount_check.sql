alter table public.subscription_payments
  drop constraint if exists subscription_payments_amount_check;

alter table public.subscription_payments
  add constraint subscription_payments_amount_check
  check (
    (plan = 'starter' and amount in (300, 500))
    or (plan = 'plus' and amount in (600, 1200))
  );
