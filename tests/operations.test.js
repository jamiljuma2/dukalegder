import test from 'node:test'
import assert from 'node:assert/strict'
import { calculateCashBalance, calculateRestockSuggestion, expiryState } from '../src/lib/operations.js'

test('cash reconciliation includes only the supplied cash movements', () => {
  const balanced = calculateCashBalance({ openingCash: 1000, cashSales: 2500, cashExpenses: 400, cashWithdrawals: 300, closingCash: 2800 })
  assert.equal(balanced.expectedClosingCash, 2800)
  assert.equal(balanced.difference, 0)
  assert.equal(balanced.status, 'balanced')
  assert.equal(calculateCashBalance({ openingCash: 0, cashSales: 100, cashExpenses: 0, cashWithdrawals: 0, closingCash: 80 }).status, 'shortage')
  assert.equal(calculateCashBalance({ openingCash: 0, cashSales: 100, cashExpenses: 0, cashWithdrawals: 0, closingCash: 120 }).status, 'surplus')
})

test('restock recommendation accounts for demand, minimum and supplier lead time', () => {
  const suggestion = calculateRestockSuggestion({ currentStock: 8, minimumStock: 5, averageDailySales: 2, leadTimeDays: 3, coverageDays: 10 })
  assert.equal(suggestion.daysUntilStockout, 4)
  assert.equal(suggestion.recommendedQuantity, 12)
  assert.equal(suggestion.reorderInDays, 1)
  const minimumOnly = calculateRestockSuggestion({ currentStock: 2, minimumStock: 5, averageDailySales: 0, leadTimeDays: 4, coverageDays: 14 })
  assert.equal(minimumOnly.recommendedQuantity, 3)
  assert.equal(minimumOnly.daysUntilStockout, null)
})

test('expiry helper distinguishes expired, warning window and safe batches', () => {
  assert.equal(expiryState('2026-10-20', 7, '2026-10-21').status, 'expired')
  assert.equal(expiryState('2026-10-26', 7, '2026-10-21').status, 'expiring')
  assert.equal(expiryState('2026-12-01', 7, '2026-10-21').status, 'ok')
})
