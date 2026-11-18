import SwiftUI
import NetworkExtension
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var showPairOnDevice = false
    @State private var showNameEasterEgg = false
    @EnvironmentObject private var vpn: LocusVPN
    @AppStorage(LocusVPN.autoConnectKey) private var autoConnect = false

    private var supportsOnDevicePairing: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(pairing.hasPairingFile ? "RPPairing file installed" : "No pairing file")
                    } icon: {
                        Image(systemName: pairing.hasPairingFile ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(pairing.hasPairingFile ? LocusTheme.statusGood : LocusTheme.statusWarn)
                    }

                    if supportsOnDevicePairing {
                        Button {
                            showPairOnDevice = true
                        } label: {
                            Label("Pair on this iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        }
                    }

                    Button("Import RPPairing file…") { showImporter = true }
                    Button("Paste RPPairing from clipboard") {
                        do {
                            try pairing.importPairingFromClipboard()
                        } catch {
                            session.lastError = error.localizedDescription
                        }
                    }
                    if pairing.hasPairingFile {
                        Button("Remove pairing file", role: .destructive) {
                            try? pairing.removePairing()
                        }
                    }
                } header: {
                    Text("Developer pairing")
                } footer: {
                    Text(supportsOnDevicePairing
                         ? "Pair on this iPhone and confirm the code under Settings › Privacy & Security › Developer Mode › Pair with Host. You can also import this iPhone’s RPPairing file."
                         : "Create an RPPairing file for this iPhone with idevice_pair on a computer. Import the file or paste its contents here.")
                }

                Section {
                    LabeledContent("VPN status") { Text(vpn.status.locusTitle) }
                    LabeledContent("Device IP") {
                        Text(verbatim: vpn.connectedPeer ?? TunnelConfig.targetIP)
                            .monospacedDigit()
                    }
                    if vpn.status == .connected {
                        if let start = vpn.connectedSince {
                            LabeledContent("Connected for") {
                                Text(start, style: .timer).monospacedDigit()
                            }
                        }
                        VPNActionButton(action: vpn.disconnect) {
                            Label("Disconnect VPN", systemImage: "power")
                        }
                        .disabled(session.isBusy || session.isSpoofing || session.simulated != nil)
                    } else {
                        VPNActionButton(action: vpn.connect) {
                            Label("Connect VPN", systemImage: "lock.shield")
                        }
                        .disabled(!vpn.status.locusCanConnect)
                    }
                    if let error = vpn.lastError {
                        Text(verbatim: error)
                            .font(.footnote)
                            .foregroundStyle(LocusTheme.statusWarn)
                            .textSelection(.enabled)
                    }
                    Toggle("Connect VPN on launch", isOn: $autoConnect)
                        .disabled(vpn.status == .invalid && !autoConnect)
                    NavigationLink("VPN addresses") { VPNAddressesView() }
                    NavigationLink("Connection log") { VPNLogView() }
                } header: {
                    Text("Local VPN")
                } footer: {
                    if session.isBusy || session.isSpoofing || session.simulated != nil {
                        Text("Stop the location simulation before disconnecting or changing VPN addresses.")
                    } else {
                        Text("The default device IP is 10.7.0.1. Use Wi-Fi for your first teleport.")
                    }
                }

                Section("Privacy") {
                    Text("Fully on-device. Favorites and recents stay in UserDefaults. No analytics, no accounts, nothing uploaded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Engine", value: "idevice DVT location simulation")
                    Text("The built-in VPN uses code from LocalDevVPN (StosVPN), by Stossy11, the SideStore Team and contributors.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Location simulation uses the MIT-licensed idevice library.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        showNameEasterEgg = true
                    } label: {
                        Text("locus, n. — a place. From the Latin for where you are.")
                            .font(.footnote.italic())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showImporter) {
            PairingDocumentPicker(
                onPick: { url in
                    showImporter = false
                    do {
                        try pairing.importPairing(from: url)
                    } catch {
                        session.lastError = error.localizedDescription
                    }
                },
                onCancel: { showImporter = false }
            )
            .ignoresSafeArea()
        }
            .sheet(isPresented: $showPairOnDevice) {
                PairOnDeviceView()
                    .environmentObject(pairing)
            }
            .fullScreenCover(isPresented: $showNameEasterEgg) {
                LocusEasterEggView()
            }
        }
    }
}

extension NEVPNStatus {
    var locusCanConnect: Bool {
        self == .invalid || self == .disconnected
    }

    var locusTitle: LocalizedStringKey {
        switch self {
        case .invalid: return "Not configured"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        @unknown default: return "Unknown"
        }
    }
}

struct VPNActionButton<Label: View>: View {
    @EnvironmentObject private var vpn: LocusVPN
    let action: @MainActor () async throws -> Void
    @ViewBuilder var label: () -> Label
    @State private var isRequesting = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            guard !isRequesting else { return }
            isRequesting = true
            Task {
                defer { isRequesting = false }
                do { try await action() }
                catch { errorMessage = error.localizedDescription }
            }
        } label: {
            label()
        }
        .disabled(isRequesting || vpn.isBusy)
        .alert("Local VPN", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }
}

private struct VPNAddressesView: View {
    @EnvironmentObject private var vpn: LocusVPN
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    @State private var interface = ""
    @State private var peer = ""
    @State private var allowIntermediate = true

    private var canSave: Bool {
        (vpn.status.locusCanConnect || vpn.status == .connected) &&
        !session.isBusy && !session.isSpoofing && session.simulated == nil &&
        (interface != vpn.interfaceCIDR || peer != vpn.peerCIDR || allowIntermediate != vpn.allowIntermediate)
    }

    var body: some View {
        Form {
            if vpn.status == .connected,
               let activeInterface = vpn.connectedInterfaceCIDR, let activePeer = vpn.connectedPeerCIDR,
               activeInterface != vpn.interfaceCIDR || activePeer != vpn.peerCIDR {
                Section("Current connection") {
                    LabeledContent("Interface address", value: activeInterface)
                    LabeledContent("Device address", value: activePeer)
                }
            }
            Section {
                LabeledContent("Interface address") {
                    TextField("10.7.1.1/32", text: $interface)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Device address") {
                    TextField("10.7.0.1/32", text: $peer)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Allow intermediate addresses", isOn: $allowIntermediate)
                Button("Use default addresses") {
                    interface = "10.7.1.1/32"
                    peer = "10.7.0.1/32"
                    allowIntermediate = true
                }
            } footer: {
                Text("Use IPv4 addresses with CIDR prefixes. Allow intermediate addresses to accept host addresses within a subnet.")
            }
            .keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Section {
                VPNActionButton(action: {
                    try await vpn.applySettings(interfaceCIDR: interface, peerIP: peer, allowIntermediate: allowIntermediate)
                    dismiss()
                }) {
                    Text("Save addresses")
                }
                .disabled(!canSave)
            } footer: {
                if session.isBusy || session.isSpoofing || session.simulated != nil {
                    Text("Stop the location simulation before disconnecting or changing VPN addresses.")
                } else if vpn.status == .connected {
                    Text("Saving addresses reconnects the local VPN.")
                }
            }
        }
        .navigationTitle("VPN addresses")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            interface = vpn.interfaceCIDR
            peer = vpn.peerCIDR
            allowIntermediate = vpn.allowIntermediate
        }
    }
}

private struct VPNLogView: View {
    @EnvironmentObject private var vpn: LocusVPN

    var body: some View {
        List {
            if vpn.logs.isEmpty {
                Text("No VPN events yet.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(vpn.logs.enumerated()), id: \.offset) { entry in
                    Text(verbatim: entry.element)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Connection log")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlacesView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss

    @State private var placeToRename: SavedPlace?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Favorites") {
                    if session.favorites.isEmpty {
                        Text("Star a pin from the map to save it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.favorites) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeFavorite(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                                Button {
                                    placeToRename = place
                                    renameText = place.name
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.gray)
                            }
                    }
                }

                Section("Recents") {
                    if session.recents.isEmpty {
                        Text("Teleports show up here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.recents) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeRecent(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                            }
                    }
                }
            }
            .navigationTitle("Places")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Favorite", isPresented: Binding(
                get: { placeToRename != nil },
                set: { if !$0 { placeToRename = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    placeToRename = nil
                }
                Button("Save") {
                    if let place = placeToRename {
                        session.renameFavorite(place, to: renameText)
                    }
                    placeToRename = nil
                }
            } message: {
                Text("Choose a name you’ll recognize later.")
            }
        }
    }

    private func placeButton(_ place: SavedPlace) -> some View {
        Button {
            session.teleport(to: place.coordinate, pairing: pairing)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).foregroundStyle(.primary)
                Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
