# remote-pointer

Turns a 1st-gen Siri Remote (A1513) into a gyro air-mouse and controller for macOS — no extra hardware.

`app/` is the menu-bar app (`make install` builds, signs and launches `~/Applications/RemotePointer.app`).

| Input | Action |
|---|---|
| Finger resting on touch surface + move remote | Pointer (roll-corrected relative motion) |
| Swipe on surface | Trackpad-style scroll (axis lock, momentum) |
| Swipe left from right edge | Notification Center |
| Click surface | Left click |
| TV/Home | 1× right click · 2× Return · 3× Mission Control · hold = app switcher (turn to pick) |
| Play/Pause | 1× play/pause · 2× fast-forward · 3× rewind · hold = cycle app windows |
| Menu | Back (⌘[) |
| Siri | Dictation (hold to talk, tap to toggle), Mac microphone |
| Volume | System volume |

## How it works (reverse-engineered)

- macOS (`/usr/sbin/BTLEServer`) exposes the remote as several IOHIDUserDevices (vid 0x004C, pid 0x0266).
- `IOHIDDeviceSetReport(feature, id=X, [X, args…])` on any of them is forwarded to the remote's keyhole
  feature report 0xF0; a wrong payload length returns ATT error 13, which maps the command table
  (`brute map`): 01/13 02/3 10/2 21/2 22/3 32/2 40/2 8E/3 95/3 96/2 98/2 99/2 A0/2 A1/2 A2/3 A3/3 A4/3 F0/2.
- **`A0 01` starts motion**: interface FF00/0010, input report 1, 25 bytes =
  `[01][quat x,y,z f32][3×i16 accel][3×i16 gyro: pitch, roll, yaw]`; world z of the quaternion is gravity-up.
- Touch: private MultitouchSupport (family 160, 7×8 grid). Buttons: report 0xFA bitmask
  (0x01 TV, 0x02 vol+, 0x04 vol−, 0x08 play, 0x10 Siri, 0x20 menu, 0x80 click).
- `98 01` (mic) is accepted only while Siri is held; audio (Speex, 50 frames/s) stays inside BTLEServer and is
  only relayed to entitled Apple clients, so dictation uses the Mac microphone.

## Research tools (repo root)

`probe` (HID dump), `mtprobe` (touch), `brute` (keyhole scan/map/enable/axes), `evmon` (HID event system),
`descdump`, `featread`, `xpctest`. `c6-probe/` is an unfinished ESP32-C6 NimBLE probe.
