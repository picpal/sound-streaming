import XCTest
@testable import MacAgentCore

final class CDPCodecTests: XCTestCase {
    func testEvaluateRequestShape() throws {
        let d = CDPCodec.evaluateRequest(id: 7, expression: "1+1")
        let o = try JSONSerialization.jsonObject(with: d) as! [String: Any]
        XCTAssertEqual(o["id"] as? Int, 7)
        XCTAssertEqual(o["method"] as? String, "Runtime.evaluate")
        let p = o["params"] as! [String: Any]
        XCTAssertEqual(p["expression"] as? String, "1+1")
        XCTAssertEqual(p["returnByValue"] as? Bool, true)
    }
    func testDecodeStringResult() {
        let json = #"{"id":7,"result":{"result":{"type":"string","value":"hi"}}}"#
        let r = CDPCodec.decodeResponse(Data(json.utf8))
        XCTAssertEqual(r?.id, 7)
        XCTAssertEqual(r?.value, "hi")
    }
    func testDecodeUndefinedResultHasNilValue() {
        let json = #"{"id":3,"result":{"result":{"type":"undefined"}}}"#
        let r = CDPCodec.decodeResponse(Data(json.utf8))
        XCTAssertEqual(r?.id, 3)
        XCTAssertNil(r?.value)
    }
    func testDecodeEventWithoutIdReturnsNil() {
        let json = #"{"method":"Runtime.consoleAPICalled","params":{}}"#
        XCTAssertNil(CDPCodec.decodeResponse(Data(json.utf8)))
    }
}
