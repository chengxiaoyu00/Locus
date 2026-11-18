import Foundation
import idevice
import UIKit
import UserNotifications
import CoreLocation

/// Runs idevice's iOS 27+ pairable-host flow on-device.
///
/// Bonjour discovery uses iOS's system service. Native pair-setup runs on its own serial executor.
@MainActor
final class PairOnDeviceService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case advertising
        case deviceConnected
        case awaitingPIN(String)
        case succeeded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pin: String?

    private static let pinNotificationID = "locus.pairing.pin"
    private var worker: PairingWorker?
    private var socket: PairingSocket?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private let keepAlive = PairingKeepAlive()
    private let audioKeepAlive = SilentAudioKeepAlive()
    private let advertiser = PairableHostAdvertiser()

    var isBusy: Bool {
        switch phase {
        case .advertising, .deviceConnected, .awaitingPIN: return true
        default: return false
        }
    }

    func start(pairingStore: PairingStore) {
        guard !isBusy else { return }
        Self.clearPINNotification()
        phase = .advertising
        pin = nil
        let worker = PairingWorker()
        self.worker = worker
        requestNotificationPermission()
        beginKeepAlive()

        let revision = pairingStore.revision
        Task { [self] in
            do {
                let info = try await worker.prepare()
                guard self.worker === worker else { return }
                try advertiser.publish(service: info.name, records: info.records) { [weak self] socket in
                    guard let self, self.worker === worker else { return }
                    self.accept(socket, worker: worker, pairingStore: pairingStore, revision: revision)
                } onFailure: { [weak self] message in
                    guard let self, self.worker === worker else { return }
                    self.handleFailure(message)
                }
            } catch {
                guard self.worker === worker else { return }
                handleFailure(error.localizedDescription)
            }
        }
    }

    private func accept(_ socket: PairingSocket, worker: PairingWorker, pairingStore: PairingStore, revision: UUID) {
        self.socket = socket
        handleConnected()
        Task { [self] in
            do {
                let data = try await worker.pair(socket) { [weak self] value in
                    guard let self, self.worker === worker else { return }
                    self.handlePIN(value)
                }
                guard self.worker === worker else { return }
                guard pairingStore.revision == revision else {
                    throw PairingFailure("The pairing file changed while pairing was in progress.")
                }
                try pairingStore.installPairingData(data)
                handleSuccess()
            } catch {
                guard self.worker === worker else { return }
                handleFailure(error.localizedDescription)
            }
        }
    }

    func acknowledgeFailure() {
        if case .failed = phase {
            teardown()
            phase = .idle
            pin = nil
        }
    }

    func resetToIdle() {
        if isBusy { NSLog("[Locus pairing] Canceled from pairing UI") }
        teardown()
        phase = .idle
        pin = nil
    }

    private func handleConnected() {
        NSLog("[Locus pairing] TCP accepted")
        phase = .deviceConnected
        Self.postPlainNotification(
            title: "Locus connected",
            body: "Generating pairing code…"
        )
    }

    private func handlePIN(_ value: String) {
        NSLog("[Locus pairing] PIN available")
        pin = value
        phase = .awaitingPIN(value)
        Self.postPINNotification(value)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func handleSuccess() {
        pin = nil
        phase = .succeeded
        teardown()
        Self.postPlainNotification(
            title: "Locus paired",
            body: String(localized: "Pairing is complete. Open Locus to start simulating your location.")
        )
    }

    private func handleFailure(_ message: String) {
        pin = nil
        phase = .failed(message)
        teardown()
    }

    private func teardown() {
        guard worker != nil else { return }
        worker = nil
        Self.clearPINNotification()
        advertiser.stop()
        socket?.interrupt()
        socket = nil
        endKeepAlive()
    }

    private func beginKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = true
        keepAlive.start()
        audioKeepAlive.start()
        guard backgroundTask == .invalid, let worker else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "locus.pairable-host") { [weak self, weak worker] in
            guard let self, let worker, self.worker === worker else { return }
            self.endKeepAlive()
        }
    }

    private func endKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = false
        keepAlive.stop()
        audioKeepAlive.stop()
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func clearPINNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [pinNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [pinNotificationID])
    }

    private static func postPINNotification(_ pin: String) {
        let content = UNMutableNotificationContent()
        content.title = "Locus pairing code"
        content.body = pin
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: pinNotificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func postPlainNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "locus.pairing.status.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

}

private final class PairingKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }

    func start() {
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }
}

private struct PairingFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let error else { return }
        defer { idevice_error_free(error) }
        throw Self(error.pointee.message.map { String(cString: $0) } ?? "Pairing error (\(error.pointee.code)).")
    }
}

private final class PairingIdentity {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { pairable_host_free(handle) }
}

private final class PINCallback: Sendable {
    let display: @MainActor @Sendable (String) -> Void
    init(_ display: @escaping @MainActor @Sendable (String) -> Void) { self.display = display }
}

private actor PairingWorker {
    struct Service: Sendable {
        let name: String
        let records: [String: String]
    }

    private static let queue = DispatchSerialQueue(label: "locus.pairable-host", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { Self.queue.asUnownedSerialExecutor() }
    private var identity: PairingIdentity?

    func prepare() throws -> Service {
        var handle: OpaquePointer?
        var name: UnsafeMutablePointer<CChar>?
        var bytes: UnsafeMutablePointer<UInt8>?
        var count: UInt = 0
        // A fresh random PIN is required for every new pairing attempt.
        try PairingFailure.check(pairable_host_prepare("Locus", "Mac17,7", false, &handle, &name, &bytes, &count, nil))
        defer {
            if let name { idevice_string_free(name) }
            if let bytes { idevice_data_free(bytes, count) }
        }
        guard let handle else { throw PairingFailure("No pairing identity was returned.") }
        identity = PairingIdentity(handle)
        guard let name, let bytes,
              let records = try PropertyListSerialization.propertyList(
                from: Data(bytes: bytes, count: Int(count)), format: nil
              ) as? [String: String] else { throw PairingFailure("Invalid Bonjour pairing information.") }
        return Service(name: String(cString: name), records: records)
    }

    func pair(_ socket: PairingSocket, onPIN: @escaping @MainActor @Sendable (String) -> Void) throws -> Data {
        guard let identity else { throw PairingFailure("No pairing identity was prepared.") }
        let callback = PINCallback(onPIN)
        var file: OpaquePointer?
        let error = withExtendedLifetime((socket, callback)) {
            pairable_host_accept_fd(identity.handle, socket.descriptor, { pin, ctx in
                guard let pin, let ctx else { return }
                let value = String(cString: pin)
                let callback = Unmanaged<PINCallback>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async { callback.display(value) }
            }, Unmanaged.passUnretained(callback).toOpaque(), nil, &file)
        }
        if let error {
            NSLog("[Locus pairing] Native handshake failed (code %d)", error.pointee.code)
            try PairingFailure.check(error)
        }
        NSLog("[Locus pairing] Native handshake completed")
        guard let file else { throw PairingFailure("Pairing finished but no pairing file was returned.") }
        defer { rp_pairing_file_free(file) }

        var bytes: UnsafeMutablePointer<UInt8>?
        var count: UInt = 0
        try PairingFailure.check(rp_pairing_file_to_bytes(file, &bytes, &count))
        guard let bytes else { throw PairingFailure("The pairing file is empty.") }
        defer { idevice_data_free(bytes, count) }
        return Data(bytes: bytes, count: Int(count))
    }
}
