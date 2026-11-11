// Peer link between RemotePointer instances on Macs that share Universal Control.
//
// Every instance advertises itself over Bonjour and connects to the others. Each one tells its peers whenever its
// own cursor moves; Universal Control only moves the cursor of the Mac it is driving, so the Mac with the remote can
// tell which machine the pointer is on. While that's another Mac, input that can't cross Universal Control as
// hardware (trackpad-style scrolling with momentum, pinch/smart zoom, Notification Center, typed dictation) is sent
// to that Mac's RemotePointer, which plays it back locally with full fidelity.
//
// The link is TLS with a pre-shared key: only Macs given the same pairing key (Copy/Paste Pairing Key in the menu,
// via Universal Clipboard) can connect, so nothing else on the network can inject input.

import AppKit
import Network

final class Peers {
    static let shared = Peers()
    static let serviceType = "_rptr._tcp"
    /// False while replaying a peer's input, so it is never bounced back out.
    static var forwarding = true

    private let queue = DispatchQueue(label: "peers")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var outgoing: [String: NWConnection] = [:]     // by service name
    private var incoming: [ObjectIdentifier: NWConnection] = [:]
    private var names: [ObjectIdentifier: String] = [:]    // connection → peer name (from its hello)
    private var lastHere: [String: Double] = [:]           // peer name → when its cursor last moved
    private var lastLocalMove = now()
    private var lastHereSent = 0.0
    let myName: String

    private init() {
        let id = Defaults.d.string(forKey: "peerID") ?? {
            let s = String(UUID().uuidString.prefix(6)); Defaults.d.set(s, forKey: "peerID"); return s
        }()
        myName = "\(Host.current().localizedName ?? "Mac") · \(id)"
    }

    // MARK: Pairing key

    static var pairingKey: Data {
        if let s = Defaults.d.string(forKey: "pairingKey"), let d = Data(base64Encoded: s), d.count == 32 { return d }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        Defaults.d.set(Data(bytes).base64EncodedString(), forKey: "pairingKey")
        return Data(bytes)
    }
    static let keyPrefix = "remote-pointer-key:"

    func copyKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.keyPrefix + Self.pairingKey.base64EncodedString(), forType: .string)
    }

    /// Returns false if the clipboard doesn't hold a pairing key.
    func pasteKey() -> Bool {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.hasPrefix(Self.keyPrefix), let d = Data(base64Encoded: String(s.dropFirst(Self.keyPrefix.count))), d.count == 32
        else { return false }
        Defaults.d.set(d.base64EncodedString(), forKey: "pairingKey")
        restart()
        return true
    }

    private static func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = pairingKey.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("remote-pointer".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)   // PSK suites are TLS 1.2
        let p = NWParameters(tls: tls)
        p.includePeerToPeer = true
        return p
    }

    // MARK: Lifecycle

    func start() {
        installCursorWatch()
        queue.async { self.startNetworking() }
    }

    func restart() {
        queue.async {
            self.listener?.cancel(); self.browser?.cancel()
            self.outgoing.values.forEach { $0.cancel() }; self.incoming.values.forEach { $0.cancel() }
            self.outgoing = [:]; self.incoming = [:]; self.names = [:]; self.lastHere = [:]
            self.startNetworking()
        }
    }

    private func startNetworking() {
        do {
            let l = try NWListener(using: Self.parameters())
            l.service = NWListener.Service(name: myName, type: Self.serviceType)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { s in if case .failed(let e) = s { log("peers: listener failed \(e)") } }
            l.start(queue: queue)
            listener = l
        } catch { log("peers: listener error \(error)") }

        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: Self.parameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.browsed(results) }
        b.start(queue: queue)
        browser = b
    }

    private func browsed(_ results: Set<NWBrowser.Result>) {
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint, name != myName, outgoing[name] == nil else { continue }
            log("peers: found \(name)")
            let c = NWConnection(to: r.endpoint, using: Self.parameters())
            outgoing[name] = c
            names[ObjectIdentifier(c)] = name
            c.stateUpdateHandler = { [weak self, weak c] s in
                guard let self, let c else { return }
                switch s {
                case .ready: log("peers: linked to \(name)"); self.send(["t": "hello", "name": self.myName], on: c); self.changed()
                case .failed(let e), .waiting(let e):
                    log("peers: \(name) unavailable (\(e)) — same pairing key on both Macs?")
                    c.cancel(); self.outgoing[name] = nil; self.names[ObjectIdentifier(c)] = nil; self.changed()
                    // Retry later; the browser only reports changes.
                    self.queue.asyncAfter(deadline: .now() + 10) { self.browsed(self.browser?.browseResults ?? []) }
                case .cancelled: self.outgoing[name] = nil; self.changed()
                default: break
                }
            }
            c.start(queue: queue)
            receive(on: c)
        }
    }

    private func accept(_ c: NWConnection) {
        incoming[ObjectIdentifier(c)] = c
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c else { return }
            switch s {
            case .failed, .cancelled:
                self.incoming[ObjectIdentifier(c)] = nil; self.names[ObjectIdentifier(c)] = nil; self.changed()
            default: break
            }
        }
        c.start(queue: queue)
        receive(on: c)
    }

    // MARK: Messages (4-byte big-endian length + JSON)

    private func send(_ msg: [String: Any], on c: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: msg) else { return }
        var len = UInt32(body.count).bigEndian
        c.send(content: Data(bytes: &len, count: 4) + body, completion: .contentProcessed { _ in })
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, done, err in
            guard let self, let head, head.count == 4, err == nil else { if done || err != nil { c.cancel() }; return }
            let n = Int(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            guard n > 0, n < 1_000_000 else { c.cancel(); return }
            c.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, err in
                guard let body, err == nil, let msg = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { c.cancel(); return }
                self.handle(msg, from: c)
                self.receive(on: c)
            }
        }
    }

    private func handle(_ m: [String: Any], from c: NWConnection) {
        let type = m["t"] as? String ?? ""
        if type == "hello", let name = m["name"] as? String {
            names[ObjectIdentifier(c)] = name; changed(); return
        }
        if type == "here", let name = names[ObjectIdentifier(c)] {
            let wasActive = activeLocked
            lastHere[name] = now()
            if activeLocked != wasActive { changed() }
            return
        }
        DispatchQueue.main.async { Self.perform(type, m) }
    }

    /// Play back input forwarded from the Mac with the remote.
    private static func perform(_ type: String, _ m: [String: Any]) {
        forwarding = false
        defer { forwarding = true }
        let mouse = pointer.mouse
        func i(_ k: String) -> Int64 { (m[k] as? NSNumber)?.int64Value ?? 0 }
        switch type {
        case "scroll":
            mouse.scroll(pixelsX: Int32(i("dx")), pixelsY: Int32(i("dy")),
                         phase: Mouse.ScrollPhase(rawValue: i("p")) ?? .none, momentum: Mouse.MomentumPhase(rawValue: i("m")) ?? .none)
        case "magnify": mouse.magnify(phase: i("p"), delta: (m["d"] as? Double) ?? 0)
        case "smart": mouse.smartMagnify()
        case "nc": SystemAction.notificationCenter()
        case "type": if let s = m["s"] as? String { Typer.type(s) }
        default: break
        }
    }

    // MARK: Which Mac has the pointer?

    /// Watch this Mac's own cursor; tell peers whenever it moves (rate-limited).
    private func installCursorWatch() {
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            guard let self else { return }
            let t = now()
            self.queue.async {
                let wasActive = self.activeLocked
                self.lastLocalMove = t
                if wasActive != nil { self.changed() }
                guard t - self.lastHereSent > 0.25 else { return }
                self.lastHereSent = t
                for c in self.allConnections { self.send(["t": "here"], on: c) }
            }
        }
    }

    private var allConnections: [NWConnection] {
        Array(outgoing.values.filter { $0.state == .ready }) + incoming.values.filter { $0.state == .ready }
    }

    /// The peer the pointer is on: the one whose cursor moved most recently, after this Mac's own cursor last moved.
    private var activeLocked: String? {
        guard let (name, t) = lastHere.max(by: { $0.value < $1.value }), t > lastLocalMove,
              allConnections.contains(where: { names[ObjectIdentifier($0)] == name }) else { return nil }
        return name
    }

    var active: String? { queue.sync { activeLocked } }
    var linked: [String] { queue.sync { Array(Set(allConnections.compactMap { names[ObjectIdentifier($0)] })).sorted() } }

    /// Send input to the Mac the pointer is on. Returns false (handle it locally) if that's this Mac.
    func forward(_ msg: [String: Any]) -> Bool {
        queue.sync {
            guard let name = activeLocked,
                  let c = allConnections.first(where: { names[ObjectIdentifier($0)] == name }) else { return false }
            send(msg, on: c)
            return true
        }
    }

    private func changed() { DispatchQueue.main.async { StatusMenu.shared.refresh() } }
}
