//
//  LocationKeepAlive.swift
//  CarPlayLyrics
//
//  Second keep-alive, alongside SilentAudioPlayer. iOS keeps an app running while it receives
//  background location updates (this is how navigation apps stay alive), so lyrics keep moving
//  even if the silent-audio trick gets suspended. Low accuracy (cell/Wi-Fi), so it's cheap.
//  Shows the blue location indicator while active. Personal-use technique.
//

import CoreLocation
import Foundation

@MainActor
final class LocationKeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = LocationKeepAlive()

    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private var isWanted = false

    var isRunning: Bool { backgroundSession != nil }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Call from the foreground (the background session can only be created there).
    func start() {
        isWanted = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        default:
            DiagnosticsLog.shared.add("Location keep-alive off: location access denied")
        }
    }

    func stop() {
        isWanted = false
        manager.stopUpdatingLocation()
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    private func begin() {
        guard isWanted, backgroundSession == nil else { return }
        backgroundSession = CLBackgroundActivitySession()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let keepAlive = LocationKeepAlive.shared
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                keepAlive.begin()
            } else if status == .denied || status == .restricted {
                DiagnosticsLog.shared.add("Location keep-alive off: location access denied")
            }
        }
    }

    // Updates only keep the app alive; the locations themselves aren't used.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in DiagnosticsLog.shared.add("Location error: \(message)") }
    }
}
