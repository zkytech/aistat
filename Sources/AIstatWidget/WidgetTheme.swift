import AppKit
import SwiftUI
import AIstatShared

/// Design tokens for desktop widgets.
/// Inspired by ui-ux-pro-max: Micro SaaS indigo + status-page greens/ambers/reds,
/// glass-friendly surfaces (system widget chrome provides blur), 8pt rhythm,
/// monospaced digits for dense KPI readability. Color is never the sole indicator.
enum WidgetTheme {
    // MARK: - Brand / status (WCAG-minded on light & dark widget materials)

    /// Micro SaaS indigo — primary healthy remaining bar / accent.
    static let accent = Color(red: 0.39, green: 0.40, blue: 0.95) // #6366F1
    /// Operational green for status "active".
    static let statusOK = Color(red: 0.09, green: 0.64, blue: 0.29) // #16A34A
    /// Warning amber when remaining ≤ 20%.
    static let statusWarn = Color(red: 0.96, green: 0.62, blue: 0.04) // #F59E0B
    /// Critical / exhausted / error.
    static let statusCritical = Color(red: 0.94, green: 0.27, blue: 0.27) // #EF4444
    /// Neutral disabled / unknown.
    static let statusMuted = Color.secondary

    static let trackFill = Color.primary.opacity(0.10)
    static let cardFill = Color.primary.opacity(0.04)
    static let dividerOpacity = 0.35

    // MARK: - Spacing (4/8pt rhythm)

    static let spaceXS: CGFloat = 4
    static let spaceSM: CGFloat = 8
    static let spaceMD: CGFloat = 12
    static let spaceLG: CGFloat = 16

    static let radiusSM: CGFloat = 6
    static let radiusMD: CGFloat = 10
    static let progressHeight: CGFloat = 5
    static let progressHeightLarge: CGFloat = 8

    // MARK: - Type scale (SF Pro — native; mono digits for KPIs)

    static func titleFont() -> Font {
        .system(size: 12, weight: .semibold)
    }

    static func labelFont() -> Font {
        .system(size: 11, weight: .medium)
    }

    static func captionFont() -> Font {
        .system(size: 10, weight: .regular)
    }

    static func kpiFont(size: CGFloat = 28) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    static func monoCaption() -> Font {
        .system(size: 11, weight: .semibold).monospacedDigit()
    }

    static func monoSmall() -> Font {
        .system(size: 10, weight: .medium).monospacedDigit()
    }

    // MARK: - Semantic colors

    static func remainingColor(for remaining: Double?) -> Color {
        switch WidgetRemainingStyle.band(for: remaining) {
        case .critical: return statusCritical
        case .warning: return statusWarn
        case .healthy: return accent
        case .unknown: return statusMuted
        }
    }

    static func remainingTextColor(for remaining: Double?) -> Color {
        switch WidgetRemainingStyle.band(for: remaining) {
        case .critical: return statusCritical
        case .warning: return statusWarn
        case .healthy: return .primary
        case .unknown: return statusMuted
        }
    }

    static func statusColor(for status: String) -> Color {
        switch status {
        case "disabled":
            return statusMuted
        case "exhausted", "unavailable", "error":
            return statusCritical
        case "active":
            return statusOK
        default:
            return statusOK
        }
    }

    static func statusSymbol(for status: String) -> String {
        switch status {
        case "disabled":
            return "minus.circle.fill"
        case "error":
            return "exclamationmark.triangle.fill"
        case "exhausted":
            return "xmark.circle.fill"
        case "unavailable":
            return "slash.circle.fill"
        default:
            return "circle.fill"
        }
    }

    static func remainingText(_ remaining: Double?) -> String {
        guard let remaining else { return "--" }
        return String(format: "%.0f%%", remaining)
    }
}

// MARK: - Shared chrome pieces

struct WidgetProgressBar: View {
    let fraction: Double
    var tint: Color
    var height: CGFloat = WidgetTheme.progressHeight

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(WidgetTheme.trackFill)
                Capsule()
                    .fill(tint)
                    .frame(width: max(geo.size.width * CGFloat(min(max(fraction, 0), 1)), fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct WidgetStatusDot: View {
    let status: String

    var body: some View {
        Image(systemName: WidgetTheme.statusSymbol(for: status))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(WidgetTheme.statusColor(for: status))
            .frame(width: 12, height: 12)
            .accessibilityLabel("状态 \(status)")
    }
}

/// Brand glyph matching the menu-bar panel (`ProviderIcon-*.png`, template tint).
struct WidgetProviderGlyph: View {
    let kind: WidgetProviderKind
    var size: CGFloat = 12

    var body: some View {
        Group {
            if let name = kind.iconResourceName,
               let image = Self.loadTemplateImage(named: name, pointSize: size) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.template)
            } else {
                Image(systemName: kind.systemImage)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(.primary.opacity(0.85))
        .accessibilityLabel(kind.displayName)
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

/// Circular remaining gauge — same language as iOS Battery / Activity rings.
struct WidgetRingGauge: View {
    /// Remaining quota 0…100; nil / error renders empty track + placeholder center.
    let remaining: Double?
    var hasError: Bool = false
    var size: CGFloat = 64
    var lineWidth: CGFloat = 7
    var centerFontSize: CGFloat = 15

    private var fraction: Double {
        if hasError { return 0 }
        guard let remaining else { return 0 }
        return min(max(remaining / 100, 0), 1)
    }

    private var tint: Color {
        if hasError { return WidgetTheme.statusCritical }
        return WidgetTheme.remainingColor(for: remaining)
    }

    private var centerText: String {
        if hasError { return "!!" }
        return WidgetTheme.remainingText(remaining)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(WidgetTheme.trackFill, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            Circle()
                .trim(from: 0, to: CGFloat(fraction))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Text(centerText)
                .font(WidgetTheme.kpiFont(size: centerFontSize))
                .foregroundStyle(
                    hasError
                        ? WidgetTheme.statusCritical
                        : WidgetTheme.remainingTextColor(for: remaining)
                )
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
