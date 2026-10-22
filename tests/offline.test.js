import 'fake-indexeddb/auto'
import test from 'node:test'
import assert from 'node:assert/strict'
import { cacheSnapshot, clearAccountData, enqueue, listOperations, readSnapshot, updateOperation } from '../src/lib/offline.js'

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
