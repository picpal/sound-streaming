import XCTest
@testable import MacAgentCore

final class SmokeTests: XCTestCase {
    func testModuleLinks() {
        _ = StreamServer(port: 0)   // 모듈 분리·링크 확인용
    }
}
