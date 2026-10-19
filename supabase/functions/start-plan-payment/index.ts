import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (request.method !== 'POST') return reply({ error: 'Method not allowed' }, 405)

  const authorization = request.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return reply({ error: 'Sign in to purchase a plan' }, 401)

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const payheroAuthorization = Deno.env.get('PAYHERO_AUTHORIZATION')?.trim()
  const apiUsername = Deno.env.get('API_USERNAME')
  const apiPassword = Deno.env.get('API_PASSWORD')
  const authorizationHeader = payheroAuthorization ||
    (apiUsername && apiPassword ? `Basic ${btoa(`${apiUsername}:${apiPassword}`)}` : '')
  const channelId = Deno.env.get('CHANNEL_ID')
  const callbackUrl = Deno.env.get('CALLBACK_URL')
  if (!supabaseUrl || !anonKey || !serviceKey || !authorizationHeader || !channelId || !callbackUrl) {
    return reply({ error: 'Plan payments are not configured yet. Contact the shop administrator.' }, 503)
  }
  let parsedCallback: URL
  try { parsedCallback = new URL(callbackUrl) } catch {
    return reply({ error: 'PayHero server configuration is invalid. Contact the shop administrator.' }, 503)
  }
  const callbackKey = parsedCallback.searchParams.get('key') || ''
  if (!/^Basic\s+\S+$/i.test(authorizationHeader) || parsedCallback.protocol !== 'https:' || !parsedCallback.pathname.endsWith('/functions/v1/payhero-callback') ||
      callbackKey.length < 32 || !Number.isSafeInteger(Number(channelId)) || Number(channelId) < 1) {
    return reply({ error: 'PayHero server configuration is invalid. Contact the shop administrator.' }, 503)
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { data: userData, error: userError } = await userClient.auth.getUser()
  if (userError || !userData.user) return reply({ error: 'Your session is invalid. Sign in again.' }, 401)

  let input: { business_id?: string; plan?: string; phone?: string }
  try { input = await request.json() } catch { return reply({ error: 'Invalid request body' }, 400) }
  if (!input.business_id || !['starter', 'plus'].includes(input.plan || '') || !input.phone) {
    return reply({ error: 'Business, plan, and M-Pesa phone number are required' }, 400)
  }

  const { data: checkoutRows, error: checkoutError } = await userClient.rpc('create_plan_payment', {
    p_business: input.business_id,
    p_plan: input.plan,
    p_phone: input.phone,
  })
  if (checkoutError) return reply({ error: checkoutError.message }, 400)
  const checkout = Array.isArray(checkoutRows) ? checkoutRows[0] : checkoutRows
  if (!checkout?.payment_id || !checkout.external_reference || !checkout.amount) {
    return reply({ error: 'Could not create the plan payment request' }, 500)
  }

  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  let providerResponse: Response
  try {
    providerResponse = await fetch('https://backend.payhero.co.ke/api/v2/payments', {
      method: 'POST',
      headers: { Authorization: authorizationHeader, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        amount: checkout.amount,
        phone_number: checkout.phone,
        channel_id: Number(channelId),
        provider: 'm-pesa',
        external_reference: checkout.external_reference,
        customer_name: userData.user.user_metadata?.full_name || userData.user.email || 'DukaLedger owner',
        callback_url: callbackUrl,
      }),
      signal: AbortSignal.timeout(20000),
    })
  } catch {
    // A timeout is ambiguous: PayHero may have accepted the request. Leave it pending
    // so a delayed callback can reconcile it and the client cannot create duplicates.
    return reply({ payment_id: checkout.payment_id, external_reference: checkout.external_reference, status: 'pending' }, 202)
  }

  let providerBody: Record<string, unknown> = {}
  try { providerBody = await providerResponse.json() } catch { /* handled as provider failure below */ }
  if (!providerResponse.ok || providerBody.success !== true) {
    const reason = String(providerBody.message || providerBody.error || `PayHero returned HTTP ${providerResponse.status}`)
    await admin.from('subscription_payments').update({ status: 'failed', failure_reason: reason.slice(0, 500) }).eq('id', checkout.payment_id).eq('status', 'pending')
    return reply({ error: 'PayHero could not start the M-Pesa prompt. Check the number and try again.' }, 502)
  }

  await admin.from('subscription_payments').update({
    payhero_reference: typeof providerBody.reference === 'string' ? providerBody.reference : null,
    checkout_request_id: typeof providerBody.CheckoutRequestID === 'string' ? providerBody.CheckoutRequestID : null,
  }).eq('id', checkout.payment_id)

  return reply({
    payment_id: checkout.payment_id,
    external_reference: checkout.external_reference,
    status: 'pending',
    message: 'Approve the M-Pesa prompt on your phone. Your plan changes after PayHero confirms payment.',
  }, 202)
})
