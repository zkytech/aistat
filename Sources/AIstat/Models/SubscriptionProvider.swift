import AppKit
import Foundation
import SwiftUI

/// Supported CLIProxy subscription providers shown in the account list.
enum SubscriptionProvider: String, CaseIterable, Sendable, Equatable {
    case openai
    case claude
    case grok

    /// Map CLIProxy `provider` field to a supported subscription type.
    static func resolve(from raw: String) -> SubscriptionProvider? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai", "codex":
            return .openai
        case "claude", "anthropic":
            return .claude
        case "xai", "grok":
            return .grok
        default:
            return nil
        }
    }

    static let supportedRawProviders: Set<String> = [
        "openai", "codex", "claude", "anthropic", "xai", "grok"
    ]

    static func isSupported(_ raw: String) -> Bool {
        resolve(from: raw) != nil
    }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .claude: return "Claude"
        case .grok: return "Grok"
        }
    }

    /// Resource name under `Resources/ProviderIcon-*.png`.
    var iconResourceName: String {
        "ProviderIcon-\(rawValue)"
    }

    var accessibilityLabel: String {
        "订阅类型 \(displayName)"
    }
}

struct ProviderIconView: View {
    let provider: SubscriptionProvider
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let image = Self.loadTemplateImage(named: provider.iconResourceName, pointSize: size) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.template)
            } else {
                Image(systemName: fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(.primary.opacity(0.85))
        .accessibilityLabel(provider.accessibilityLabel)
    }

    private var fallbackSystemImage: String {
        switch provider {
        case .openai: return "circle.hexagongrid.fill"
        case .claude: return "sparkles"
        case .grok: return "bolt.fill"
        }
    }

    private static func loadTemplateImage(named name: String, pointSize: CGFloat) -> NSImage? {
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }
}
