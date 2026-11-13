import Foundation

@main
struct RecordingVisibilityTests {
    static func main() {
        func check(_ actual: Bool, _ expected: Bool, _ label: String) {
            precondition(actual == expected, label)
        }
        let defaultThreshold = RecordingVisibility.defaultMinimumDurationSeconds
        precondition(defaultThreshold == 5, "Default minimum must be five seconds")
        check(RecordingVisibility.includes(duration: 4.999, minimumDurationSeconds: defaultThreshold), false, "Below 5 seconds is hidden")
        check(RecordingVisibility.includes(duration: 5, minimumDurationSeconds: defaultThreshold), true, "Exactly 5 seconds is shown")
        check(RecordingVisibility.includes(duration: nil, minimumDurationSeconds: defaultThreshold), true, "Missing duration is shown")
        check(RecordingVisibility.includes(duration: .nan, minimumDurationSeconds: defaultThreshold), true, "Invalid duration is shown")
        check(RecordingVisibility.includes(duration: -.infinity, minimumDurationSeconds: defaultThreshold), true, "Non-finite duration is shown")
        check(RecordingVisibility.includes(duration: -1, minimumDurationSeconds: defaultThreshold), true, "Negative duration is shown")
        check(RecordingVisibility.includes(duration: 0, minimumDurationSeconds: 0), true, "A zero threshold disables filtering")
        check(RecordingVisibility.includes(duration: 4.999, minimumDurationSeconds: 0), true, "Zero threshold shows short recordings")
        check(RecordingVisibility.includes(duration: 9, minimumDurationSeconds: 10), false, "Custom thresholds filter correctly")
        print("Recording visibility: default, boundary, unknown, and disabled checks passed")
    }
}
