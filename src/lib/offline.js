import { openDB } from 'idb'
import { supabase } from './supabase.js'

const DB_NAME = 'dukaledger-offline-v1'
const DB_VERSION = 2
const STORE = 'records'

let dbPromise
function openDb() {
  if (!globalThis.indexedDB) throw new Error('This browser does not support offline storage.')
  if (!dbPromise) dbPromise = openDB(DB_NAME, DB_VERSION, { upgrade(db,oldVersion,newVersion,transaction) {
    const store=db.objectStoreNames.contains(STORE)?transaction.objectStore(STORE):db.createObjectStore(STORE,{keyPath:'id'})
    if(!store.indexNames.contains('scope'))store.createIndex('scope',['userId','businessId','kind'])
    if(!store.indexNames.contains('userId'))store.createIndex('userId','userId')
  } })
  return dbPromise
}

async function transact(mode, callback) {
  const db = await openDb()
  const tx = db.transaction(STORE, mode)
  const result = await callback(tx.store)
  await tx.done
  return result
}

export const makeId = () => crypto.randomUUID()
export const scopeId = (userId, businessId, kind) => `${kind}:${userId}:${businessId}`

export async function cacheSnapshot(userId, businessId, data) {
  return transact('readwrite', store => store.put({ id: scopeId(userId, businessId, 'snapshot'), userId, businessId, kind: 'snapshot', savedAt: new Date().toISOString(), data }))
}
export async function readSnapshot(userId, businessId) {
  const db = await openDb()
  return (await db.get(STORE, scopeId(userId, businessId, 'snapshot'))) || null
}
export async function cacheNamedSnapshot(userId,businessId,name,data){return transact('readwrite',store=>store.put({id:`snapshot:${userId}:${businessId}:${name}`,userId,businessId,kind:'snapshot',savedAt:new Date().toISOString(),data}))}
export async function readNamedSnapshot(userId,businessId,name){const db=await openDb();return (await db.get(STORE,`snapshot:${userId}:${businessId}:${name}`))||null}
export async function enqueue(userId, businessId, type, payload, id = makeId()) {
  const operation = { id, userId, businessId, kind: 'operation', type, payload, status: 'pending', attempts: 0, createdAt: new Date().toISOString(), nextAttemptAt: 0, error: null }
  await transact('readwrite', store => store.put(operation))
  return operation
}
export async function listOperations(userId, businessId) {
  const db = await openDb()
  return (await db.getAllFromIndex(STORE, 'scope', [userId, businessId, 'operation'])).sort((a, b) => b.createdAt.localeCompare(a.createdAt))
}
export async function listUserOperations(userId){const db=await openDb();return db.getAllFromIndex(STORE,'userId',userId)}
export async function updateOperation(operation) { return transact('readwrite', store => store.put(operation)) }
export async function clearAccountData(userId, businessId) {
  const operations = await listOperations(userId, businessId)
  if (operations.some(op => ['pending', 'syncing', 'failed'].includes(op.status))) throw new Error('This shop has queued changes. Sync or review them before clearing local data.')
  return transact('readwrite', store => store.delete(scopeId(userId, businessId, 'snapshot')))
}

export function isTransientError(error) {
  const message = `${error?.message || ''} ${error?.code || ''}`.toLowerCase()
  return !navigator.onLine || error?.code==='SYNC_DEPENDENCY' || /fetch|network|timeout|temporar|502|503|504|429|connection/.test(message)
}
async function send(operation) {
  const p = operation.payload
  if (operation.type === 'sale') return supabase.rpc('create_sale', { p_business: operation.businessId, p_request_key: operation.id, p_items: p.items, p_method: p.method, p_amount_paid: p.amountPaid, p_customer: p.customerId, p_discount: p.discount })
  if (operation.type === 'repayment') return supabase.rpc('record_repayment', { p_business: operation.businessId, p_request_key: operation.id, p_customer: p.customerId, p_amount: p.amount, p_method: p.method, p_note: p.note })
  if (operation.type === 'expense') return supabase.rpc('record_expense', { p_business: operation.businessId, p_request_key: operation.id, p_description: p.description, p_category: p.category, p_amount: p.amount, p_spent_on: p.spentOn, p_method: p.method, p_notes: p.notes })
  if (operation.type === 'customer') return supabase.rpc('record_customer', { p_business: operation.businessId, p_request_key: p.requestKey, p_customer_id: operation.id, p_full_name: p.fullName, p_phone: p.phone, p_notes: p.notes })
  if (operation.type === 'adjustment') return supabase.rpc('adjust_stock_idempotent', { p_business: operation.businessId, p_product: p.productId, p_request_key: operation.id, p_delta: p.delta, p_reason: p.reason, p_kind: p.kind })
  if (operation.type === 'product_save') {
    const { data, error } = await supabase.rpc('offline_save_product', { p_business: operation.businessId, p_product: p.productId, p_request_key: operation.id, p_expected_updated_at: p.expectedUpdatedAt, p_values: p.values })
    if(error)throw error
    if(p.image||p.imageRemoved){
      const file=p.image
      let path=null,url=null
      if(file){path=`${operation.businessId}/${p.productId}/offline-${operation.id}.${file.type==='image/webp'?'webp':file.type==='image/png'?'png':'jpg'}`
        const {error:uploadError}=await supabase.storage.from('product-images').upload(path,file,{cacheControl:'31536000',upsert:true,contentType:file.type})
        if(uploadError)throw uploadError
        url=supabase.storage.from('product-images').getPublicUrl(path).data.publicUrl}
      const {error:linkError}=await supabase.rpc('offline_link_product_image',{p_business:operation.businessId,p_product:p.productId,p_request_key:operation.id,p_path:path,p_url:url})
      if(linkError)throw linkError
      if(p.previousPath&&p.previousPath!==path){try{const {data:references,error:checkError}=await supabase.from('products').select('id').eq('image_path',p.previousPath).limit(1);if(!checkError&&!references?.length)await supabase.storage.from('product-images').remove([p.previousPath])}catch(error){console.warn('The previous product image could not be cleaned up:',error)}}
    }
    return {data}
  }
  if (operation.type === 'purchase_draft') return supabase.rpc('save_supplier_purchase', { p_business: operation.businessId,p_purchase:null,p_request_key:operation.id,p_supplier:p.supplier,p_invoice_reference:p.invoiceReference,p_date:p.date,p_notes:p.notes,p_items:p.items })
  if (operation.type === 'purchase_edit') return supabase.rpc('offline_edit_supplier_purchase',{p_business:operation.businessId,p_purchase:p.purchaseId,p_request_key:operation.id,p_expected_updated_at:p.expectedUpdatedAt,p_supplier:p.supplier,p_invoice_reference:p.invoiceReference,p_date:p.date,p_notes:p.notes,p_items:p.items})
  if(operation.type==='purchase_confirm'||operation.type==='supplier_payment'){
    let purchaseId=p.purchaseId
    if(p.purchaseRef){const draft=(await listOperations(operation.userId,operation.businessId)).find(row=>row.id===p.purchaseRef);if(!draft?.serverId){const error=new Error('Waiting for the purchase draft to sync first.');error.code='SYNC_DEPENDENCY';throw error}purchaseId=draft.serverId}
    if(operation.type==='purchase_confirm')return supabase.rpc('confirm_supplier_purchase',{p_purchase:purchaseId})
    return supabase.rpc('record_supplier_payment', { p_business:operation.businessId,p_purchase:purchaseId,p_request_key:operation.id,p_amount:p.amount,p_method:p.method,p_note:p.note,p_paid_on:p.paidOn })
  }
  throw new Error(`Unsupported queued operation: ${operation.type}`)
}

async function appliedServerId(operation){
  const p=operation.payload,b=operation.businessId
  let query
  if(operation.type==='sale')query=supabase.from('sales').select('id').eq('business_id',b).eq('request_key',operation.id).maybeSingle()
  else if(operation.type==='repayment')query=supabase.from('payments').select('id').eq('business_id',b).eq('request_key',operation.id).eq('kind','debt_repayment').maybeSingle()
  else if(operation.type==='expense')query=supabase.from('expenses').select('id').eq('business_id',b).eq('request_key',operation.id).maybeSingle()
  else if(operation.type==='customer')query=supabase.from('customers').select('id').eq('business_id',b).eq('request_key',operation.id).maybeSingle()
  else if(operation.type==='adjustment')query=supabase.from('inventory_movements').select('id').eq('business_id',b).eq('request_key',operation.id).maybeSingle()
  else if(operation.type==='product_save'){
    const receipt=await supabase.from('offline_operation_receipts').select('entity_id').eq('business_id',b).eq('request_key',operation.id).maybeSingle()
    if(receipt.error||!receipt.data)return null
    if(p.image||p.imageRemoved){const expectedPath=p.image?`${b}/${p.productId}/offline-${operation.id}.${p.image.type==='image/webp'?'webp':p.image.type==='image/png'?'png':'jpg'}`:null;const product=await supabase.from('products').select('id,image_path').eq('business_id',b).eq('id',p.productId).maybeSingle();if(product.error||!product.data||product.data.image_path!==expectedPath)return null}
    return receipt.data.entity_id
  }else if(operation.type==='purchase_draft')query=supabase.from('supplier_purchases').select('id').eq('business_id',b).eq('request_key',operation.id).maybeSingle()
  else if(operation.type==='purchase_edit')query=supabase.from('offline_operation_receipts').select('entity_id').eq('business_id',b).eq('request_key',operation.id).maybeSingle()
  else if(operation.type==='purchase_confirm'){const result=await supabase.from('supplier_purchases').select('id,status').eq('id',p.purchaseId||((await listOperations(operation.userId,b)).find(row=>row.id===p.purchaseRef)?.serverId)).maybeSingle();return !result.error&&result.data?.status==='received'?result.data.id:null}
  else if(operation.type==='supplier_payment')query=supabase.from('supplier_payments').select('id').eq('business_id',b).eq('request_key',operation.id).maybeSingle()
  if(!query)return null
  const {data,error}=await query
  if(error||!data)return null
  return data.id||data.entity_id||true
}

export async function syncOperations(userId, businessId, onChange = () => {}, force = false) {
  if (!navigator.onLine) return
  const { data: sessionData } = await supabase.auth.getSession()
  if (sessionData.session?.user?.id !== userId) return
  const operations = (await listOperations(userId, businessId)).filter(op => op.status === 'pending' && (force || op.nextAttemptAt <= Date.now()))
  for (const operation of operations.reverse()) {
    const { data: current } = await supabase.auth.getSession()
    if (current.session?.user?.id !== userId) break
    const sending = { ...operation, status: 'syncing', error: null }
    await updateOperation(sending); onChange()
    try {
      const { data, error } = await send(sending)
      if (error) throw error
      const completed = { ...sending, status: 'synced', syncedAt: new Date().toISOString(), serverId: typeof data==='string'?data:sending.serverId, error: null }
      if(completed.type==='product_save'&&completed.payload.image)completed.payload={...completed.payload,image:null}
      await updateOperation(completed)
    } catch (error) {
      const appliedId=await appliedServerId(sending)
      if(appliedId){const completed={...sending,status:'synced',syncedAt:new Date().toISOString(),serverId:typeof appliedId==='string'?appliedId:sending.serverId,error:null};if(completed.type==='product_save'&&completed.payload.image)completed.payload={...completed.payload,image:null};await updateOperation(completed);onChange();continue}
      const attempts = sending.attempts + 1
      const transient = isTransientError(error)
      await updateOperation({ ...sending, attempts, status: transient ? 'pending' : 'failed', error: error.message || 'Synchronization failed', nextAttemptAt: transient ? Date.now() + Math.min(3600000, 2000 * (2 ** Math.min(attempts, 10))) : 0 })
    }
    onChange()
  }
}
