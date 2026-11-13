import Foundation

/// A presentation-only filter. Unknown or invalid durations remain visible.
enum RecordingVisibility {
    static let defaultMinimumDurationSeconds = 5

    static func includes(duration: Double?, minimumDurationSeconds: Int) -> Bool {
        guard let duration, duration.isFinite, duration >= 0 else { return true }
        return duration >= Double(max(0, minimumDurationSeconds))
    }
}
