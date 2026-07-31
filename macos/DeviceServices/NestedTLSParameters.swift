import Crypto
import DeviceProtocol
import Foundation
import Network
import Security
import SwiftASN1
import X509

public enum NestedTLSParametersFailure: Error, Equatable {
    case invalidGeneration
    case invalidHexMaterial
    case identityConversionFailed
    case exporterUnavailable
    case exporterConfirmationFailed
}

public enum NestedTLSRole: UInt8, Equatable, Sendable {
    case device = 1
    case proxy = 2

    public var peer: NestedTLSRole {
        switch self {
        case .device: .proxy
        case .proxy: .device
        }
    }
}

public struct NestedTLSGenerationMaterial: Equatable, Sendable {
    public static let byteCount = 32

    public let generation: UInt64
    public let expectedPeerSPKISHA256: Data
    public let exporterContext: Data

    public init(
        generation: UInt64,
        expectedPeerSPKISHA256Hex: String,
        exporterContextHex: String
    ) throws {
        guard (1 ... maximumActiveDeviceSessionGeneration).contains(generation) else {
            throw NestedTLSParametersFailure.invalidGeneration
        }
        self.generation = generation
        expectedPeerSPKISHA256 = try Self.decodeHex(expectedPeerSPKISHA256Hex)
        exporterContext = try Self.decodeHex(exporterContextHex)
    }

    private static func decodeHex(_ value: String) throws -> Data {
        let bytes = Array(value.utf8)
        guard bytes.count == byteCount * 2,
              bytes.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 102).contains($0)
              })
        else {
            throw NestedTLSParametersFailure.invalidHexMaterial
        }
        var decoded = Data(capacity: byteCount)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                throw NestedTLSParametersFailure.invalidHexMaterial
            }
            decoded.append(high << 4 | low)
        }
        return decoded
    }

    private static func nibble(_ value: UInt8) -> UInt8? {
        switch value {
        case 48 ... 57: value - 48
        case 97 ... 102: value - 87
        default: nil
        }
    }
}

public enum NestedTLSParameters {
    public static let exporterLabel = "EXPORTER-agent-remote-device-v1"
    public static let exporterOutputBytes = 32
    public static let confirmationRecordBytes = 34

    private static let confirmationLabel = "agent-remote-device-exporter-confirm-v1"
    private static let confirmationVersion: UInt8 = 1

    public static func make(
        identity: NestedTLSGenerationIdentity,
        material: NestedTLSGenerationMaterial,
        verificationQueue: DispatchQueue
    ) throws -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let options = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(options, true)
        guard let localIdentity = sec_identity_create(identity.securityIdentity) else {
            throw NestedTLSParametersFailure.identityConversionFailed
        }
        sec_protocol_options_set_local_identity(options, localIdentity)
        let expectedPin = material.expectedPeerSPKISHA256
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let trustReference = sec_trust_copy_ref(trust).takeRetainedValue()
            let chain = (SecTrustCopyCertificateChain(trustReference) as? [SecCertificate]) ?? []
            let certificateData = chain.map { SecCertificateCopyData($0) as Data }
            complete(peerCertificateMatches(
                certificateChainDER: certificateData,
                expectedSPKISHA256: expectedPin,
                now: Date()
            ))
        }, verificationQueue)
        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }

    public static func peerCertificateMatches(
        certificateChainDER: [Data],
        expectedSPKISHA256: Data,
        now: Date
    ) -> Bool {
        guard certificateChainDER.count == 1,
              expectedSPKISHA256.count == NestedTLSGenerationMaterial.byteCount,
              let certificateData = certificateChainDER.first,
              let certificate = try? Certificate(derEncoded: Array(certificateData)),
              certificate.notValidBefore <= now,
              certificate.notValidAfter >= now
        else {
            return false
        }
        var serializer = DER.Serializer()
        guard (try? serializer.serialize(certificate.publicKey)) != nil else { return false }
        return Data(SHA256.hash(data: Data(serializer.serializedBytes))) == expectedSPKISHA256
    }

    public static func exporterBinding(
        metadata: sec_protocol_metadata_t,
        material: NestedTLSGenerationMaterial
    ) throws -> Data {
        let label = Array(exporterLabel.utf8)
        let secret: dispatch_data_t? = label.withUnsafeBytes { labelBytes in
            material.exporterContext.withUnsafeBytes { contextBytes in
                guard let labelAddress = labelBytes.baseAddress,
                      let contextAddress = contextBytes.baseAddress
                else {
                    return nil
                }
                return sec_protocol_metadata_create_secret_with_context(
                    metadata,
                    labelBytes.count,
                    labelAddress.assumingMemoryBound(to: CChar.self),
                    contextBytes.count,
                    contextAddress.assumingMemoryBound(to: UInt8.self),
                    exporterOutputBytes
                )
            }
        }
        guard let secret else { throw NestedTLSParametersFailure.exporterUnavailable }
        let dispatchData = secret as DispatchData
        let result = dispatchData.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) in
            Data(bytes: bytes, count: dispatchData.count)
        }
        guard result.count == exporterOutputBytes else {
            throw NestedTLSParametersFailure.exporterUnavailable
        }
        return result
    }

    public static func confirmationRecord(
        exporterBinding: Data,
        role: NestedTLSRole,
        generation: UInt64,
        deviceSessionID: UUID
    ) throws -> Data {
        guard exporterBinding.count == exporterOutputBytes else {
            throw NestedTLSParametersFailure.exporterConfirmationFailed
        }
        let transcript = confirmationTranscript(
            role: role,
            generation: generation,
            deviceSessionID: deviceSessionID
        )
        let key = SymmetricKey(data: exporterBinding)
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: transcript,
            using: key
        )
        var record = Data([confirmationVersion, role.rawValue])
        record.append(contentsOf: authenticationCode)
        return record
    }

    public static func verifyPeerConfirmation(
        _ record: Data,
        exporterBinding: Data,
        localRole: NestedTLSRole,
        generation: UInt64,
        deviceSessionID: UUID
    ) throws {
        let peerRole = localRole.peer
        guard record.count == confirmationRecordBytes,
              record[record.startIndex] == confirmationVersion,
              record[record.startIndex + 1] == peerRole.rawValue,
              exporterBinding.count == exporterOutputBytes
        else {
            throw NestedTLSParametersFailure.exporterConfirmationFailed
        }
        let transcript = confirmationTranscript(
            role: peerRole,
            generation: generation,
            deviceSessionID: deviceSessionID
        )
        let authenticationCode = record.dropFirst(2)
        guard HMAC<SHA256>.isValidAuthenticationCode(
            authenticationCode,
            authenticating: transcript,
            using: SymmetricKey(data: exporterBinding)
        ) else {
            throw NestedTLSParametersFailure.exporterConfirmationFailed
        }
    }

    private static func confirmationTranscript(
        role: NestedTLSRole,
        generation: UInt64,
        deviceSessionID: UUID
    ) -> Data {
        var transcript = Data(confirmationLabel.utf8)
        transcript.append(0)
        transcript.append(confirmationVersion)
        transcript.append(role.rawValue)
        var networkGeneration = generation.bigEndian
        withUnsafeBytes(of: &networkGeneration) { transcript.append(contentsOf: $0) }
        var uuid = deviceSessionID.uuid
        withUnsafeBytes(of: &uuid) { transcript.append(contentsOf: $0) }
        return transcript
    }
}
