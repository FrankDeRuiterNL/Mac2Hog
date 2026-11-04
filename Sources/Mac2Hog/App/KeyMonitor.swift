#if os(macOS)
import AppKit

/// Global space-bar handling for the main window: GO (manual mode) or play/pause (timecode mode).
/// Ignored while the user is typing in a text field.
final class KeyMonitor {
    private var monitor: Any?

    func start(onSpace: @escaping () -> Void, onEscape: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSText || responder is NSTextView {
                return event
            }
            // Only the main show window, not the Settings window or sheets.
            guard NSApp.keyWindow?.identifier?.rawValue.contains("Settings") != true,
                  NSApp.keyWindow?.attachedSheet == nil, NSApp.keyWindow?.sheetParent == nil else { return event }
            switch event.keyCode {
            case 49: onSpace(); return nil   // space
            case 53: onEscape(); return nil  // escape
            default: return event
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    deinit { stop() }
}
#endif
