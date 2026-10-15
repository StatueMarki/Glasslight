import Cocoa

/// User-adjustable look of the search panel, stored in UserDefaults (domain local.glasslight).
/// A missing key means "built-in default"; default colors are dynamic and follow light/dark mode.
enum Appearance {
    enum Key {
        static let variant = "GlassVariant"            // Int 0–23, private glass variants (0 regular, 2 clear)
        static let lensing = "GlassLensing"            // Int 0–3
        static let tintColor = "GlassTintColor"        // "#RRGGBB"
        static let tintOpacity = "GlassTint"           // Double 0–1
        static let cornerRadius = "GlassCornerRadius"  // Double 0–28
        static let textColor = "TextColor"             // "#RRGGBB"
        static let selectionColor = "SelectionColor"   // "#RRGGBB"
        static let selectionOpacity = "SelectionOpacity" // Double 0–1
        static let all = [variant, lensing, tintColor, tintOpacity, cornerRadius, textColor, selectionColor, selectionOpacity]
    }

    static let maxCornerRadius: Double = 28

    private static var defaults: UserDefaults { .standard }

    // MARK: Stored values

    static var variant: Int {
        get { defaults.object(forKey: Key.variant) as? Int ?? 2 }
        set { defaults.set(newValue, forKey: Key.variant) }
    }
    static var lensing: Int {
        get { defaults.object(forKey: Key.lensing) as? Int ?? 2 }
        set { defaults.set(newValue, forKey: Key.lensing) }
    }
    static var tintOpacity: Double {
        get { defaults.object(forKey: Key.tintOpacity) as? Double ?? 0.3 }
        set { defaults.set(newValue, forKey: Key.tintOpacity) }
    }
    static var cornerRadius: Double {
        get { defaults.object(forKey: Key.cornerRadius) as? Double ?? maxCornerRadius }
        set { defaults.set(newValue, forKey: Key.cornerRadius) }
    }
    /// nil = appearance-dependent default (0.16 dark, 0.07 light).
    static var selectionOpacity: Double? {
        get { defaults.object(forKey: Key.selectionOpacity) as? Double }
        set { defaults.set(newValue, forKey: Key.selectionOpacity) }
    }
    static var tintColor: NSColor? {
        get { color(Key.tintColor) }
        set { setColor(newValue, Key.tintColor) }
    }
    static var textColor: NSColor? {
        get { color(Key.textColor) }
        set { setColor(newValue, Key.textColor) }
    }
    static var selectionColor: NSColor? {
        get { color(Key.selectionColor) }
        set { setColor(newValue, Key.selectionColor) }
    }

    static func reset() {
        Key.all.forEach(defaults.removeObject)
    }

    // MARK: Resolved colors

    static var tint: NSColor {
        let alpha = tintOpacity
        if let custom = tintColor { return custom.withAlphaComponent(alpha) }
        return NSColor(name: nil) { $0.isDark ? .black.withAlphaComponent(alpha) : .white.withAlphaComponent(alpha) }
    }
    static var text: NSColor { textColor ?? .labelColor }
    static var secondaryText: NSColor { textColor?.withAlphaComponent(0.6) ?? .secondaryLabelColor }
    static var tertiaryText: NSColor { textColor?.withAlphaComponent(0.4) ?? .tertiaryLabelColor }
    static var selection: NSColor {
        let custom = selectionColor, opacity = selectionOpacity
        return NSColor(name: nil) { appearance in
            let base = custom ?? (appearance.isDark ? .white : .black)
            return base.withAlphaComponent(opacity ?? (appearance.isDark ? 0.16 : 0.07))
        }
    }

    /// The color a default actually shows right now, for the settings controls.
    static func effectiveTintColor(in appearance: NSAppearance) -> NSColor {
        tintColor ?? (appearance.isDark ? .black : .white)
    }
    static func effectiveTextColor(in appearance: NSAppearance) -> NSColor {
        textColor ?? resolved(.labelColor, in: appearance).withAlphaComponent(1)
    }
    static func effectiveSelectionColor(in appearance: NSAppearance) -> NSColor {
        selectionColor ?? (appearance.isDark ? .white : .black)
    }
    static func effectiveSelectionOpacity(in appearance: NSAppearance) -> Double {
        selectionOpacity ?? (appearance.isDark ? 0.16 : 0.07)
    }

    // MARK: Hex colors

    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        let v = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()).clamped(0, 255) }
        return String(format: "#%02X%02X%02X", v[0], v[1], v[2])
    }

    static func color(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    private static func color(_ key: String) -> NSColor? {
        defaults.string(forKey: key).flatMap { color(hex: $0) }
    }

    private static func setColor(_ color: NSColor?, _ key: String) {
        if let color { defaults.set(hex(color), forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) ?? color }
        return result
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
