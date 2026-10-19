export function costOfGoodsSold(items = []) {
  return items.reduce((total, item) => total + Number(item.cost_price || 0) * Number(item.quantity || 0), 0)
}

export function grossProfitEstimate(revenue, cost) {
  return Number(revenue || 0) - Number(cost || 0)
}

export function operatingProfitEstimate(revenue, cost, expenses) {
  return grossProfitEstimate(revenue, cost) - Number(expenses || 0)
}

export function customerOutstanding(sales = [], repayments = []) {
  const soldOnCredit = sales.reduce((sum, sale) => sum + Math.max(0, Number(sale.total) - Number(sale.amount_paid)), 0)
  const paidBack = repayments.reduce((sum, payment) => sum + Number(payment.amount), 0)
  return Math.max(0, soldOnCredit - paidBack)
}

export function productLimit(plan) {
  return plan === 'free' ? 20 : Number.POSITIVE_INFINITY
}
