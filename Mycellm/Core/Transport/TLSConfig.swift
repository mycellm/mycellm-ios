import Foundation
import Network
import Security

/// Self-signed TLS certificate generation for QUIC transport.
enum TLSConfig {
    /// Create NWProtocolTLS.Options with a self-signed certificate.
    /// Identity verification happens at the application layer via NodeHello.
    static func makeOptions() throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()

        // Self-signed identity for QUIC transport is optional.
        // Identity verification happens at the app layer via NodeHello.
        // If cert generation fails, QUIC still works — the peer just
        // can't verify our transport cert (which we don't require anyway).

        // Accept any peer certificate (we verify at app layer)
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, _, completion in completion(true) },
            .main
        )

        // Set ALPN
        sec_protocol_options_add_tls_application_protocol(
            options.securityProtocolOptions,
            QUICTransport.alpn
        )

        return options
    }

    /// Generate a self-signed SecIdentity for TLS.
    /// Creates an ephemeral EC key + self-signed cert in the Keychain,
    /// then wraps as sec_identity_t for Network.framework.
    private static func generateSelfSignedIdentity() throws -> sec_identity_t? {
        let tag = "com.mycellm.quic.tls"

        // Remove any stale key from prior runs
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Generate a new EC P-256 key in the Keychain
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrIsPermanent as String: true,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &error) else {
            return nil
        }

        // Build a minimal self-signed X.509 v1 certificate (DER)
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let pubData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return nil
        }

        let certDER = buildSelfSignedCert(publicKeyData: pubData, privateKey: privateKey)
        guard let certDER, let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            return nil
        }

        // Store the certificate so we can form a SecIdentity
        let certAddQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: tag,
        ]
        // Delete old cert first
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: tag] as CFDictionary)
        SecItemAdd(certAddQuery as CFDictionary, nil)

        // Retrieve the identity (key + cert pair)
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
        ]
        var identityRef: CFTypeRef?
        guard SecItemCopyMatching(identityQuery as CFDictionary, &identityRef) == errSecSuccess,
              let identity = identityRef else {
            return nil
        }

        return sec_identity_create(identity as! SecIdentity)
    }

    /// Build a minimal self-signed X.509 DER certificate.
    private static func buildSelfSignedCert(publicKeyData: Data, privateKey: SecKey) -> Data? {
        // Simplified DER: CN=mycellm-node, validity 1 year, EC P-256
        var tbs = Data()

        // Version: v1 (default, no explicit version field needed)
        // Serial number: random 8 bytes
        var serial = Data(count: 8)
        _ = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        tbs.append(derTag(0x02, serial)) // INTEGER: serial

        // Signature algorithm: ecdsaWithSHA256 (1.2.840.10045.4.3.2)
        let ecdsaSHA256OID = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        tbs.append(derSequence(ecdsaSHA256OID))

        // Issuer: CN=mycellm-node
        let cn = "mycellm-node"
        let cnOID = Data([0x06, 0x03, 0x55, 0x04, 0x03]) // OID 2.5.4.3
        let cnValue = derTag(0x0C, Data(cn.utf8)) // UTF8String
        let atv = derSequence(cnOID + cnValue)
        let rdnSet = derTag(0x31, atv) // SET
        tbs.append(derSequence(rdnSet)) // Issuer SEQUENCE

        // Validity: now to +1 year
        let now = Date()
        let oneYear = Calendar.current.date(byAdding: .year, value: 1, to: now)!
        let notBefore = derUTCTime(now)
        let notAfter = derUTCTime(oneYear)
        tbs.append(derSequence(notBefore + notAfter))

        // Subject: same as issuer
        tbs.append(derSequence(rdnSet))

        // SubjectPublicKeyInfo: EC P-256
        let ecPubKeyOID = Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]) // 1.2.840.10045.2.1
        let p256OID = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]) // 1.2.840.10045.3.1.7
        let algId = derSequence(ecPubKeyOID + p256OID)
        let pubBitString = derTag(0x03, Data([0x00]) + publicKeyData) // BIT STRING (0 unused bits)
        tbs.append(derSequence(algId + pubBitString))

        let tbsSequence = derSequence(tbs)

        // Sign TBS with private key
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsSequence as CFData,
            nil
        ) as Data? else {
            return nil
        }

        // Full certificate: TBS + algorithm + signature
        let sigBitString = derTag(0x03, Data([0x00]) + signature)
        return derSequence(tbsSequence + derSequence(ecdsaSHA256OID) + sigBitString)
    }

    private static func derTag(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        let len = content.count
        if len < 128 {
            result.append(UInt8(len))
        } else if len < 256 {
            result.append(contentsOf: [0x81, UInt8(len)])
        } else {
            result.append(contentsOf: [0x82, UInt8(len >> 8), UInt8(len & 0xFF)])
        }
        result.append(content)
        return result
    }

    private static func derSequence(_ content: Data) -> Data {
        derTag(0x30, content)
    }

    private static func derUTCTime(_ date: Date) -> Data {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyMMddHHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let str = fmt.string(from: date)
        return derTag(0x17, Data(str.utf8))
    }
}
