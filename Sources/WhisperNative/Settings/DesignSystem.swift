import SwiftUI

/// Shared visual language for the Settings and History windows: a small,
/// deliberate type scale, a consistent spacing rhythm, and corner-radius
/// tokens. Both windows reference these so they read as one refined-native app.
enum DesignSystem {

    // MARK: - Type scale

    /// Named fonts used across both windows. Rounded is used where warmth helps
    /// (titles, empty states); monospaced/rounded for compact metadata.
    enum Typography {
        /// Section / group headers.
        static let sectionTitle = Font.headline.weight(.semibold)
        /// Primary row label.
        static let rowTitle = Font.body
        /// Secondary explanatory line under a row.
        static let rowSubtitle = Font.caption
        /// Compact metadata chips (model / language / duration).
        static let metadata = Font.caption2.monospacedDigit()
        /// Empty-state headline.
        static let emptyTitle = Font.title3.weight(.semibold)
        /// Window header / toolbar title.
        static let windowTitle = Font.headline.weight(.semibold)
    }

    // MARK: - Spacing

    /// Vertical / horizontal rhythm. Linear-tight, aligned to one grid.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: - Corner radii

    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 12
    }

    // MARK: - Motion

    /// Standard motion curves. SwiftUI honors Reduce Motion for these transitions.
    enum Motion {
        static let smooth = Animation.smooth(duration: 0.28)
        static let snappy = Animation.snappy(duration: 0.22)
    }
}

// MARK: - Metadata chip

/// A subtle pill used for compact metadata (language / model / duration) and
/// section accents. Reads as a quiet, native capsule, not a colored badge.
struct MetadataChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    init(_ text: String, systemImage: String? = nil, tint: Color = .secondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(DesignSystem.Typography.metadata)
        .foregroundStyle(tint)
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(.quaternary.opacity(0.6))
        )
    }
}
