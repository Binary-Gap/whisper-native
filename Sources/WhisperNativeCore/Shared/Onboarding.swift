import Foundation

public enum Onboarding {
    /// Bump when the onboarding gains content every existing user should see.
    public static let currentVersion = 1
}

/// One page of the first-run onboarding flow, in display order.
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case engineAndModel
    case permissions
    case hotkeys
    case language
    case audioTags
    case done

    public var title: String {
        switch self {
        case .welcome: "Welcome"
        case .engineAndModel: "Engine & Model"
        case .permissions: "Permissions"
        case .hotkeys: "Hotkeys"
        case .language: "Language"
        case .audioTags: "Audio Tags"
        case .done: "All Set"
        }
    }

    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    public var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
    public var isLast: Bool { next == nil }
}
