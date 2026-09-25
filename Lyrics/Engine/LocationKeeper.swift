import CoreLocation

/// iOS rejects Live Activity updates from a process that is "only playing background media",
/// so a coarse location session runs alongside the silent audio to give the app another background reason.
@MainActor
final class LocationKeeper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var session: CLBackgroundActivitySession?
    private var wantsRunning = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        wantsRunning = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        default:
            break
        }
    }

    func stop() {
        wantsRunning = false
        manager.stopUpdatingLocation()
        session?.invalidate()
        session = nil
    }

    private func begin() {
        guard session == nil else { return }
        // Must be created while the app is in the foreground.
        session = CLBackgroundActivitySession()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        DiagnosticsLog.write("location keeper started")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            DiagnosticsLog.write("location auth: \(self.manager.authorizationStatus.rawValue)")
            if self.wantsRunning { self.start() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
