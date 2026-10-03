import XCTest
@testable import WhisperNativeCore

final class GeminiPricingTests: XCTestCase {
    func testLocalModelsAreFree() {
        XCTAssertNil(GeminiPricing.estimatedDollars(modelName: "ggml-large-v3-turbo.bin", audioSeconds: 60, text: "hi"))
    }

    func testUnknownAudioLengthHasNoEstimate() {
        XCTAssertNil(GeminiPricing.estimatedDollars(modelName: GeminiLiveSession.modelID, audioSeconds: nil, text: "hi"))
    }

    func testLiveMinuteMatchesListPrice() throws {
        // 1500 audio tokens in + 175 text tokens out, the docs' per-minute estimate.
        let text = String(repeating: "a", count: 700)
        let dollars = try XCTUnwrap(
            GeminiPricing.estimatedDollars(modelName: GeminiLiveSession.modelID, audioSeconds: 60, text: text)
        )
        XCTAssertEqual(dollars, (1500 * 3.50 + 175 * 21.00) / 1_000_000, accuracy: 1e-9)
    }

    func testBatchUsesBatchRates() throws {
        let dollars = try XCTUnwrap(
            GeminiPricing.estimatedDollars(modelName: GeminiBackend.modelID, audioSeconds: 60, text: "")
        )
        XCTAssertEqual(dollars, 1500 * 2.00 / 1_000_000, accuracy: 1e-9)
    }
}
