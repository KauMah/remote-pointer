// RemotePointer — Siri Remote (1st gen, A1513) as a gyro air-mouse for macOS.
//
// Touch the remote's touch surface to engage; while touching, turning the remote moves the cursor (yaw → x,
// pitch → y). Lift to disengage. Swipe = trackpad-style scroll (axis-locked, with momentum). Swipe left from
// the right edge = Notification Center. Click the surface = left click,
// TV = right click (2× Return, 3× Mission Control, hold = app switcher: turn to pick, release to switch), Play/Pause = play/pause (2× fast-forward, 3× rewind,
// hold = cycle the app's windows), Volume = system volume, Menu = Back (⌘[) (2× Backspace, 2× and hold = delete words), Siri = dictation (hold to talk, tap to toggle), Play/Pause+Siri held = pinch zoom (tilt), double-tap the surface = smart zoom, tap then drag up/down = pinch zoom. Cursor motion is posted as HID-level mouse
// events with deltas, so Universal Control can carry it across to a nearby iPad/Mac.
//
// How motion is unlocked: BTLEServer forwards feature-report SETs on any of the remote's HID interfaces to the
// remote's keyhole (report 0xF0). Command A0 01 starts the motion stream: interface FF00/0010, input report 1,
// 25 bytes = [01][3 × f32 orientation][3 × i16 accel][3 × i16 gyro: pitch, roll, yaw]. A0 00 stops it.

import AppKit
import IOKit.hid
import CoreGraphics
import QuartzCore
import ServiceManagement

setvbuf(stdout, nil, _IOLBF, 0)
let debug = CommandLine.arguments.contains("--debug")
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemotePointer.log")
let logHandle: FileHandle? = {
    guard debug || UserDefaults.standard.bool(forKey: "debugLog") else { return nil }
    if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
    let h = try? FileHandle(forWritingTo: logURL); h?.seekToEndOfFile(); return h
}()
func log(_ s: @autoclosure () -> String) {
    guard debug || logHandle != nil else { return }
    let line = String(format: "%.3f ", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000)) + s()
    if debug { print(line) }
    logHandle?.write((line + "\n").data(using: .utf8)!)
}
func now() -> Double { CFAbsoluteTimeGetCurrent() }

/// A main-run-loop timer that keeps firing while a menu is open (event-tracking mode), unlike Timer.scheduledTimer.
@discardableResult
func commonTimer(withTimeInterval interval: TimeInterval, repeats: Bool, block: @escaping (Timer) -> Void) -> Timer {
    let t = Timer(timeInterval: interval, repeats: repeats, block: block)
    RunLoop.main.add(t, forMode: .common)
    return t
}

// MARK: - Settings

enum Defaults {
    static let d = UserDefaults.standard
    static var enabled: Bool { get { d.object(forKey: "enabled") as? Bool ?? true } set { d.set(newValue, forKey: "enabled") } }
    static func num(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
    static var pointerSpeed: Double { get { num("pointerSpeed", 40) } set { d.set(newValue, forKey: "pointerSpeed") } }
    static var pointerAccel: Double { get { num("pointerAccel", 1) } set { d.set(newValue, forKey: "pointerAccel") } }
    static var scrollSpeed: Double { get { num("scrollSpeed", 1000) } set { d.set(newValue, forKey: "scrollSpeed") } }
    static var scrollGlide: Double { get { num("scrollGlide", 0.6) } set { d.set(newValue, forKey: "scrollGlide") } }
    static var gravityAligned: Bool { get { d.object(forKey: "gravityAligned") as? Bool ?? true } set { d.set(newValue, forKey: "gravityAligned") } }
    static var edgeGestures: Bool { get { d.object(forKey: "edgeGestures") as? Bool ?? true } set { d.set(newValue, forKey: "edgeGestures") } }
    static var invertX: Bool { get { d.bool(forKey: "invertX") } set { d.set(newValue, forKey: "invertX") } }
    static var invertY: Bool { get { d.bool(forKey: "invertY") } set { d.set(newValue, forKey: "invertY") } }
    static var naturalScroll: Bool { get { d.object(forKey: "naturalScroll") as? Bool ?? true } set { d.set(newValue, forKey: "naturalScroll") } }
}

// MARK: - Mouse output

final class Mouse {
    let source = CGEventSource(stateID: .hidSystemState)
    var leftDown = false
    var lastClickTime = 0.0, lastClickPos = CGPoint.zero, clickCount = 1
    var accX = 0.0, accY = 0.0
    /// Recently applied deltas, so a click can rewind the wobble the press itself caused.
    var history: [(t: Double, dx: Double, dy: Double)] = []

    var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Pointer/scroll events take their modifier flags from the source's own remembered key state, which can still
    /// hold ⌘ from synthetic shortcuts (⌘[, ⌘`, the app switcher) — making clicks ⌘-clicks (Dock → "Show in
    /// Finder"). Stamp every pointer event with the real current modifier state instead.
    func stamp(_ e: CGEvent) {
        e.flags = CGEventSource.flagsState(.hidSystemState).intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn])
    }

    func clampToDisplays(_ p: CGPoint, from: CGPoint) -> CGPoint {
        var id = CGDirectDisplayID(0), count: UInt32 = 0
        if CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 { return p }
        // Off every display: clamp inside the display we came from (deltas still carry the push for Universal Control).
        if CGGetDisplaysWithPoint(from, 1, &id, &count) == .success, count > 0 {
            let b = CGDisplayBounds(id)
            return CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
        }
        return from
    }

    func move(dx: Double, dy: Double, record: Bool = true) {
        accX += dx; accY += dy
        let ix = accX.rounded(.towardZero), iy = accY.rounded(.towardZero)
        guard ix != 0 || iy != 0 else { return }
        accX -= ix; accY -= iy
        if VirtualMouse.shared.ensureConnected() {             // real-HID path: Universal Control follows it
            VirtualMouse.shared.move(dx: ix, dy: iy)
            if record { let t = now(); history.append((t, ix, iy)); history.removeAll { t - $0.t > 0.25 } }
            return
        }
        let from = location
        let to = clampToDisplays(CGPoint(x: from.x + ix, y: from.y + iy), from: from)
        let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(ix))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(iy))
        stamp(e)
        e.post(tap: .cghidEventTap)
        if record {
            let t = now()
            history.append((t, ix, iy))
            history.removeAll { t - $0.t > 0.25 }
        }
    }

    /// Undo the cursor motion of the last `window` seconds (the press wobble), then forget it.
    func rewind(_ window: Double) {
        let t = now()
        let recent = history.filter { t - $0.t <= window }
        let (dx, dy) = recent.reduce((0.0, 0.0)) { ($0.0 + $1.dx, $0.1 + $1.dy) }
        history.removeAll()
        if dx != 0 || dy != 0 { move(dx: -dx, dy: -dy, record: false) }
    }

    func button(_ button: CGMouseButton, down: Bool) {
        let p = location
        let type: CGEventType
        switch (button, down) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (_, true): type = .rightMouseDown
        default: type = .rightMouseUp
        }
        if button == .left && down {
            let t = now()
            clickCount = (t - lastClickTime < NSEvent.doubleClickInterval && hypot(p.x - lastClickPos.x, p.y - lastClickPos.y) < 6) ? clickCount + 1 : 1
            lastClickTime = t; lastClickPos = p
        }
        if button == .left { leftDown = down }
        if VirtualMouse.shared.ensureConnected() {
            VirtualMouse.shared.button(button == .left ? 1 : 2, down: down)   // the system counts double-clicks itself
            return
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(button == .left ? clickCount : 1))
        stamp(e)
        e.post(tap: .cghidEventTap)
    }

    enum ScrollPhase: Int64 { case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8 }
    enum MomentumPhase: Int64 { case none = 0, begin = 1, `continue` = 2, end = 3 }
    static let scrollPhaseField = CGEventField(rawValue: 99)!      // kCGScrollWheelEventScrollPhase
    static let momentumPhaseField = CGEventField(rawValue: 123)!   // kCGScrollWheelEventMomentumPhase

    /// Trackpad-style pixel scroll with gesture/momentum phases, so AppKit treats it like a real trackpad
    /// (smooth scrolling, rubber-banding at edges). Positive dy reveals content above, positive dx content to the left.
    private var wheelAccX = 0.0, wheelAccY = 0.0
    static let pixelsPerWheelTick = 12.0

    func scroll(pixelsX dx: Int32, pixelsY dy: Int32, phase: ScrollPhase, momentum: MomentumPhase = .none, extraFlags: CGEventFlags = []) {
        // On another Mac running RemotePointer: send it the scroll to replay with full trackpad fidelity.
        if Peers.forwarding && Peers.shared.forward(["t": "scroll", "dx": dx, "dy": dy, "p": phase.rawValue, "m": momentum.rawValue]) { return }
        // On another device without it, only real HID reaches it: send wheel ticks (no gesture phases, so no rubber-banding there).
        // The other Mac applies its own natural-scrolling setting to wheel input, so undo ours.
        if VirtualMouse.shared.remote && VirtualMouse.shared.connected {
            let sign = Defaults.naturalScroll ? -1.0 : 1.0
            wheelAccX += Double(-dx) * sign / Self.pixelsPerWheelTick
            wheelAccY += Double(dy) * sign / Self.pixelsPerWheelTick
            let tx = wheelAccX.rounded(.towardZero), ty = wheelAccY.rounded(.towardZero)
            wheelAccX -= tx; wheelAccY -= ty
            if tx != 0 || ty != 0 { VirtualMouse.shared.wheel(x: Int(tx), y: Int(ty)) }
            return
        }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(Self.scrollPhaseField, value: phase.rawValue)
        e.setIntegerValueField(Self.momentumPhaseField, value: momentum.rawValue)
        stamp(e)
        e.flags.formUnion(extraFlags)
        e.post(tap: .cghidEventTap)
    }

    // Trackpad gesture events (NSEventTypeGesture = 29). Field 110 = HID event type (8 zoom/pinch, 22 zoom
    // toggle = smart magnify), 113 = magnification delta, 132 = phase (1 began, 2 changed, 4 ended).
    // Verified: apps receive these as magnify(with:) / smartMagnify(with:).
    static let gestureType = CGEventType(rawValue: 29)!
    private func gesture(hidType: Int64, configure: (CGEvent) -> Void) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = Self.gestureType
        e.location = location
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: hidType)
        configure(e)
        e.post(tap: .cghidEventTap)
    }
    /// Two-finger double-tap "smart zoom".
    func smartMagnify() {
        if Peers.forwarding && Peers.shared.forward(["t": "smart"]) { return }
        gesture(hidType: 22) { _ in }
    }
    /// Pinch: phase 1 began, 2 changed, 4 ended; delta is the magnification change (+ zooms in).
    private var remoteZoomAcc = 0.0
    func magnify(phase: Int64, delta: Double) {
        if Peers.forwarding && Peers.shared.forward(["t": "magnify", "p": phase, "d": delta]) { return }
        // Gesture events can't cross Universal Control; on another device, step browser/app zoom with ⌘= / ⌘− instead.
        if VirtualMouse.shared.remote && VirtualMouse.shared.connected {
            if phase == 1 { remoteZoomAcc = 0 }
            remoteZoomAcc += delta
            while remoteZoomAcc > 0.15 { remoteZoomAcc -= 0.15; key(24, flags: .maskCommand) }    // ⌘=
            while remoteZoomAcc < -0.15 { remoteZoomAcc += 0.15; key(27, flags: .maskCommand) }   // ⌘−
            return
        }
        gesture(hidType: 8) { e in
            e.setDoubleValueField(CGEventField(rawValue: 113)!, value: delta)
            e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        }
    }

    /// System media key (NX_KEYTYPE_SOUND_UP = 0, SOUND_DOWN = 1).
    func mediaKey(_ key: Int) {
        // NX key type → HID consumer usage: volume up/down, play/pause, next (fast), previous (rewind).
        let consumer: [Int: UInt16] = [0: 0xE9, 1: 0xEA, 16: 0xCD, 19: 0xB5, 20: 0xB6]
        if let u = consumer[key], VirtualMouse.shared.ensureConnected() { VirtualMouse.shared.tap(.consumer, u); return }
        for down in [true, false] {
            let flags = down ? 0xA00 : 0xB00
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (key << 16) | flags, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private(set) var commandHeld = false

    /// Press or release a modifier key on its own (e.g. hold ⌘ for the app switcher).
    func modifier(_ code: CGKeyCode, _ flag: CGEventFlags, down: Bool) {
        if VirtualMouse.shared.ensureConnected() {
            VirtualMouse.shared.setModifier(Self.hidModifiers(flag), down: down)
            if flag == .maskCommand { commandHeld = down }
            return
        }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = down ? flag : []
        e.post(tap: .cghidEventTap)
        if flag == .maskCommand { commandHeld = down }
    }

    static func hidModifiers(_ f: CGEventFlags) -> UInt8 {
        var m: UInt8 = 0
        if f.contains(.maskControl) { m |= VirtualMouse.ctrl }
        if f.contains(.maskShift) { m |= VirtualMouse.shift }
        if f.contains(.maskAlternate) { m |= VirtualMouse.option }
        if f.contains(.maskCommand) { m |= VirtualMouse.command }
        return m
    }

    /// Keys go through the virtual keyboard when it's available, so they reach whichever device
    /// Universal Control is driving.
    func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        if let usage = HIDKeys.fromKeyCode[code], VirtualMouse.shared.ensureConnected() {
            VirtualMouse.shared.tap(usage, modifiers: Self.hidModifiers(flags))
            return
        }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - System actions (edge gestures)

enum SystemAction {
    static func missionControl() {
        if VirtualMouse.shared.ensureConnected() { VirtualMouse.shared.tap(.appleKeyboard, 0x0010); return }   // Mission Control key
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    /// Open Notification Center shows as a large on-screen window owned by "Notification Center" (none when closed).
    static func notificationCenterOpen() -> Bool {
        let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return wins.contains { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "Notification Center",
                  let b = w[kCGWindowBounds as String] as? [String: Any], let h = b["Height"] as? Double else { return false }
            guard h > 300 else { return false }
            let wb = b["Width"] as? Double ?? 0, x = b["X"] as? Double ?? 0, layer = w[kCGWindowLayer as String] as? Int ?? 0
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            log("NC window seen: x=\(Int(x)) w=\(Int(wb)) h=\(Int(h)) layer=\(layer) alpha=\(alpha) name=\(w[kCGWindowName as String] ?? "-")")
            return alpha > 0.1 && layer > 0
        }
    }

    /// Notification Center has no public API: press the menu-bar Clock (what clicking it does). On current macOS the
    /// clock is an AXMenuBarItem nested in a group under MenuBarAgent's extras menu bar; older versions host it in
    /// ControlCenter. Search both, preferring an item described "Clock", else the right-most extra.
    static func notificationCenter() {
        if Peers.forwarding && Peers.shared.forward(["t": "nc"]) { return }
        if VirtualMouse.shared.remote && VirtualMouse.shared.connected { VirtualMouse.shared.tapWithFn(0x11); return }  // fn+N
        func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
        }
        func kids(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        func x(_ e: AXUIElement) -> CGFloat {
            var p = CGPoint.zero
            if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
            return p.x
        }
        var candidates: [AXUIElement] = []
        for bid in ["com.apple.MenuBarAgent", "com.apple.controlcenter"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
                  let bar = attr(AXUIElementCreateApplication(app.processIdentifier), "AXExtrasMenuBar") else { continue }
            for top in kids(bar as! AXUIElement) {
                for e in [top] + kids(top) where (attr(e, kAXRoleAttribute) as? String) == kAXMenuBarItemRole {
                    let desc = (attr(e, kAXDescriptionAttribute) as? String ?? "") + (attr(e, "AXIdentifier") as? String ?? "")
                    if desc.localizedCaseInsensitiveContains("clock") {
                        AXUIElementPerformAction(e, kAXPressAction as CFString); log("notification center: pressed clock"); return
                    }
                    candidates.append(e)
                }
            }
        }
        if let rightmost = candidates.max(by: { x($0) < x($1) }) {
            AXUIElementPerformAction(rightmost, kAXPressAction as CFString); log("notification center: pressed right-most extra")
        } else { log("notification center: no menu-bar clock found") }
    }
}

// MARK: - Scrolling (trackpad emulation)

/// Turns finger motion on the remote's surface into trackpad-style scrolling: gesture phases, axis lock,
/// release-velocity momentum with time-based exponential decay on the display refresh, flick compounding,
/// and touch-to-stop — the behaviours that make a Mac trackpad feel the way it does.
final class Scroller: NSObject {
    let mouse: Mouse
    init(mouse: Mouse) { self.mouse = mouse }

    enum Axis { case vertical, horizontal }
    private(set) var active = false            // a scroll gesture owns the current touch
    private var axis: Axis = .vertical
    private var began = false
    private var remainder = (x: 0.0, y: 0.0)
    private var samples: [(t: Double, dx: Double, dy: Double)] = []   // output-space deltas for release velocity
    private var lastMoveTime = 0.0

    // Momentum
    private var velocity = (x: 0.0, y: 0.0)    // px/s, output space
    private var coasting = false, coastStarted = false
    private var lastFrame = 0.0
    private var interrupted: (vel: (x: Double, y: Double), axis: Axis, t: Double)?
    private var link: AnyObject?               // CADisplayLink on macOS 14+; a 120 Hz timer before that
    private var fallbackTimer: Timer?

    static let releaseMinSpeed = 150.0          // px/s needed to coast
    static let stopSpeed = 12.0                 // px/s where coasting ends
    static let maxSpeed = 14000.0

    /// Per-millisecond velocity retention, from the Glide slider (0…1).
    var decayPerMs: Double { 0.9955 + 0.003 * Defaults.scrollGlide }

    /// Touch began: catch any coasting scroll (like resting a finger on a trackpad).
    func touchBegan() {
        if coasting {
            interrupted = (velocity, axis, now())
            endCoast()
        }
        active = false; began = false; samples = []; remainder = (0, 0)
    }

    /// The touch moved far enough to be a scroll: lock the axis from the initial direction. Horizontal needs a
    /// clearly sideways swipe (within ~27° of horizontal); everything else scrolls vertically.
    func start(dx: Double, dy: Double) {
        active = true
        axis = abs(dx) > 2 * abs(dy) ? .horizontal : .vertical
        log("scroll start (\(axis))")
    }

    /// Finger moved by (dx, dy) in surface fractions (x right, y up) over dt seconds.
    func fingerMoved(dx: Double, dy: Double, dt: Double) {
        guard active else { return }
        let base = Defaults.scrollSpeed
        var ox = dx * base, oy = dy * base
        let speed = hypot(ox, oy) / max(dt, 0.001)
        let accel = 1 + min(speed / 2500, 1.5)       // fast swipes travel further
        ox *= accel; oy *= accel
        if axis == .vertical { ox = 0 } else { oy = 0 }
        let t = now()
        samples.append((t, ox, oy))
        samples.removeAll { t - $0.t > 0.1 }
        if ox != 0 || oy != 0 { lastMoveTime = t }
        emit(fingerX: ox, fingerY: oy, phase: began ? .changed : .began)
        began = true
    }

    /// Finger lifted: end the gesture and coast with the release velocity.
    func touchEnded() {
        guard active else { return }
        active = false
        if began { mouse.scroll(pixelsX: 0, pixelsY: 0, phase: .ended) }
        let t = now()
        // Least-squares-free estimate: displacement over the last 100 ms; a pause before lifting means no coast.
        guard t - lastMoveTime < 0.05, let first = samples.first else { samples = []; return }
        let span = max(t - first.t, 1.0 / 60)
        var v = samples.reduce((x: 0.0, y: 0.0)) { (x: $0.x + $1.dx, y: $0.y + $1.dy) }
        v = (v.x / span, v.y / span)
        samples = []
        // Flick again in the same direction while it was still coasting → it builds speed, like a trackpad.
        if let i = interrupted, i.axis == axis, t - i.t < 0.8,
           (v.x * i.vel.x > 0 || v.y * i.vel.y > 0) {
            v = (v.x + i.vel.x * 0.8, v.y + i.vel.y * 0.8)
        }
        interrupted = nil
        let s = hypot(v.x, v.y)
        guard s > Self.releaseMinSpeed else { return }
        if s > Self.maxSpeed { v = (v.x * Self.maxSpeed / s, v.y * Self.maxSpeed / s) }
        velocity = v
        coasting = true; coastStarted = false; lastFrame = now()
        startFrames()
    }

    private func emit(fingerX: Double, fingerY: Double, phase: Mouse.ScrollPhase, momentum: Mouse.MomentumPhase = .none) {
        let sign = Defaults.naturalScroll ? 1.0 : -1.0
        let wy = -fingerY * sign + remainder.y     // natural: finger up → content moves up (reveals below)
        let wx = fingerX * sign + remainder.x      // natural: finger right → content moves right (reveals left)
        let iy = wy.rounded(.towardZero), ix = wx.rounded(.towardZero)
        remainder = (wx - ix, wy - iy)
        mouse.scroll(pixelsX: Int32(ix), pixelsY: Int32(iy), phase: phase, momentum: momentum)
    }

    // Display-synchronised momentum frames.
    private func startFrames() {
        if #available(macOS 14.0, *) {
            if link == nil, let l = NSScreen.main?.displayLink(target: self, selector: #selector(frame)) {
                l.add(to: .main, forMode: .common)
                link = l
            }
        }
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.isPaused = false }
        else if fallbackTimer == nil {
            fallbackTimer = commonTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.frame() }
        }
    }

    private func stopFrames() {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.isPaused = true }
        fallbackTimer?.invalidate(); fallbackTimer = nil
    }

    @objc private func frame() {
        guard coasting else { stopFrames(); return }
        let t = now()
        let dtMs = min((t - lastFrame) * 1000, 50)
        lastFrame = t
        let k = pow(decayPerMs, dtMs)
        velocity = (velocity.x * k, velocity.y * k)
        if hypot(velocity.x, velocity.y) < Self.stopSpeed { endCoast(); return }
        emit(fingerX: velocity.x * dtMs / 1000, fingerY: velocity.y * dtMs / 1000, phase: .none,
             momentum: coastStarted ? .continue : .begin)
        coastStarted = true
    }

    private func endCoast() {
        if coastStarted { mouse.scroll(pixelsX: 0, pixelsY: 0, phase: .none, momentum: .end) }
        coasting = false; coastStarted = false; velocity = (0, 0)
        stopFrames()
    }
}

// MARK: - Pointer logic

final class Pointer {
    let mouse = Mouse()
    lazy var scroller = Scroller(mouse: mouse)
    var touching = false
    var motionActive = false            // a motion report arrived recently
    var lastMotion = 0.0, lastTouch = 0.0, lastEnableSent = 0.0
    var freezeUntil = 0.0
    var bias = [0.0, 0.0, 0.0]          // gyro pitch/roll/yaw bias in counts
    var stillCount = 0
    var gMean = [0.0, 0.0, 0.0], gVar = [100.0, 100.0, 100.0]
    // Pointer ballistics (Samsung/LG "Magic Remote"-style): smoothed rates, low-speed damping, stillness lock.
    let filterH = OneEuro(minCutoff: 1.2, beta: 0.015), filterV = OneEuro(minCutoff: 1.2, beta: 0.015)
    var locked = true, slowSince = 0.0
    static let lockBelow = 1.8          // °/s: hand this still for `lockAfter` → cursor locks completely
    static let unlockAbove = 5.0        // °/s: a quick deliberate move releases at once
    static let lockAfter = 0.15
    static let precisionEnd = 9.0       // °/s: below this, motion is progressively damped (fine control, no creep)
    static let precisionFloor = 0.3     // slowest motion still moves at this fraction of normal gain
    // A slow, small, deliberate nudge never reaches `unlockAbove`, but it does turn the remote steadily one way;
    // tremor jiggles back and forth around a point. So while locked, integrate rotation (leaking, so residual gyro
    // bias can't build up) and release once it has turned this far in one direction.
    static let unlockDegrees = 0.3
    static let unlockLeak = 0.6         // s: time constant of that integral
    var lockedAngle: (h: Double, v: Double) = (0, 0)
    static let touchSettle = 0.06       // s: ignore the nudge from pressing the thumb down
    var buttons: UInt8 = 0
    var volumeTimer: Timer?
    var siriDownAt = 0.0, siriStartedThisPress = false
    var siriPending: Timer?
    // Zoom mode (Play/Pause + Siri held): tilting up/down pinch-zooms the app under the cursor.
    var zoomActive = false
    static let zoomPerDegree = 0.012            // pinch magnification per degree of tilt
    // Double-tap on the touch surface (no click) = smart zoom.
    var lastTapEnd = 0.0
    var clickedThisTouch = false
    static let tapMaxDuration = 0.22, tapMaxMove = 0.06, doubleTapGap = 0.35
    var pinchCandidate = false
    var lastPos: (x: Double, y: Double) = (0, 0)
    static let pinchStartMove = 0.05            // vertical travel that turns a second touch into a pinch
    static let pinchPerSurface = 2.5            // magnification change for a full-surface drag
    // NX_KEYTYPE_PLAY = 16, FAST = 19, REWIND = 20 (what the F8/F9/F7 media keys send)
    // Play/Pause: 1× play/pause, 2× fast-forward, 3× rewind; hold = cycle this app's windows (⌘`, repeating).
    lazy var playClicks = ClickCounter(
        onClicks: { [unowned self] n in
            switch n {
            case 1: self.mouse.mediaKey(16)
            case 2: self.mouse.mediaKey(19)
            default: self.mouse.mediaKey(20)
            }
        },
        onHold: { [unowned self] _ in self.mouse.key(50, flags: .maskCommand) },   // ⌘`
        holdRepeat: 0.7)
    // TV/Home: 1× right click, 2× Return, 3× Mission Control; hold = app switcher (turn left/right to pick, release to switch).
    lazy var tvClicks = ClickCounter(
        onClicks: { [unowned self] n in
            switch n {
            case 1: self.mouse.button(.right, down: true); self.mouse.button(.right, down: false)
            case 2: self.mouse.key(36)                    // Return
            default: SystemAction.missionControl()
            }
        },
        onHold: { [unowned self] _ in
            self.mouse.modifier(55, .maskCommand, down: true)
            self.mouse.key(48, flags: .maskCommand)       // ⌘Tab opens the switcher on the next app
            self.switcherActive = true; self.switcherAccum = 0; self.switcherStart = now()
            if !self.motionActive { Remote.shared.setMotion(true) }
        },
        onHoldEnd: { [unowned self] in
            self.switcherActive = false
            self.mouse.modifier(55, .maskCommand, down: false)   // releasing ⌘ switches to the selection
        })
    // Menu: 1× Back (⌘[), 2× Backspace; press then press-and-hold = delete word by word (⌥⌫, repeating).
    lazy var menuClicks = ClickCounter(
        maxCount: 2,
        onClicks: { [unowned self] n in
            if n == 1 { self.mouse.key(0x21, flags: .maskCommand) }   // ⌘[
            else { self.mouse.key(51) }                               // ⌫
        },
        onHold: { [unowned self] n in if n >= 2 { self.mouse.key(51, flags: .maskAlternate) } },  // ⌥⌫
        holdRepeat: 0.25)
    // App switcher: while TV is held, turning the remote left/right moves the selection (faster turn = more apps).
    var switcherActive = false
    var switcherAccum = 0.0
    var switcherStart = 0.0
    static let switcherStepDegrees = 4.0

    // Touch gesture state
    enum TouchMode { case undecided, point, scroll, edge(EdgeGesture), pinch, done }
    enum EdgeGesture { case notificationCenter, dismissNotificationCenter }
    var mode: TouchMode = .undecided
    var touchStart: (x: Double, y: Double) = (0, 0)
    var smooth: (x: Double, y: Double) = (0, 0)
    var lastTouchTime = 0.0

    // A touch becomes a scroll only for a deliberate swipe. The 7×8 sensor's contact point wanders as the thumb
    // rolls while the remote is moved, so require: enough travel, made quickly (a swipe, not drift), while the
    // remote itself is fairly still, and before this touch has been used to point.
    static let scrollStartDistance = 0.16       // fraction of the surface
    static let swipeMinSpeed = 0.9              // surface widths per second over the last ~120 ms
    static let pointingGyroLimit = 120.0        // °/s: only a fast sweep of the remote vetoes a swipe
    static let pointedLockPixels = 80.0         // a touch that has clearly been pointing (this far, for
    static let pointedLockAge = 0.3             //   at least this long) stays a point
    var touchBeganAt = 0.0
    var peakSwipeSpeed = 0.0, maxGyroDuringTouch = 0.0
    var touchTrail: [(t: Double, x: Double, y: Double)] = []
    var gyroSpeed = 0.0                          // smoothed |rotation| in °/s
    var pointedThisTouch = 0.0
    static let rightEdgeStart = 0.72             // touches starting right of this can open Notification Center
                                                 // (the 7-column sensor rarely reports x above ~0.87)
    static let edgeTrigger = 0.25                // leftward travel that fires it
    static let dismissTrigger = 0.12             // rightward travel that closes it (fires before a scroll can start)
    static let countsPerDPS = 16.4               // ITG-3600 class gyro at ±2000 °/s
    static let deadZoneDPS = 1.5

    var pointing: Bool {
        if case .scroll = mode { return false }
        if case .edge = mode { return false }
        if case .done = mode { return false }
        if case .pinch = mode { return false }
        if pinchCandidate { return false }          // second touch of a possible double-tap: hold the cursor
        return true
    }

    /// Gyro rates (body frame: x = pitch axis, y = pointing axis, z = face normal) → (horizontal, vertical).
    ///
    /// Cursor motion follows how the remote's tip moves relative to the screen, whatever its orientation:
    /// - vertical = rotation about the screen's left-right axis R (changes the tip's elevation),
    /// - horizontal = rotation about R × pointing (sweeps the tip sideways).
    /// Pointing level this is ordinary yaw/pitch with twist corrected; pointing at the ceiling, rotation about the
    /// screen-facing axis sweeps sideways — so after tilting up 90° and twisting 90°, the remote's own tilt moves
    /// the cursor left/right and its yaw moves it up/down. Twisting about the pointing axis never moves the cursor.
    /// The screen direction is the remote's horizontal heading while it points within ~60° of level, frozen
    /// while it points steeply (where heading is undefined).
    var screenForward: (x: Double, y: Double) = (0, 1)   // world-horizontal unit vector towards the screen
    func screenRates(_ w: [Double], quat q: (w: Double, x: Double, y: Double, z: Double)?) -> (h: Double, v: Double) {
        guard Defaults.gravityAligned, let q else { return (w[2], w[0]) }
        // Body→world rotation matrix (world z = gravity-up).
        let (qw, qx, qy, qz) = (q.w, q.x, q.y, q.z)
        let m = [[1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qw * qz), 2 * (qx * qz + qw * qy)],
                 [2 * (qx * qy + qw * qz), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qw * qx)],
                 [2 * (qx * qz - qw * qy), 2 * (qy * qz + qw * qx), 1 - 2 * (qx * qx + qy * qy)]]
        let ww = (0..<3).map { i in m[i][0] * w[0] + m[i][1] * w[1] + m[i][2] * w[2] }   // ω in world
        let p = [m[0][1], m[1][1], m[2][1]]                                              // pointing axis in world
        let horiz = hypot(p[0], p[1])
        if horiz > 0.5 { screenForward = (p[0] / horiz, p[1] / horiz) }
        let f = screenForward
        let r = [f.y, -f.x, 0.0]                                                         // R = F × up
        let a = [r[1] * p[2] - r[2] * p[1], r[2] * p[0] - r[0] * p[2], r[0] * p[1] - r[1] * p[0]]  // R × p
        let h = ww[0] * a[0] + ww[1] * a[1] + ww[2] * a[2]
        let v = ww[0] * r[0] + ww[1] * r[1] + ww[2] * r[2]
        return (h, v)
    }

    func onMotion(gyro g: [Double], quat q: (w: Double, x: Double, y: Double, z: Double)?) {
        let t = now()
        if !motionActive { log("motion stream on") }
        motionActive = true; lastMotion = t

        // Gyro bias: learn only when the remote is genuinely at rest — low variance on every axis over ~0.6 s,
        // not merely "small" readings (a slow steady turn is small but not still, and learning it causes drift).
        for i in 0..<3 {
            gMean[i] += (g[i] - gMean[i]) * 0.08
            gVar[i] += ((g[i] - gMean[i]) * (g[i] - gMean[i]) - gVar[i]) * 0.08
        }
        if (0..<3).allSatisfy({ gVar[$0] < 9 && abs(gMean[$0] - bias[$0]) < 40 }) {
            stillCount += 1
            let rate = touching ? 0.02 : 0.08          // resting untouched on a table: converge faster
            if stillCount > 40 { for i in 0..<3 { bias[i] += (gMean[i] - bias[i]) * rate } }
        } else { stillCount = 0 }

        let rawSpeed = hypot((g[0] - bias[0]) / Self.countsPerDPS, (g[2] - bias[2]) / Self.countsPerDPS)
        gyroSpeed += (rawSpeed - gyroSpeed) * 0.3
        if zoomActive {
            let r = screenRates((0..<3).map { (g[$0] - bias[$0]) / Self.countsPerDPS }, quat: q)
            var v = abs(r.v) < 2 ? 0 : r.v                        // °/s; tilt up = positive
            if Defaults.invertY { v = -v }
            if v != 0 { mouse.magnify(phase: 2, delta: v / 66.0 * Self.zoomPerDegree) }   // tilt up = zoom in
            return
        }
        if switcherActive {
            let r = screenRates((0..<3).map { (g[$0] - bias[$0]) / Self.countsPerDPS }, quat: q)
            var deg = abs(r.h) < Self.deadZoneDPS ? 0 : -r.h / 66.0        // same sign as cursor x
            if Defaults.invertX { deg = -deg }
            // Speed decides how far a turn goes: slow = one app per 4°, a fast flick covers several apps.
            let speed = abs(r.h)                                            // °/s
            switcherAccum += deg * (1 + min(max(speed - 30, 0) / 80, 2.5))
            while switcherAccum > Self.switcherStepDegrees { switcherAccum -= Self.switcherStepDegrees; mouse.key(124, flags: .maskCommand) }  // →
            while switcherAccum < -Self.switcherStepDegrees { switcherAccum += Self.switcherStepDegrees; mouse.key(123, flags: .maskCommand) } // ←
            return
        }
        guard Defaults.enabled, touching, pointing, t >= freezeUntil else { return }
        let dt = 1.0 / 66.0
        let rates = screenRates((0..<3).map { (g[$0] - bias[$0]) / Self.countsPerDPS }, quat: q)
        guard t - touchBeganAt > Self.touchSettle else { filterH.reset(); filterV.reset(); return }
        // 1. Adaptive smoothing (1€ filter): heavy at low speed to remove tremor, light when moving fast.
        var yaw = filterH.filter(rates.h, t: t)
        var pitch = filterV.filter(rates.v, t: t)
        var speed = hypot(pitch, yaw)                       // °/s
        // 2. Stillness lock with hysteresis: a nearly-still hand holds the cursor dead still.
        if locked {
            let leak = exp(-dt / Self.unlockLeak)
            lockedAngle = (lockedAngle.h * leak + yaw * dt, lockedAngle.v * leak + pitch * dt)
            if speed > Self.unlockAbove {
                locked = false; lockedAngle = (0, 0)
            } else if hypot(lockedAngle.h, lockedAngle.v) > Self.unlockDegrees {
                // Released by a small deliberate turn: apply the turn itself, at precision gain, so it isn't lost.
                locked = false; slowSince = 0
                emit(yaw: lockedAngle.h / dt * Self.precisionFloor, pitch: lockedAngle.v / dt * Self.precisionFloor, speed: 0, dt: dt)
                lockedAngle = (0, 0)
                return
            } else { return }
        } else if speed < Self.lockBelow {
            if slowSince == 0 { slowSince = t }
            if t - slowSince > Self.lockAfter { locked = true; slowSince = 0; lockedAngle = (0, 0); return }
        } else { slowSince = 0 }
        // 3. Precision zone: smoothly damp slow motion (no hard dead-zone edge, no creep), never below the floor.
        let x = min(max((speed - Self.lockBelow) / (Self.precisionEnd - Self.lockBelow), 0), 1)
        let damp = Self.precisionFloor + (1 - Self.precisionFloor) * x * x * (3 - 2 * x)   // smoothstep
        yaw *= damp; pitch *= damp; speed *= damp
        emit(yaw: yaw, pitch: pitch, speed: speed, dt: dt)
    }

    /// Ballistics: damped screen rates (°/s) → cursor motion.
    private func emit(yaw: Double, pitch: Double, speed: Double, dt: Double) {
        // Faster swings travel further.
        let gain = Defaults.pointerSpeed * (0.6 + Defaults.pointerAccel * min(speed / 120, 2.0))  // px per degree
        var dx = -yaw * dt * gain
        var dy = -pitch * dt * gain
        if Defaults.invertX { dx = -dx }
        if Defaults.invertY { dy = -dy }
        pointedThisTouch += abs(dx) + abs(dy)
        mouse.move(dx: dx, dy: dy)
    }

    func onTouch(_ down: Bool, x xf: Float, y yf: Float) {
        let t = now()
        let x = Double(xf), y = Double(yf)
        if down && !touching {                                   // touch began
            log("touch down at \(String(format: "%.2f,%.2f", x, y))")
            touchStart = (x, y); smooth = (x, y); lastTouchTime = t; lastPos = (x, y)
            touchTrail = []; pointedThisTouch = 0; touchBeganAt = t; peakSwipeSpeed = 0; maxGyroDuringTouch = 0
            locked = true; slowSince = 0; lockedAngle = (0, 0); filterH.reset(); filterV.reset(); clickedThisTouch = false
            mode = .undecided
            scroller.touchBegan()
            if Defaults.edgeGestures { mode = edgeCandidate(x, y).map { .edge($0) } ?? .undecided }
            // Touching again right after a tap: either a double-tap (smart zoom) or tap-and-drag (pinch zoom).
            pinchCandidate = Defaults.enabled && lastTapEnd > 0 && t - lastTapEnd < Self.doubleTapGap
            if pinchCandidate { mode = .undecided }
        }
        if !down && touching {                                   // touch ended
            if case .scroll = mode { log("touch up (scrolled)") } else {
                log("  mode at lift: \(mode)"); log(String(format: "touch up — no scroll: moved %.2f, peak swipe %.2f/s, max gyro %.0f°/s, pointed %.0f px",
                           hypot(smooth.x - touchStart.x, smooth.y - touchStart.y), peakSwipeSpeed, maxGyroDuringTouch, pointedThisTouch))
            }
            if case .scroll = mode { scroller.touchEnded() }
            pinchCandidate = false
            if case .pinch = mode {
                mouse.magnify(phase: 4, delta: 0); log("pinch end")
                mode = .undecided; lastTapEnd = 0
                touching = down
                return
            }
            var wasPointOrUndecided = false
            if case .undecided = mode { wasPointOrUndecided = true }
            if case .point = mode { wasPointOrUndecided = true }
            if wasPointOrUndecided && !clickedThisTouch && Defaults.enabled && t - touchBeganAt < Self.tapMaxDuration
                && hypot(lastPos.x - touchStart.x, lastPos.y - touchStart.y) < Self.tapMaxMove {   // lift frames report (0,0)
                if t - lastTapEnd < Self.doubleTapGap + Self.tapMaxDuration {
                    mouse.rewind(0.3)
                    mouse.smartMagnify(); log("double tap → smart zoom"); lastTapEnd = 0
                } else { lastTapEnd = t; log("tap") }
            }
            mode = .undecided
        }
        touching = down
        guard down else { return }
        lastTouch = t
        lastPos = (x, y)
        if !motionActive && t - lastEnableSent > 0.3 { Remote.shared.setMotion(true) }
        guard Defaults.enabled else { return }

        // Light smoothing: the 7×8 sensor is coarse, raw positions step.
        let prev = smooth
        smooth = (prev.x + (x - prev.x) * 0.5, prev.y + (y - prev.y) * 0.5)
        let dt = max(t - lastTouchTime, 0.001)
        lastTouchTime = t
        let moved = (x: x - touchStart.x, y: y - touchStart.y)

        if pinchCandidate, case .undecided = mode {
            if abs(y - touchStart.y) > Self.pinchStartMove {
                mode = .pinch; pinchCandidate = false
                mouse.magnify(phase: 1, delta: 0); log("tap-and-drag → pinch")
            } else if t - touchBeganAt > Self.tapMaxDuration && hypot(x - touchStart.x, y - touchStart.y) < Self.tapMaxMove {
                // Held still too long for a double-tap and not dragging: it's an ordinary pointing touch.
                pinchCandidate = false; lastTapEnd = 0
                touchBeganAt = t                      // restart the touch-settle window
            }
            return
        }
        switch mode {
        case .pinch:
            mouse.magnify(phase: 2, delta: (smooth.y - prev.y) * Self.pinchPerSurface)    // finger up = zoom in
            return
        case .undecided, .point:
            touchTrail.append((t, x, y))
            touchTrail.removeAll { t - $0.t > 0.12 }
            let recent = touchTrail.first.map { hypot(x - $0.x, y - $0.y) / max(t - $0.t, 0.04) } ?? 0
            peakSwipeSpeed = max(peakSwipeSpeed, recent); maxGyroDuringTouch = max(maxGyroDuringTouch, gyroSpeed)
            if pointedThisTouch > Self.pointedLockPixels && t - touchBeganAt > Self.pointedLockAge { mode = .point }
            if case .undecided = mode,
               hypot(moved.x, moved.y) > Self.scrollStartDistance,
               recent > Self.swipeMinSpeed,
               gyroSpeed < Self.pointingGyroLimit {
                mode = .scroll
                mouse.rewind(0.25)                               // undo cursor drift from the start of the swipe
                scroller.start(dx: moved.x, dy: moved.y)
            }
        case .scroll:
            scroller.fingerMoved(dx: smooth.x - prev.x, dy: smooth.y - prev.y, dt: dt)
        case .edge(let g):
            let inward: Double
            switch g {
            case .notificationCenter: inward = -moved.x          // from the right edge, moving left
            case .dismissNotificationCenter:                     // any mostly-rightward swipe
                inward = moved.x > abs(moved.y) ? moved.x : 0
            }
            let trigger = g == .dismissNotificationCenter ? Self.dismissTrigger : Self.edgeTrigger
            if inward > trigger {
                mode = .done
                mouse.rewind(0.4)
                fire(g)
            } else if hypot(moved.x, moved.y) > Self.scrollStartDistance && inward < hypot(moved.x, moved.y) * 0.5 {
                // Moving along the edge rather than inward: treat as a normal scroll.
                mode = .scroll
                mouse.rewind(0.25)
                scroller.start(dx: moved.x, dy: moved.y)
            }
        case .done:
            break
        }
    }

    func edgeCandidate(_ x: Double, _ y: Double) -> EdgeGesture? {
        if SystemAction.notificationCenterOpen() { return .dismissNotificationCenter }   // start anywhere
        return x > Self.rightEdgeStart ? .notificationCenter : nil
    }

    func fire(_ g: EdgeGesture) {
        log("edge gesture: \(g)")
        switch g {
        case .notificationCenter, .dismissNotificationCenter: SystemAction.notificationCenter()   // the clock toggles it
        }
    }

    func onButtons(_ b: UInt8) {
        let changed = b ^ buttons
        buttons = b
        func went(_ bit: UInt8) -> Bool? { changed & bit == 0 ? nil : (b & bit != 0) }
        if went(0x80) == true { clickedThisTouch = true; lastTapEnd = 0 }
        if let down = went(0x80) {            // touch-surface click → left button, rewinding the press wobble
            if down { mouse.rewind(0.08) }
            freezeUntil = now() + 0.15
            mouse.button(.left, down: down)
        }
        if let down = went(0x08) { down ? playClicks.down() : playClicks.up() }   // Play/Pause (see playClicks)
        if let down = went(0x01) { down ? tvClicks.down() : tvClicks.up() }       // TV/Home (see tvClicks)
        if let down = went(0x20) { down ? menuClicks.down() : menuClicks.up() }   // Menu (see menuClicks)
        // Play/Pause + Siri held together = zoom (tilt up/down). Takes over both buttons until both are released.
        if b & 0x18 == 0x18 && !zoomActive {
            zoomActive = true
            siriPending?.invalidate(); siriPending = nil
            playClicks.cancel()
            if Dictation.shared.active { Dictation.shared.cancel() }
            siriStartedThisPress = false
            if !motionActive { Remote.shared.setMotion(true) }
            mouse.magnify(phase: 1, delta: 0)
            log("zoom mode on")
        }
        if zoomActive {
            if b & 0x18 == 0 { zoomActive = false; mouse.magnify(phase: 4, delta: 0); log("zoom mode off") }
            return
        }
        if let down = went(0x10) {            // Siri → dictation: hold = push-to-talk, quick tap = toggle
            let d = Dictation.shared
            if down {
                siriDownAt = now()
                if d.active { d.stop(); siriStartedThisPress = false }
                else {
                    // Brief grace period so pressing Play/Pause alongside becomes zoom rather than dictation.
                    siriPending = commonTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                        guard let self else { return }
                        self.siriPending = nil
                        self.siriStartedThisPress = d.start()   // a quick tap leaves it running (toggle mode)
                    }
                }
            } else {
                if let pending = siriPending { pending.fire() }      // quick tap: start now (toggle mode)
                else if siriStartedThisPress && now() - siriDownAt > 0.4 { d.stop() }
            }
        }
        for (bit, key) in [(UInt8(0x02), 0), (UInt8(0x04), 1)] {   // Volume → system volume, repeating while held
            guard let down = went(bit) else { continue }
            volumeTimer?.invalidate(); volumeTimer = nil
            if down {
                mouse.mediaKey(key)
                volumeTimer = commonTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.mouse.mediaKey(key) }
                volumeTimer?.fireDate = Date().addingTimeInterval(0.4)
            }
        }
    }

    /// Keep motion on while in use; turn it off after a quiet spell to save the remote's battery.
    func tick() {
        let t = now()
        if motionActive && t - lastMotion > 0.4 { motionActive = false; log("motion stream stopped") }
        if (touching || switcherActive || zoomActive) && !motionActive && t - lastEnableSent > 0.5 { Remote.shared.setMotion(true) }
        // Never switch motion off while the app switcher is open; it steers the selection.
        if motionActive && !touching && !switcherActive && !zoomActive && t - lastTouch > 15 { Remote.shared.setMotion(false); motionActive = false }
        // Keep the stream alive during a long switcher hold (re-enable if it stops; refresh every few seconds).
        if switcherActive && t - lastEnableSent > 4 { Remote.shared.setMotion(true) }
        // Failsafe: never leave ⌘ held if the release never arrives.
        if switcherActive && t - switcherStart > 30 { log("switcher failsafe release"); tvClicks.up() }
    }
}

let pointer = Pointer()

// MARK: - Remote HID (buttons, motion, keyhole commands)

final class Remote {
    static let shared = Remote()
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    var commandDevice: IOHIDDevice?
    var connected: Bool { commandDevice != nil }
    var buffers: [UnsafeMutablePointer<UInt8>] = []

    func start() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x004C, kIOHIDProductIDKey: 0x0266] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, d in Remote.shared.attach(d) }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, d in Remote.shared.detach(d) }, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    func usage(_ d: IOHIDDevice) -> (Int, Int) {
        (IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0,
         IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0)
    }

    func attach(_ d: IOHIDDevice) {
        let (page, use) = usage(d)
        switch (page, use) {
        case (0x000C, 0x0001):   // buttons: seize so Play/Pause and Volume don't also reach the system
            var r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if r != kIOReturnSuccess { log("seize buttons failed \(String(format: "0x%08X", UInt32(bitPattern: r))); opening shared"); r = IOHIDDeviceOpen(d, 0) }
            listen(d) { id, bytes in if id == 0xFA, bytes.count >= 2 { pointer.onButtons(bytes[1]) } }
        case (0xFF00, 0x0010):   // sensors
            IOHIDDeviceOpen(d, 0)
            listen(d) { id, bytes in
                guard id == 1, bytes.count >= 25 else { return }
                let g = (0..<3).map { k -> Double in Double(Int16(bitPattern: UInt16(bytes[19 + 2 * k]) | UInt16(bytes[20 + 2 * k]) << 8)) }
                // Orientation quaternion vector part (x, y, z) as f32; w is implied non-negative.
                let f: [Double] = (0..<3).map { k in
                    var v: Float = 0
                    bytes.withUnsafeBytes { raw in v = raw.loadUnaligned(fromByteOffset: 1 + 4 * k, as: Float.self) }
                    return Double(v)
                }
                let n2 = f[0] * f[0] + f[1] * f[1] + f[2] * f[2]
                let q = n2 <= 1.0001 && n2.isFinite ? (w: (max(0, 1 - n2)).squareRoot(), x: f[0], y: f[1], z: f[2]) : nil
                pointer.onMotion(gyro: g, quat: q)
            }
        case (0x000C, 0x0004):   // microphone interface: use it to send keyhole commands
            IOHIDDeviceOpen(d, 0)
            commandDevice = d
            log("remote connected")
            Touch.shared.rescan()
            StatusMenu.shared.refresh()
        default: break
        }
    }

    func detach(_ d: IOHIDDevice) {
        if d == commandDevice {
            commandDevice = nil
            // The remote went away mid-press: release anything held so ⌘ etc. don't stay stuck down.
            if pointer.buttons & 0x01 != 0 { pointer.tvClicks.up() }
            if pointer.buttons & 0x08 != 0 { pointer.playClicks.up() }
            if pointer.mouse.leftDown { pointer.mouse.button(.left, down: false) }
            pointer.buttons = 0
            Touch.shared.attached = false   // the multitouch device is recreated on reconnect
            log("remote disconnected"); StatusMenu.shared.refresh()
        }
    }

    func listen(_ d: IOHIDDevice, _ handler: @escaping (UInt32, [UInt8]) -> Void) {
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 512); buffers.append(buf)
        let box = Unmanaged.passRetained(HandlerBox(handler)).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(d, buf, 512, { ctx, _, _, _, id, report, len in
            let h = Unmanaged<HandlerBox>.fromOpaque(ctx!).takeUnretainedValue()
            h.fn(id, Array(UnsafeBufferPointer(start: report, count: len)))
        }, box)
    }

    func setMotion(_ on: Bool) {
        guard let d = commandDevice else { return }
        var payload: [UInt8] = [0xA0, on ? 1 : 0]
        let r = IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 0xA0, &payload, payload.count)
        pointer.lastEnableSent = now()
        log("motion \(on ? "on" : "off") → \(String(format: "0x%08X", UInt32(bitPattern: r)))")
    }
}

final class HandlerBox { let fn: (UInt32, [UInt8]) -> Void; init(_ f: @escaping (UInt32, [UInt8]) -> Void) { fn = f } }

// MARK: - Touch (private MultitouchSupport) — the clutch

final class Touch {
    static let shared = Touch()
    let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    var attached = false
    var lists: [CFArray] = []          // keep device lists (and their devices) alive while callbacks are registered

    func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    func rescan() {
        guard !attached else { return }
        guard let create = sym("MTDeviceCreateList", MTDeviceCreateListFn.self),
              let register = sym("MTRegisterContactFrameCallback", MTRegisterContactFrameCallbackFn.self),
              let start = sym("MTDeviceStart", MTDeviceStartFn.self),
              let family = sym("MTDeviceGetFamilyID", MTDeviceGetFamilyIDFn.self),
              let list = create()?.takeRetainedValue() else { log("MultitouchSupport unavailable"); return }
        for i in 0..<CFArrayGetCount(list) {
            guard let dev = CFArrayGetValueAtIndex(list, i) else { continue }
            let ref = UnsafeMutableRawPointer(mutating: dev)
            var fam: Int32 = 0
            _ = family(ref, &fam)
            guard fam == 160 else { continue }   // 160 = Siri Remote (7×8 sensor)
            register(ref) { _, touches, n, _, _ in
                var down = false, x: Float = 0, y: Float = 0
                if let touches {
                    for k in 0..<Int(n) where [3, 4].contains(touches[k].state) {
                        down = true; x = touches[k].normalized.pos.x; y = touches[k].normalized.pos.y; break
                    }
                }
                DispatchQueue.main.async { pointer.onTouch(down, x: x, y: y) }
                return 0
            }
            start(ref, 0)
            attached = true
            lists.append(list)
            log("touch surface attached")
        }
    }
}

// MARK: - Menu bar

/// Controls cheatsheet shown in the menu bar menu. KEEP THIS IN SYNC whenever a control is added or changed.
enum Cheatsheet {
    static let sections: [(String, [(String, String)])] = [
        ("Touch surface", [
            ("Rest finger + move remote", "Move pointer"),
            ("Click", "Left click"),
            ("Swipe", "Scroll (with momentum)"),
            ("Double-tap", "Smart zoom"),
            ("Tap, then drag up/down", "Pinch zoom"),
            ("Swipe in from right edge", "Open Notification Center"),
            ("Swipe right (while open)", "Close Notification Center"),
        ]),
        ("TV / Home", [
            ("Press", "Right click"),
            ("Press twice", "Return"),
            ("Press 3×", "Mission Control"),
            ("Hold + turn left/right", "App switcher (release to switch)"),
        ]),
        ("Play / Pause", [
            ("Press", "Play / pause"),
            ("Press twice", "Fast-forward"),
            ("Press 3×", "Rewind"),
            ("Hold", "Cycle the app's windows (⌘`)"),
            ("Hold + Siri, tilt up/down", "Zoom in / out"),
        ]),
        ("Menu", [
            ("Press", "Back (⌘[)"),
            ("Press twice", "Backspace"),
            ("Press, then press and hold", "Delete word by word"),
        ]),
        ("Siri", [
            ("Hold", "Dictate while held"),
            ("Tap", "Start / stop dictation"),
        ]),
        ("Volume", [
            ("+ / −", "System volume (repeats while held)"),
        ]),
    ]

    static func menuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Controls Cheatsheet", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 230)]
        let font = NSFont.menuFont(ofSize: 0)
        for (i, (title, rows)) in sections.enumerated() {
            if i > 0 { sub.addItem(.separator()) }
            let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            h.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: font.pointSize)])
            h.isEnabled = false
            sub.addItem(h)
            for (input, action) in rows {
                let r = NSMenuItem(title: "", action: #selector(Cheatsheet.Target.noop), keyEquivalent: "")
                r.target = Target.shared
                let s = NSMutableAttributedString(string: input + "\t", attributes: [.font: font, .paragraphStyle: para, .foregroundColor: NSColor.secondaryLabelColor])
                s.append(NSAttributedString(string: action, attributes: [.font: font, .paragraphStyle: para, .foregroundColor: NSColor.labelColor]))
                r.attributedTitle = s
                sub.addItem(r)
            }
        }
        root.submenu = sub
        return root
    }

    // Rows are enabled (so text isn't greyed out) but do nothing when chosen.
    final class Target: NSObject { static let shared = Target(); @objc func noop() {} }
}

final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()
    var item: NSStatusItem?
    let menu = NSMenu()

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "Remote Pointer")
        item.menu = menu
        menu.delegate = self
        self.item = item
        refresh()
    }

    private var isOpen = false, refreshPending = false
    func menuWillOpen(_ menu: NSMenu) { isOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        if refreshPending { refreshPending = false; refresh() }
    }

    /// Rebuild the menu (deferred while it's open, so status changes don't yank items out from under the pointer).
    func refresh() {
        if isOpen { refreshPending = true; return }
        menu.removeAllItems()
        let status = NSMenuItem(title: Remote.shared.connected ? "Siri Remote connected" : "Siri Remote not connected", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let vm = NSMenuItem(title: VirtualMouse.shared.connected ? "Universal Control: virtual mouse on"
                                                                  : "Universal Control: off (virtual mouse helper not running)",
                            action: nil, keyEquivalent: "")
        vm.isEnabled = false
        menu.addItem(vm)
        let linked = Peers.shared.linked, active = Peers.shared.active
        let peers = NSMenuItem(title: linked.isEmpty ? "Other Macs: none linked"
                                      : "Linked: " + linked.map { $0 == active ? "\($0) (pointer here)" : $0 }.joined(separator: ", "),
                               action: nil, keyEquivalent: "")
        peers.isEnabled = false
        menu.addItem(peers)
        menu.addItem(.separator())
        add("Enabled", #selector(toggleEnabled), on: Defaults.enabled)
        menu.addItem(Cheatsheet.menuItem())
        menu.addItem(.separator())
        header("Pointer")
        slider("Speed", 10, 120, Defaults.pointerSpeed) { Defaults.pointerSpeed = $0 }
        slider("Acceleration", 0, 2, Defaults.pointerAccel) { Defaults.pointerAccel = $0 }
        add("Invert Horizontal", #selector(toggleInvertX), on: Defaults.invertX)
        add("Invert Vertical", #selector(toggleInvertY), on: Defaults.invertY)
        add("Gravity-Aligned (ignore twist)", #selector(toggleGravity), on: Defaults.gravityAligned)
        menu.addItem(.separator())
        header("Scrolling")
        slider("Speed", 400, 2200, Defaults.scrollSpeed) { Defaults.scrollSpeed = $0 }
        slider("Momentum", 0, 1, Defaults.scrollGlide) { Defaults.scrollGlide = $0 }
        add("Natural Scrolling", #selector(toggleNatural), on: Defaults.naturalScroll)
        menu.addItem(.separator())
        add("Edge Swipe for Notification Center", #selector(toggleEdges), on: Defaults.edgeGestures)
        let help = NSMenuItem(title: "Swipe in from the right edge to open, back out over it to close", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
        menu.addItem(.separator())
        header("Other Macs (Universal Control)")
        add("Copy Pairing Key", #selector(copyKey), on: nil)
        add("Paste Pairing Key from Clipboard", #selector(pasteKey), on: nil)
        menu.addItem(.separator())
        add("Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        add("Quit Remote Pointer", #selector(quit), on: nil, key: "q")
    }

    func header(_ title: String) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        menu.addItem(i)
    }

    func slider(_ title: String, _ min: Double, _ max: Double, _ value: Double, _ set: @escaping (Double) -> Void) {
        let i = NSMenuItem()
        i.view = SliderView(title: title, min: min, max: max, value: value, onChange: set)
        menu.addItem(i)
    }

    func add(_ title: String, _ sel: Selector, on: Bool?, key: String = "") {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        if let on { i.state = on ? .on : .off }
        menu.addItem(i)
    }

    @objc func copyKey() { Peers.shared.copyKey(); Overlay.shared.flash("Pairing key copied — paste it into RemotePointer on your other Mac") }
    @objc func pasteKey() {
        Overlay.shared.flash(Peers.shared.pasteKey() ? "Pairing key saved — linking…" : "No RemotePointer pairing key on the clipboard")
    }
    @objc func toggleEnabled() { Defaults.enabled.toggle(); refresh() }
    @objc func toggleInvertX() { Defaults.invertX.toggle(); refresh() }
    @objc func toggleInvertY() { Defaults.invertY.toggle(); refresh() }
    @objc func toggleNatural() { Defaults.naturalScroll.toggle(); refresh() }
    @objc func toggleGravity() { Defaults.gravityAligned.toggle(); refresh() }
    @objc func toggleEdges() { Defaults.edgeGestures.toggle(); refresh() }
    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do { if svc.status == .enabled { try svc.unregister() } else { try svc.register() } }
        catch { log("login item: \(error)") }
        refresh()
    }
    @objc func quit() { Remote.shared.setMotion(false); NSApp.terminate(nil) }
}

/// 1€ filter (Casiez et al.): a low-pass whose cutoff rises with speed — strong jitter removal when slow,
/// little lag when fast. Standard for pointing devices.
final class OneEuro {
    let minCutoff: Double, beta: Double, dCutoff: Double
    private var x: Double?, dx = 0.0, lastT = 0.0
    init(minCutoff: Double, beta: Double, dCutoff: Double = 1.0) { self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff }
    private func alpha(_ cutoff: Double, _ dt: Double) -> Double { let tau = 1 / (2 * .pi * cutoff); return 1 / (1 + tau / dt) }
    func reset() { x = nil; dx = 0 }
    func filter(_ value: Double, t: Double) -> Double {
        guard let prev = x else { x = value; lastT = t; return value }
        let dt = max(t - lastT, 1.0 / 240); lastT = t
        let a = alpha(dCutoff, dt)
        dx = a * ((value - prev) / dt) + (1 - a) * dx
        let v = alpha(minCutoff + beta * abs(dx), dt) * (value - prev) + prev
        x = v
        return v
    }
}

/// Counts presses that arrive within the double-click interval of each other, then reports the total once the
/// sequence ends (or immediately on reaching maxCount).
/// A press held past `holdAfter` becomes a hold instead: onHold fires (and repeats every `holdRepeat` while held),
/// onHoldEnd fires on release, and any pending clicks are discarded.
final class ClickCounter {
    let maxCount: Int
    let onClicks: (Int) -> Void
    let onHold: ((Int) -> Void)?
    let holdRepeat: Double?
    let onHoldEnd: (() -> Void)?
    static let holdAfter = 0.45
    private var count = 0
    private var clickTimer: Timer?, holdTimer: Timer?, repeatTimer: Timer?
    private var holding = false

    init(maxCount: Int = 3, onClicks: @escaping (Int) -> Void, onHold: ((Int) -> Void)? = nil,
         holdRepeat: Double? = nil, onHoldEnd: (() -> Void)? = nil) {
        self.maxCount = maxCount; self.onClicks = onClicks; self.onHold = onHold
        self.holdRepeat = holdRepeat; self.onHoldEnd = onHoldEnd
    }

    func down() {
        count += 1
        clickTimer?.invalidate(); clickTimer = nil
        guard let onHold else { if count >= maxCount { fire() }; return }
        holdTimer = commonTimer(withTimeInterval: Self.holdAfter, repeats: false) { [weak self] _ in
            guard let self else { return }
            let n = self.count
            self.holding = true; self.count = 0
            log("hold after \(n) press(es)")
            onHold(n)
            if let r = self.holdRepeat {
                self.repeatTimer = commonTimer(withTimeInterval: r, repeats: true) { _ in onHold(n) }
            }
        }
    }

    func up() {
        holdTimer?.invalidate(); holdTimer = nil
        if holding {
            holding = false
            repeatTimer?.invalidate(); repeatTimer = nil
            onHoldEnd?()
            return
        }
        if count >= maxCount { fire(); return }
        clickTimer = commonTimer(withTimeInterval: min(NSEvent.doubleClickInterval, 0.35), repeats: false) { [weak self] _ in self?.fire() }
    }

    /// Abandon the current press sequence (e.g. the button became part of a combo).
    func cancel() {
        clickTimer?.invalidate(); clickTimer = nil
        holdTimer?.invalidate(); holdTimer = nil
        repeatTimer?.invalidate(); repeatTimer = nil
        if holding { holding = false; onHoldEnd?() }
        count = 0
    }

    private func fire() {
        clickTimer?.invalidate(); clickTimer = nil
        let n = count; count = 0
        guard n > 0 else { return }
        log("click ×\(n)")
        onClicks(n)
    }
}

/// A labelled slider row for the menu.
final class SliderView: NSView {
    let onChange: (Double) -> Void
    init(title: String, min: Double, max: Double, value: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 20, y: 6, width: 90, height: 16)
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        s.frame = NSRect(x: 110, y: 4, width: 135, height: 20)
        s.isContinuous = true
        s.target = self
        s.action = #selector(changed(_:))
        addSubview(label); addSubview(s)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func changed(_ s: NSSlider) { onChange(s.doubleValue) }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    print("Grant Accessibility (System Settings → Privacy & Security → Accessibility) so cursor/click events are delivered, then relaunch.")
}

StatusMenu.shared.install()
VirtualMouse.shared.ensureConnected()
Peers.shared.start()
// The driver recreates its device when it reloads, which resets acceleration; reapply now and then.
commonTimer(withTimeInterval: 30, repeats: true) { _ in
    if VirtualMouse.shared.ensureConnected() { VirtualMouse.makeLinear() }
}
Dictation.shared.requestPermissions()
Remote.shared.start()
Touch.shared.rescan()
commonTimer(withTimeInterval: 0.1, repeats: true) { _ in pointer.tick() }
commonTimer(withTimeInterval: 2, repeats: true) { _ in if Remote.shared.connected { Touch.shared.rescan() } }
signal(SIGINT) { _ in Remote.shared.setMotion(false); exit(0) }
print("Remote Pointer running (menu bar). Touch the remote and turn it to point. Ctrl-C to quit.")
app.run()
