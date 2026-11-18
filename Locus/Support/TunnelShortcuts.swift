// Shortcut controls adapted from LocalDevVPN (SideStore Team, StosVPN License).
import AppIntents
import Foundation

enum LocusTunnelOperation: String, AppEnum {
    case enable
    case disable
    case toggle

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Operation")
    static let caseDisplayRepresentations: [LocusTunnelOperation: DisplayRepresentation] = [
        .enable: "Enable",
        .disable: "Disable",
        .toggle: "Toggle",
    ]
}

enum LocusIntermediateAddressPolicy: String, AppEnum {
    case appSetting
    case allow
    case disallow

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Intermediate Addresses")
    static let caseDisplayRepresentations: [LocusIntermediateAddressPolicy: DisplayRepresentation] = [
        .appSetting: "Use App Setting",
        .allow: "Allow",
        .disallow: "Disallow",
    ]
}

struct ControlLocusTunnelIntent: AppIntent {
    static let title: LocalizedStringResource = "Locus Tunnel"
    static let description = IntentDescription(
        "Enables, disables, or toggles Locus Tunnel. Optional IP addresses apply only to the new connection."
    )

    static let openAppWhenRun = false

    @Parameter(
        title: "Operation",
        description: "Choose whether to enable, disable, or toggle the VPN.",
        default: .enable
    )
    var operation: LocusTunnelOperation

    @Parameter(
        title: "Tunnel IP",
        description: "A temporary tunnel interface address in CIDR notation. Leave empty to use the in-app setting."
    )
    var tunnelIP: String?

    @Parameter(
        title: "Device IP",
        description: "A temporary peer address in CIDR notation. Leave empty to use the in-app setting."
    )
    var deviceIP: String?

    @Parameter(
        title: "Intermediate Addresses",
        description: "Choose whether temporary IP validation uses the in-app setting, allows intermediate addresses, or disallows them.",
        default: .appSetting
    )
    var intermediateAddressPolicy: LocusIntermediateAddressPolicy

    init() {}

    init(operation: LocusTunnelOperation) {
        self.operation = operation
    }

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$operation) Locus Tunnel") {
            \.$tunnelIP
            \.$deviceIP
            \.$intermediateAddressPolicy
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let vpn = LocusVPN.shared
        let policy: Bool?
        switch intermediateAddressPolicy {
        case .appSetting: policy = nil
        case .allow: policy = true
        case .disallow: policy = false
        }
        let overrides = LocusVPN.Overrides(interfaceCIDR: tunnelIP, peerCIDR: deviceIP, allowIntermediate: policy)
        switch operation {
        case .enable: try await vpn.connect(overrides: overrides)
        case .disable: try await vpn.disconnect()
        case .toggle: try await vpn.toggle(overrides: overrides)
        }
        return .result()
    }
}

struct LocusTunnelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ControlLocusTunnelIntent(operation: .enable),
            phrases: [
                "Start \(.applicationName) tunnel",
                "Connect \(.applicationName) tunnel",
                "Enable \(.applicationName) tunnel"
            ],
            shortTitle: "Enable VPN",
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: ControlLocusTunnelIntent(operation: .disable),
            phrases: [
                "Stop \(.applicationName) tunnel",
                "Disconnect \(.applicationName) tunnel",
                "Disable \(.applicationName) tunnel"
            ],
            shortTitle: "Disable VPN",
            systemImageName: "lock.shield.slash"
        )
        AppShortcut(
            intent: ControlLocusTunnelIntent(operation: .toggle),
            phrases: [
                "Toggle \(.applicationName) tunnel"
            ],
            shortTitle: "Toggle VPN",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
