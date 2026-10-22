import 'fake-indexeddb/auto'
import test from 'node:test'
import assert from 'node:assert/strict'
import { cacheSnapshot, clearAccountData, enqueue, listOperations, readSnapshot, syncErrorMessage, syncOperations, updateOperation } from '../src/lib/offline.js'

test('offline records persist by account and shop scope', async () => {
  const userA='offline-test-user-a',userB='offline-test-user-b',shop='offline-test-shop'
  const sale=await enqueue(userA,shop,'sale',{items:[{product_id:'p1',quantity:2}],total:40},'offline-test-sale')
  await cacheSnapshot(userA,shop,{products:[{id:'p1',quantity:5}],customers:[]})
  assert.equal((await readSnapshot(userA,shop)).data.products[0].quantity,5)
  assert.equal(await readSnapshot(userB,shop),null)
  assert.equal((await listOperations(userA,shop)).find(row=>row.id===sale.id).status,'pending')
  assert.deepEqual(await listOperations(userB,shop),[])
})

test('failed operations remain durable and block local cleanup', async () => {
  const user='offline-test-user-failed',shop='offline-test-shop-failed'
  const op=await enqueue(user,shop,'expense',{amount:10},'offline-test-expense')
  await updateOperation({...op,status:'failed',error:'Server validation failed'})
  await assert.rejects(clearAccountData(user,shop),/queued changes/)
  const rows=await listOperations(user,shop)
  assert.equal(rows[0].status,'failed')
  assert.equal(rows[0].payload.amount,10)
})

test('a fetch failure during send and idempotency lookup stays queued with a retry message', async () => {
  Object.defineProperty(globalThis,'navigator',{configurable:true,value:{onLine:true}})
  const user='offline-test-user-network',shop='offline-test-shop-network'
  const op=await enqueue(user,shop,'expense',{description:'test',amount:10},'offline-test-network-failure')
  await updateOperation({...op,status:'syncing'})
  const client={
    auth:{getSession:async()=>({data:{session:{user:{id:user}}}})},
    rpc:async()=>{throw new TypeError('Failed to fetch')},
    from:()=>({select(){return this},eq(){return this},maybeSingle(){throw new TypeError('Failed to fetch')}}),
  }

  await syncOperations(user,shop,()=>{},true,client)

  const saved=(await listOperations(user,shop)).find(row=>row.id===op.id)
  assert.equal(saved.status,'pending')
  assert.equal(saved.attempts,1)
  assert.ok(saved.nextAttemptAt>Date.now())
  assert.match(saved.error,/still queued.*retry automatically/i)
  assert.doesNotMatch(saved.error,/failed to fetch/i)
})

test('an interrupted syncing operation is retried with its original idempotency key', async () => {
  Object.defineProperty(globalThis,'navigator',{configurable:true,value:{onLine:true}})
  const user='offline-test-user-stale-sync',shop='offline-test-shop-stale-sync'
  const op=await enqueue(user,shop,'expense',{description:'test',amount:12},'offline-test-stale-sync')
  await updateOperation({...op,status:'syncing'})
  const client={
    auth:{getSession:async()=>({data:{session:{user:{id:user}}}})},
    rpc:async(_name,args)=>{assert.equal(args.p_request_key,op.id);throw new TypeError('Failed to fetch')},
    from:()=>({select(){return this},eq(){return this},maybeSingle(){throw new TypeError('Failed to fetch')}}),
  }

  await syncOperations(user,shop,()=>{},true,client)

  const saved=(await listOperations(user,shop)).find(row=>row.id===op.id)
  assert.equal(saved.status,'pending')
  assert.equal(saved.attempts,1)
  assert.equal(saved.syncStartedAt,null)
  assert.match(saved.error,/Could not reach the server/i)
})

test('an ambiguous network failure is marked synced if the idempotency lookup finds the server row', async () => {
  Object.defineProperty(globalThis,'navigator',{configurable:true,value:{onLine:true}})
  const user='offline-test-user-applied',shop='offline-test-shop-applied'
  const op=await enqueue(user,shop,'expense',{description:'test',amount:14},'offline-test-applied')
  const client={
    auth:{getSession:async()=>({data:{session:{user:{id:user}}}})},
    rpc:async()=>{throw new TypeError('Failed to fetch')},
    from:()=>({select(){return this},eq(){return this},maybeSingle:async()=>({data:{id:'server-expense-id'},error:null})}),
  }

  await syncOperations(user,shop,()=>{},true,client)

  const saved=(await listOperations(user,shop)).find(row=>row.id===op.id)
  assert.equal(saved.status,'synced')
  assert.equal(saved.serverId,'server-expense-id')
})

test('offline sync errors are explained without exposing browser fetch wording', () => {
  assert.match(syncErrorMessage(new TypeError('Failed to fetch'),false),/offline.*still saved on this device/i)
})

test('a session refresh fetch failure leaves queued work intact for the next sync', async () => {
  Object.defineProperty(globalThis,'navigator',{configurable:true,value:{onLine:true}})
  const user='offline-test-user-auth-fetch',shop='offline-test-shop-auth-fetch'
  const op=await enqueue(user,shop,'expense',{description:'test',amount:16},'offline-test-auth-fetch')
  const client={auth:{getSession:async()=>{throw new TypeError('Failed to fetch')}}}

  await syncOperations(user,shop,()=>{},true,client)

  const saved=(await listOperations(user,shop)).find(row=>row.id===op.id)
  assert.equal(saved.status,'pending')
  assert.equal(saved.attempts,0)
})
