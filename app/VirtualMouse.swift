// Virtual HID mouse via the root helper (helper/rp-hid-helper) and the Karabiner DriverKit driver.
// macOS treats its reports as real hardware, so Universal Control carries the pointer to a nearby Mac/iPad,
// which synthetic CGEvents can't do. When the helper isn't installed or running, Mouse falls back to CGEvents.

import Foundation
import IOKit.hid

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

    private func send(dx: Int, dy: Int, vwheel: Int = 0, hwheel: Int = 0) {
        guard ensureConnected() else { return }
        var m = [UInt8](repeating: 0, count: 8)
        m[0] = 1; m[1] = buttons
        let x = Int16(clamping: dx), y = Int16(clamping: dy)
        m[2] = UInt8(truncatingIfNeeded: x); m[3] = UInt8(truncatingIfNeeded: x >> 8)
        m[4] = UInt8(truncatingIfNeeded: y); m[5] = UInt8(truncatingIfNeeded: y >> 8)
        m[6] = UInt8(bitPattern: Int8(clamping: vwheel)); m[7] = UInt8(bitPattern: Int8(clamping: hwheel))
        let n = write(fd, m, m.count)
        if n != m.count && !(n < 0 && errno == EAGAIN) {
            log("virtual mouse: helper went away")
            close(fd); fd = -1
            DispatchQueue.main.async { StatusMenu.shared.refresh() }
        }
    }

    /// Move by a delta in points (fractions carry over).
    func move(dx: Double, dy: Double) {
        accX += dx / Self.pointsPerCount; accY += dy / Self.pointsPerCount
        let ix = accX.rounded(.towardZero), iy = accY.rounded(.towardZero)
        guard ix != 0 || iy != 0 else { return }
        accX -= ix; accY -= iy
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
