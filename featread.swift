// Read-only: GET feature/input report 0xFF (and a few others) from each Siri Remote HID interface.
import Foundation
import IOKit.hid
setvbuf(stdout, nil, _IOLBF, 0)
let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x004C, kIOHIDProductIDKey: 0x0266] as CFDictionary)
let devs = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []
for d in devs {
  let page = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
  let usage = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
  let open = IOHIDDeviceOpen(d, 0)
  print(String(format: "== 0x%04X/0x%04X open 0x%08X", page, usage, UInt32(bitPattern: open)))
  guard open == kIOReturnSuccess else { continue }
  for (type, tname) in [(kIOHIDReportTypeFeature, "feature"), (kIOHIDReportTypeInput, "input")] {
    for id in [0xFF, 0x01, 0x02, 0x00] {
      var buf = [UInt8](repeating: 0, count: 256); var len = buf.count
      let r = IOHIDDeviceGetReport(d, type, CFIndex(id), &buf, &len)
      if r == kIOReturnSuccess {
        print("   \(tname) id \(String(format: "0x%02X", id)) len \(len): " + buf[0..<len].map { String(format: "%02X", $0) }.joined(separator: " "))
      } else {
        print("   \(tname) id \(String(format: "0x%02X", id)) err \(String(format: "0x%08X", UInt32(bitPattern: r)))")
      }
    }
  }
  IOHIDDeviceClose(d, 0)
}
