import Foundation

/// Shared, behavior-preserving conversions from `Duration` to wall-clock seconds / milliseconds.
///
/// `Duration.components` yields whole `seconds` plus `attoseconds` (1e-18); both are summed so
/// sub-second values survive the conversion. This is the single source of truth for the math that
/// was previously hand-rolled in `WhisperKitTranscriber` (#63 STT timing), `DictationCoordinator`'s
/// pipeline metrics, and its `Date`-arithmetic freshness helper. `1e18 == 1_000_000_000_000_000_000.0`
/// exactly in `Double`, so this is byte-identical to every prior copy.
public extension Duration {
    /// The duration in fractional seconds.
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// The duration in fractional milliseconds.
    var milliseconds: Double { seconds * 1000 }
}
