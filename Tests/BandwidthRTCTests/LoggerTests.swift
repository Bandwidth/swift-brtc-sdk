import XCTest
@testable import BandwidthRTC

final class LoggerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset to a known state before each test
        Logger.shared.level = .warn
    }

    func testLevelOffSuppressesAll() {
        Logger.shared.level = .off
        // Calling these must not crash and must be suppressed
        Logger.shared.error("error message")
        Logger.shared.warn("warn message")
        Logger.shared.info("info message")
        Logger.shared.debug("debug message")
        // No assertion beyond "no crash" — level is checked internally
        XCTAssertEqual(Logger.shared.level, .off)
    }

    func testErrorLevelOnlyShowsError() {
        Logger.shared.level = .error
        XCTAssertTrue(Logger.shared.level >= .error)
        XCTAssertFalse(Logger.shared.level >= .warn)
        XCTAssertFalse(Logger.shared.level >= .info)
        XCTAssertFalse(Logger.shared.level >= .debug)
    }

    func testWarnLevelShowsWarnAndError() {
        Logger.shared.level = .warn
        XCTAssertTrue(Logger.shared.level >= .error)
        XCTAssertTrue(Logger.shared.level >= .warn)
        XCTAssertFalse(Logger.shared.level >= .info)
        XCTAssertFalse(Logger.shared.level >= .debug)
    }

    func testInfoLevelShowsInfoAndAbove() {
        Logger.shared.level = .info
        XCTAssertTrue(Logger.shared.level >= .error)
        XCTAssertTrue(Logger.shared.level >= .warn)
        XCTAssertTrue(Logger.shared.level >= .info)
        XCTAssertFalse(Logger.shared.level >= .debug)
    }

    func testDebugLevelShowsAll() {
        Logger.shared.level = .debug
        XCTAssertTrue(Logger.shared.level >= .error)
        XCTAssertTrue(Logger.shared.level >= .warn)
        XCTAssertTrue(Logger.shared.level >= .info)
        XCTAssertTrue(Logger.shared.level >= .debug)
    }

    func testSetLevelOnShared() {
        Logger.shared.level = .debug
        XCTAssertEqual(Logger.shared.level, .debug)
        Logger.shared.level = .error
        XCTAssertEqual(Logger.shared.level, .error)
    }

    func testLogLevelComparable() {
        XCTAssertTrue(LogLevel.debug > .info)
        XCTAssertTrue(LogLevel.info > .warn)
        XCTAssertTrue(LogLevel.warn > .error)
        XCTAssertTrue(LogLevel.error > .off)
        XCTAssertFalse(LogLevel.off > .error)
        XCTAssertEqual(LogLevel.info, .info)
    }
}
