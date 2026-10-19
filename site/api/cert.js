// POST {id, token, csr} → {cert}. Issues a Let's Encrypt certificate for *.<id>.direct.encorescreen.com.
// The Mac makes its own key and sends only a certificate request (CSR): the private key never leaves the Mac.
// Ownership of the name is proven to Let's Encrypt with a DNS-01 challenge written through Porkbun.
import acme from 'acme-client'
import { authorize, records, createRecord, deleteRecords, readJSON, SUB, ZONE } from './_lib.js'

export const config = { maxDuration: 60 }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// Waits until all of Porkbun's name servers answer with the challenge value (usually a few seconds).
async function waitForTXT(fqdn, value) {
  const { Resolver } = await import('node:dns/promises')
  const servers = ['curitiba.ns.porkbun.com', 'fortaleza.ns.porkbun.com', 'maceio.ns.porkbun.com', 'salvador.ns.porkbun.com']
  const ips = (await Promise.all(servers.map((s) => new Resolver().resolve4(s).catch(() => [])))).flat()
  for (let i = 0; i < 20; i++) {
    const answers = await Promise.all(ips.map(async (ip) => {
      const r = new Resolver(); r.setServers([ip])
      try { return (await r.resolveTxt(fqdn)).flat().includes(value) } catch { return false }
    }))
    if (answers.length && answers.every(Boolean)) return
    await sleep(2000)
  }
  throw new Error('challenge record not visible in time')
}

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' })
  const { id, token, csr } = await readJSON(req)
  const challengeName = `_acme-challenge.${id}.${SUB}`
  try {
    if (typeof csr !== 'string' || !csr.includes('CERTIFICATE REQUEST')) return res.status(400).json({ error: 'Missing CSR' })
    if (!(await authorize(id, token))) return res.status(403).json({ error: 'Not your id' })

    const domain = `*.${id}.${SUB}.${ZONE}`
    const info = acme.crypto.readCsrDomains(csr)
    if (info.commonName !== domain && !(info.altNames || []).includes(domain)) return res.status(400).json({ error: `CSR must be for ${domain}` })

    const staging = req.query?.staging === '1'
    const client = new acme.Client({
      directoryUrl: staging ? acme.directory.letsencrypt.staging : acme.directory.letsencrypt.production,
      accountKey: process.env.ACME_ACCOUNT_KEY.replace(/\\n/g, '\n'),
    })
    await client.createAccount({ termsOfServiceAgreed: true, contact: ['mailto:hello@encorescreen.com'] })

    const order = await client.createOrder({ identifiers: [{ type: 'dns', value: domain }] })
    const [authz] = await client.getAuthorizations(order)
    if (authz.status !== 'valid') {
      const challenge = authz.challenges.find((c) => c.type === 'dns-01')
      const value = await client.getChallengeKeyAuthorization(challenge)
      await deleteRecords('TXT', challengeName).catch(() => {})
      await createRecord('TXT', challengeName, value)
      await waitForTXT(`${challengeName}.${ZONE}`, value)
      await client.completeChallenge(challenge)
      await client.waitForValidStatus(challenge)
    }
    // Signing can take a moment: wait for the order to be valid before downloading the certificate.
    let done = await client.finalizeOrder(order, csr)
    if (done.status !== 'valid') done = await client.waitForValidStatus(done)
    const cert = await client.getCertificate(done)
    res.status(200).json({ cert })
  } catch (e) {
    res.status(500).json({ error: String(e.message || e) })
  } finally {
    await deleteRecords("TXT", challengeName).catch(() => {})
  }
}
