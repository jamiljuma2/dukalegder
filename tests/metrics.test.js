import test from 'node:test'
import assert from 'node:assert/strict'
import { customerOutstanding, costOfGoodsSold, grossProfitEstimate, operatingProfitEstimate, productLimit } from '../src/lib/metrics.js'

test('cost of goods sold uses the cost snapshots and sold quantities', () => {
  assert.equal(costOfGoodsSold([{ cost_price: '120.50', quantity: 2 }, { cost_price: 30, quantity: 3 }]), 331)
})

test('gross and operating profit keep COGS separate from operating expenses', () => {
  assert.equal(grossProfitEstimate(1000, 620), 380)
  assert.equal(operatingProfitEstimate(1000, 620, 130), 250)
})

test('customer balance includes partial sale payments and later repayments', () => {
  assert.equal(customerOutstanding([{ total: 500, amount_paid: 100 }, { total: 250, amount_paid: 250 }], [{ amount: 125 }]), 275)
  assert.equal(customerOutstanding([{ total: 100, amount_paid: 100 }], []), 0)
})

test('free plan caps active products at 20; paid plans do not', () => {
  assert.equal(productLimit('free'), 20)
  assert.equal(productLimit('starter'), Infinity)
  assert.equal(productLimit('plus'), Infinity)
})
