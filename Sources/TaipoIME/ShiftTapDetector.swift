import Foundation

/// Spec 013 Behavior 1: recognises a lone Shift tap. No AppKit types, so it is unit-testable.
public final class ShiftTapDetector {
    public static let maxTap: TimeInterval = 0.5
    private var pressedAt: TimeInterval?

    /// Only left Shift toggles; right Shift is the Spec 012 voice trigger (2026-10-26).
    public static let leftShiftKeyCode: UInt16 = 56
    /// Device-independent Shift bit. The left/right device bits are not used: they were absent
    /// from the events the IME received (2026-10-26), so the side comes from the keyCode alone.
    static let shift: UInt = 1 << 17
    /// Control, Option, Command, Fn (device-independent bits of NSEvent.ModifierFlags).
    static let others: UInt = (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)

    public init() {}

    /// Maps one `flagsChanged` event to a left-Shift edge; nil for any other key (right Shift
    /// included). The caller treats nil as `otherKey()`, so right Shift during a tap cancels it.
    public static func leftShiftEdge(keyCode: UInt16, flags: UInt) -> (down: Bool, otherModifiers: Bool)? {
        guard keyCode == leftShiftKeyCode else { return nil }
        return (flags & shift != 0, flags & others != 0)
    }

    /// Feed every Shift press/release; returns true on the release that completes a tap.
    public func shift(down: Bool, at time: TimeInterval, otherModifiers: Bool) -> Bool {
        if down {
            pressedAt = otherModifiers ? nil : time
            return false
        }
        defer { pressedAt = nil }
        guard let start = pressedAt, !otherModifiers else { return false }
        return time - start <= Self.maxTap
    }

    /// Any other key while Shift is held makes it a typing Shift.
    public func otherKey() { pressedAt = nil }
}
