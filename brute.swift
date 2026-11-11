// brute: probe the Siri Remote's (A1513) 0xFF feature-report gateway on its sensor/vendor interfaces,
// while watching every input report for anything new (motion data).
//
// Phase "scan" (default): for each target interface, for inner id 0..255:
//   SET feature [0xFF, id]  then  GET feature 0xFF  → log any response longer than the 1-byte "FF" echo.
// Phase "poke <iface> <hex bytes...>": SET feature [0xFF, bytes...] on one interface, then watch input for 3 s.
//
// Excludes 0xFF00/0x0010 (has extra report ids 0x01/0x02 — possibly firmware update; don't touch).
// Build: swiftc -O brute.swift -o brute

import Foundation
import IOKit.hid

setvbuf(stdout, nil, _IOLBF, 0)
let start = Date()
func ts() -> String { String(format: "%7.3f", Date().timeIntervalSince(start)) }
func hexs(_ b: UnsafePointer<UInt8>, _ n: Int) -> String { (0..<n).map { String(format: "%02X", b[$0]) }.joined(separator: " ") }
func hexs(_ a: [UInt8]) -> String { a.map { String(format: "%02X", $0) }.joined(separator: " ") }

struct Iface { let page: Int; let usage: Int; let dev: IOHIDDevice
    var name: String { String(format: "%04X/%04X", page, usage) } }

let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x004C, kIOHIDProductIDKey: 0x0266] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let devs = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
var ifaces: [Iface] = devs.map {
    Iface(page: IOHIDDeviceGetProperty($0, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0,
          usage: IOHIDDeviceGetProperty($0, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0, dev: $0)
}.sorted { $0.name < $1.name }
guard !ifaces.isEmpty else { print("Remote not found — is it paired and awake?"); exit(1) }

// Watch input on every interface. Report 0xFA with all-zero buttons is the known idle/touch heartbeat: count, don't print.
var heartbeat = 0, novel = 0
var siriDown = false
var samples: [[Double]] = []
var removed = false
IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, _ in removed = true }, nil)
var buffers: [UnsafeMutablePointer<UInt8>] = []
for i in ifaces {
    IOHIDDeviceOpen(i.dev, 0)
    IOHIDDeviceScheduleWithRunLoop(i.dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 512); buffers.append(buf)
    let label = Unmanaged.passRetained(i.name as NSString).toOpaque()
    IOHIDDeviceRegisterInputReportCallback(i.dev, buf, 512, { ctx, _, _, _, id, report, len in
        if id == 0xFA && len == 2 { siriDown = report[1] & 0x10 != 0 }
        if id == 0xFA && len == 2 && report[1] == 0 { heartbeat += 1; return }
        novel += 1
        let name = Unmanaged<NSString>.fromOpaque(ctx!).takeUnretainedValue()
        print("\(ts())   INPUT \(name) id 0x\(String(id, radix: 16)) len \(len): \(hexs(report, len))")
    }, label)
}

func spin(_ s: Double) { CFRunLoopRunInMode(.defaultMode, s, false) }

func set(_ i: Iface, _ bytes: [UInt8]) -> IOReturn {
    var b = bytes
    return IOHIDDeviceSetReport(i.dev, kIOHIDReportTypeFeature, CFIndex(b[0]), &b, b.count)
}
func get(_ i: Iface, _ id: Int = 0xFF) -> (IOReturn, [UInt8]) {
    var b = [UInt8](repeating: 0, count: 256); var n = b.count
    let r = IOHIDDeviceGetReport(i.dev, kIOHIDReportTypeFeature, CFIndex(id), &b, &n)
    return (r, r == kIOReturnSuccess ? Array(b[0..<n]) : [])
}
func err(_ r: IOReturn) -> String { String(format: "0x%08X", UInt32(bitPattern: r)) }

let args = Array(CommandLine.arguments.dropFirst())
let excluded = ["FF00/0010"]

// Validation: does a SET through these interfaces reach the remote at all? While Siri is held, send the
// known mic-enable command (keyhole 0x98 = 1) through every interface; real audio frames prove the path.
if args.first == "siri" {
    let paths = ifaces.filter { !excluded.contains($0.name) }
    let secs = args.count > 1 ? Double(args[1]) ?? 30 : 30
    print("\(ts()) Hold the Siri button for a few seconds, release, repeat a couple of times. \(Int(secs)) s.")
    var wasDown = false
    let end = Date().addingTimeInterval(secs)
    while Date() < end {
        spin(0.02)
        if siriDown && !wasDown {
            let r = set(ifaces.first { $0.name == "000C/0004" }!, [0x98, 0x01])
            print("\(ts()) Siri down → keyhole [98 01] → \(err(r))")
        }
        wasDown = siriDown
    }
    print("\(ts()) done: heartbeat \(heartbeat), novel input \(novel)")
    exit(0)
}

// map [fromHex] [toHex]: for each keyhole command id, find which payload lengths the remote accepts, writing all-zero
// values (usually "off"). The remote validates length per command (ATT error 13 otherwise), so this maps the command
// table without enabling anything. Skips length 1 (bare commands = actions like reset) and 0xFF (the wrapper id).
if args.first == "map" {
    let via = ifaces.first { $0.name == "000C/0004" }!
    let from = args.count > 1 ? Int(args[1], radix: 16)! : 0x00
    let to = args.count > 2 ? Int(args[2], radix: 16)! : 0xFE
    let lengths = Array(2...12) + [13, 16, 17, 20, 21, 24, 25, 32]
    var accepted: [String] = []
    var consecutiveTimeouts = 0
    for id in from...to {
        print("\(ts()) · trying id 0x\(String(format: "%02X", id))")
        var found: [Int] = []
        for len in lengths {
            var payload = [UInt8](repeating: 0, count: len); payload[0] = UInt8(id)
            let r = set(via, payload)
            spin(0)
            if removed { print("\(ts()) remote DISCONNECTED after id 0x\(String(format: "%02X", id)) len \(len) (or just before)"); exit(3) }
            if r == kIOReturnSuccess { found.append(len); break }
            if r == IOReturn(bitPattern: 0xE00002D6) || r == IOReturn(bitPattern: 0xE00002D8) {
                consecutiveTimeouts += 1
                print("\(ts()) id 0x\(String(format: "%02X", id)) len \(len): \(err(r)) (timeout/not responding)")
                if consecutiveTimeouts > 5 { print("remote stopped responding — aborting"); exit(2) }
                spin(1)
            } else { consecutiveTimeouts = 0 }
        }
        if !found.isEmpty {
            let line = "id 0x\(String(format: "%02X", id)) accepts len \(found[0])"
            accepted.append(line)
            print("\(ts()) \(line)")
        }
        spin(0.005)
    }
    spin(1)
    print("\(ts()) map done 0x\(String(format: "%02X", from))–0x\(String(format: "%02X", to)): \(accepted.count) commands; novel input \(novel)")
    accepted.forEach { print("  \($0)") }
    exit(0)
}

// enable: for each mapped command, write non-zero variants, watch 1.5 s for any new input (motion would appear as
// reports on FF00/0010 ids 1/2 or anything else not the FA button report), then write zeros to revert.
// Skips 0x40 (disconnects the remote), 0x98 (mic), 0x01 (13-byte, unknown structure).
if args.first == "enable" {
    let via = ifaces.first { $0.name == "000C/0004" }!
    let table: [(UInt8, Int)] = [(0x02,3),(0x10,2),(0x21,2),(0x22,3),(0x32,2),(0x8E,3),(0x95,3),(0x96,2),(0x99,2),
                                 (0xA0,2),(0xA1,2),(0xA2,3),(0xA3,3),(0xA4,3),(0xF0,2)]
    let only = args.count > 1 ? Set(args.dropFirst().compactMap { UInt8($0, radix: 16) }) : nil
    for (id, len) in table where only == nil || only!.contains(id) {
        let variants: [[UInt8]] = len == 2 ? [[1], [0xFF]] : [[1, 0], [0, 1], [1, 1], [0x0A, 0x00], [0xFF, 0xFF]]
        for v in variants {
            let payload = [id] + v
            let before = novel
            let r = set(via, payload)
            print("\(ts()) SET [\(hexs(payload))] → \(err(r))")
            spin(1.5)
            if removed { print("\(ts()) remote DISCONNECTED after [\(hexs(payload))]"); exit(3) }
            if novel > before { print("\(ts()) *** HIT [\(hexs(payload))]: \(novel - before) novel input reports") }
            _ = set(via, [id] + [UInt8](repeating: 0, count: len - 1))
            spin(0.3)
        }
    }
    print("\(ts()) enable pass done: novel input \(novel), heartbeat \(heartbeat)")
    exit(0)
}

// axes: turn motion on (A0 01) and guide the user through still / yaw / pitch / roll, printing per-field RMS per
// phase so we can tell which bytes are the gyro axes. Motion report: id 0x01, 25 bytes = [01][3 x f32][6 x i16].
if args.first == "axes" {
    let via = ifaces.first { $0.name == "000C/0004" }!
    let sensors = ifaces.first { $0.name == "FF00/0010" }!
    let mbuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    IOHIDDeviceRegisterInputReportCallback(sensors.dev, mbuf, 512, { _, _, _, _, id, r, len in
        guard id == 1, len >= 25 else { return }
        var v: [Double] = []
        for k in 0..<3 { var f: Float = 0; memcpy(&f, r + 1 + 4 * k, 4); v.append(Double(f)) }
        for k in 0..<6 { var h: Int16 = 0; memcpy(&h, r + 13 + 2 * k, 2); v.append(Double(h)) }
        samples.append(v)
    }, nil)
    let phases = ["HOLD STILL (rest it on your knee)", "TURN LEFT-RIGHT, like shaking your head 'no' (yaw)",
                  "TILT UP-DOWN, like nodding 'yes' (pitch)", "TWIST YOUR WRIST, rolling it (roll)"]
    let names = ["f0", "f1", "f2", "a0", "a1", "a2", "b0", "b1", "b2"]
    print("Keep a finger resting on the touch surface the whole time (keeps the remote awake).")
    for (n, phase) in phases.enumerated() {
        print("\nIn 2 s: \(phase) — for 4 s"); spin(2)
        samples = []
        _ = set(via, [0xA0, 0x01])
        print(">>> GO: \(phase)")
        spin(4)
        let cnt = samples.count
        guard cnt > 2 else { print("phase \(n): only \(cnt) samples"); continue }
        var line = String(format: "phase %d (%3d samples) RMS:", n, cnt)
        for i in 0..<9 {
            let col = samples.map { $0[i] }
            let mean = col.reduce(0, +) / Double(cnt)
            let rms = (col.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(cnt)).squareRoot()
            line += i < 3 ? String(format: " %@ %.4f", names[i], rms) : String(format: " %@ %6.0f", names[i], rms)
        }
        print(line)
    }
    _ = set(via, [0xA0, 0x00])
    print("\nDone — motion off.")
    exit(0)
}

// raw <iface> <reportID> <bytes...>: SET feature with an arbitrary report id (BTLEServer forwards it through the
// keyhole as inner id), then GET the same id.
if args.first == "raw" {
    guard args.count >= 3, let target = ifaces.first(where: { $0.name == args[1].uppercased() }) else {
        print("usage: brute raw <PAGE/USAGE> <reportID hex> [bytes hex...]"); exit(1)
    }
    if excluded.contains(target.name) { print("\(target.name) is excluded"); exit(1) }
    let payload: [UInt8] = args.dropFirst(2).compactMap { UInt8($0, radix: 16) }
    let r = set(target, payload)
    print("\(ts()) SET \(target.name) id 0x\(String(format: "%02X", payload[0])) [\(hexs(payload))] → \(err(r))")
    let (gr, resp) = get(target, Int(payload[0]))
    print("\(ts()) GET \(target.name) id 0x\(String(format: "%02X", payload[0])) → \(err(gr)) [\(hexs(resp))]")
    spin(3)
    print("\(ts()) done: heartbeat \(heartbeat), novel input \(novel)")
    exit(0)
}

if args.first == "poke" {
    guard args.count >= 3, let target = ifaces.first(where: { $0.name == args[1].uppercased() }) else {
        print("usage: brute poke <PAGE/USAGE e.g. 0020/00E0> <hex bytes after 0xFF...>"); exit(1)
    }
    if excluded.contains(target.name) { print("\(target.name) is excluded"); exit(1) }
    let payload: [UInt8] = [0xFF] + args.dropFirst(2).compactMap { UInt8($0, radix: 16) }
    let r = set(target, payload)
    print("\(ts()) SET \(target.name) [\(hexs(payload))] → \(err(r))")
    let (gr, resp) = get(target)
    print("\(ts()) GET \(target.name) → \(err(gr)) [\(hexs(resp))]")
    spin(3)
    print("\(ts()) done: heartbeat \(heartbeat), novel input \(novel)")
    exit(0)
}

// Scan.
let targets = ifaces.filter { !excluded.contains($0.name) && ["0020/00E0", "0020/0042", "FF00/000B", "000D/0001", "000C/0004", "000C/0109", "000C/0001"].contains($0.name) }
print("\(ts()) interfaces: \(ifaces.map(\.name).joined(separator: " ")); scanning \(targets.map(\.name).joined(separator: " "))")
for i in targets {
    var setErrs: [String: Int] = [:], getErrs: [String: Int] = [:], hits = 0
    for id in 0...255 {
        let r = set(i, [0xFF, UInt8(id)])
        setErrs[err(r), default: 0] += 1
        spin(0.015)
        let (gr, resp) = get(i)
        if gr != kIOReturnSuccess { getErrs[err(gr), default: 0] += 1 }
        else if resp.count > 1 || resp.first != 0xFF {
            hits += 1
            print("\(ts()) \(i.name) id 0x\(String(format: "%02X", id)) set \(err(r)) → len \(resp.count): \(hexs(Array(resp.prefix(64))))")
        }
        if r == IOReturn(bitPattern: 0xE00002D6) || gr == IOReturn(bitPattern: 0xE00002D6) { // not responding
            print("\(ts()) \(i.name) not responding at id \(id) — remote asleep? touch it"); spin(1)
        }
    }
    print("\(ts()) \(i.name) done: \(hits) hits; set results \(setErrs); get errors \(getErrs)")
}
spin(2)
print("\(ts()) scan done: heartbeat \(heartbeat), novel input \(novel)")
