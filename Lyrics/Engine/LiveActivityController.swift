import ActivityKit
import UIKit

@MainActor
final class LiveActivityController {
    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: LyricsActivityAttributes.ContentState?

    func update(_ state: LyricsActivityAttributes.ContentState) {
        if let activity, activity.activityState == .ended || activity.activityState == .dismissed {
            self.activity = nil
            lastState = nil
        }
        guard state != lastState else { return }

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
            print("Live Activity request failed: \(error)")
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
