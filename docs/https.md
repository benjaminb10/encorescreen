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

Already done in the app: TLS listeners, wss in the page, https URL in the QR code (tested end to end with a
temporary certificate on the 2012 iMac). Missing: the domain and the certificate service.
