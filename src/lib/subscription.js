const DAY_MS = 24 * 60 * 60 * 1000
const REMINDER_DAYS = new Set([7, 3, 1])

function localCalendarDay(value, timeZone) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(value)
  const dateParts = Object.fromEntries(parts.filter(part => part.type !== 'literal').map(part => [part.type, Number(part.value)]))
  return Date.UTC(dateParts.year, dateParts.month - 1, dateParts.day) / DAY_MS
}

export function getSubscriptionExpiryState(plan, periodEndsAt, now = new Date(), timeZone = 'Africa/Nairobi') {
  if (!periodEndsAt || !plan || plan === 'free') return null
  const expiry = new Date(periodEndsAt)
  const currentTime = new Date(now)
  if (!Number.isFinite(expiry.getTime()) || !Number.isFinite(currentTime.getTime())) return null

  const expired = expiry.getTime() <= currentTime.getTime()
  const calendarDaysRemaining = Math.max(0, localCalendarDay(expiry, timeZone) - localCalendarDay(currentTime, timeZone))
  return {
    expired,
    expiresToday: !expired && calendarDaysRemaining === 0,
    daysRemaining: expired ? 0 : calendarDaysRemaining,
    reminderDays: !expired && REMINDER_DAYS.has(calendarDaysRemaining) ? calendarDaysRemaining : null,
    expiry,
  }
}
