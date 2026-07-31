import Crypto
import Foundation
import Security
import SwiftASN1
import X509

// Xcode 16's Security overlay omits this macOS 10.12 API even though the symbol is public.
@_silgen_name("SecIdentityCreate")
private func createSecIdentity(
    _ allocator: CFAllocator?,
    _ certificate: SecCertificate,
    _ privateKey: SecKey
) -> Unmanaged<SecIdentity>?

public enum NestedTLSIdentityFailure: Error, Equatable {
    case privateKeyConversionFailed
    case identityCreationFailed
}

public struct NestedTLSGenerationIdentity: @unchecked Sendable {
    public static let maximumLifetime: TimeInterval = 15 * 60

    public let certificateDER: Data
    public let spkiSHA256: String
    let securityIdentity: SecIdentity

    public static func generate(now: Date = Date()) throws -> NestedTLSGenerationIdentity {
        let swiftCryptoKey = P256.Signing.PrivateKey()
        let key = Certificate.PrivateKey(swiftCryptoKey)
        let name = try DistinguishedName {
            CommonName("agent-remote-device-generation")
        }
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-30),
            notValidAfter: now.addingTimeInterval(maximumLifetime),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: key
        )

        var certificateSerializer = DER.Serializer()
        try certificateSerializer.serialize(certificate)
        let certificateDER = Data(certificateSerializer.serializedBytes)
        var spkiSerializer = DER.Serializer()
        try spkiSerializer.serialize(key.publicKey)
        let spkiSHA256 = SHA256.hash(data: Data(spkiSerializer.serializedBytes))
            .map { String(format: "%02x", $0) }
            .joined()

        guard let secCertificate = SecCertificateCreateWithData(
            nil,
            certificateDER as CFData
        ) else {
            throw NestedTLSIdentityFailure.identityCreationFailed
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        var keyError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(
            swiftCryptoKey.x963Representation as CFData,
            attributes as CFDictionary,
            &keyError
        ) else {
            throw NestedTLSIdentityFailure.privateKeyConversionFailed
        }
        guard let securityIdentity = createSecIdentity(nil, secCertificate, secKey)?.takeRetainedValue()
        else {
            throw NestedTLSIdentityFailure.identityCreationFailed
        }
        return NestedTLSGenerationIdentity(
            certificateDER: certificateDER,
            spkiSHA256: spkiSHA256,
            securityIdentity: securityIdentity
        )
    }
}
