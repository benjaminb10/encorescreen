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
    var onInput: (([String: Any]) -> Void)?
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
        // Apple devices often answer with a random private name (a UUID): not useful, fall back to the IP.
        if name.isEmpty || name.range(of: "^[0-9a-fA-F-]{30,}$", options: .regularExpression) != nil { return nil }
        return name
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
               json["t"] != nil {
                debug("ws input \(json["t"] ?? "")")
                self.onInput?(json)
            } else if let data, let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
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
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { req, _, _, _ in
            let path = req.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: " ").dropFirst().first ?? "/"
            debug("http \(path) from \(c.endpoint)")
            let isVersion = path.hasPrefix("/version")
            let body = Data((isVersion ? WebPage.version : WebPage.page).utf8)
            var head = "HTTP/1.1 200 OK\r\nContent-Type: \(isVersion ? "text/plain" : "text/html"); charset=utf-8\r\nCache-Control: no-store\r\n"
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
    // The page carries its own version; when the Mac serves a newer one, an open page reloads itself
    // (handy for the home-screen web app on iPhone, which otherwise keeps the old page in memory).
    static let version = String(UInt32(truncatingIfNeeded: html.hashValueStable), radix: 36)
    static var page: String { html.replacingOccurrences(of: "__VERSION__", with: version) }
    static let html = #"""
<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Encore Screen">
<meta name="theme-color" content="#000000">
<title>Encore Screen</title>
<style>
html,body{margin:0;height:100%;background:#000;overflow:hidden}
canvas{position:fixed;inset:0;width:100%;height:100%;object-fit:contain;cursor:none}
#p{position:fixed;left:0;top:0;pointer-events:none;display:none;will-change:transform}
#msg{position:fixed;inset:0;display:flex;flex-direction:column;gap:10px;align-items:center;justify-content:center;
 color:#fff;font:600 20px -apple-system,system-ui,sans-serif;text-align:center;padding:24px;
 background:linear-gradient(135deg,#FFB347,#FF6B6B);cursor:pointer}
#msg small{font-weight:400;font-size:14px;opacity:.9}
#kb{position:fixed;right:max(16px,env(safe-area-inset-right));bottom:max(16px,env(safe-area-inset-bottom));width:56px;height:56px;
 border-radius:28px;border:0;background:linear-gradient(135deg,#FFB347,#FF6B6B);color:#fff;font-size:26px;display:none;
 box-shadow:0 6px 18px rgba(0,0,0,.35);z-index:5}
#ti{position:fixed;left:0;bottom:0;width:1px;height:1px;opacity:0;font-size:16px;border:0;padding:0}
#tip{font-weight:400;font-size:13px;opacity:.85;max-width:320px;margin-top:8px}
</style></head>
<body><canvas id="v"></canvas><img id="p"><button id="kb" aria-label="Keyboard">⌨︎</button>
<input id="ti" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"><div id="msg"></div>
<script>
const msg=document.getElementById('msg'),cv=document.getElementById('v'),ctx=cv.getContext('2d'),ptr=document.getElementById('p');
let sent=null,resizeTimer;
// Rotation: reconnect so the Mac recreates the extra screen in the new orientation. Only a real orientation change
// counts: on phones the visible height changes all the time (toolbars showing and hiding), which must not reconnect.
const landscape=()=>innerWidth>innerHeight;
addEventListener('resize',()=>{clearTimeout(resizeTimer);resizeTimer=setTimeout(()=>{
 if(!sent||!ws||ws.readyState!==1)return;if(landscape()===(sent[0]>sent[1]))return;
 ws.onclose=null;ws.close();cfg='';needKey=true;vw=0;connect()},800)});
let ws,dec,cfg='',needKey=true,vw=0,vh=0,hot=[0,0],ps=[0,0],ts=0,denied=false;
const key=(location.hash.match(/k=([a-z0-9]+)/)||[])[1]||'';
let id=localStorage.getItem('es-id');if(!id){id=crypto.getRandomValues(new Uint32Array(4)).join('-');localStorage.setItem('es-id',id)}
const ua=navigator.userAgent,name=/iPad/.test(ua)||(/Macintosh/.test(ua)&&navigator.maxTouchPoints>1)?'iPad':/iPhone/.test(ua)?'iPhone':
 /Android/.test(ua)?'Android device':/Windows/.test(ua)?'Windows PC':/CrOS/.test(ua)?'Chromebook':/Macintosh/.test(ua)?'Mac':'Browser';
const standalone=navigator.standalone||matchMedia('(display-mode: standalone)').matches||matchMedia('(display-mode: fullscreen)').matches;
const tip=(/iPhone|iPod/.test(navigator.userAgent)&&!standalone)?'<div id="tip">For a true full screen: tap Share, then \u201CAdd to Home Screen\u201D, and open Encore Screen from there.</div>':'';
function say(t,s){msg.innerHTML=t+(s?'<small>'+s+'</small>':'')+tip;msg.style.display='flex'}
say('Tap to start','This screen becomes your Mac\'s extra screen.');
if(!key) say('Scan the QR code on your Mac','Open Encore Screen\'s menu on your Mac, then \u201CAdd Any Device with a Browser\u201D.');
else if(!('VideoDecoder' in window)) say('This browser can\'t show the screen here','Use a recent Chrome or Safari. On this page, video decoding needs a secure connection.');
msg.onclick=()=>{if(!key||!('VideoDecoder' in window))return;denied=false;document.documentElement.requestFullscreen?.().catch(()=>{});connect()};
// Auto-start (kiosk use): after the whole script has run, so every variable below is initialized.
if(location.search.includes('auto')&&key&&('VideoDecoder' in window))setTimeout(connect,0);
const VERSION='__VERSION__';
// The Mac sends a heartbeat every second while streaming. Four seconds of silence means the connection died
// without a proper close (the Mac app restarted, Wi-Fi dropped): reconnect instead of staying frozen.
let lastMsg=0;
setInterval(()=>{if(ws&&ws.readyState===1&&vw&&Date.now()-lastMsg>4000){lastMsg=Date.now();ws.close()}},1000);
function connect(){
 lastMsg=Date.now();vw=0;
 fetch('/version',{cache:'no-store'}).then(r=>r.text()).then(v=>{if(v&&v!==VERSION)location.replace(location.pathname+'?auto=1'+location.hash)}).catch(()=>{});
 msg.style.display='none';
 ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.hostname+':7791');ws.binaryType='arraybuffer';
 ws.onopen=()=>{const d=window.devicePixelRatio||1;
  sent=[innerWidth,innerHeight];
  ws.send(JSON.stringify({w:Math.round(innerWidth*d),h:Math.round(innerHeight*d),scale:d>=1.5?2:1,key,id,name}));
  say('Waiting for your Mac to allow this '+name+'…','Click \u201CAllow\u201D on your Mac.')};
 ws.onclose=()=>{cfg='';needKey=true;if(denied){say('Not allowed','This link is out of date, or the device was refused on the Mac. Scan the QR code again.');return}
  say('Waiting for your Mac…','Reconnecting');setTimeout(connect,2000)};
 ws.onmessage=e=>{lastMsg=Date.now();const b=new Uint8Array(e.data),t=b[0],p=b.subarray(1);
  if(t===1)configure(p);else if(t===2)frame(p);else if(t===6)move(p);else if(t===7)shape(p);else if(t===4)ws.close();else if(t===8){denied=true;ws.close()}
  else if(t===9){try{const f=JSON.parse(new TextDecoder().decode(p));kb.style.display=f.on?'block':'none';if(!f.on)ti.blur()}catch(_){}}};
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
// Touch control: tap = click, double tap = double click, long press = right click,
// one finger drag = scroll, pinch = zoom. Positions are sent as 0…1 on the extra screen.
cv.style.touchAction='none';
let touch=null,lastTap=0,pinch=null,longTimer=null;
function pos(t){const W=innerWidth,H=innerHeight,k=Math.min(W/vw,H/vh),rx=(W-vw*k)/2,ry=(H-vh*k)/2;
 return {x:Math.min(1,Math.max(0,(t.clientX-rx)/(vw*k))),y:Math.min(1,Math.max(0,(t.clientY-ry)/(vh*k))),k}}
function sendInput(m){if(ws&&ws.readyState===1&&vw)ws.send(JSON.stringify(m))}
cv.addEventListener('touchstart',e=>{e.preventDefault();
 if(e.touches.length===2){clearTimeout(longTimer);touch=null;const[a,b]=e.touches;
  pinch={d:Math.hypot(a.clientX-b.clientX,a.clientY-b.clientY),mid:{clientX:(a.clientX+b.clientX)/2,clientY:(a.clientY+b.clientY)/2}};return}
 const t=e.touches[0];touch={x0:t.clientX,y0:t.clientY,x:t.clientX,y:t.clientY,t0:Date.now(),moved:false,long:false};
 longTimer=setTimeout(()=>{if(touch&&!touch.moved){touch.long=true;const p=pos(t);sendInput({t:'right',x:p.x,y:p.y})}},550)},{passive:false});
cv.addEventListener('touchmove',e=>{e.preventDefault();
 if(pinch&&e.touches.length===2){const[a,b]=e.touches,d=Math.hypot(a.clientX-b.clientX,a.clientY-b.clientY),p=pos(pinch.mid);
  if(d/pinch.d>1.25){sendInput({t:'zoom',dir:'in',x:p.x,y:p.y});pinch.d=d}else if(d/pinch.d<0.8){sendInput({t:'zoom',dir:'out',x:p.x,y:p.y});pinch.d=d}return}
 if(!touch)return;const t=e.touches[0],dx=t.clientX-touch.x,dy=t.clientY-touch.y;
 if(Math.hypot(t.clientX-touch.x0,t.clientY-touch.y0)>8){touch.moved=true;clearTimeout(longTimer)}
 if(touch.moved){const p=pos(t);sendInput({t:'scroll',x:p.x,y:p.y,dx:dx/p.k,dy:dy/p.k});touch.x=t.clientX;touch.y=t.clientY}},{passive:false});
cv.addEventListener('touchend',e=>{e.preventDefault();clearTimeout(longTimer);
 if(e.touches.length===0)pinch=null;if(!touch||touch.moved||touch.long){touch=null;return}
 const p=pos({clientX:touch.x0,clientY:touch.y0}),now=Date.now();
 if(now-lastTap<300){sendInput({t:'double',x:p.x,y:p.y});lastTap=0}else{sendInput({t:'tap',x:p.x,y:p.y});lastTap=now}touch=null},{passive:false});
// Keyboard: the Mac reports a focused text field, the page shows ⌨︎; tapping it opens the phone's keyboard
// (iOS only allows that from a tap). Whatever is typed goes to the Mac.
const kb=document.getElementById('kb'),ti=document.getElementById('ti');
kb.addEventListener('touchend',e=>{e.preventDefault();e.stopPropagation();ti.value='';ti.focus()},{passive:false});
kb.addEventListener('click',()=>{ti.value='';ti.focus()});
// Text goes through beforeinput; Enter, Backspace and arrows through keydown (fires even when the field is empty).
ti.addEventListener('beforeinput',e=>{e.preventDefault();
 if(e.inputType==='insertText'||e.inputType==='insertReplacementText'||e.inputType==='insertFromPaste')sendInput({t:'text',s:e.data||''})});
ti.addEventListener('keydown',e=>{if(['Enter','Backspace','Tab','Escape','ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key)){
 e.preventDefault();sendInput({t:'key',k:e.key})}});
function shape(p){const v=i=>((p[i]<<8)|p[i+1])/16;hot=[v(0),v(2)];ps=[v(4),v(6)];
 if(ptr.src)URL.revokeObjectURL(ptr.src);ptr.src=URL.createObjectURL(new Blob([p.slice(8)],{type:'image/png'}))}
</script></body></html>
"""#
}

extension String {
    // FNV-1a: same value on every launch (Swift's hashValue is randomized per process).
    var hashValueStable: UInt64 {
        utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }
}
