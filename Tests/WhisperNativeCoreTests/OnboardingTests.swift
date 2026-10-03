import XCTest
@testable import WhisperNativeCore

final class OnboardingTests: XCTestCase {
    func testStepsRunInOrderFromWelcomeToDone() {
        var visited: [OnboardingStep] = [.welcome]
        while let next = visited.last?.next { visited.append(next) }
        XCTAssertEqual(visited, OnboardingStep.allCases)
        XCTAssertEqual(visited.first, .welcome)
        XCTAssertEqual(visited.last, .done)
    }

    func testPreviousMirrorsNext() {
        for step in OnboardingStep.allCases {
            if let next = step.next { XCTAssertEqual(next.previous, step) }
        }
        XCTAssertNil(OnboardingStep.welcome.previous)
        XCTAssertTrue(OnboardingStep.done.isLast)
        XCTAssertFalse(OnboardingStep.welcome.isLast)
    }

    func testEveryStepHasATitle() {
        for step in OnboardingStep.allCases { XCTAssertFalse(step.title.isEmpty) }
    }

    func testConfigWithoutOnboardingKeyNeedsOnboarding() throws {
        let data = Data("{}".utf8)
        let config = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(config.onboardingCompletedVersion, 0)
        XCTAssertTrue(config.needsOnboarding)
    }

    func testCompletedVersionRoundTripsAndClearsNeed() throws {
        var config = Config()
        config.onboardingCompletedVersion = Onboarding.currentVersion
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.onboardingCompletedVersion, Onboarding.currentVersion)
        XCTAssertFalse(decoded.needsOnboarding)
    }

    func testParakeetStartsNotLoaded() async {
        let state = await ParakeetBackend.shared.loadState()
        XCTAssertEqual(state, .notLoaded)
    }
}
