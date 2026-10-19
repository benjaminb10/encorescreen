// HTTPS without any setup: each Mac gets its own name, e.g. 192-168-1-15.k3x9q2m7pa.direct.encorescreen.com,
// pointing to its local address, and a real Let's Encrypt certificate for *.k3x9q2m7pa.direct.encorescreen.com.
// The key is made here and never leaves the Mac: the service (encorescreen.com/api) only sees a certificate request.
// Renewed when less than 30 days are left; a new local address only needs a new name, not a new certificate.
import Foundation

@available(macOS 14.0, *)
enum DirectCertificate {
    private static let api = "https://encorescreen.com/api/"
    private static let q = DispatchQueue(label: "encorescreen.certificate")
    private static var running = false

    private static var folder: URL { TLSIdentity.folder }
    private static func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    // Random name for this Mac and the secret that proves it owns it.
    private static var id: String { stored("direct-id.txt") { random(12, "abcdefghijkmnpqrstuvwxyz23456789") } }
    private static var token: String { stored("direct-token.txt") { random(40, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") } }
    private static var domain: String { "*.\(id).direct.encorescreen.com" }

    // Calls done(true) on the main queue when the certificate or the name changed (the server must reload them).
    static func refresh(done: @escaping (Bool) -> Void) {
        q.async {
            guard !running else { return }
            running = true
            defer { running = false }
            var changed = false
            do {
                if needsCertificate() { try issue(); changed = true }
                if try updateName() { changed = true }
            } catch {
                log("certificate: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { done(changed) }
        }
    }

    private static func needsCertificate() -> Bool {
        let cert = file("tls-cert.pem")
        guard FileManager.default.fileExists(atPath: TLSIdentity.p12.path), FileManager.default.fileExists(atPath: cert.path),
              let text = try? openssl(["x509", "-in", cert.path, "-noout", "-subject", "-text"]),
              text.contains(domain), text.contains("rsaEncryption") else { return true }
        // Exit status 0 when still valid in 30 days.
        return (try? openssl(["x509", "-in", cert.path, "-noout", "-checkend", "2592000"])) == nil
    }

    private static func issue() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = file("tls-key.pem"), csr = file("tls-csr.pem")
        // RSA: its chain ends at ISRG Root X1, trusted by older iPhones, Android phones and Macs (ECDSA ends at the newer X2).
        try openssl(["genrsa", "-out", key.path, "2048"])
        chmod(key.path, 0o600)
        try openssl(["req", "-new", "-key", key.path, "-subj", "/CN=\(domain)", "-addext", "subjectAltName=DNS:\(domain)", "-out", csr.path])
        let reply = try post("cert", ["id": id, "token": token, "csr": try String(contentsOf: csr)], timeout: 120)
        guard let pem = reply["cert"] as? String else { throw failure(reply["error"] as? String ?? "no certificate") }
        let cert = file("tls-cert.pem")
        try pem.write(to: cert, atomically: true, encoding: .utf8)
        let password = random(24, "abcdefghijklmnopqrstuvwxyz0123456789")
        try openssl(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-name", "Encore Screen",
                     "-out", TLSIdentity.p12.path, "-passout", "pass:\(password)"])
        try password.write(to: file("tls-password.txt"), atomically: true, encoding: .utf8)
        chmod(TLSIdentity.p12.path, 0o600); chmod(file("tls-password.txt").path, 0o600)
        try? FileManager.default.removeItem(at: csr)
        log("certificate: issued for \(domain)")
    }

    // Points <ip>.<id>.direct.encorescreen.com to this Mac's current address. True when the name changed.
    private static func updateName() throws -> Bool {
        guard let ip = localIPv4() else { return false }
        let host = "\(ip.replacingOccurrences(of: ".", with: "-")).\(id).direct.encorescreen.com"
        if TLSIdentity.hostName == host { return false }
        let reply = try post("ip", ["id": id, "token": token, "ip": ip], timeout: 30)
        guard let h = reply["host"] as? String, h == host else { throw failure(reply["error"] as? String ?? "no name") }
        try host.write(to: file("tls-host.txt"), atomically: true, encoding: .utf8)
        log("certificate: name \(host)")
        return true
    }

    // MARK: helpers

    private static func stored(_ name: String, _ make: () -> String) -> String {
        if let s = try? String(contentsOf: file(name)).trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        let s = make()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? s.write(to: file(name), atomically: true, encoding: .utf8)
        chmod(file(name).path, 0o600)
        return s
    }

    private static func random(_ n: Int, _ chars: String) -> String {
        let alphabet = Array(chars)
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static func failure(_ s: String) -> NSError { NSError(domain: "EncoreScreen", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

    @discardableResult
    private static func openssl(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw failure("openssl \(args.first ?? "") failed") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func post(_ path: String, _ body: [String: String], timeout: TimeInterval) throws -> [String: Any] {
        var req = URLRequest(url: URL(string: api + path)!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]?, err: Error?
        URLSession.shared.dataTask(with: req) { data, _, error in
            err = error
            result = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            sem.signal()
        }.resume()
        sem.wait()
        if let err { throw err }
        guard let result else { throw failure("bad reply from \(path)") }
        return result
    }
}
