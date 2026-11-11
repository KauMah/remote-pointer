// Dump HID report descriptors for the Siri Remote (vid 0x004C pid 0x0266). Read-only; no device open needed.
import Foundation
import IOKit.hid
let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x004C, kIOHIDProductIDKey: 0x0266] as CFDictionary)
let devs = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []
for d in devs.sorted(by: { (IOHIDDeviceGetProperty($0, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0) < (IOHIDDeviceGetProperty($1, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0) }) {
  let page = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
  let usage = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
  let desc = IOHIDDeviceGetProperty(d, kIOHIDReportDescriptorKey as CFString) as? Data ?? Data()
  print(String(format: "== interface 0x%04X/0x%04X  descriptor %d bytes", page, usage, desc.count))
  print(desc.map { String(format: "%02X", $0) }.joined(separator: " "))
}
