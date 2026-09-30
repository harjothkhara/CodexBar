import Foundation

public enum BAIProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .bai,
        displayName: "B.AI",
        sessionLabel: "Member quota",
        weeklyLabel: "Weekly",
        dashboardURL: "https://b.ai",
        color: .init(hex: 0xC26B35),
        confetti: [0xC26B35, 0xF2BE91],
        noDataMessage: "B.AI cost history is not available.",
        environmentKey: "BAI_API_KEY",
        missingCredentialMessage: { _ in "Set a B.AI API key in Settings or BAI_API_KEY." },
        menuBarMetrics: .init(supported: [.automatic, .primary]),
        apiKeyField: .init(
            id: "bai-api-key",
            title: "B.AI API key",
            subtitle: "Saved in CodexBar's local config file. Or set BAI_API_KEY. Reports Credits."))
}
