// Push-to-talk dictation: hold the Siri button to record (Mac microphone), Apple's on-device speech recognition
// transcribes it, and on release the text is typed into whatever has focus. Works in any app, unlike the
// Edit → Start Dictation menu route. A small non-activating overlay shows the live transcript.

import AppKit
import Speech
import AVFoundation

final class Dictation {
    static let shared = Dictation()
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private(set) var active = false
    private var finishing = false
    private var finishTimer: Timer?

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { s in log("speech recognition authorization: \(s.rawValue)") }
        AVCaptureDevice.requestAccess(for: .audio) { ok in log("microphone access: \(ok)") }
    }

    @discardableResult
    func start() -> Bool {
        guard !active else { return true }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            Overlay.shared.flash("Allow Speech Recognition for RemotePointer in System Settings")
            requestPermissions()
            return false
        }
        guard let recognizer, recognizer.isAvailable else { Overlay.shared.flash("Speech recognition unavailable"); return false }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            log("audio engine: \(error)")
            input.removeTap(onBus: 0)
            Overlay.shared.flash("Microphone unavailable")
            return false
        }

        latest = ""; finishing = false; active = true; request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(result, error) }
        }
        Overlay.shared.show("Listening…", listening: true)
        log("dictation started")
        return true
    }

    /// Stop recording; type the transcript once the recognizer finalises (or after a short timeout).
    func stop() {
        guard active, !finishing else { return }
        finishing = true
        stopAudio()
        request?.endAudio()
        Overlay.shared.show(latest.isEmpty ? "…" : latest, listening: false)
        finishTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in self?.finish() }
    }

    /// Stop without typing anything (e.g. the Siri press turned into a button combo).
    func cancel() {
        guard active else { return }
        latest = ""
        finish()
    }

    private func handle(_ result: SFSpeechRecognitionResult?, _ error: Error?) {
        guard active else { return }
        if let result {
            latest = result.bestTranscription.formattedString
            if !finishing { Overlay.shared.show(latest.isEmpty ? "Listening…" : latest, listening: true) }
            if result.isFinal { finish(); return }
        }
        if let error {
            log("recognition: \(error.localizedDescription)")
            finish()
        }
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func finish() {
        guard active else { return }
        active = false; finishing = false
        finishTimer?.invalidate(); finishTimer = nil
        stopAudio()
        task?.cancel(); task = nil; request = nil
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        Overlay.shared.hide()
        log("dictation result: \"\(text)\"")
        if !text.isEmpty { Typer.type(text) }
    }
}

/// Types text into the focused app as Unicode keyboard events (no clipboard involvement).
enum Typer {
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e.post(tap: .cghidEventTap)
            }
            usleep(3000)
            i += 16
        }
    }
}

/// Small floating HUD near the bottom of the screen; never takes focus from the app being typed into.
final class Overlay {
    static let shared = Overlay()
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var hideTimer: Timer?

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 56),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let fx = NSVisualEffectView(frame: p.contentView!.bounds)
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.masksToBounds = true
        fx.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(fx)

        dot.frame = NSRect(x: 18, y: 22, width: 12, height: 12)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        fx.addSubview(dot)

        label.frame = NSRect(x: 40, y: 10, width: 464, height: 36)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingHead      // keep the newest words visible
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        fx.addSubview(label)
        panel = p
        return p
    }

    func show(_ text: String, listening: Bool) {
        hideTimer?.invalidate(); hideTimer = nil
        let p = ensurePanel()
        label.stringValue = text
        dot.layer?.backgroundColor = (listening ? NSColor.systemRed : NSColor.systemGray).cgColor
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 80))
        }
        p.orderFrontRegardless()
    }

    func flash(_ text: String) {
        show(text, listening: false)
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in self?.hide() }
    }

    func hide() { panel?.orderOut(nil) }
}
