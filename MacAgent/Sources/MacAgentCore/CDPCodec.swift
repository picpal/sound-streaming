import Foundation

/// Chrome DevTools Protocol 메시지 직렬화. Runtime.evaluate만 사용한다 (spec §11 — 고정 스니펫 실행 전용).
enum CDPCodec {
    static func evaluateRequest(id: Int, expression: String, awaitPromise: Bool = false) -> Data {
        let msg: [String: Any] = [
            "id": id,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "returnByValue": true, "awaitPromise": awaitPromise],
        ]
        return try! JSONSerialization.data(withJSONObject: msg)   // 키·값 전부 JSON-호환 리터럴
    }

    /// 응답이면 (id, string value). 이벤트(id 없음)나 파싱 불가면 nil.
    static func decodeResponse(_ data: Data) -> (id: Int, value: String?)? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["id"] as? Int else { return nil }
        let inner = (o["result"] as? [String: Any])?["result"] as? [String: Any]
        return (id, inner?["value"] as? String)
    }
}
