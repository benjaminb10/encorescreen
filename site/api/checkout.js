// POST {amount} (euros, 1 to 500) → {clientSecret, publishableKey}: a Stripe Checkout session shown inside the
// site's support dialog (Embedded Checkout). Tax included in the amount, PDF invoice sent after payment.
// Needs STRIPE_SECRET_KEY (restricted key: Checkout Sessions write) and STRIPE_PUBLISHABLE_KEY.
import { readJSON } from './_lib.js'

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' })
  if (!process.env.STRIPE_SECRET_KEY || !process.env.STRIPE_PUBLISHABLE_KEY) return res.status(503).json({ error: 'not configured' })
  const { amount } = await readJSON(req)
  const euros = Math.round(Number(amount) * 100) / 100
  if (!(euros >= 1 && euros <= 500)) return res.status(400).json({ error: 'Amount must be between €1 and €500' })

  const form = new URLSearchParams({
    ui_mode: 'embedded_page',
    mode: 'payment',
    return_url: 'https://encorescreen.com/?thanks=1',
    'line_items[0][quantity]': '1',
    'line_items[0][price_data][currency]': 'eur',
    'line_items[0][price_data][unit_amount]': String(Math.round(euros * 100)),
    'line_items[0][price_data][tax_behavior]': 'inclusive',
    'line_items[0][price_data][product_data][name]': 'Support Encore Screen',
    'line_items[0][price_data][product_data][tax_code]': 'txcd_10202000',
    'invoice_creation[enabled]': 'true',
    submit_type: 'pay',
  })
  if (process.env.STRIPE_AUTOMATIC_TAX === '1') form.set('automatic_tax[enabled]', 'true')

  const r = await fetch('https://api.stripe.com/v1/checkout/sessions', {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}`, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form,
  })
  const session = await r.json()
  if (!r.ok) { console.error('checkout', session.error); return res.status(502).json({ error: 'Payment is unavailable right now' }) }
  res.status(200).json({ clientSecret: session.client_secret, publishableKey: process.env.STRIPE_PUBLISHABLE_KEY })
}
