import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Base meters per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }
}

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case active
    case reconnecting
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "Not Spoofing"
        case .connecting: return "Starting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Interrupted"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    @Published var isBusy = false
    @Published var joystickActive = false

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []

    private let engine = LocationEngine()
    private let vpn = LocusVPN.shared
    private var operation: Task<Void, Never>?
    private var stopping = false
    private var refreshTask: Task<Void, Never>?
    private var nextRefresh = ContinuousClock.now
    private var joystickTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    private let locationKeeper = BackgroundKeepAlive()

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"

    init() {
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)
        vpn.beforeDisconnect = { [weak self] in
            guard let self, self.operation != nil || self.simulated != nil || self.routeTask != nil || self.joystickActive else { return }
            await self.stop().value
            if self.status.isDropped { throw LocationEngineError.locationClear }
        }
    }

    var isSpoofing: Bool {
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        guard !stopping else { return }
        routeTask?.cancel()
        pin = coordinate
        apply(coordinate, pairing: pairing, markRecent: true, connectVPN: true)
    }

    func vpnDidDisconnect() {
        // A failed native write can mark the session as dropped before iOS reports the disconnect.
        guard simulated != nil, !stopping,
              refreshTask != nil || routeTask != nil || joystickActive || operation != nil else { return }
        stop()
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        if stopping, let operation { return operation }
        stopping = true
        routeTask?.cancel()
        routeTask = nil
        stopJoystick()
        refreshTask?.cancel()
        refreshTask = nil

        let previous = operation
        previous?.cancel()
        isBusy = true
        let task = Task {
            // A native write already in progress must finish before the final clear.
            await previous?.value
            let result = await engine.clear()
            operation = nil
            isBusy = false
            stopping = false
            endBackground()
            switch result {
            case .success:
                simulated = nil
                status = .idle
                // Keep the map puck tracking the real GPS fix after stopping.
                locationKeeper.start()
            case .failure(let error):
                lastError = error.localizedDescription
                status = .dropped(error.localizedDescription)
                postDropNotification(error.localizedDescription)
            }
        }
        operation = task
        return task
    }

    /// Best-known real device coordinate (not the teleport pin).
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate
    }

    /// Start lightweight GPS updates for the map puck / locate button.
    func startLocationUpdates() {
        locationKeeper.start()
    }

    func startJoystick(pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        guard !stopping else { return }
        let start = simulated ?? pin ?? locationKeeper.lastKnownCoordinate
        guard let start else {
            lastError = "Drop a pin or teleport somewhere before using the joystick."
            return
        }
        routeTask?.cancel()
        if simulated == nil || vpn.status != .connected {
            apply(start, pairing: pairing, markRecent: false, connectVPN: true)
        }
        joystickActive = true
        joystickTask?.cancel()
        joystickTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.tickJoystick(pairing: pairing)
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystickTask?.cancel()
        joystickTask = nil
    }

    func followRoute(_ coordinates: [CLLocationCoordinate2D], pairing: PairingStore) {
        guard !stopping, pairing.hasPairingFile, coordinates.count >= 2 else { return }
        routeTask?.cancel()
        stopJoystick()
        let mode = travelMode
        routeTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            var previous = coordinates[0]
            await self.apply(previous, pairing: pairing, markRecent: true, connectVPN: true).value
            guard !Task.isCancelled, self.status == .active else { return }
            for next in coordinates.dropFirst() {
                if Task.isCancelled { return }
                let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
                var speed = mode.baseSpeed * Double.random(in: 0.88...1.12)
                speed = max(0.8, speed)
                let stepMeters: CLLocationDistance = min(12, max(4, speed * 0.5))
                let steps = max(1, Int(ceil(distance / stepMeters)))
                for i in 1...steps {
                    if Task.isCancelled { return }
                    let t = Double(i) / Double(steps)
                    let coord = CLLocationCoordinate2D(
                        latitude: previous.latitude + (next.latitude - previous.latitude) * t,
                        longitude: previous.longitude + (next.longitude - previous.longitude) * t
                    )
                    let delay = stepMeters / speed
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch { return }
                    guard !Task.isCancelled else { return }
                    await self.apply(coord, pairing: pairing, markRecent: false).value
                }
                previous = next
            }
        }
    }

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Don't let a generic star overwrite a named favorite for the same spot.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// Best display name for starring the current pin (search title, matching recent, etc.).
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let favorite = favorites.first(where: { $0.id == SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude).id }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.00015 && abs($0.longitude - coordinate.longitude) < 0.00015
        }), !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Favorite" { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    @discardableResult
    private func apply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool, connectVPN: Bool = false) -> Task<Void, Never> {
        if status == .idle || status.isDropped {
            status = .connecting
        }
        isBusy = true
        let previous = operation
        previous?.cancel()
        let pairingPath = pairing.pairingPath
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                // Only a user action can start the VPN. A scheduled resend must respect a disconnect.
                if connectVPN { try await vpn.connect() }
                try Task.checkCancellation()
                guard vpn.status == .connected, let peer = vpn.connectedPeer else {
                    throw LocationEngineError.vpnDisconnected
                }
                try await engine.set(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                     pairingPath: pairingPath, deviceIP: peer).get()
                try Task.checkCancellation()
                guard vpn.status == .connected else {
                    _ = await engine.clear()
                    throw LocationEngineError.vpnDisconnected
                }
                if simulated == nil { locationKeeper.start() }
                simulated = coordinate
                pin = coordinate
                status = .active
                lastError = nil
                beginBackground()
                nextRefresh = .now + .seconds(8)
                startRefresh(pairing: pairing)
                if markRecent { pushRecent(coordinate) }
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
                if simulated != nil {
                    status = .dropped(error.localizedDescription)
                    nextRefresh = .now + .seconds(12)
                    postDropNotification(error.localizedDescription)
                } else {
                    status = .idle
                    stopJoystick()
                }
            }
            operation = nil
            isBusy = false
        }
        operation = task
        return task
    }

    private func tickJoystick(pairing: PairingStore) {
        guard joystickActive, !isBusy, let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)
        guard magnitude > 0.08 else { return }
        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        let speed = travelMode.baseSpeed * min(1.0, magnitude) * Double.random(in: 0.9...1.1)
        let dt = 0.25
        let meters = speed * dt
        let next = offset(coordinate: current, eastMeters: nx * meters, northMeters: ny * meters)
        apply(next, pairing: pairing, markRecent: false)
    }

    private func startRefresh(pairing: PairingStore) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while let deadline = self?.nextRefresh {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch { return }
                guard let self, !Task.isCancelled, let coordinate = self.simulated else { return }
                // Movement resets the deadline. Avoid resending a previous coordinate while a write is pending.
                if let operation = self.operation {
                    await operation.value
                    continue
                }
                guard deadline == self.nextRefresh else { continue }
                if self.status.isDropped { self.status = .reconnecting }
                await self.apply(coordinate, pairing: pairing, markRecent: false).value
            }
        }
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: Self.coordinateLabel(coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func postDropNotification(_ message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Locus spoof dropped"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func offset(coordinate: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let earth = 6378137.0
        let dLat = northMeters / earth * (180 / .pi)
        let dLon = eastMeters / (earth * cos(coordinate.latitude * .pi / 180)) * (180 / .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }
}
