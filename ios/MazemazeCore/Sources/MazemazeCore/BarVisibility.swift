import Foundation

/// Decides when the address bar and the toolbar slide away while reading (like Safari): scrolling down hides
/// them, scrolling up (or reaching the top) shows them. Pure logic, no UIKit.
public struct BarVisibility: Equatable, Sendable {
    public static let hideDistance = 28.0     // points of downward scrolling before the bars hide
    public static let showDistance = 16.0     // points of upward scrolling before they come back
    public static let topZone = 24.0          // within this distance of the top they are always shown
    public static let settleSeconds = 0.4     // after a change the page re-lays out: ignore the offset jitter

    public private(set) var hidden = false
    private var last: Double?
    private var travelled = 0.0
    private var ignoreUntil = -Double.infinity

    public init() {}

    /// Feed every content-offset change. `minOffset` is the offset at the very top (negative when the page is inset),
    /// `now` is a monotonic time in seconds. Returns true when `hidden` changed.
    @discardableResult
    public mutating func update(offset: Double, minOffset: Double, now: Double, userDriven: Bool = true) -> Bool {
        defer { last = offset }
        if !userDriven {      // the page moved itself (an anchor, a script, a rotation): only the top shows the bars
            return offset <= minOffset + Self.topZone ? set(false, now: now) : false
        }
        guard now >= ignoreUntil else { return false }           // the page is re-laying out
        guard let previous = last else { return false }
        let delta = offset - previous
        if offset <= minOffset + Self.topZone {
            travelled = 0
            return set(false, now: now)
        }
        if delta == 0 { return false }
        if (delta > 0) != (travelled > 0) { travelled = 0 }       // direction changed: start counting again
        travelled += delta
        if travelled >= Self.hideDistance { travelled = 0; return set(true, now: now) }
        if travelled <= -Self.showDistance { travelled = 0; return set(false, now: now) }
        return false
    }

    /// A new page, the address field, an error, VoiceOver, ...: show the bars now.
    public mutating func reveal(now: Double) { travelled = 0; _ = set(false, now: now) }

    /// Forget the scroll position (a different page is shown).
    public mutating func reset() { hidden = false; last = nil; travelled = 0; ignoreUntil = -Double.infinity }

    private mutating func set(_ value: Bool, now: Double) -> Bool {
        guard value != hidden else { return false }
        hidden = value
        ignoreUntil = now + Self.settleSeconds
        return true
    }
}
