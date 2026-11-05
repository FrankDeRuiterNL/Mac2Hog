import Foundation

/// Parsing and formatting of second values typed by the user (cue delay, duration, pauses).
/// Accepts both "1.15" and "1,15" whatever the Mac's region, and keeps up to two decimals.
public enum SecondsText {
    public static let maxDecimals = 2

    /// "0.1", "0,10", "1.15", " 2 ", "1,5s" → seconds (rounded to 2 decimals); nil if not a number.
    public static func parse(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("s") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, t.filter({ $0 == "." }).count <= 1, let value = Double(t), value.isFinite else { return nil }
        return round(value)
    }

    public static func round(_ value: Double) -> Double {
        let f = pow(10, Double(maxDecimals))
        return (value * f).rounded() / f
    }

    /// Up to two decimals, no trailing zeros: 1 → "1", 0.1 → "0.1", 1.15 → "1.15".
    /// `decimalSeparator` defaults to the current locale's (a comma for Dutch Macs).
    public static func format(_ value: Double, decimalSeparator: String? = nil) -> String {
        let rounded = round(value)
        var s = String(format: "%.\(maxDecimals)f", rounded)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        let sep = decimalSeparator ?? (Locale.current.decimalSeparator ?? ".")
        return sep == "." ? s : s.replacingOccurrences(of: ".", with: sep)
    }
}
