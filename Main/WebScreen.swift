// Browser screens: any device with a recent browser (Chrome, Safari) becomes an extra screen, nothing to install.
// The main Mac serves a page on port 7790 and streams over a WebSocket on 7791: the same H.264 frames as the
// native screen (decoded by the device's hardware through WebCodecs) and the same pointer messages.
import AppKit
import CoreImage.CIFilterBuiltins
import Network
import SwiftUI

@available(macOS 14.0, *)
final class WebLink: ScreenLink {
    let conn: NWConnection
    let sendsPointerInline = true
    let localNetworkDenied = false
    var onHello: ((Hello) -> Void)?
    var onClose: (() -> Void)?
    private let q = DispatchQueue(label: "encorescreen.web", qos: .userInteractive)
    private var inflight = 0
    private var closed = false

    init(conn: NWConnection) { self.conn = conn }

    var remoteHost: NWEndpoint.Host? {
        if case let .hostPort(host, _) = conn.endpoint { return host }
        return nil
    }

    // The device's name on the local network (e.g. "imac-de-benjamin"), friendlier than its IP address.
    static func networkName(_ ip: String) -> String? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let a = res else { return nil }
        defer { freeaddrinfo(res) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        let name = String(cString: host).components(separatedBy: ".").first ?? ""
        return name.isEmpty ? nil : name
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.receive()
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: q)
    }

    func stop() { conn.cancel() }

    func sayGoodbye() {
        _ = send(type: Proto.bye, payload: Data())
        q.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.conn.cancel() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        DispatchQueue.main.async { self.onClose?() }
    }

    // The page says hello once, as JSON: {"w": pixels, "h": pixels, "scale": 1 or 2}.
    private func receive() {
        conn.receiveMessage { [weak self] data, ctx, _, err in
            guard let self, err == nil else { self?.conn.cancel(); return }
            if let data, let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .text,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let w = json["w"] as? Int, let h = json["h"] as? Int {
                var hello = Hello(width: w, height: h, sizeMM: .zero, scale: json["scale"] as? Int ?? 1,
                                  deviceID: json["id"] as? String ?? "", deviceName: json["name"] as? String ?? "Browser",
                                  key: json["key"] as? String)
                if let host = self.remoteHost {
                    let ip = "\(host)".replacingOccurrences(of: "%.*", with: "", options: .regularExpression)
                    hello.deviceName += " (\(WebLink.networkName(ip) ?? ip))"
                }
                DispatchQueue.main.async { self.onHello?(hello) }
            }
            self.receive()
        }
    }

    func send(type: UInt8, payload: Data) -> Bool {
        if q.sync(execute: { closed || inflight > 3_000_000 }) { return false }
        var msg = Data(capacity: payload.count + 1)
        msg.append(type)
        msg.append(payload)
        let n = msg.count
        q.sync { inflight += n }
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        conn.send(content: msg, contentContext: ctx, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.q.async { self?.inflight -= n }
        })
        return true
    }
}

@available(macOS 14.0, *)
final class WebScreenServer: ObservableObject {
    static let pagePort: UInt16 = 7790
    static let socketPort: UInt16 = 7791

    @Published private(set) var sessions: [Session] = []
    var onActivity: (() -> Void)?
    var onChange: (() -> Void)?
    var bitrate = 25_000_000
    private var http: NWListener?
    private var socket: NWListener?
    private let q = DispatchQueue(label: "encorescreen.webserver")

    // Secret part of the link (after #, so it never travels in the page request). Without it, no stream.
    @Published private(set) var key: String = WebScreenServer.loadKey()
    private let identity = TLSIdentity.load()

    var url: String {
        if identity != nil, let host = TLSIdentity.hostName { return "https://\(host):\(Self.pagePort)/#k=\(key)" }
        return "http://\(localIPv4() ?? "localhost"):\(Self.pagePort)/#k=\(key)"
    }
    var encrypted: Bool { identity != nil }

    private static func loadKey() -> String {
        if let k = UserDefaults.standard.string(forKey: "webKey") { return k }
        return newKey()
    }

    @discardableResult
    private static func newKey() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let k = String(bytes.map { alphabet[Int($0) % alphabet.count] })
        UserDefaults.standard.set(k, forKey: "webKey")
        return k
    }

    // New link: the old QR code stops working and connected browsers are disconnected.
    func renewKey() {
        key = Self.newKey()
        stopAll()
    }

    func start() {
        if let l = try? NWListener(using: TLSIdentity.parameters(identity), on: NWEndpoint.Port(rawValue: Self.pagePort)!) {
            l.newConnectionHandler = { [weak self] c in self?.servePage(c) }
            l.start(queue: q)
            http = l
        }
        let params = TLSIdentity.parameters(identity)
        params.serviceClass = .interactiveVideo
        let ws = NWProtocolWebSocket.Options()
        ws.maximumMessageSize = 16 << 20
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        if let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.socketPort)!) {
            l.newConnectionHandler = { [weak self] c in DispatchQueue.main.async { self?.accept(c) } }
            l.start(queue: q)
            socket = l
        }
    }

    func stopAll() { sessions.forEach { $0.stop() } }

    private func accept(_ c: NWConnection) {
        var who = "Browser"
        if case let .hostPort(host, _) = c.endpoint { who = "Browser \(host)".replacingOccurrences(of: "%.*", with: "", options: .regularExpression) }
        let s = Session(name: who, link: WebLink(conn: c), bitrate: bitrate)
        // Wrong or missing secret: refused without asking. Right secret: the user allows the device once.
        s.approve = { [weak self] hello, done in
            guard let self, let k = hello.key, !k.isEmpty, k == self.key else { done(false); return }
            ApprovedDevices.ask(hello, completion: done)
        }
        s.onActivity = { [weak self] in self?.onActivity?() }
        s.onStateChange = { [weak self] in self?.onChange?() }
        s.onEnd = { [weak self, weak s] _ in
            guard let self, let s else { return }
            self.sessions.removeAll { $0 === s }
            self.onChange?()
        }
        sessions.append(s)
        s.start()
        onChange?()
    }

    private func servePage(_ c: NWConnection) {
        c.start(queue: q)
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { _, _, _, _ in
            let body = Data(WebPage.html.utf8)
            var head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n"
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

// Window with the QR code to open on the device that will become the screen.
@available(macOS 14.0, *)
struct WebScreenQRView: View {
    @ObservedObject var server: WebScreenServer
    private var url: String { server.url }

    var body: some View {
        VStack(spacing: 14) {
            Text("Use any device as a screen").font(.system(size: 20, weight: .bold, design: .rounded))
            Text("On a tablet, phone or another computer on the same Wi-Fi, scan this code or open the link in Chrome or Safari.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let img = qr(url) {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: 220, height: 220)
                    .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(.white))
            }
            Text(url).font(.system(size: 12, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                .multilineTextAlignment(.center)
            Text("Then tap the page once to go full screen. You'll be asked to allow the device on this Mac.")
                .font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Label(server.encrypted ? "Encrypted connection" : "Not encrypted yet: use it on a Wi-Fi you trust",
                  systemImage: server.encrypted ? "lock.fill" : "lock.open")
                .font(.system(size: 11)).foregroundStyle(server.encrypted ? .green : .orange)
            Button("New Link") { server.renewKey() }
                .help("The current link and QR code stop working, and connected devices are disconnected.")
        }
        .padding(28)
        .frame(width: 380)
    }

    private func qr(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height))
    }
}

enum WebPage {
    static let html = #"""
<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<title>Encore Screen</title>
<style>
html,body{margin:0;height:100%;background:#000;overflow:hidden}
canvas{position:fixed;inset:0;width:100%;height:100%;object-fit:contain;cursor:none}
#p{position:fixed;left:0;top:0;pointer-events:none;display:none;will-change:transform}
#msg{position:fixed;inset:0;display:flex;flex-direction:column;gap:10px;align-items:center;justify-content:center;
 color:#fff;font:600 20px -apple-system,system-ui,sans-serif;text-align:center;padding:24px;
 background:linear-gradient(135deg,#FFB347,#FF6B6B);cursor:pointer}
#msg small{font-weight:400;font-size:14px;opacity:.9}
</style></head>
<body><canvas id="v"></canvas><img id="p"><div id="msg">Tap to start<small>This screen becomes your Mac's extra screen.</small></div>
<script>
const msg=document.getElementById('msg'),cv=document.getElementById('v'),ctx=cv.getContext('2d'),ptr=document.getElementById('p');
let ws,dec,cfg='',needKey=true,vw=0,vh=0,hot=[0,0],ps=[0,0],ts=0,denied=false;
const key=(location.hash.match(/k=([a-z0-9]+)/)||[])[1]||'';
let id=localStorage.getItem('es-id');if(!id){id=crypto.getRandomValues(new Uint32Array(4)).join('-');localStorage.setItem('es-id',id)}
const ua=navigator.userAgent,name=/iPad/.test(ua)||(/Macintosh/.test(ua)&&navigator.maxTouchPoints>1)?'iPad':/iPhone/.test(ua)?'iPhone':
 /Android/.test(ua)?'Android device':/Windows/.test(ua)?'Windows PC':/CrOS/.test(ua)?'Chromebook':/Macintosh/.test(ua)?'Mac':'Browser';
function say(t,s){msg.innerHTML=t+(s?'<small>'+s+'</small>':'');msg.style.display='flex'}
if(!key) say('Scan the QR code on your Mac','Open Encore Screen\'s menu on your Mac, then \u201CAdd Any Device with a Browser\u201D.');
else if(!('VideoDecoder' in window)) say('This browser can\'t show the screen here','Use a recent Chrome or Safari. On this page, video decoding needs a secure connection.');
msg.onclick=()=>{if(!key||!('VideoDecoder' in window))return;denied=false;document.documentElement.requestFullscreen?.().catch(()=>{});connect()};
if(location.search.includes('auto')&&key&&('VideoDecoder' in window))connect();
function connect(){
 msg.style.display='none';
 ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.hostname+':7791');ws.binaryType='arraybuffer';
 ws.onopen=()=>{const d=window.devicePixelRatio||1;
  ws.send(JSON.stringify({w:Math.round(screen.width*d),h:Math.round(screen.height*d),scale:d>=1.5?2:1,key,id,name}));
  say('Waiting for your Mac to allow this '+name+'…','Click \u201CAllow\u201D on your Mac.')};
 ws.onclose=()=>{cfg='';needKey=true;if(denied){say('Not allowed','This link is out of date, or the device was refused on the Mac. Scan the QR code again.');return}
  say('Waiting for your Mac…','Reconnecting');setTimeout(connect,2000)};
 ws.onmessage=e=>{const b=new Uint8Array(e.data),t=b[0],p=b.subarray(1);
  if(t===1)configure(p);else if(t===2)frame(p);else if(t===6)move(p);else if(t===7)shape(p);else if(t===4)ws.close();else if(t===8){denied=true;ws.close()}};
}
function configure(p){
 const sl=(p[0]<<8)|p[1],sps=p.subarray(2,2+sl),o=2+sl,pl=(p[o]<<8)|p[o+1],pps=p.subarray(o+2,o+2+pl);
 const key=Array.from(p).join(',');if(key===cfg&&dec&&dec.state==='configured')return;cfg=key;
 const a=new Uint8Array(11+sl+pl);a.set([1,sps[1],sps[2],sps[3],0xff,0xe1,sl>>8,sl&255]);a.set(sps,8);
 a.set([1,pl>>8,pl&255],8+sl);a.set(pps,11+sl);
 const codec='avc1.'+[sps[1],sps[2],sps[3]].map(x=>x.toString(16).padStart(2,'0')).join('');
 if(!dec||dec.state==='closed')dec=new VideoDecoder({output:draw,error:e=>{console.log(e);dec=null;cfg='';needKey=true}});
 dec.configure({codec,description:a,optimizeForLatency:true,hardwareAcceleration:'prefer-hardware'});needKey=true;
}
function isKey(p){let i=0;while(i+4<p.length){const n=((p[i]<<24)|(p[i+1]<<16)|(p[i+2]<<8)|p[i+3])>>>0;if((p[i+4]&31)===5)return true;i+=4+n}return false}
function frame(p){if(!dec||dec.state!=='configured')return;const k=isKey(p);if(needKey&&!k)return;needKey=false;
 dec.decode(new EncodedVideoChunk({type:k?'key':'delta',timestamp:(ts+=16667),data:p}))}
function draw(f){msg.style.display='none';if(cv.width!==f.displayWidth||cv.height!==f.displayHeight){cv.width=vw=f.displayWidth;cv.height=vh=f.displayHeight}
 ctx.drawImage(f,0,0);f.close()}
function move(p){if(!vw)return;const x=((p[2]<<8)|p[3])/65535,y=((p[4]<<8)|p[5])/65535,vis=p[6]===1;
 const W=innerWidth,H=innerHeight,k=Math.min(W/vw,H/vh),rx=(W-vw*k)/2,ry=(H-vh*k)/2;
 ptr.style.display=vis&&ptr.src?'block':'none';ptr.style.width=ps[0]*k+'px';ptr.style.height=ps[1]*k+'px';
 ptr.style.transform='translate('+(rx+x*vw*k-hot[0]*k)+'px,'+(ry+y*vh*k-hot[1]*k)+'px)'}
function shape(p){const v=i=>((p[i]<<8)|p[i+1])/16;hot=[v(0),v(2)];ps=[v(4),v(6)];
 if(ptr.src)URL.revokeObjectURL(ptr.src);ptr.src=URL.createObjectURL(new Blob([p.slice(8)],{type:'image/png'}))}
</script></body></html>
"""#
}
