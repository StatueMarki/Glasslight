import Cocoa

/// Global hotkey: double-tap the right ⌘ key.
///
/// A listen-only CGEventTap that sees modifier changes only (⌘ ⇧ ⌥ ⌃ fn): it never sees what
/// you type and never delays a keystroke. A background app needs Input Monitoring for this;
/// without it macOS creates the tap but keeps it disabled, so "active" means *enabled*, and
/// a cheap watchdog retries until access is granted, then stops.
@MainActor
final class HotKey {
    private let handler: () -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var triedReenable = false
    private var detector = DoubleTapDetector()

    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func start() {
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        install()
        watch()
    }

    /// Shows the system prompt, or the Input Monitoring settings pane if it was dismissed before.
    func requestAccess() {
        if !CGRequestListenEventAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
        watch()
    }

    private func watch() {
        guard watchdog == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if self.isActive {
                    timer.invalidate()
                    self.watchdog = nil
                } else if CGPreflightListenEventAccess() {
                    // Access arrived while running: re-enable first, rebuild the tap if that isn't enough.
                    if self.triedReenable || self.tap == nil {
                        self.uninstall()
                        self.install()
                    } else if let tap = self.tap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    self.triedReenable.toggle()
                }
            }
        }
        timer.tolerance = 1
        watchdog = timer
    }

    private func install() {
        guard tap == nil else { return }
        let callback: CGEventTapCallBack = { _, type, event, context in
            let hotKey = Unmanaged<HotKey>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.handle(type, event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    private func uninstall() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if detector.handle(keyCode: keyCode, flags: event.flags, at: ProcessInfo.processInfo.systemUptime,
                               otherInputAge: Self.secondsSinceKeyOrClick) {
                handler()
            }
        case .tapDisabledByTimeout:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            // .tapDisabledByUserInput: also what macOS sends when access is missing.
            // Re-enabling right here could loop, so let the watchdog retry calmly.
            watch()
        }
    }

    /// Readable without any permission, unlike the key events themselves.
    private static func secondsSinceKeyOrClick() -> Double {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min()!
    }
}
