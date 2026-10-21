import test from 'node:test'
import assert from 'node:assert/strict'
import { getSubscriptionExpiryState } from '../src/lib/subscription.js'

const now = new Date('2026-10-21T09:00:00.000Z')

test('shows reminders exactly 7, 3, and 1 Nairobi calendar days before expiry', () => {
  for (const days of [7, 3, 1]) {
    const expiry = new Date(now.getTime() + days * 24 * 60 * 60 * 1000)
    const state = getSubscriptionExpiryState('starter', expiry, now)
    assert.equal(state.daysRemaining, days)
    assert.equal(state.reminderDays, days)
    assert.equal(state.expired, false)
  }
})

test('uses Nairobi date boundaries and reports expiry today without marking it expired early', () => {
  const beforeLocalMidnight = new Date('2026-10-20T20:59:00.000Z')
  const shortlyAfterLocalMidnight = new Date('2026-10-20T21:01:00.000Z')
  const expiry = new Date('2026-10-28T18:00:00.000Z')
  assert.equal(getSubscriptionExpiryState('plus', expiry, beforeLocalMidnight).daysRemaining, 8)
  assert.equal(getSubscriptionExpiryState('plus', expiry, shortlyAfterLocalMidnight).reminderDays, 7)

  const expiresLaterToday = new Date('2026-10-21T18:00:00.000Z')
  const todayState = getSubscriptionExpiryState('plus', expiresLaterToday, now)
  assert.equal(todayState.expiresToday, true)
  assert.equal(todayState.expired, false)
  assert.equal(todayState.daysRemaining, 0)
})

test('detects elapsed expiry and ignores free plans', () => {
  assert.equal(getSubscriptionExpiryState('starter', '2026-10-20T18:00:00.000Z', now).expired, true)
  assert.equal(getSubscriptionExpiryState('free', '2026-10-28T18:00:00.000Z', now), null)
  assert.equal(getSubscriptionExpiryState('plus', 'not-a-date', now), null)
})

test('an unchanged expiry keeps its reminder; an extended expiry clears it', () => {
  const currentExpiry = '2026-10-28T18:00:00.000Z'
  assert.equal(getSubscriptionExpiryState('starter', currentExpiry, now).reminderDays, 7)
  const renewedExpiry = '2026-11-28T18:00:00.000Z'
  assert.equal(getSubscriptionExpiryState('starter', renewedExpiry, now).reminderDays, null)
})
