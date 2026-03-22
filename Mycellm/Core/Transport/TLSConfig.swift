import Foundation
import Network
import Security

/// Self-signed TLS certificate generation for QUIC transport.
enum TLSConfig {
    /// Create NWProtocolTLS.Options with a self-signed certificate.
    /// Identity verification happens at the application layer via NodeHello.
    static func makeOptions() throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()

        // Generate a self-signed identity for QUIC transport
        // The actual peer identity is verified via NodeHello after connection
        if let identity = try? generateSelfSignedIdentity() {
            sec_protocol_options_set_local_identity(
                options.securityProtocolOptions,
                identity
            )
        }

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
    private static func generateSelfSignedIdentity() throws -> sec_identity_t? {
        // TODO: Phase 4 — generate PKCS#12 with self-signed cert
        // For now, this is a stub. Network.framework needs a SecIdentity
        // which requires creating a certificate + private key pair in the Keychain.
        return nil
    }
}
