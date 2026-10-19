import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

function constantTimeEqual(left: string, right: string) {
  if (left.length !== right.length) return false
  let mismatch = 0
  for (let i = 0; i < left.length; i++) mismatch |= left.charCodeAt(i) ^ right.charCodeAt(i)
  return mismatch === 0
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const configuredCallback = Deno.env.get('CALLBACK_URL')
  const providedUrl = new URL(request.url)
  const expectedUrl = configuredCallback ? new URL(configuredCallback) : null
  const expectedKey = expectedUrl?.searchParams.get('key') || ''
  const providedKey = providedUrl.searchParams.get('key') || ''
  if (!expectedUrl || expectedKey.length < 32 || !constantTimeEqual(providedKey, expectedKey)) {
    return json({ error: 'Unauthorized' }, 401)
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !serviceKey) return json({ error: 'Callback service is not configured' }, 503)

  let body: Record<string, unknown>
  try { body = await request.json() } catch { return json({ error: 'Invalid JSON callback' }, 400) }
  const result = (body.response && typeof body.response === 'object' ? body.response : body) as Record<string, unknown>
  const getString = (...values: unknown[]) => values.find((value): value is string => typeof value === 'string' && value.length > 0) || null
  const externalReference = getString(result.ExternalReference, result.external_reference, body.ExternalReference, body.external_reference)
  if (!externalReference) return json({ error: 'Missing external reference' }, 400)

  const status = String(result.Status ?? result.status ?? '').toLowerCase()
  const resultCode = result.ResultCode ?? result.result_code
  const hasResultCode = resultCode !== undefined && resultCode !== null && resultCode !== ''
  const resultSucceeded = result.success === true || (result.success !== false && (status === 'success' || (status === '' && hasResultCode && Number(resultCode) === 0)))
  const resultFailed = result.success === false || ['failed', 'failure', 'cancelled', 'canceled'].includes(status) || (hasResultCode && Number(resultCode) !== 0)
  if (!resultSucceeded && !resultFailed) return json({ error: 'Payment callback has no final status' }, 400)
  const success = resultSucceeded && (!hasResultCode || Number(resultCode) === 0)
  const rawAmount = result.Amount ?? result.amount
  const amount = rawAmount !== undefined && rawAmount !== null && Number.isInteger(Number(rawAmount)) ? Number(rawAmount) : null
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data, error } = await admin.rpc('finalize_plan_payment', {
    p_external_reference: externalReference,
    p_success: success,
    p_amount: amount,
    p_payhero_reference: getString(result.MerchantRequestID, result.merchant_request_id, result.reference),
    p_checkout_request_id: getString(result.CheckoutRequestID, result.checkout_request_id),
    p_receipt: getString(result.MpesaReceiptNumber, result.mpesa_receipt, result.receipt),
    p_failure_reason: getString(result.ResultDesc, result.result_desc, result.message) || 'Payment was not completed',
    p_callback_payload: body,
  })
  if (error) return json({ error: 'Payment callback could not be reconciled' }, 400)
  return json({ received: true, status: data })
})
