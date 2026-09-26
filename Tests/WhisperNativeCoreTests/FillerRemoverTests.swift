import XCTest
@testable import WhisperNativeCore

final class FillerRemoverTests: XCTestCase {

    func testRemovesEnglishFillersAndRecapitalizesSentenceStart() {
        let raw = "Uh see if you agree. Every hour. Um Um Um does what I do, a lot of uh personal things"
        XCTAssertEqual(
            FillerRemover.removeFillers(from: raw, language: .auto),
            "See if you agree. Every hour. Does what I do, a lot of personal things"
        )
    }

    func testFillerCarryingSentenceEndMovesItToPreviousWord() {
        XCTAssertEqual(
            FillerRemover.removeFillers(from: "I think so uh. Next one", language: .english),
            "I think so. Next one"
        )
    }

    func testKeepsPortugueseArticleUm() {
        let raw = "E uma interface em que eu possa ver um gráfico, uh, do scroll"
        XCTAssertEqual(
            FillerRemover.removeFillers(from: raw, language: .auto),
            "E uma interface em que eu possa ver um gráfico, do scroll"
        )
        XCTAssertEqual(FillerRemover.removeFillers(from: "ver um gráfico", language: .portuguese), "ver um gráfico")
    }
}
