# HTTPS for browser screens

Browsers only decode video in hardware (WebCodecs) on secure pages, and the stream should be encrypted
anyway. Each Mac therefore needs a real certificate for a name that points to its local IP address.

## Plan (same approach as Plex's `*.plex.direct`)

1. **Domain**: `encorescreen.com`, with a wildcard DNS zone `*.direct.encorescreen.com`.
2. **DNS**: `192-168-1-15.<macid>.direct.encorescreen.com` resolves to `192.168.1.15`
   (a tiny DNS responder, or a provider that supports this pattern).
3. **Certificates**: a small service (e.g. Cloudflare Worker) receives a CSR from the Mac, proves control
   with an ACME DNS-01 challenge on `*.<macid>.direct.encorescreen.com`, and returns a Let's Encrypt
   certificate. The private key never leaves the Mac. Renewed every 60 days.
4. **App**: stores `tls.p12`, `tls-password.txt` and `tls-host.txt` in
   `~/Library/Application Support/Encore Screen/`. `TLSIdentity` picks them up: the page and the
   WebSocket switch to HTTPS / WSS and the QR code shows the https link.

## Status: live

- Service: `site/api/cert.js` and `site/api/ip.js`, deployed with the site on Vercel (encorescreen.com/api).
  Env vars: `PORKBUN_API_KEY`, `PORKBUN_SECRET_KEY`, `ACME_ACCOUNT_KEY`. `?staging=1` uses Let's Encrypt staging.
- Ownership: the first request stores sha256(token) in `_owner.<id>.direct` (TXT). Only private IPv4 addresses
  are accepted for names.
- App: `Main/Certificate.swift` (runs at launch and every 15 min). RSA 2048 keys, so the chain ends at
  ISRG Root X1 (older iPhones, Android, Catalina). The full chain is sent by `TLSIdentity.load()`.
- Abuse protection: a Vercel firewall rule allows 10 requests per hour per IP on `/api/cert` and `/api/ip`
  (the Hobby plan allows one rate limit rule).
- Limit to watch: Let's Encrypt allows 50 new certificates per week for encorescreen.com (renewals don't count).
  If the app takes off: ask Let's Encrypt for a rate limit increase, or add `direct.encorescreen.com` to the
  Public Suffix List.
