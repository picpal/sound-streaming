import Foundation
import Security

final class PinnedSessionDelegate: NSObject, URLSessionDelegate {
    static let caCert: SecCertificate = {
        let url = Bundle.main.url(forResource: "ca", withExtension: "crt")!
        let pem = try! String(contentsOf: url)
        let b64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return SecCertificateCreateWithData(nil, Data(base64Encoded: b64)! as CFData)!
    }()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            let trust = challenge.protectionSpace.serverTrust!
            SecTrustSetAnchorCertificates(trust, [Self.caCert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)          // 시스템 CA 무시
            var err: CFError?
            if SecTrustEvaluateWithError(trust, &err) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        case NSURLAuthenticationMethodClientCertificate:
            if let id = KeyStore.identity() {
                completionHandler(.useCredential, URLCredential(identity: id, certificates: nil, persistence: .forSession))
            } else { completionHandler(.performDefaultHandling, nil) }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum EnrollClient {
    /// macAddr 예: "192.168.0.10" — Caddy :8444
    static func enroll(macAddr: String, code: String) async throws -> Bool {
        let session = URLSession(configuration: .default, delegate: PinnedSessionDelegate(), delegateQueue: nil)
        var req = URLRequest(url: URL(string: "https://\(macAddr):8444/enroll")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["code": code, "pubkeyPem": KeyStore.publicKeyPEM()])
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONDecoder().decode([String: String].self, from: data),
              let der = Data(base64Encoded: obj["certDer"] ?? "") else { return false }
        try KeyStore.storeCertificate(der: der)
        return KeyStore.identity() != nil
    }
}
