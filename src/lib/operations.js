export function calculateCashBalance({ openingCash = 0, cashSales = 0, cashExpenses = 0, cashWithdrawals = 0, closingCash = 0 }) {
  const expectedClosingCash = Number(openingCash) + Number(cashSales) - Number(cashExpenses) - Number(cashWithdrawals)
  const difference = Number(closingCash) - expectedClosingCash
  return { expectedClosingCash, difference, status: difference < 0 ? 'shortage' : difference > 0 ? 'surplus' : 'balanced' }
}

export function calculateRestockSuggestion({ currentStock, minimumStock, averageDailySales, leadTimeDays, coverageDays }) {
  const stock = Number(currentStock) || 0
  const minimum = Number(minimumStock) || 0
  const daily = Number(averageDailySales) || 0
  const lead = Number(leadTimeDays) || 0
  const coverage = Number(coverageDays) || 0
  const daysUntilStockout = daily > 0 ? stock / daily : null
  const recommendedQuantity = Math.max(0, Math.ceil(daily * coverage) - stock, stock <= minimum ? minimum - stock : 0)
  return { daysUntilStockout, recommendedQuantity, needsReorder: recommendedQuantity > 0,
    reorderInDays: Math.max(0, Math.floor(daysUntilStockout ?? 0) - lead) }
}

export function expiryState(expiryDate, warningDays = 30, today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Nairobi' }).format(new Date())) {
  const daysRemaining = Math.ceil((Date.parse(`${expiryDate}T00:00:00Z`) - Date.parse(`${today}T00:00:00Z`)) / 86400000)
  return { daysRemaining, status: daysRemaining < 0 ? 'expired' : daysRemaining <= Number(warningDays) ? 'expiring' : 'ok' }
}
