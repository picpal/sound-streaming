import Foundation
import Security

enum KeyStore {
    static let tag = "com.youtumu.watch.key".data(using: .utf8)!

    /// Secure Enclave P-256 키 (없으면 생성). SE 미지원 판명 시 kSecAttrTokenID 제거가 fallback (결과를 status.json note에 기록할 것)
    static func privateKey() throws -> SecKey {
        let q: [String: Any] = [kSecClass as String: kSecClassKey,
                                kSecAttrApplicationTag as String: tag,
                                kSecReturnRef as String: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess { return item as! SecKey }
        let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                     [.privateKeyUsage], nil)!
        var attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                                            kSecAttrApplicationTag as String: tag,
                                            kSecAttrAccessControl as String: access]]
        #if !targetEnvironment(simulator)
        attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave   // Simulator에는 SE 없음
        #endif
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw err!.takeRetainedValue() as Error
        }
        return key
    }

    /// 공개키를 SPKI PEM으로 (EC uncompressed point 앞에 P-256 SPKI 고정 헤더)
    static func publicKeyPEM() throws -> String {
        let pub = SecKeyCopyPublicKey(try privateKey())!
        var err: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(pub, &err) as Data? else {
            throw err!.takeRetainedValue() as Error
        }
        let spkiHeader: [UInt8] = [0x30,0x59,0x30,0x13,0x06,0x07,0x2A,0x86,0x48,0xCE,0x3D,
                                   0x02,0x01,0x06,0x08,0x2A,0x86,0x48,0xCE,0x3D,0x03,0x01,
                                   0x07,0x03,0x42,0x00]
        let der = Data(spkiHeader) + raw
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PUBLIC KEY-----\n\(b64)\n-----END PUBLIC KEY-----\n"
    }

    static func storeCertificate(der: Data) throws {
        let cert = SecCertificateCreateWithData(nil, der as CFData)!
        SecItemDelete([kSecClass as String: kSecClassCertificate,
                       kSecAttrLabel as String: "youtumu-client"] as CFDictionary)
        let add: [String: Any] = [kSecClass as String: kSecClassCertificate,
                                  kSecValueRef as String: cert,
                                  kSecAttrLabel as String: "youtumu-client"]
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess || st == errSecDuplicateItem else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(st))
        }
    }

    /// 저장된 cert + SE 키 → SecIdentity (Phase 0의 핵심 검증 지점)
    static func identity() -> SecIdentity? {
        let q: [String: Any] = [kSecClass as String: kSecClassIdentity,
                                kSecReturnRef as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecIdentity)
    }
}
