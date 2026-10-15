import CoreGraphics

/// Recognizes a double tap of the right ⌘ key from modifier-change events alone. Pure logic, no I/O.
///
/// Only modifier events are observed (that needs no permission), so keys and clicks are detected
/// through `otherInputAge`: seconds since the last key or mouse press anywhere. Fires when the
/// second tap is released, so a stray tap right before a ⌘-shortcut (tap ⌘, then ⌘C) never
/// opens the panel by mistake.
struct DoubleTapDetector {
    static let rightCommandKey: Int64 = 0x36   // kVK_RightCommand
    static let rightCommandBit: UInt64 = 0x10  // NX_DEVICERCMDKEYMASK
    static let leftCommandBit: UInt64 = 0x08   // NX_DEVICELCMDKEYMASK
    static let maxHold = 0.35                  // a longer press is a hold, not a tap
    static let maxGap = 0.35                   // from first release to second press

    private var pressedAt: Double?
    /// The completed first tap: when it was pressed and released.
    private var firstTap: (down: Double, up: Double)?

    /// Feed every modifier-change event; returns true when a double tap completes.
    mutating func handle(keyCode: Int64, flags: CGEventFlags, at time: Double, otherInputAge: () -> Double) -> Bool {
        guard keyCode == Self.rightCommandKey else {
            reset() // another modifier breaks the sequence
            return false
        }
        if flags.rawValue & Self.rightCommandBit != 0 {
            let others: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
            guard flags.isDisjoint(with: others), flags.rawValue & Self.leftCommandBit == 0 else {
                reset()
                return false
            }
            if let first = firstTap, time - first.up > Self.maxGap { firstTap = nil }
            pressedAt = time
            return false
        }

        guard let down = pressedAt else { return false }
        pressedAt = nil
        // A tap is short and has no key or click inside it (⌘C, ⌘-click).
        guard time - down <= Self.maxHold, otherInputAge() >= time - down else {
            firstTap = nil
            return false
        }
        if let first = firstTap, otherInputAge() >= time - first.down {
            firstTap = nil
            return true
        }
        firstTap = (down, time)
        return false
    }

    private mutating func reset() {
        pressedAt = nil
        firstTap = nil
    }
}
