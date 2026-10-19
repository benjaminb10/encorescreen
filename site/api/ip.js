// POST {id, token, ip} → {host}. Points <ip-with-dashes>.<id>.direct.encorescreen.com to the Mac's local address.
// The Mac's certificate covers *.<id>.direct.encorescreen.com, so a new address needs no new certificate.
import { authorize, privateIPv4, records, createRecord, readJSON, SUB, ZONE } from './_lib.js'

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' })
  const { id, token, ip } = await readJSON(req)
  try {
    if (!privateIPv4(ip)) return res.status(400).json({ error: 'Only local network addresses are allowed' })
    if (!(await authorize(id, token))) return res.status(403).json({ error: 'Not your id' })
    const label = `${ip.replace(/\./g, '-')}.${id}.${SUB}`
    const existing = await records('A', label)
    if (!existing.some((r) => r.content === ip)) await createRecord('A', label, ip)
    res.status(200).json({ host: `${label}.${ZONE}` })
  } catch (e) {
    res.status(500).json({ error: String(e.message || e) })
  }
}
