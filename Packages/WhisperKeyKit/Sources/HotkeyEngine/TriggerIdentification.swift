import Foundation

public enum TriggerTransition: Sendable, Equatable {
    case pressed
    case released
}

/// Deciding whether a `flagsChanged` event is a press or a release of a *specific* key.
///
/// `CGEventFlags` carries two kinds of information in one raw value. The documented,
/// side-agnostic bits (`kCGEventFlagMaskCommand` and friends) say only "some Command key
/// is down". Alongside them macOS carries the undocumented-but-stable device-dependent
/// bits from `IOLLEvent.h` (`NX_DEVICE{L,R}{CMD,SHIFT,ALT}KEYMASK`), which say *which*
/// one.
///
/// Reading only the shared bit is what made a release look like a press: with left ⌘ held
/// down, releasing right ⌘ leaves the shared Command bit set, so the release was reported
/// as "still pressed" — a second press. Taps survived that because they are short; a hold
/// gesture would open a panel that never closes.
///
/// A device that reports no side bits at all (some external keyboards, and every
/// synthesised event) falls back to the shared bit, which is exactly the old answer.
extension TriggerKey {
    /// The device-dependent bit for this exact key.
    var deviceFlagMask: UInt64 {
        switch self {
        case .rightShift: return 0x0000_0004    // NX_DEVICERSHIFTKEYMASK
        case .rightCommand: return 0x0000_0010  // NX_DEVICERCMDKEYMASK
        case .rightOption: return 0x0000_0040   // NX_DEVICERALTKEYMASK
        }
    }

    /// Both device-dependent bits — left and right — of the modifier this key belongs to.
    var deviceFlagPairMask: UInt64 {
        switch self {
        case .rightShift: return 0x0000_0002 | 0x0000_0004    // NX_DEVICE{L,R}SHIFTKEYMASK
        case .rightCommand: return 0x0000_0008 | 0x0000_0010  // NX_DEVICE{L,R}CMDKEYMASK
        case .rightOption: return 0x0000_0020 | 0x0000_0040   // NX_DEVICE{L,R}ALTKEYMASK
        }
    }

    /// The side-agnostic `CGEventFlags` bit for the modifier this key belongs to.
    var sharedFlagMask: UInt64 {
        switch self {
        case .rightShift: return 0x0002_0000    // kCGEventFlagMaskShift
        case .rightCommand: return 0x0010_0000  // kCGEventFlagMaskCommand
        case .rightOption: return 0x0008_0000   // kCGEventFlagMaskAlternate
        }
    }

    /// Whether the raw flag value of a `flagsChanged` event whose key code is this
    /// trigger's describes the key going down or coming up.
    ///
    /// Pure by design: `CGEventFlags.rawValue` goes in, a decision comes out, so the
    /// left/right discrimination is provable without an event tap.
    public func transition(rawFlags: UInt64) -> TriggerTransition {
        if rawFlags & deviceFlagMask != 0 {
            return .pressed
        }
        if rawFlags & deviceFlagPairMask != 0 {
            // The other side of this modifier is down and we are not. This is the case
            // the shared mask gets wrong.
            return .released
        }
        // No side information at all for this modifier: trust the shared bit.
        return rawFlags & sharedFlagMask != 0 ? .pressed : .released
    }
}

/// The same decision for any modifier key, not only the three that can be triggers.
///
/// Needed because "a foreign modifier was pressed" cancels the hold-to-reveal gesture
/// while "a foreign modifier was released" must not — letting go of Shift cannot take the
/// panel away.
public enum ModifierKey {
    /// Virtual key codes of every modifier macOS reports through `flagsChanged`.
    private static let masks: [Int64: (side: UInt64, pair: UInt64, shared: UInt64)] = [
        55: (0x0000_0008, 0x0000_0018, 0x0010_0000),  // kVK_Command
        54: (0x0000_0010, 0x0000_0018, 0x0010_0000),  // kVK_RightCommand
        56: (0x0000_0002, 0x0000_0006, 0x0002_0000),  // kVK_Shift
        60: (0x0000_0004, 0x0000_0006, 0x0002_0000),  // kVK_RightShift
        58: (0x0000_0020, 0x0000_0060, 0x0008_0000),  // kVK_Option
        61: (0x0000_0040, 0x0000_0060, 0x0008_0000),  // kVK_RightOption
        59: (0x0000_0001, 0x0000_2001, 0x0004_0000),  // kVK_Control
        62: (0x0000_2000, 0x0000_2001, 0x0004_0000),  // kVK_RightControl
        57: (0, 0, 0x0001_0000),                      // kVK_CapsLock
        63: (0, 0, 0x0080_0000),                      // kVK_Function
    ]

    /// Whether a `flagsChanged` event for `keyCode` describes that key going down or
    /// coming up. An unrecognised key code is reported as `.pressed`, which keeps an
    /// unknown modifier behaving as it did before: it cancels the gesture.
    public static func transition(keyCode: Int64, rawFlags: UInt64) -> TriggerTransition {
        guard let mask = masks[keyCode] else { return .pressed }
        if mask.side != 0 {
            if rawFlags & mask.side != 0 { return .pressed }
            if rawFlags & mask.pair != 0 { return .released }
        }
        return rawFlags & mask.shared != 0 ? .pressed : .released
    }
}
