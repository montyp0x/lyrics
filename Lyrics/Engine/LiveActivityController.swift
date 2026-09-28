import ActivityKit
import UIKit

@MainActor
final class LiveActivityController {
    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: LyricsActivityAttributes.ContentState?
    /// Without an activity `lastState` stays nil, so log on changes of this key instead of every tick.
    private var lastLogKey: String?

    func update(_ state: LyricsActivityAttributes.ContentState) {
        if let activity, activity.activityState == .ended || activity.activityState == .dismissed {
            self.activity = nil
            lastState = nil
        }
        guard state != lastState else { return }
        let logKey = "\(activity.map { "\($0.activityState)" } ?? "nil") \(state.title)"
        if logKey != lastLogKey {
            lastLogKey = logKey
            DiagnosticsLog.write("activity \(activity.map { "\($0.activityState)" } ?? "nil") -> \(state.title): \(state.currentLine)")
        }

        if let activity {
            lastState = state
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }

        // Activities can only be started while the app is in the foreground.
        guard UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let existing = Activity<LyricsActivityAttributes>.activities.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
            activity = existing
            lastState = state
            Task { await existing.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }

        do {
            activity = try Activity.request(
                attributes: LyricsActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastState = state
        } catch {
            DiagnosticsLog.write("activity request failed: \(error)")
        }
    }

    func end() {
        let activities = Activity<LyricsActivityAttributes>.activities
        activity = nil
        lastState = nil
        Task {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
