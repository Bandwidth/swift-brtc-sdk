import XCTest
@testable import BandwidthRTC

final class JsonRpcTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - JsonRpcRequest encoding

    func testEncodeJsonRpcRequest() throws {
        let request = JsonRpcRequest(id: "1", method: "testMethod", params: EmptyParams())
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["id"] as? String, "1")
        XCTAssertEqual(json["method"] as? String, "testMethod")
        XCTAssertNotNil(json["params"])
    }

    // MARK: - JsonRpcIncoming decoding

    func testDecodeJsonRpcResponse() throws {
        let json = """
        {"jsonrpc":"2.0","id":"42","result":{"foo":"bar"}}
        """.data(using: .utf8)!
        let incoming = try decoder.decode(JsonRpcIncoming.self, from: json)

        XCTAssertEqual(incoming.id, "42")
        XCTAssertNil(incoming.method)
        XCTAssertNotNil(incoming.result)
        XCTAssertTrue(incoming.isResponse)
        XCTAssertFalse(incoming.isNotification)
    }

    func testDecodeJsonRpcError() throws {
        let json = """
        {"jsonrpc":"2.0","id":"5","error":{"code":403,"message":"Forbidden"}}
        """.data(using: .utf8)!
        let incoming = try decoder.decode(JsonRpcIncoming.self, from: json)

        XCTAssertEqual(incoming.id, "5")
        XCTAssertEqual(incoming.error?.code, 403)
        XCTAssertEqual(incoming.error?.message, "Forbidden")
        XCTAssertTrue(incoming.isResponse)
    }

    func testDecodeJsonRpcNotification() throws {
        let json = """
        {"jsonrpc":"2.0","method":"sdpOffer","params":{"sdpOffer":"v=0..."}}
        """.data(using: .utf8)!
        let incoming = try decoder.decode(JsonRpcIncoming.self, from: json)

        XCTAssertNil(incoming.id)
        XCTAssertEqual(incoming.method, "sdpOffer")
        XCTAssertTrue(incoming.isNotification)
        XCTAssertFalse(incoming.isResponse)
    }

    func testIsResponseTrueWhenIdAndResultPresent() throws {
        let json = """
        {"jsonrpc":"2.0","id":"1","result":null}
        """.data(using: .utf8)!
        let incoming = try decoder.decode(JsonRpcIncoming.self, from: json)
        XCTAssertTrue(incoming.isResponse)
        XCTAssertFalse(incoming.isNotification)
    }

    func testIsResponseFalseForNotification() throws {
        let json = """
        {"jsonrpc":"2.0","method":"ready","params":{}}
        """.data(using: .utf8)!
        let incoming = try decoder.decode(JsonRpcIncoming.self, from: json)
        XCTAssertFalse(incoming.isResponse)
        XCTAssertTrue(incoming.isNotification)
    }

    // MARK: - OfferSdpParams encoding

    func testOfferSdpParamsEncoding() throws {
        let params = OfferSdpParams(sdpOffer: "v=0...", peerType: "publish")
        let data = try encoder.encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["sdpOffer"] as? String, "v=0...")
        XCTAssertEqual(json["peerType"] as? String, "publish")
    }

    // MARK: - AnswerSdpParams encoding

    func testAnswerSdpParamsEncoding() throws {
        let params = AnswerSdpParams(peerType: "subscribe", sdpAnswer: "v=0...answer")
        let data = try encoder.encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["sdpAnswer"] as? String, "v=0...answer")
        XCTAssertEqual(json["peerType"] as? String, "subscribe")
    }

    // MARK: - SetMediaPreferencesResult decoding

    func testSetMediaPreferencesResultDecoding() throws {
        let json = """
        {
          "endpointId": "ep-123",
          "deviceId": "dev-456",
          "publishSdpOffer": {"peerType":"publish","sdpOffer":"v=0...pub"},
          "subscribeSdpOffer": {"peerType":"subscribe","sdpOffer":"v=0...sub"}
        }
        """.data(using: .utf8)!
        let result = try decoder.decode(SetMediaPreferencesResult.self, from: json)

        XCTAssertEqual(result.endpointId, "ep-123")
        XCTAssertEqual(result.deviceId, "dev-456")
        XCTAssertEqual(result.publishSdpOffer?.sdpOffer, "v=0...pub")
        XCTAssertEqual(result.subscribeSdpOffer?.peerType, "subscribe")
    }

    // MARK: - SDPOfferNotification decoding

    func testSDPOfferNotificationDecoding() throws {
        let json = """
        {
          "sdpOffer": "v=0...",
          "peerType": "subscribe",
          "sdpRevision": 3,
          "endpointId": "ep-1",
          "streamSourceMetadata": {}
        }
        """.data(using: .utf8)!
        let notification = try decoder.decode(SDPOfferNotification.self, from: json)

        XCTAssertEqual(notification.sdpOffer, "v=0...")
        XCTAssertEqual(notification.peerType, "subscribe")
        XCTAssertEqual(notification.sdpRevision, 3)
        XCTAssertEqual(notification.endpointId, "ep-1")
        XCTAssertNotNil(notification.streamSourceMetadata)
    }

    // MARK: - HangupConnectionParams encoding

    func testHangupConnectionParamsEncoding() throws {
        let params = HangupConnectionParams(endpoint: "e164:+15551234567", type: .phoneNumber)
        let data = try encoder.encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["endpoint"] as? String, "e164:+15551234567")
        XCTAssertEqual(json["type"] as? String, "PHONE_NUMBER")
    }
}
