import SwiftUI

@main
struct LocusApp: App {
    @StateObject private var session = SpoofSession()
    @StateObject private var pairing = PairingStore()
    @StateObject private var vpn = LocusVPN.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var checkedAutoConnect = false
    @AppStorage(SetupGate.defaultsKey) private var setupComplete = false

    /// Map when setup finished, or when already paired outside this walkthrough.
    private var showMap: Bool {
        setupComplete || (pairing.hasPairingFile && !SetupGate.isInProgress)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showMap {
                    RootView()
                } else {
                    SetupFlowView(initialStep: SetupGate.initialStep(hasPairingFile: pairing.hasPairingFile)) {
                        SetupGate.markComplete()
                        setupComplete = true
                    }
                }
            }
            .environmentObject(session)
            .environmentObject(pairing)
            .environmentObject(vpn)
            .preferredColorScheme(.dark)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await vpn.refresh()
                guard !Task.isCancelled, !checkedAutoConnect else { return }
                checkedAutoConnect = true
                if UserDefaults.standard.bool(forKey: LocusVPN.autoConnectKey), vpn.status == .disconnected {
                    try? await vpn.connect()
                }
            }
            .onChange(of: vpn.status) { _, status in
                if status == .disconnected || status == .invalid {
                    session.vpnDidDisconnect()
                }
            }
            .onOpenURL { url in
                handleIncoming(url)
            }
            .onAppear {
                if !setupComplete, pairing.hasPairingFile, !SetupGate.isInProgress {
                    SetupGate.markComplete()
                    setupComplete = true
                }
            }
        }
    }

    private func handleIncoming(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["plist", "mobiledevicepairing", "mobiledevicepair"].contains(ext) {
            try? pairing.importPairing(from: url)
        } else if ext == "gpx" {
            NotificationCenter.default.post(name: .locusImportGPX, object: url)
        }
    }
}

extension Notification.Name {
    static let locusImportGPX = Notification.Name("locusImportGPX")
}
