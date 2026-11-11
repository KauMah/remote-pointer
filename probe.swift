// Probe: discover what the Siri Remote (A1513) exposes to macOS.
// Prints every HID device, then every raw input report and parsed value from
// devices matching the filter, plus whatever GameController reports.
//
// Build: swiftc -O probe.swift -o probe
// Run:   ./probe            (lists devices, streams from anything named *remote*)
//        ./probe all        (streams from every HID device — noisy)
// Needs Input Monitoring permission for your terminal (System Settings → Privacy & Security).

import Foundation
import IOKit.hid
import GameController

// Line-buffer stdout so `| tee` gets output live and Ctrl-C doesn't drop a buffered tail.
setvbuf(stdout, nil, _IOLBF, 0)

let streamAll = CommandLine.arguments.dropFirst().contains("all")

func prop(_ d: IOHIDDevice, _ key: String) -> Any? { IOHIDDeviceGetProperty(d, key as CFString) }
func hex(_ v: Any?) -> String { (v as? Int).map { String(format: "0x%04X", $0) } ?? "-" }

func describe(_ d: IOHIDDevice) -> String {
    let name = prop(d, kIOHIDProductKey) as? String ?? "?"
    let transport = prop(d, kIOHIDTransportKey) as? String ?? "?"
    return "\(name) [vid \(hex(prop(d, kIOHIDVendorIDKey))) pid \(hex(prop(d, kIOHIDProductIDKey))) " +
        "usage \(hex(prop(d, kIOHIDPrimaryUsagePageKey)))/\(hex(prop(d, kIOHIDPrimaryUsageKey))) \(transport)]"
}

func wanted(_ d: IOHIDDevice) -> Bool {
    if streamAll { return true }
    // The A1513 enumerates with its serial number as the product name, so match vid/pid.
    if prop(d, kIOHIDVendorIDKey) as? Int == 0x004C, prop(d, kIOHIDProductIDKey) as? Int == 0x0266 { return true }
    let name = (prop(d, kIOHIDProductKey) as? String ?? "").lowercased()
    return name.contains("remote") || name.contains("siri")
}

let start = Date()
func ts() -> String { String(format: "%8.3f", Date().timeIntervalSince(start)) }

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, nil) // all devices

var buffers: [UnsafeMutablePointer<UInt8>] = []

IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
    let isWanted = wanted(device)
    print("\(ts()) + \(describe(device))\(isWanted ? "  <-- streaming" : "")")
    guard isWanted else { return }

    // Dump the element list once so we can see what the report descriptor declares.
    if let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
        for e in elements where IOHIDElementGetType(e) != kIOHIDElementTypeCollection {
            print(String(format: "           element page 0x%04X usage 0x%04X size %2d count %d range %d..%d",
                         IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e),
                         IOHIDElementGetReportSize(e), IOHIDElementGetReportCount(e),
                         IOHIDElementGetLogicalMin(e), IOHIDElementGetLogicalMax(e)))
        }
    }

    // Raw reports: catches vendor-specific data that has no parsed elements.
    let size = (prop(device, kIOHIDMaxInputReportSizeKey) as? Int) ?? 64
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(size, 64))
    buffers.append(buf)
    IOHIDDeviceRegisterInputReportCallback(device, buf, max(size, 64), { _, _, _, _, reportID, report, length in
        let bytes = (0..<length).map { String(format: "%02X", report[$0]) }.joined(separator: " ")
        print("\(ts())   report id \(reportID) len \(length): \(bytes)")
    }, nil)
}, nil)

IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, device in
    print("\(ts()) - \(describe(device))")
}, nil)

// Parsed values (buttons, consumer keys) from the devices we stream.
IOHIDManagerRegisterInputValueCallback(manager, { _, _, _, value in
    let e = IOHIDValueGetElement(value)
    let device = IOHIDElementGetDevice(e)
    guard wanted(device) else { return }
    print(String(format: "%@   value page 0x%04X usage 0x%04X = %d", ts(),
                 IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e), IOHIDValueGetIntegerValue(value)))
}, nil)

IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openResult != kIOReturnSuccess {
    print("IOHIDManagerOpen failed (0x\(String(openResult, radix: 16))). Grant Input Monitoring to your terminal and rerun.")
}

// GameController: on tvOS the Siri Remote is a GCMicroGamepad with motion; see if macOS does the same.
func report(_ c: GCController) {
    print("\(ts()) GC controller: \(c.vendorName ?? "?") category \(c.productCategory) " +
          "micro \(c.microGamepad != nil) extended \(c.extendedGamepad != nil) motion \(c.motion != nil)")
    if let pad = c.microGamepad {
        pad.reportsAbsoluteDpadValues = true
        pad.dpad.valueChangedHandler = { _, x, y in print(String(format: "%@   GC dpad %.3f %.3f", ts(), x, y)) }
        pad.buttonA.pressedChangedHandler = { _, _, p in print("\(ts())   GC buttonA \(p)") }
        pad.buttonX.pressedChangedHandler = { _, _, p in print("\(ts())   GC buttonX \(p)") }
    }
    if let m = c.motion {
        var n = 0
        m.valueChangedHandler = { m in
            n += 1
            guard n % 10 == 0 else { return } // throttle
            print(String(format: "%@   GC motion rot %.2f %.2f %.2f grav %.2f %.2f %.2f", ts(),
                         m.rotationRate.x, m.rotationRate.y, m.rotationRate.z,
                         m.gravity.x, m.gravity.y, m.gravity.z))
        }
    }
}
GCController.shouldMonitorBackgroundEvents = true
NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
    if let c = n.object as? GCController { report(c) }
}
GCController.controllers().forEach(report)

print("Listening. Touch, swipe, click, press every button, and tilt/rotate the remote. Ctrl-C to quit.")
CFRunLoopRun()
