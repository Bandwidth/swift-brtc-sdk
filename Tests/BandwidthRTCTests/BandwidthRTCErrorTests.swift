import XCTest
@testable import BandwidthRTC

final class BandwidthRTCErrorTests: XCTestCase {

    func testAllCasesHaveLocalizedDescription() {
        let cases: [BandwidthRTCError] = [
            .invalidToken,
            .connectionFailed("detail"),
            .signalingError("detail"),
            .webSocketDisconnected,
            .sdpNegotiationFailed("detail"),
            .mediaAccessDenied,
            .alreadyConnected,
            .notConnected,
            .publishFailed("detail"),
            .rpcError(code: 400, message: "Bad request"),
        ]

        for error in cases {
            let desc = error.errorDescription
            XCTAssertNotNil(desc, "Missing errorDescription for \(error)")
            XCTAssertFalse(desc!.isEmpty, "Empty errorDescription for \(error)")
        }
    }

    func testInvalidTokenDescription() {
        let desc = BandwidthRTCError.invalidToken.errorDescription ?? ""
        XCTAssertTrue(
            desc.lowercased().contains("invalid") || desc.lowercased().contains("token"),
            "Expected 'invalid' or 'token' in: \(desc)"
        )
    }

    func testConnectionFailedIncludesDetail() {
        let desc = BandwidthRTCError.connectionFailed("timeout").errorDescription ?? ""
        XCTAssertTrue(desc.contains("timeout"), "Expected 'timeout' in: \(desc)")
    }

    func testRpcErrorIncludesCodeAndMessage() {
        let desc = BandwidthRTCError.rpcError(code: 403, message: "Forbidden").errorDescription ?? ""
        XCTAssertTrue(desc.contains("403"), "Expected '403' in: \(desc)")
        XCTAssertTrue(desc.contains("Forbidden"), "Expected 'Forbidden' in: \(desc)")
    }

    func testSdpNegotiationFailedIncludesDetail() {
        let detail = "ice-failure"
        let desc = BandwidthRTCError.sdpNegotiationFailed(detail).errorDescription ?? ""
        XCTAssertTrue(desc.contains(detail), "Expected '\(detail)' in: \(desc)")
    }

    func testPublishFailedIncludesDetail() {
        let detail = "no-peer-connection"
        let desc = BandwidthRTCError.publishFailed(detail).errorDescription ?? ""
        XCTAssertTrue(desc.contains(detail), "Expected '\(detail)' in: \(desc)")
    }
}
