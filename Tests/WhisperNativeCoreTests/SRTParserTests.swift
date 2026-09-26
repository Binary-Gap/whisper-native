import XCTest
@testable import WhisperNativeCore

final class SRTParserTests: XCTestCase {

    func testParsesTimestampToSeconds() throws {
        XCTAssertEqual(try XCTUnwrap(SRTParser.parseTimestamp("00:00:07,850")), 7.85, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(SRTParser.parseTimestamp("01:02:03,004")), 3723.004, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(SRTParser.parseTimestamp("  00:00:00,000 ")), 0.0, accuracy: 0.0001)
    }

    func testRejectsMalformedTimestamp() {
        XCTAssertNil(SRTParser.parseTimestamp("00:00:07.850")) // period, not comma
        XCTAssertNil(SRTParser.parseTimestamp("7,850"))        // missing HMS
        XCTAssertNil(SRTParser.parseTimestamp("garbage"))
    }

    func testParsesBasicSRT() {
        let srt = """
        1
        00:00:00,000 --> 00:00:04,120
        Welcome to the local server.

        2
        00:00:04,120 --> 00:00:07,850
        It provides transcription.
        """
        let segments = SRTParser.parse(srt)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0.0, accuracy: 0.0001)
        XCTAssertEqual(segments[0].end, 4.12, accuracy: 0.0001)
        XCTAssertEqual(segments[0].text, "Welcome to the local server.")
        XCTAssertEqual(segments[1].start, 4.12, accuracy: 0.0001)
        XCTAssertEqual(segments[1].text, "It provides transcription.")
    }

    func testJoinsMultiLineBlockText() {
        let srt = """
        1
        00:00:00,000 --> 00:00:03,000
        First line
        second line
        """
        let segments = SRTParser.parse(srt)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "First line second line")
    }

    func testHandlesCRLFLineEndings() {
        let srt = "1\r\n00:00:00,000 --> 00:00:02,000\r\nHello\r\n\r\n2\r\n00:00:02,000 --> 00:00:04,000\r\nWorld"
        let segments = SRTParser.parse(srt)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Hello")
        XCTAssertEqual(segments[1].text, "World")
    }

    func testFullTextNewlineJoins() {
        let segments = [
            TranscriptionSegment(text: "One.", start: 0, end: 1),
            TranscriptionSegment(text: "Two.", start: 1, end: 2),
        ]
        XCTAssertEqual(SRTParser.fullText(from: segments), "One.\nTwo.")
    }

    func testEmptyInputYieldsNoSegments() {
        XCTAssertTrue(SRTParser.parse("").isEmpty)
        XCTAssertTrue(SRTParser.parse("\n\n").isEmpty)
    }
}
