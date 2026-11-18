//
//  PacketTunnelProvider.swift
//  TunnelProv
//
//  Created by Stossy11 on 28/03/2025.
//

import NetworkExtension
import os
#if DEBUG
import os.log
#endif

@inline(__always)
private func tunnelLog(_ message: @autoclosure () -> String) {
#if DEBUG
    os_log("[TunnelProv] %{public}@", type: .error, message())
#endif
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let packets = PacketLoop()

    nonisolated(nonsending) override func startTunnel(options: [String: NSObject]?) async throws {
        let session = packets.begin()
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let ifaceIP = options?[TunnelConstants.ifaceIPConfigurationKey] as? String
            ?? configuration?[TunnelConstants.ifaceIPConfigurationKey] as? String
            ?? TunnelConstants.defaultIfaceIP
        let peerIP = options?[TunnelConstants.peerIPConfigurationKey] as? String
            ?? configuration?[TunnelConstants.peerIPConfigurationKey] as? String
            ?? TunnelConstants.defaultPeerIP

        let iface = CIDREndpoint(ifaceIP, defaultPrefix: 24)
        let peer = CIDREndpoint(peerIP, defaultPrefix: 32)
        let ipv4 = NEIPv4Settings(addresses: [iface.ip], subnetMasks: [iface.subnetMask])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: peer.ip, subnetMask: peer.subnetMask)]
        ipv4.excludedRoutes = [.default()]
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peer.ip)
        settings.ipv4Settings = ipv4

        tunnelLog("Configuring tunnel: interface=\(iface.ip)/\(iface.prefix), peer=\(peer.ip)/\(peer.prefix)")
        try await setTunnelNetworkSettings(settings)
        try packets.activate(session, flow: packetFlow, addresses: [
            TunnelConstants.ifaceIPConfigurationKey: iface.formattedCIDR,
            TunnelConstants.peerIPConfigurationKey: peer.formattedCIDR
        ])
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard messageData == TunnelConstants.addressQuery, let addresses = packets.addresses else { return nil }
        return try? JSONEncoder().encode(addresses)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        packets.stop()
    }
}

// Keep a single outstanding read per session. NetworkExtension can deliver a final
// read after stop, so the callback carries its session and does not retain the flow.
private final class PacketLoop: Sendable {
    private struct State {
        var session: UUID?
        var flow: NEPacketTunnelFlow?
        var addresses: [String: String]?
    }

    // The SDK flow is not Sendable. It is used only while holding this lock,
    // including registering the next read and writing to the current session.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var addresses: [String: String]? { state.withLock { $0.addresses } }

    func begin() -> UUID {
        let id = UUID()
        state.withLock { $0 = State(session: id) }
        return id
    }

    func activate(_ id: UUID, flow: NEPacketTunnelFlow, addresses: [String: String]) throws {
        try state.withLockUnchecked {
            guard $0.session == id else { throw CancellationError() }
            $0.flow = flow
            $0.addresses = addresses
            read(flow, for: id)
        }
    }

    func stop() {
        state.withLock { $0 = State() }
    }

    private func read(_ flow: NEPacketTunnelFlow, for id: UUID) {
        flow.readPackets { [weak self] packets, protocols in
            // Never reenter the lock if the SDK completes a buffered read inline.
            Task { self?.receive(packets, protocols: protocols, for: id) }
        }
    }

    private func receive(_ packets: [Data], protocols: [NSNumber], for id: UUID) {
        var modified = packets
        for i in modified.indices where protocols[i].int32Value == AF_INET && modified[i].count >= 20 {
            modified[i].withUnsafeMutableBytes { bytes in
                guard let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
                let src = ptr[3]
                let dst = ptr[4]
                ptr[3] = dst
                ptr[4] = src
            }
        }

        let output = modified
        state.withLock { current in
            guard current.session == id, let flow = current.flow else { return }
            flow.writePackets(output, withProtocols: protocols)
            read(flow, for: id)
        }
    }
}
