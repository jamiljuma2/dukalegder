export const money = (value = 0) => new Intl.NumberFormat('en-KE', { style: 'currency', currency: 'KES', maximumFractionDigits: 0 }).format(Number(value) || 0)
export const todayNairobi = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Nairobi' }).format(new Date())
export const nairobiStart = (date = todayNairobi()) => new Date(`${date}T00:00:00+03:00`).toISOString()
export const nairobiEnd = (date = todayNairobi()) => new Date(`${date}T00:00:00+03:00`).getTime() + 86400000
export const shortDate = (value) => new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Nairobi', day: '2-digit', month: '2-digit', year: 'numeric' }).format(new Date(value))
