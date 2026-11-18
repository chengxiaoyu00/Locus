// VPN control adapted from LocalDevVPN (SideStore Team, StosVPN License).
import Combine
import Foundation
import NetworkExtension

@MainActor
final class LocusVPN: ObservableObject {
    static let shared = LocusVPN()
    static let autoConnectKey = "locus.vpn.autoConnect"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var connectedPeer: String?
    @Published private(set) var connectedSince: Date?
    @Published private(set) var connectedInterfaceCIDR: String?
    @Published private(set) var connectedPeerCIDR: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isBusy = false
    @Published private(set) var logs: [String] = []
    var beforeDisconnect: (() async throws -> Void)?

    private static let interfaceKey = "locus.vpn.interfaceCIDR"
    private static let peerPrefixKey = "locus.vpn.peerPrefix"
    private static let intermediateKey = "locus.vpn.allowIntermediate"
    private let defaults = UserDefaults.standard
    private var manager: NETunnelProviderManager?
    private var observation: AnyCancellable?
    private var pending: Pending?
    private var stopFence: Pending?

    private init() {}

    var interfaceCIDR: String { defaults.string(forKey: Self.interfaceKey) ?? TunnelConstants.defaultIfaceIP }
    var peerCIDR: String {
        let peer = TunnelConfig.targetIP
        if peer.contains("/") { return peer }
        let prefix = defaults.object(forKey: Self.peerPrefixKey) as? Int ?? 32
        return "\(peer)/\(prefix)"
    }
    var allowIntermediate: Bool {
        defaults.object(forKey: Self.intermediateKey) as? Bool ?? TunnelConstants.defaultAllowIntermediateAddresses
    }

    private struct Addresses: Equatable {
        let iface: String
        let peer: String

        init(iface: String, peer: String, allowIntermediate: Bool) throws {
            // Earlier Locus versions stored a bare peer IPv4 address.
            let route = peer.contains("/") ? peer : peer + "/32"
            let parsed = try CIDRValidator.shared.validatePair(
                tunnelIfaceInput: iface, tunnelPeerInput: route, allowIntermediateAddresses: allowIntermediate
            )
            self.iface = parsed.iface.formattedCIDR
            self.peer = parsed.peer.formattedCIDR
        }

        var values: [String: String] {
            [TunnelConstants.ifaceIPConfigurationKey: iface, TunnelConstants.peerIPConfigurationKey: peer]
        }
        var peerIP: String { CIDREndpoint(peer).ip }
    }

    private enum Action: Equatable {
        case refresh
        case connect(Overrides)
        case disconnect
        case settings(Addresses, Bool)
    }

    struct Overrides: Equatable {
        var interfaceCIDR: String?
        var peerCIDR: String?
        var allowIntermediate: Bool?
    }

    private struct Pending {
        let id: UUID
        let action: Action
        let task: Task<Void, Error>
    }

    private var isActive: Bool {
        guard let state = manager?.connection.status else { return false }
        return state == .connected || state == .connecting || state == .reasserting
    }

    func refresh() async {
        try? await perform(.refresh) {
            let existing = try await self.loadOwnedManager()
            if let connection = existing?.connection, connection.status == .connected {
                try await self.readActivePeer(on: connection)
            }
        }
    }

    func connect() async throws { try await connect(overrides: Overrides()) }

    func connect(overrides: Overrides) async throws {
        try Task.checkCancellation()
        // A canceled location operation must not queue another start behind a deliberate stop.
        while let fence = stopFence {
            _ = try? await Self.result(of: fence.task)
            try Task.checkCancellation()
        }
        if pending == nil, let connection = manager?.connection,
           connection.status == .connected, connectedPeer != nil, connectedSince == connection.connectedDate { return }
        try await perform(.connect(overrides)) {
            try await self.start(overrides)
        }
    }

    func disconnect() async throws {
        try await perform(.disconnect, clearSimulation: true) {
            if let manager = try await self.loadOwnedManager() {
                try await self.stop(manager.connection)
            }
        }
    }

    func toggle(overrides: Overrides) async throws {
        // Resolve the toggle against the last completed request, including a cold Shortcuts launch.
        if manager == nil && pending == nil { await refresh() }
        while let previous = pending {
            _ = try? await Self.result(of: previous.task)
            try Task.checkCancellation()
        }
        if isActive { try await disconnect() } else { try await connect(overrides: overrides) }
    }

    func applySettings(interfaceCIDR: String, peerIP: String, allowIntermediate: Bool) async throws {
        let addresses: Addresses
        do {
            addresses = try Addresses(iface: interfaceCIDR, peer: peerIP, allowIntermediate: allowIntermediate)
        } catch {
            report(error)
            throw error
        }
        let matchesPreferences = {
            addresses.iface == self.interfaceCIDR && addresses.peer == self.peerCIDR
                && allowIntermediate == self.allowIntermediate
        }
        if pending == nil && matchesPreferences() { return }
        try await perform(.settings(addresses, allowIntermediate), clearSimulation: true) {
            guard !matchesPreferences() else { return }
            let existing = try await self.loadOwnedManager()
            let restart = self.isActive
            if let existing {
                if restart { try await self.stop(existing.connection) }
                try await self.save(existing, addresses: addresses)
            }
            self.defaults.set(addresses.iface, forKey: Self.interfaceKey)
            self.defaults.set(CIDREndpoint(addresses.peer).prefix, forKey: Self.peerPrefixKey)
            self.defaults.set(allowIntermediate, forKey: Self.intermediateKey)
            TunnelConfig.setTargetIP(addresses.peerIP)
            if let existing, restart { try await self.start(existing, using: addresses) }
        }
    }

    private func perform(
        _ action: Action, clearSimulation: Bool = false, work: @escaping @MainActor () async throws -> Void
    ) async throws {
        if let tail = pending, tail.action == action { return try await Self.result(of: tail.task) }
        let previous = pending?.task
        let id = UUID()
        // Clear native state while the tunnel still works. The hook can await a caller of connect().
        let cleanup = clearSimulation ? beforeDisconnect.map { callback in Task { try await callback() } } : nil
        let task = Task {
            defer {
                if stopFence?.id == id { stopFence = nil }
                if pending?.id == id { pending = nil; isBusy = false }
            }
            _ = await previous?.result
            if action != .refresh { lastError = nil }
            do {
                try await cleanup?.value
                try await work()
            } catch {
                report(error)
                throw error
            }
        }
        let request = Pending(id: id, action: action, task: task)
        if clearSimulation { stopFence = request }
        pending = request
        if action != .refresh { isBusy = true }
        try await Self.result(of: task)
    }

    // A request may be shared by a map update, a button and Shortcuts. Canceling one
    // waiter must release it immediately without canceling the system operation for the others.
    private static func result(of task: Task<Void, Error>) async throws {
        let (events, sender) = AsyncStream<Result<Void, Error>>.makeStream()
        let waiter = Task { sender.yield(await task.result); sender.finish() }
        defer { waiter.cancel() }
        for await result in events { return try result.get() }
        throw CancellationError()
    }

    private func loadOwnedManager() async throws -> NETunnelProviderManager? {
        let identifier = try extensionID()
        let local = try await NETunnelProviderManager.loadAllFromPreferences().filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier
        }
        let selected = local.first { $0.connection.status == .connected || $0.connection.status == .reasserting }
            ?? local.first { $0.connection.status == .connecting } ?? local.first
        observe(selected)
        return selected
    }

    private func extensionID() throws -> String {
        guard let bundle = Bundle.main.bundleIdentifier else { throw VPNError.missingIdentifier }
        return bundle + ".TunnelProv"
    }

    private func observe(_ selected: NETunnelProviderManager?) {
        manager = selected
        observation = nil
        guard let connection = selected?.connection else {
            updateStatus(nil)
            return
        }
        observation = NotificationCenter.default.publisher(for: .NEVPNStatusDidChange, object: connection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.manager?.connection === connection else { return }
                let previous = self.status
                self.updateStatus(connection)
                guard self.pending == nil else { return }
                if connection.status == .connected, self.connectedPeer == nil {
                    Task { await self.refresh() }
                } else if previous != .disconnected, connection.status == .disconnected {
                    Task {
                        do { try await connection.fetchLastDisconnectError() }
                        catch {
                            if self.manager?.connection === connection, connection.status == .disconnected {
                                self.report(error)
                            }
                        }
                    }
                }
            }
        updateStatus(connection)
    }

    private func updateStatus(_ connection: NEVPNConnection?) {
        let next = connection?.status ?? .invalid
        if connectedPeer != nil && (next != .connected || connectedSince != connection?.connectedDate) {
            connectedPeer = nil
            connectedSince = nil
            connectedInterfaceCIDR = nil
            connectedPeerCIDR = nil
        }
        if status != next {
            status = next
            let label: String
            switch next {
            case .invalid: label = String(localized: "Not configured")
            case .disconnected: label = String(localized: "Disconnected")
            case .connecting: label = String(localized: "Connecting…")
            case .connected: label = String(localized: "Connected")
            case .reasserting: label = String(localized: "Reconnecting…")
            case .disconnecting: label = String(localized: "Disconnecting…")
            @unknown default: label = String(localized: "Unknown")
            }
            log(label)
        }
    }

    private func start(_ overrides: Overrides) async throws {
        let existing = try await loadOwnedManager()
        if let connection = existing?.connection, isActive {
            if connection.status != .connected { try await wait(for: .connected, on: connection) }
            try await readActivePeer(on: connection)
            return
        }
        let preferred = try Addresses(iface: interfaceCIDR, peer: peerCIDR, allowIntermediate: allowIntermediate)
        let actual = try Addresses(iface: overrides.interfaceCIDR ?? preferred.iface,
                                   peer: overrides.peerCIDR ?? preferred.peer,
                                   allowIntermediate: overrides.allowIntermediate ?? allowIntermediate)
        let selected = existing ?? NETunnelProviderManager()
        if selected.connection.status == .disconnecting { try await wait(for: .disconnected, on: selected.connection) }
        let config = (selected.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration as? [String: String]
        if !selected.isEnabled || config != preferred.values || selected.isOnDemandEnabled {
            try await save(selected, addresses: preferred)
        }
        try await start(selected, using: actual)
    }

    private func save(_ selected: NETunnelProviderManager, addresses: Addresses) async throws {
        let proto = selected.protocolConfiguration as? NETunnelProviderProtocol ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = try extensionID()
        proto.serverAddress = "Locus Local Tunnel"
        proto.providerConfiguration = addresses.values
        selected.protocolConfiguration = proto
        selected.localizedDescription = "Locus"
        selected.isOnDemandEnabled = false
        selected.isEnabled = true
        try await selected.saveToPreferences()
        try await selected.loadFromPreferences()
        observe(selected)
    }

    private func start(_ selected: NETunnelProviderManager, using addresses: Addresses) async throws {
        let connection = selected.connection
        if connection.status == .connecting || connection.status == .reasserting || connection.status == .connected {
            if connection.status != .connected { try await wait(for: .connected, on: connection) }
            try await readActivePeer(on: connection)
            return
        }
        try await wait(for: .connected, on: connection) {
            try connection.startVPNTunnel(options: addresses.values as [String: NSString])
        }
        updateStatus(connection)
        guard connection.status == .connected else { throw VPNError.disconnected }
        record(addresses, on: connection)
        log("Connected to \(addresses.peerIP)")
    }

    private func stop(_ connection: NEVPNConnection) async throws {
        if connection.status != .invalid && connection.status != .disconnected {
            try await wait(for: .disconnected, on: connection) {
                if connection.status != .disconnecting { connection.stopVPNTunnel() }
            }
        }
        updateStatus(connection)
    }

    private func wait(for destination: NEVPNStatus, on connection: NEVPNConnection,
                      issue: (() throws -> Void)? = nil) async throws {
        let (events, sender) = AsyncStream<NEVPNStatus>.makeStream()
        let observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange,
                                                              object: connection, queue: .main) { note in
            if let source = note.object as? NEVPNConnection { sender.yield(source.status) }
        }
        defer { NotificationCenter.default.removeObserver(observer); sender.finish() }
        try issue?()
        let timeout = Task { try await Task.sleep(for: .seconds(30)); sender.finish() }
        defer { timeout.cancel() }
        let initial = connection.status
        if initial == destination || (destination == .disconnected && initial == .invalid) { return }
        if issue == nil && destination == .connected && (initial == .invalid || initial == .disconnected) {
            try await connection.fetchLastDisconnectError()
            throw VPNError.disconnected
        }
        for await state in events {
            if state == destination || (destination == .disconnected && state == .invalid) { return }
            if destination == .connected, state == .invalid || state == .disconnected {
                try await connection.fetchLastDisconnectError()
                throw VPNError.disconnected
            }
        }
        throw VPNError.timeout
    }

    private func readActivePeer(on connection: NEVPNConnection) async throws {
        updateStatus(connection)
        if connectedPeer != nil, connectedSince == connection.connectedDate { return }
        guard let session = connection as? NETunnelProviderSession, session.status == .connected else {
            throw VPNError.missingAddresses
        }
        let date = session.connectedDate
        let (replies, sender) = AsyncStream<Data?>.makeStream()
        defer { sender.finish() }
        try session.sendProviderMessage(TunnelConstants.addressQuery) { data in
            sender.yield(data)
            sender.finish()
        }
        let timeout = Task { try await Task.sleep(for: .seconds(5)); sender.finish() }
        defer { timeout.cancel() }
        for await reply in replies {
            guard let data = reply, let config = try? JSONDecoder().decode([String: String].self, from: data),
                  let iface = config[TunnelConstants.ifaceIPConfigurationKey], let peer = config[TunnelConstants.peerIPConfigurationKey],
                  let addresses = try? Addresses(iface: iface, peer: peer, allowIntermediate: true),
                  manager?.connection === session, session.status == .connected, session.connectedDate == date else { break }
            record(addresses, on: session)
            return
        }
        throw VPNError.missingAddresses
    }

    private func record(_ addresses: Addresses, on connection: NEVPNConnection) {
        connectedPeer = addresses.peerIP
        connectedPeerCIDR = addresses.peer
        connectedInterfaceCIDR = addresses.iface
        connectedSince = connection.connectedDate
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        log(error.localizedDescription)
    }

    private func log(_ message: String) {
        if logs.count >= 200 { logs.removeFirst() }
        logs.append("\(Date.now.formatted(date: .omitted, time: .standard))  \(message)")
    }

    private enum VPNError: LocalizedError {
        case disconnected, timeout, missingAddresses, missingIdentifier

        var errorDescription: String? {
            switch self {
            case .disconnected: return String(localized: "The local tunnel disconnected before it finished connecting.")
            case .timeout: return String(localized: "Timed out waiting for the local tunnel.")
            case .missingAddresses: return String(localized: "Could not read the active tunnel addresses.")
            case .missingIdentifier: return String(localized: "The app’s VPN extension identifier is unavailable.")
            }
        }
    }
}
