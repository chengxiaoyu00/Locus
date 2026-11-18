import Darwin
import dnssd
import Foundation
import Network

/// A connected descriptor remains owned until both the UI and the native handshake release it.
final class PairingSocket: Sendable {
    let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    func interrupt() {
        _ = shutdown(descriptor, SHUT_RDWR)
    }

    deinit { close(descriptor) }
}

@MainActor
final class PairableHostAdvertiser {
    private var listener: DispatchSourceRead?
    private var registration: DNSServiceRef?
    private var onFailure: ((String) -> Void)?

    func publish(
        service: String, records: [String: String],
        onConnection: @escaping (PairingSocket) -> Void,
        onFailure: @escaping (String) -> Void
    ) throws {
        stop()
        let fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            guard let self, self.listener?.handle == UInt(fd) else { return }
            let peer = accept(fd, nil, nil)
            if peer >= 0 {
                // The paired peer keeps its socket, and Settings can still discover the host until pair-setup finishes.
                self.stopAccepting()
                onConnection(PairingSocket(peer))
            } else if errno != EWOULDBLOCK && errno != EINTR {
                let message = POSIXError(.init(rawValue: errno) ?? .EIO).localizedDescription
                self.stop()
                onFailure(message)
            }
        }
        listener = source
        self.onFailure = onFailure
        source.activate()

        do {
            var dualStack: Int32 = 0
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            var length = socklen_t(address.sin6_len)
            guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &dualStack, socklen_t(MemoryLayout.size(ofValue: dualStack))) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, $0, &length) == 0
                }
            }
            guard bound else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let txt = NWTXTRecord(records).data
            let error = txt.withUnsafeBytes { buffer in
                DNSServiceRegister(
                    &registration, DNSServiceFlags(kDNSServiceFlagsIncludeP2P), 0, service,
                    "_remotepairing-pairable-host._tcp", "local.", nil, address.sin6_port,
                    UInt16(buffer.count), buffer.baseAddress, pairingRegistrationCallback,
                    Unmanaged.passUnretained(self).toOpaque()
                )
            }
            guard error == kDNSServiceErr_NoError, let registration else {
                throw Self.bonjourError(error)
            }
            let scheduleError = DNSServiceSetDispatchQueue(registration, .main)
            guard scheduleError == kDNSServiceErr_NoError else { throw Self.bonjourError(scheduleError) }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let registration { DNSServiceRefDeallocate(registration) }
        registration = nil
        stopAccepting()
        onFailure = nil
    }

    private func stopAccepting() {
        listener?.cancel()
        listener = nil
    }

    fileprivate func registrationDidReply(_ identifier: UInt, error: DNSServiceErrorType) {
        guard let registration, identifier == UInt(bitPattern: registration), let onFailure else { return }
        if error == kDNSServiceErr_NoError {
            NSLog("[Locus pairing] Bonjour published")
        } else {
            NSLog("[Locus pairing] Bonjour registration failed (code %d)", error)
            stop()
            onFailure(Self.bonjourError(error).localizedDescription)
        }
    }

    private static func bonjourError(_ code: DNSServiceErrorType) -> NSError {
        NSError(domain: "Bonjour", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "Could not advertise pairing with Bonjour (\(code))."
        ])
    }
}

private let pairingRegistrationCallback: DNSServiceRegisterReply = { ref, _, error, _, _, _, context in
    guard let context, let ref else { return }
    let advertiser = Unmanaged<PairableHostAdvertiser>.fromOpaque(context).takeUnretainedValue()
    let identifier = UInt(bitPattern: ref)
    // DNSServiceSetDispatchQueue registers this callback on the main queue.
    MainActor.assumeIsolated {
        advertiser.registrationDidReply(identifier, error: error)
    }
}
