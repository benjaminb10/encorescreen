// Shared helpers for the certificate service: Porkbun DNS, request checks.
// Each Mac picks a random id and a secret token. The first request stores sha256(token) in a TXT record
// (_owner.<id>.direct.encorescreen.com), so only that Mac can later renew its certificate or move its address.
import crypto from 'node:crypto'

export const ZONE = 'encorescreen.com'
export const SUB = 'direct'

async function porkbun(path, body = {}) {
  const res = await fetch(`https://api.porkbun.com/api/json/v3/${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ apikey: process.env.PORKBUN_API_KEY, secretapikey: process.env.PORKBUN_SECRET_KEY, ...body }),
  })
  const json = await res.json()
  if (json.status !== 'SUCCESS') throw new Error(`porkbun ${path}: ${json.message || res.status}`)
  return json
}

// name is relative to the zone, e.g. "_owner.ab12cd34ef.direct".
export async function records(type, name) {
  return (await porkbun(`dns/retrieveByNameType/${ZONE}/${type}/${name}`)).records || []
}
export async function createRecord(type, name, content) {
  return porkbun(`dns/create/${ZONE}`, { type, name, content, ttl: '600' })
}
export async function deleteRecords(type, name) {
  return porkbun(`dns/deleteByNameType/${ZONE}/${type}/${name}`)
}

export const validId = (id) => typeof id === 'string' && /^[a-z0-9]{10,32}$/.test(id)
export const hash = (s) => crypto.createHash('sha256').update(String(s)).digest('hex')

// Checks the token against the stored owner record, or claims the id on first use.
export async function authorize(id, token) {
  if (!validId(id) || typeof token !== 'string' || token.length < 20) return false
  const owner = await records('TXT', `_owner.${id}.${SUB}`)
  if (owner.length === 0) {
    await createRecord('TXT', `_owner.${id}.${SUB}`, hash(token))
    return true
  }
  return owner.some((r) => r.content.replace(/"/g, '') === hash(token))
}

// Only addresses of a home or office network: public DNS never points to someone else's server.
export function privateIPv4(ip) {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip || '')
  if (!m) return false
  const [a, b] = [Number(m[1]), Number(m[2])]
  if (m.slice(1).some((x) => Number(x) > 255)) return false
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127)
}

export function readJSON(req) {
  if (req.body && typeof req.body === 'object') return Promise.resolve(req.body)
  return new Promise((resolve) => {
    let data = ''
    req.on('data', (c) => (data += c))
    req.on('end', () => { try { resolve(JSON.parse(data || '{}')) } catch { resolve({}) } })
  })
}
