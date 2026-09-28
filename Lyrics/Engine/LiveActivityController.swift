import ActivityKit
import UIKit

/// Starts, updates, and replaces the lyrics Live Activity.
///
/// iOS ends a Live Activity 8 hours after it starts but leaves its last content on screen, which looks like
/// frozen lyrics. So the controller replaces an activity that has ended, retrying from the background, and
/// starts a fresh one whenever the app comes to the foreground with an activity older than an hour.
@MainActor
final class LiveActivityController {
    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: LyricsActivityAttributes.ContentState?
    /// Without an activity `lastState` stays nil, so log on changes of this key instead of every tick.
    private var lastLogKey: String?
    /// Set when the current activity should be replaced rather than adopted again.
    private var wantsFreshActivity = false
    private var lastStartAttempt: Date?
    private var lastStartError: String?

    private static let refreshAge: TimeInterval = 60 * 60
    private static let backgroundRetryInterval: TimeInterval = 60

    func update(_ state: LyricsActivityAttributes.ContentState) {
        if let activity, activity.activityState == .ended || activity.activityState == .dismissed {
            DiagnosticsLog.write("activity \(activity.id.prefix(8)) is \(activity.activityState), age \(age(of: activity))")
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
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if !wantsFreshActivity, let existing = Activity<LyricsActivityAttributes>.activities.first(where: {
            $0.activityState == .active || $0.activityState == .stale
        }) {
            activity = existing
            lastState = state
            observe(existing, adopted: true)
            Task { await existing.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        start(with: state)
    }

    /// Called when the app comes to the foreground, the only time starting an activity is guaranteed to work.
    func appDidBecomeActive() {
        if let activity, Date.now.timeIntervalSince(startDate(of: activity)) > Self.refreshAge {
            DiagnosticsLog.write("activity \(activity.id.prefix(8)) is \(age(of: activity)) old; starting a fresh one")
            wantsFreshActivity = true
            self.activity = nil
            lastState = nil
        }
        lastStartAttempt = nil
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

    private func start(with state: LyricsActivityAttributes.ContentState) {
        let inForeground = UIApplication.shared.applicationState == .active
        // Starting from the background may be refused; don't retry on every tick.
        if !inForeground, let last = lastStartAttempt, Date.now.timeIntervalSince(last) < Self.backgroundRetryInterval {
            return
        }
        lastStartAttempt = .now
        do {
            let created = try Activity.request(
                attributes: LyricsActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            activity = created
            lastState = state
            wantsFreshActivity = false
            lastStartError = nil
            observe(created, adopted: false)
            DiagnosticsLog.write("activity started from \(inForeground ? "foreground" : "background")")
            // Remove replaced or expired activities so their stale content doesn't linger on screen.
            let others = Activity<LyricsActivityAttributes>.activities.filter { $0.id != created.id }
            Task {
                for other in others {
                    await other.end(nil, dismissalPolicy: .immediate)
                }
            }
        } catch {
            // Keep using the existing activity rather than retrying a failing request every tick.
            wantsFreshActivity = false
            let message = "\(error)"
            if message != lastStartError {
                lastStartError = message
                DiagnosticsLog.write("activity request failed (\(inForeground ? "foreground" : "background")): \(message)")
            }
        }
    }

    // MARK: - Age tracking

    private var observer: Task<Void, Never>?
    private static let startDatesKey = "liveActivityStartDates"

    private func startDate(of activity: Activity<LyricsActivityAttributes>) -> Date {
        let starts = UserDefaults.standard.dictionary(forKey: Self.startDatesKey) as? [String: Double] ?? [:]
        return starts[activity.id].map { Date(timeIntervalSince1970: $0) } ?? .now
    }

    private func age(of activity: Activity<LyricsActivityAttributes>) -> String {
        let minutes = Int(Date.now.timeIntervalSince(startDate(of: activity)) / 60)
        return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m"
    }

    /// Records the start date and logs every state change with the activity's age.
    private func observe(_ activity: Activity<LyricsActivityAttributes>, adopted: Bool) {
        var starts = UserDefaults.standard.dictionary(forKey: Self.startDatesKey) as? [String: Double] ?? [:]
        if starts[activity.id] == nil { starts[activity.id] = Date.now.timeIntervalSince1970 }
        let known = Set(Activity<LyricsActivityAttributes>.activities.map(\.id))
        starts = starts.filter { known.contains($0.key) }
        UserDefaults.standard.set(starts, forKey: Self.startDatesKey)

        let id = activity.id.prefix(8)
        DiagnosticsLog.write("activity \(id) \(adopted ? "adopted" : "created"), age \(age(of: activity))")
        observer?.cancel()
        observer = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                DiagnosticsLog.write("activity \(id) state -> \(state), age \(self?.age(of: activity) ?? "?")")
            }
        }
    }
}
