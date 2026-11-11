// Virtual HID mouse via the root helper (helper/rp-hid-helper) and the Karabiner DriverKit driver.
// macOS treats its reports as real hardware, so Universal Control carries the pointer to a nearby Mac/iPad,
// which synthetic CGEvents can't do. When the helper isn't installed or running, Mouse falls back to CGEvents.

import Foundation
import IOKit.hid
import CoreGraphics

final class VirtualMouse {
    static let shared = VirtualMouse()
    static let socketPath = "/var/run/remote-pointer-hid.sock"
    /// Points moved per report count once acceleration is off (measured: 0.8 pt/count).
    static let pointsPerCount = 0.8

    private var fd: Int32 = -1
    private var lastAttempt = 0.0
    private var accX = 0.0, accY = 0.0
    private(set) var buttons: UInt8 = 0
    var connected: Bool { fd >= 0 }

    /// Connect if needed (retrying at most every 2 s). Returns whether the helper is reachable.
    @discardableResult
    func ensureConnected() -> Bool {
        if fd >= 0 { return true }
        let t = now()
        guard t - lastAttempt > 2 else { return false }
        lastAttempt = t
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            Self.socketPath.withCString { _ = strlcpy(p.baseAddress!.assumingMemoryBound(to: CChar.self), $0, p.count) }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else { close(s); return false }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
        log("virtual mouse: connected to helper")
        Self.makeLinear()
        DispatchQueue.main.async { StatusMenu.shared.refresh() }
        return true
    }

    private func write(_ m: [UInt8]) {
        guard ensureConnected() else { return }
        let n = Darwin.write(fd, m, m.count)
        if n != m.count && !(n < 0 && errno == EAGAIN) {
            log("virtual mouse: helper went away")
            close(fd); fd = -1
            DispatchQueue.main.async { StatusMenu.shared.refresh() }
        }
    }

    private func send(dx: Int, dy: Int, vwheel: Int = 0, hwheel: Int = 0) {
        var m = [UInt8](repeating: 0, count: 16)
        m[0] = 1; m[1] = buttons
        let x = Int16(clamping: dx), y = Int16(clamping: dy)
        m[2] = UInt8(truncatingIfNeeded: x); m[3] = UInt8(truncatingIfNeeded: x >> 8)
        m[4] = UInt8(truncatingIfNeeded: y); m[5] = UInt8(truncatingIfNeeded: y >> 8)
        m[6] = UInt8(bitPattern: Int8(clamping: vwheel)); m[7] = UInt8(bitPattern: Int8(clamping: hwheel))
        write(m)
    }

    // MARK: Keyboard

    enum Page: UInt8 { case keyboard = 2, consumer = 3, appleKeyboard = 4, appleTopCase = 5 }
    /// HID modifier bits (left-hand keys).
    static let ctrl: UInt8 = 0x01, shift: UInt8 = 0x02, option: UInt8 = 0x04, command: UInt8 = 0x08
    /// Modifiers held across key presses (e.g. ⌘ for the app switcher).
    private(set) var heldModifiers: UInt8 = 0

    /// Send the full set of keys currently down on one page (empty = all up).
    private func sendKeys(_ page: Page, modifiers: UInt8 = 0, _ usages: [UInt16]) {
        var m = [UInt8](repeating: 0, count: 16)
        m[0] = page.rawValue; m[1] = modifiers; m[2] = UInt8(min(usages.count, 6))
        for (i, u) in usages.prefix(6).enumerated() { m[4 + 2 * i] = UInt8(u & 0xFF); m[5 + 2 * i] = UInt8(u >> 8) }
        write(m)
    }

    func setModifier(_ bit: UInt8, down: Bool) {
        if down { heldModifiers |= bit } else { heldModifiers &= ~bit }
        sendKeys(.keyboard, modifiers: heldModifiers, [])
    }

    /// Tap a keyboard-page key with extra modifiers (on top of any held ones).
    func tap(_ usage: UInt16, modifiers: UInt8 = 0) {
        let mods = heldModifiers | modifiers
        if modifiers != 0 { sendKeys(.keyboard, modifiers: mods, []) }
        sendKeys(.keyboard, modifiers: mods, [usage])
        sendKeys(.keyboard, modifiers: mods, [])
        if modifiers != 0 { sendKeys(.keyboard, modifiers: heldModifiers, []) }
    }

    /// Tap a key on another page (consumer media keys, Apple's Mission Control key…).
    func tap(_ page: Page, _ usage: UInt16) {
        sendKeys(page, [usage])
        sendKeys(page, [])
    }

    /// Globe/fn held while tapping a keyboard key (e.g. fn+N = Notification Center).
    func tapWithFn(_ usage: UInt16) {
        sendKeys(.appleTopCase, [0x0003])
        tap(usage)
        sendKeys(.appleTopCase, [])
    }

    /// Type ASCII text as US-layout key presses (works on whichever Mac Universal Control is driving).
    /// Returns false if the text has characters this can't type.
    @discardableResult
    func type(_ text: String) -> Bool {
        let keys = text.map { HIDKeys.ascii[$0] }
        guard keys.allSatisfy({ $0 != nil }) else { return false }
        for k in keys { tap(k!.usage, modifiers: k!.shift ? Self.shift : 0); usleep(2000) }
        return true
    }

    /// Scroll by wheel ticks (positive y = up, positive x = right).
    func wheel(x: Int, y: Int) { send(dx: 0, dy: 0, vwheel: y, hwheel: x) }

    // MARK: Is the pointer on another device?
    // Universal Control parks the local cursor while it forwards this Mac's HID input to the other device. So if the
    // virtual mouse moves in a direction the local cursor is free to go and the cursor doesn't budge, it's remote.
    private(set) var remote = false
    private var stuck = 0
    private var lastLocation = CGPoint.zero
    private var pendingFree = false

    private func checkRemote(dx: Double, dy: Double) {
        let p = CGEvent(source: nil)?.location ?? .zero
        if pendingFree {
            if p == lastLocation { stuck += 1 } else { stuck = 0 }
            let r = stuck >= 6
            if r != remote { remote = r; log("pointer is \(r ? "on another device (Universal Control)" : "back on this Mac")") }
        }
        lastLocation = p
        // Would this move change the local cursor? (not if it only pushes into a screen edge)
        func onDisplay(_ q: CGPoint) -> Bool {
            var id = CGDirectDisplayID(0), n: UInt32 = 0
            return CGGetDisplaysWithPoint(q, 1, &id, &n) == .success && n > 0
        }
        let freeX = dx != 0 && onDisplay(CGPoint(x: p.x + (dx > 0 ? 2 : -2), y: p.y))
        let freeY = dy != 0 && onDisplay(CGPoint(x: p.x, y: p.y + (dy > 0 ? 2 : -2)))
        pendingFree = (freeX && abs(dx) >= 1) || (freeY && abs(dy) >= 1)
    }

    /// Move by a delta in points (fractions carry over).
    func move(dx: Double, dy: Double) {
        accX += dx / Self.pointsPerCount; accY += dy / Self.pointsPerCount
        let ix = accX.rounded(.towardZero), iy = accY.rounded(.towardZero)
        guard ix != 0 || iy != 0 else { return }
        accX -= ix; accY -= iy
        checkRemote(dx: dx, dy: dy)
        send(dx: Int(ix), dy: Int(iy))
    }

    /// Button 1 = left, 2 = right.
    func button(_ index: Int, down: Bool) {
        let bit = UInt8(1 << (index - 1))
        if down { buttons |= bit } else { buttons &= ~bit }
        send(dx: 0, dy: 0)
    }

    // MARK: Pointer acceleration
    // The virtual mouse would otherwise get the system mouse curve (slow moves shrink to ~0.3×, fast ones grow),
    // on top of RemotePointer's own ballistics. Turn it off for this one device; HIDMouseAcceleration = -1.0
    // (16.16 fixed) means "no acceleration". It resets whenever the device reappears, so reapply on connect.

    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    private typealias SetProperty = @convention(c) (AnyObject, CFString, CFTypeRef) -> Bool

    static func makeLinear() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let c = dlsym(h, "IOHIDEventSystemClientCreateSimpleClient"), let cs = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let cp = dlsym(h, "IOHIDServiceClientCopyProperty"), let sp = dlsym(h, "IOHIDServiceClientSetProperty") else { return }
        let create = unsafeBitCast(c, to: CreateClient.self), copy = unsafeBitCast(cs, to: CopyServices.self)
        let getp = unsafeBitCast(cp, to: CopyProperty.self), setp = unsafeBitCast(sp, to: SetProperty.self)
        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue(),
              let services = copy(client)?.takeRetainedValue() as? [AnyObject] else { return }
        for s in services {
            let name = getp(s, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            guard name.contains("VirtualHIDPointing") else { continue }
            let ok = setp(s, "HIDMouseAcceleration" as CFString, -65536 as CFNumber)
                && setp(s, "HIDPointerAcceleration" as CFString, -65536 as CFNumber)
            log("virtual mouse: acceleration off → \(ok)")
        }
    }
}

/// CGKeyCode (ANSI) → HID keyboard usage, and ASCII → (usage, shift) for the US layout.
enum HIDKeys {
    static let fromKeyCode: [CGKeyCode: UInt16] = [
        0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B, 34: 0x0C, 38: 0x0D, 40: 0x0E, 37: 0x0F,
        46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17, 32: 0x18, 9: 0x19, 13: 0x1A,
        7: 0x1B, 16: 0x1C, 6: 0x1D, 18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25,
        25: 0x26, 29: 0x27, 36: 0x28, 53: 0x29, 51: 0x2A, 48: 0x2B, 49: 0x2C, 27: 0x2D, 24: 0x2E, 33: 0x2F, 30: 0x30,
        42: 0x31, 41: 0x33, 39: 0x34, 50: 0x35, 43: 0x36, 47: 0x37, 44: 0x38, 117: 0x4C, 124: 0x4F, 123: 0x50,
        125: 0x51, 126: 0x52, 115: 0x4A, 119: 0x4D, 116: 0x4B, 121: 0x4E,
    ]

    static let ascii: [Character: (usage: UInt16, shift: Bool)] = {
        var m: [Character: (UInt16, Bool)] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            m[c] = (0x04 + UInt16(i), false)
            m[Character(c.uppercased())] = (0x04 + UInt16(i), true)
        }
        for (i, c) in "1234567890".enumerated() { m[c] = (0x1E + UInt16(i), false) }
        for (i, c) in "!@#$%^&*()".enumerated() { m[c] = (0x1E + UInt16(i), true) }
        let pairs: [(Character, Character, UInt16)] = [("-", "_", 0x2D), ("=", "+", 0x2E), ("[", "{", 0x2F), ("]", "}", 0x30),
            ("\\", "|", 0x31), (";", ":", 0x33), ("'", "\"", 0x34), ("`", "~", 0x35), (",", "<", 0x36), (".", ">", 0x37), ("/", "?", 0x38)]
        for (a, b, u) in pairs { m[a] = (u, false); m[b] = (u, true) }
        m[" "] = (0x2C, false); m["\n"] = (0x28, false); m["\t"] = (0x2B, false)
        return m
    }()
}
