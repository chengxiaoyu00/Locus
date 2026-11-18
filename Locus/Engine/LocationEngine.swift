import Foundation
import idevice

enum LocationEngineError: LocalizedError {
    case vpnDisconnected
    case invalidIP
    case pairingRead
    case tunnelCreate
    case remoteServer
    case simulationCreate
    case locationSet
    case locationClear

    var errorDescription: String? {
        switch self {
        case .vpnDisconnected: return String(localized: "The Locus VPN is disconnected. Connect it in Settings and try again.")
        case .invalidIP: return String(localized: "The device IP is invalid. Check the VPN addresses in Locus Settings.")
        case .pairingRead: return "Could not read the RPPairing file. Generate one with idevice_pair in RPPairing mode."
        case .tunnelCreate: return String(localized: "The VPN connected, but the developer tunnel could not open. Check Wi-Fi and the pairing file for this iPhone.")
        case .remoteServer: return "Connected to the tunnel but RemoteXPC handshake failed."
        case .simulationCreate: return "Could not open Apple’s location simulation service."
        case .locationSet: return "Failed to set simulated coordinates."
        case .locationClear: return "Failed to clear simulated location."
        }
    }
}

/// Thin Swift wrapper around idevice’s DVT location simulation (injects into locationd).
actor LocationEngine {
    // The native calls block, so give them a serial queue independent of the UI and cooperative pool.
    private nonisolated let queue = DispatchSerialQueue(label: "com.chrismack.locus.location", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var remoteServer: OpaquePointer?
    private var locationSimulation: OpaquePointer?

    func clear() -> Result<Void, LocationEngineError> {
        guard let locationSimulation else { return .success(()) }
        if let error = location_simulation_clear(locationSimulation) {
            // Keep the handles for a retry while the VPN is still available.
            idevice_error_free(error)
            return .failure(.locationClear)
        }
        cleanup()
        return .success(())
    }

    private func cleanup() {
        // The simulation borrows the remote server until location_simulation_free.
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    func set(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) -> Result<Void, LocationEngineError> {
        if let locationSimulation {
            if let err = location_simulation_set(locationSimulation, latitude, longitude) {
                idevice_error_free(err)
                cleanup()
            } else {
                return .success(())
            }
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(49152).bigEndian
        let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else { return .failure(.invalidIP) }

        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            idevice_error_free(pairingError)
            return .failure(.pairingRead)
        }
        guard let pairingHandle else { return .failure(.pairingRead) }
        defer { rp_pairing_file_free(pairingHandle) }

        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        let providerError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing(
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.stride),
                    "LocusLocation",
                    pairingHandle,
                    nil,
                    nil,
                    &newAdapter,
                    &newHandshake
                )
            }
        }
        adapter = newAdapter
        handshake = newHandshake
        if let providerError {
            idevice_error_free(providerError)
            cleanup()
            return .failure(.tunnelCreate)
        }

        if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            idevice_error_free(remoteServerError)
            cleanup()
            return .failure(.remoteServer)
        }

        if let simError = location_simulation_new(remoteServer, &locationSimulation) {
            idevice_error_free(simError)
            cleanup()
            return .failure(.simulationCreate)
        }
        if let setError = location_simulation_set(locationSimulation, latitude, longitude) {
            idevice_error_free(setError)
            cleanup()
            return .failure(.locationSet)
        }
        return .success(())
    }
}
