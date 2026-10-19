# DukaLedger

DukaLedger is a mobile-first shop ledger for Kenyan small retailers. This first MVP includes Supabase authentication, shop onboarding, inventory, sales, customer balances and repayments, operating expenses, daily metrics, and date-filtered CSV reports.

## Requirements

- Node.js 20 or newer and npm
- A Supabase project (PostgreSQL and Supabase Auth)
- A Vercel account for hosting (optional during local development)

## Local setup

1. Copy `.env.example` to `.env` and set both values:

   - `VITE_SUPABASE_URL`: the project URL from Supabase Project Settings → API.
   - `VITE_SUPABASE_ANON_KEY`: the project publishable key (or legacy anon key). This is a public client key; database access is protected by RLS. Never use a service-role key here.

2. Apply the SQL files in `supabase/migrations` in filename order using the Supabase SQL editor or Supabase CLI. The migrations create the schema, RLS policies, authentication profile trigger, and trusted functions for business creation, product creation, stock adjustments, sales, and debt repayments. Migration `202610190002_expense_creator_default.sql` fixes the authenticated expense insert default. Migration `202610190004_multi_business_staff_access.sql` adds business invitations, multiple businesses per account, and role-based access. Migration `202610190005_rpc_result_type_casts.sql` applies explicit result casts for the team and debt RPCs. Migration `202610190006_invite_crypto_search_path.sql` makes invitation token hashing work when Supabase has `pgcrypto` installed in its `extensions` schema. Migration `202610190007_payhero_subscription_billing.sql` adds monthly subscription checkout and verified callback reconciliation. Migration `202610190008_global_super_admin.sql` adds global platform roles, admin-only inspection/role management, and super-admin read policies. Migration `202610190009_super_admin_business_deletion.sql` adds a protected super-admin-only business deletion function. Migration `202610190010_super_admin_dashboard_metrics.sql` adds admin-only cross-platform metrics for the dashboard. Migration `202610190011_admin_platform_revenue.sql` reports gross revenue from confirmed subscription payments to super admins.

### Platform super admin

Apply migration `202610190008_global_super_admin.sql` after the existing migrations. To grant platform admin access to an account created later, first verify the account in **Supabase Dashboard → Authentication → Users** and copy its user ID. Before promoting an account that owns a shop, transfer that shop to another owner. Then run this one-time statement in the Supabase SQL editor, replacing the placeholder with the verified user ID:

```sql
begin;

do $$
declare target_user uuid := 'REPLACE_WITH_VERIFIED_AUTH_USER_ID'::uuid;
begin
  if not exists (
    select 1 from auth.users
    where id = target_user and email_confirmed_at is not null
  ) then
    raise exception 'A confirmed Auth user with that ID was not found';
  end if;

  update public.profiles
  set global_role = 'super_admin'
  where id = target_user;
  if not found then raise exception 'User profile was not found'; end if;

  delete from public.business_members where user_id = target_user;
end
$$;

commit;
```

The account can then sign in and open **Platform admin** without joining or selecting a shop. The database rejects future business memberships for super admins. Promotion removes existing memberships but keeps shop records. Global roles are stored in `public.profiles`; authenticated clients cannot change them. Later role changes must use the admin-only `admin_set_global_role` function. Keep account IDs, emails, passwords, and service-role keys out of checked-in documentation, source code, and frontend environment variables.

Super admins can delete a business from **Platform admin → Businesses**. The operation requires typing the business name exactly and permanently deletes that business's related sales, customers, inventory, payments, subscriptions, and audit history.

The admin dashboard's **Platform revenue** is the gross total of subscription payment records marked `paid` after PayHero confirmation. It excludes shops' sales (shown separately in Sales activity) and does not subtract processor fees or refunds, which are not currently represented in the billing schema. Apply migration `202610190011_admin_platform_revenue.sql` to enable this figure.

3. In Supabase Authentication → URL Configuration, set the local site URL to `http://localhost:5173` and allow that URL as a redirect URL. Configure email confirmation and password recovery email templates for your domain before inviting customers.

4. Install and start the app:

   ```sh
   npm install
   npm run dev
   ```

5. Create an account, confirm the email if required, sign in, and complete shop onboarding. All records are scoped to the selected business membership.

## Development data

`supabase/seed.sql` contains fictional sample products and a fictional customer. Replace the example business UUID with a development business UUID before running it. The sample records are not real customer data. Avoid using seed records in a production shop.

Business owners can create additional businesses from Settings and invite staff or managers from **Staff & access**. Invite links expire after seven days and are bound to the email address entered by the owner. The link can be copied and shared manually; automatic email delivery requires an email provider integration. Staff can record sales and view stock. Managers can also manage products, customers, expenses, reports, and debt repayments. Owners can manage the business profile and team.

## Checks

```sh
npm test
npm run build
```

The automated Node tests cover the pure profit, cost, balance and plan-limit helpers. Critical writes are enforced by PostgreSQL functions and constraints. This repository does not yet include an automated Supabase integration suite for RLS, transaction concurrency, or cross-business isolation; test those against a separate development Supabase project before a customer pilot.

## Deploy to Vercel

1. Import this directory as a Vite project in Vercel (the default build command `npm run build` and output directory `dist` are correct).
2. Add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` under Vercel project environment variables for Preview and Production. These are client-side values, not secrets.
3. Deploy, then add the Vercel production domain and any preview domains to Supabase Auth's allowed redirect URLs. Set the production site URL to the canonical domain.
4. Apply SQL migrations to the correct Supabase project before directing users to the app. Keep development, preview and production projects separate where possible.

### PayHero subscription payments

The plan prices are Free (KSh 0), Starter (KSh 300/month), and Plus (KSh 600/month). An owner starts an M-Pesa STK push from Settings. The database creates the expected amount and reference; the plan is activated for one month only after the callback matches that reference and amount. Repeated callbacks are idempotent. Plus is required to invite staff, and expired paid plans fall back to the Free product cap and staff access.

1. Create a PayHero account, register an M-Pesa payment channel, and create API credentials. The API call uses PayHero's documented `POST https://backend.payhero.co.ke/api/v2/payments` endpoint with Basic authentication, an M-Pesa phone number, channel ID, external reference, and callback URL.
2. Set server-side Edge Function secrets; do not put these in Vite variables or the browser `.env`:

   ```sh
   npx supabase secrets set \
     PAYHERO_AUTHORIZATION="Basic YOUR_PAYHERO_AUTH_TOKEN" \
     CHANNEL_ID="YOUR_PAYHERO_CHANNEL_ID" \
     CALLBACK_URL="https://YOUR_PROJECT_REF.supabase.co/functions/v1/payhero-callback?key=YOUR_LONG_RANDOM_SECRET"
   ```

   Copy the complete Basic authorization value from PayHero's API credentials and use the numeric channel ID shown in your PayHero account. Use a randomly generated callback key with at least 32 characters. The `CALLBACK_URL` value must exactly match the deployed callback endpoint and include that key in its `key` query parameter. Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions automatically. `supabase/functions/.env.example` shows the local function environment format.
3. Deploy the authenticated checkout function and the public callback. The callback is protected by the high-entropy key in its URL; `supabase/config.toml` disables the Supabase JWT check for this provider endpoint:

   ```sh
   npx supabase functions deploy start-plan-payment
   npx supabase functions deploy payhero-callback
   ```

4. Apply the SQL migrations through `202610190007_payhero_subscription_billing.sql` before deploying the app with `npx supabase db push`. Use PayHero test credits/test transactions first; verify both success and cancellation callbacks in the Supabase function logs and confirm that only successful, amount-matched callbacks activate a plan.

## Data safety and recovery

Use Supabase's managed backup/PITR options appropriate to the selected plan, and confirm retention and restore access before production use. Periodically export a database backup to storage you control, restrict who can download it, and perform a restore rehearsal in a separate project. A recovery needs both the database backup and the deployed app/configuration; rotate credentials if an exposed key is ever discovered. Never put service-role keys in Vite environment variables.

## Current scope and remaining production work

- Sale recording and stock deduction run in one database transaction, validate stock server-side, snapshot item costs/prices, and reject unpaid sales without a customer. Stock quantity edits use an audited RPC. Customer balances are derived from sales and repayment records.
- The Free plan's 20 active-product cap is checked in a serialized database function. Starter and Plus use the proposed KSh 300/KSh 600 monthly prices. Paid upgrades use PayHero STK push and server-side callback reconciliation; production still requires valid PayHero credentials/channel settings and live end-to-end payment verification.
- The launch workflow still needs a verified Supabase integration test suite for RLS isolation, concurrent stock/sale operations, and repayments; add monitoring and error reporting; configure and rehearse backups; and complete mobile/browser QA on target devices.
- Sale detail/printable receipts, sale cancellation/refunds, editing expenses, a seven-day chart, downloadable customer statements, automatic subscription renewals, and payment-status reconciliation when a provider callback is missing are not implemented. Staff invitations and one-time PayHero plan checkout are implemented. Customer account history shows sales and repayments, and WhatsApp reminders open a message for manual review and sending.
- Financial reports are operational estimates. Gross profit uses stored sale cost snapshots; operating profit subtracts recorded operating expenses and excludes stock purchases to avoid double counting. Reports are not formal accounting or tax advice.

## Stack

React + Vite, React Router, Lucide React, Supabase Auth/Postgres/RLS, and browser-generated CSV exports. The interface uses Africa/Nairobi date boundaries, DD/MM/YYYY display dates and Kenyan shillings.
