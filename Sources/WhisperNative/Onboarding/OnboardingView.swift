import SwiftUI
import WhisperNativeCore

// MARK: - OnboardingNavigation

/// The current onboarding page, held outside SwiftUI `@State` so
/// `OnboardingWindowController.show()` can reset it to `.welcome` on every open.
@MainActor
final class OnboardingNavigation: ObservableObject {
    @Published var step: OnboardingStep = .welcome
}

// MARK: - OnboardingView

/// Container for the first-run onboarding flow: a step header with progress
/// dots, the current step's body (from `OnboardingSteps.swift`), and a
/// Back/Next/Skip/Finish bottom bar.
struct OnboardingView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var modelSectionState: ModelSectionState
    @ObservedObject var permissions: PermissionsState
    @ObservedObject var navigation: OnboardingNavigation
    let onFinish: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            stepBody
            Divider()
            bottomBar
        }
        .frame(minWidth: 620, minHeight: 560)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(navigation.step.title)
                .font(DesignSystem.Typography.emptyTitle)
            HStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Circle()
                        .fill(dotStyle(for: step))
                        .frame(width: 6, height: 6)
                        // Only already-visited steps (strictly before the current
                        // one) can be jumped back to; later steps stay inert
                        // until reached in order.
                        .onTapGesture {
                            guard step.rawValue < navigation.step.rawValue else { return }
                            withAnimation(DesignSystem.Motion.smooth) {
                                navigation.step = step
                            }
                        }
                }
            }
        }
        // Extra top padding clears the traffic lights: the window uses
        // .fullSizeContentView with a transparent title bar.
        .padding(.top, DesignSystem.Spacing.xl)
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.bottom, DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dotStyle(for step: OnboardingStep) -> AnyShapeStyle {
        step == navigation.step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)
    }

    // MARK: Body

    @ViewBuilder
    private var stepBody: some View {
        Group {
            switch navigation.step {
            case .welcome:
                WelcomeStepView()
            case .engineAndModel:
                EngineModelStepView(store: store, modelSectionState: modelSectionState)
            case .permissions:
                PermissionsStepView(permissions: permissions)
            case .hotkeys:
                HotkeysStepView(store: store)
            case .language:
                LanguageStepView(store: store)
            case .audioTags:
                AudioTagsStepView(store: store)
            case .done:
                DoneStepView(store: store)
            }
        }
        .id(navigation.step)
        .transition(.opacity)
        .animation(DesignSystem.Motion.smooth, value: navigation.step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            if !navigation.step.isLast {
                Button("Skip setup", action: onSkip)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if navigation.step != .welcome {
                Button("Back", action: goBack)
            }
            Button(primaryButtonTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(DesignSystem.Spacing.lg)
    }

    private var primaryButtonTitle: String {
        switch navigation.step {
        case .welcome: "Get Started"
        case .done: "Finish"
        default: "Continue"
        }
    }

    private func goBack() {
        guard let previous = navigation.step.previous else { return }
        withAnimation(DesignSystem.Motion.smooth) {
            navigation.step = previous
        }
    }

    private func primaryAction() {
        if navigation.step == .done {
            onFinish()
        } else if let next = navigation.step.next {
            withAnimation(DesignSystem.Motion.smooth) {
                navigation.step = next
            }
        }
    }
}
