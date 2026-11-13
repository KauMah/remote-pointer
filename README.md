# remote-pointer

Turn a 1st-generation **Siri Remote (A1513)** into a gyro air-mouse for macOS, like the pointer remotes on Samsung TVs or a Wiimote. Rest a finger on the touch surface and wave the remote to move the cursor. Lift your finger and the cursor stays put.

There's no extra hardware and no firmware changes. The remote's motion sensors are off by default and macOS doesn't expose them, so this project switches them on over Bluetooth through a HID command found by brute-forcing the remote's command interface (details below).

Beyond pointing, the app adds trackpad-style scrolling with momentum, zoom gestures, an app switcher you steer by turning the remote, push-to-talk dictation and a remap of every button. Cursor motion is posted as HID-level mouse events, so it also works across Universal Control onto a nearby Mac or iPad.

## Controls

The same cheatsheet is in the menu bar menu under **Controls Cheatsheet**.

| Input | Action |
|---|---|
| **Touch surface** | |
| Rest finger + move remote | Move pointer |
| Click | Left click |
| Swipe | Scroll, with axis lock and macOS-style momentum |
| Double-tap | Smart zoom |
| Tap, then drag up/down | Pinch zoom |
| Swipe in from the right edge | Open Notification Center |
| Swipe right while it's open | Close Notification Center |
| **TV / Home** | |
| Press | Right click |
| Press twice | Return |
| Press 3× | Mission Control |
| Hold + turn left/right | App switcher (turn faster to skip more apps, release to switch) |
| **Play / Pause** | |
| Press | Play / pause |
| Press twice | Fast-forward |
| Press 3× | Rewind |
| Hold | Cycle the current app's windows (⌘`) |
| Hold + Siri, tilt up/down | Zoom in / out |
| **Menu** | |
| Press | Back (⌘[) |
| Press twice | Backspace |
| Press, then press and hold | Delete word by word |
| **Siri** | |
| Hold | Dictate while held |
| Tap | Start / stop dictation |
| **Volume + / −** | System volume |

## How the pointer feels right

- **Screen-relative mapping.** The remote reports its orientation as a quaternion with gravity as world-up. Rotation is projected onto the screen's right and up axes, so "up" always moves the cursor up, however the remote is twisted or angled. If you point it at the ceiling and roll it 90°, tilting still moves the cursor sideways.
- **Drift-free when still.** A 1€ filter removes hand tremor. A stillness lock holds the cursor dead still when your hand is nearly steady. It releases on a quick move, or on a small slow turn that keeps going one way, since tremor only jiggles back and forth. Slow movement is damped for precision but never to zero, so tiny nudges onto a small close button still register. The gyro bias is relearned only when the variance shows the remote is truly at rest.
- **Ballistics.** Faster swings travel further, like a mouse with acceleration.
- **Click stability.** Pressing the touch surface rewinds the last ~80 ms of motion and briefly freezes the cursor, so the press doesn't nudge your target.
- **Scroll vs. point.** A touch scrolls only when the finger travels far and fast enough while the remote is mostly still. Otherwise it's a pointing touch.

## Install

Requirements: macOS 13 or later, Xcode command-line tools, and the remote paired to the Mac. To pair, hold **Menu + Volume Up** for a few seconds near the Mac, then open System Settings → Bluetooth.

```sh
cd app
make install        # builds, signs, installs to ~/Applications/RemotePointer.app and launches it
```

The app lives in the menu bar. On first launch, grant these permissions:

- **Accessibility**, to post mouse and keyboard events and open Notification Center.
- **Input Monitoring**, to read the remote's buttons.
- **Microphone** and **Speech Recognition**, for dictation (on-device).

The Makefile signs with your Apple Development identity if you have one, so permissions survive rebuilds. With ad-hoc signing you'll have to grant them again after each build.

The menu bar menu has sliders for pointer speed, acceleration, scroll speed and momentum, plus toggles for inversion, natural scrolling, the edge gesture and Open at Login.

## Universal Control (optional)

Synthetic mouse events stay on the Mac that posts them. To carry the pointer to a nearby Mac or iPad, RemotePointer can drive a **virtual HID mouse** instead, which macOS treats like real hardware. This uses the [Karabiner DriverKit VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice) driver, which only takes commands from root, so a small root helper (`helper/rp-hid-helper`) owns the device and the app sends it pointer reports over a Unix socket. The socket accepts connections only from your own user account.

```sh
cd helper
make                                   # fetches the driver's client headers (needs cmake) and builds the helper
sudo ./install.sh "$(make -s pkg)"     # installs the driver + launchd daemons (from a folder outside ~/Desktop)
/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager activate
```

Approve the driver in System Settings → General → Login Items & Extensions → Driver Extensions. The menu shows "Universal Control: virtual mouse on" once the app is connected. RemotePointer switches off the system acceleration curve for the virtual mouse only, so its own pointer tuning still applies. Pointer motion, clicks, button shortcuts, media keys and Mission Control go through the virtual mouse and keyboard, so they work on whichever device Universal Control is driving.

**Install RemotePointer on your other Macs too** (just `make install` in `app/`; they don't need the helper or the driver). The copies find each other over Bonjour. Each one reports when its own cursor moves, so the Mac with the remote knows which machine the pointer is on. Scrolling with momentum, pinch and smart zoom, Notification Center and dictated text are then sent to that Mac's RemotePointer, which plays them back locally exactly as it would there. The link is TLS with a pre-shared key: choose **Copy Pairing Key** on one Mac, then **Paste Pairing Key from Clipboard** on the other (Universal Clipboard carries it across). Macs without the key can't connect.

On a device that isn't running RemotePointer, such as an iPad:

- scrolling falls back to wheel ticks;
- pinch zoom becomes ⌘= / ⌘−;
- Notification Center opens with fn+N;
- dictation types US-layout ASCII through the virtual keyboard.

Root can't read files under `~/Desktop` (macOS privacy protection), so if the repo lives there, copy `helper/` somewhere else before running `install.sh`.

## How it works (reverse-engineered)

- macOS's `/usr/sbin/BTLEServer` exposes the remote (vid `0x004C`, pid `0x0266`) as several `IOHIDUserDevice`s. Its product name is its serial number.
- `IOHIDDeviceSetReport(feature, id=X, [X, args…])` on any of those interfaces is forwarded over the air to the remote's "keyhole" feature report `0xF0`. Sending a payload of the wrong length returns ATT error 13, and that error was used to map the command table (`brute map`). Each entry is command / payload length:
  `01/13 02/3 10/2 21/2 22/3 32/2 40/2 8E/3 95/3 96/2 98/2 99/2 A0/2 A1/2 A2/3 A3/3 A4/3 F0/2`
  (`40 00` disconnects the remote).
- **`A0 01` turns motion on.** The motion data arrives on interface `FF00/0010` as input report 1, 25 bytes at ~66 Hz:
  `[01][quat x,y,z f32 (w implied)][3×i16 accel][3×i16 gyro: pitch, roll, yaw]`. The quaternion's world z axis points up, against gravity.
- **Touch** comes through the private MultitouchSupport framework (device family 160, a 7×8 grid).
- **Buttons** come as report `0xFA`, a bitmask: `0x01` TV, `0x02` vol+, `0x04` vol−, `0x08` play, `0x10` Siri, `0x20` menu, `0x80` click. The app seizes this interface so the buttons don't also do their default actions.
- **Microphone:** `98 01` is accepted only while Siri is held. The audio (Speex, 50 frames/s) stays inside BTLEServer and is relayed only to Apple clients with the right entitlement, so dictation uses the Mac's microphone instead.
- **Output:** mouse moves, scroll phases with momentum, and type-29 gesture events (pinch and smart magnify) are all posted at the HID event tap.

## Repo layout

| Path | What |
|---|---|
| `app/` | The menu-bar app (`main.swift`, `Dictation.swift`, `VirtualMouse.swift`, `Peers.swift`) |
| `helper/` | Root helper that owns the virtual HID mouse, plus its installer |
| `probe.swift` | Dumps HID interfaces and reports |
| `mtprobe.c` | Raw MultitouchSupport touch frames |
| `brute.swift` | Keyhole scanner: `map`, `enable`, `axes`, `raw`, `poke`, `scan`, `siri` |
| `evmon.c`, `descdump.swift`, `featread.swift`, `xpctest.c` | HID event system, descriptor, feature-report and XPC experiments |
| `axes.log`, `enable.log` | Captured motion data used to work out the report layout |
| `c6-probe/` | Unfinished ESP32-C6 BLE probe (not needed) |

## Caveats

- This relies on private macOS frameworks and undocumented remote commands, so a macOS update could break it.
- Only tested with the 1st-gen Siri Remote (A1513).
- The remote goes to sleep after about 40 s without input. A click wakes it.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md): you're free to use, study, modify and share this for any noncommercial purpose, including personal projects, research, hobby use and use by schools or nonprofits. Commercial use is not permitted. If you'd like to use it commercially, open an issue to ask.
