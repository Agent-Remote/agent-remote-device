import Darwin
import DeviceProtocol
import Foundation
import LocalAuthentication
import Security

private let brokerCredentialSchemaVersion: UInt64 = 1
private let maximumServerURLBytes = 2_048
private let maximumAccessTokenBytes = 4_096
private let maximumCredentialLifetime: UInt64 = 90 * 24 * 60 * 60
private let brokerCredentialService = "dev.agentremote.device.broker-credential"
private let brokerCredentialAccount = "active-device"
private let brokerCredentialAccessGroupSuffix = "dev.agentremote.device.credentials"

public enum NetworkBrokerCredentialFailure: Error, Equatable, Sendable {
    case accessGroupUnavailable
    case itemNotFound
    case keychain(OSStatus)
    case fileSystem(Int32)
    case malformed
    case expired
}

public struct NetworkBrokerCredential: Codable, Equatable, Sendable {
    public let schemaVersion: UInt64
    public let serverURL: String
    public let deviceID: String
    public let accessToken: String
    public let expiresAtUnix: UInt64

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case serverURL = "server_url"
        case deviceID = "device_id"
        case accessToken = "access_token"
        case expiresAtUnix = "expires_at_unix"
    }

    public init(
        schemaVersion: UInt64,
        serverURL: String,
        deviceID: String,
        accessToken: String,
        expiresAtUnix: UInt64,
        now: Date = Date()
    ) throws {
        self.schemaVersion = schemaVersion
        self.serverURL = serverURL
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.expiresAtUnix = expiresAtUnix
        try validate(now: now)
    }

    public static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= DeviceCredentialBounds.maximumEncodedBytes else {
            throw NetworkBrokerCredentialFailure.malformed
        }
        do {
            try StrictJSON.validateUniqueObjectKeys(data, maximumDepth: 4)
        } catch {
            throw NetworkBrokerCredentialFailure.malformed
        }
        guard
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue))
        else {
            throw NetworkBrokerCredentialFailure.malformed
        }
        let credential: Self
        do {
            credential = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw NetworkBrokerCredentialFailure.malformed
        }
        try credential.validate(now: now)
        return credential
    }

    public func validate(now: Date = Date()) throws {
        guard schemaVersion == brokerCredentialSchemaVersion,
              !serverURL.isEmpty,
              serverURL.utf8.count <= maximumServerURLBytes,
              serverURL == serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverURL.hasSuffix("/"),
              let components = URLComponents(string: serverURL),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              let identifier = UUID(uuidString: deviceID),
              identifier.uuidString.lowercased() == deviceID,
              (32 ... maximumAccessTokenBytes).contains(accessToken.utf8.count),
              accessToken.utf8.allSatisfy({ (0x21 ... 0x7e).contains($0) })
        else {
            throw NetworkBrokerCredentialFailure.malformed
        }
        let current = UInt64(max(0, now.timeIntervalSince1970.rounded(.down)))
        guard expiresAtUnix > current else {
            throw NetworkBrokerCredentialFailure.expired
        }
        guard expiresAtUnix - current <= maximumCredentialLifetime else {
            throw NetworkBrokerCredentialFailure.malformed
        }
    }
}

public protocol NetworkBrokerCredentialLoading: Sendable {
    func loadCredential(now: Date) throws -> NetworkBrokerCredential
}

public struct KeychainNetworkBrokerCredentialStore: NetworkBrokerCredentialLoading, Sendable {
    private let accessGroup: String

    public init(bundle: Bundle = .main) throws {
        guard let teamIdentifier = bundle.object(
            forInfoDictionaryKey: "AgentRemoteTeamIdentifier"
        ) as? String,
            teamIdentifier.count == 10,
            teamIdentifier.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) })
        else {
            throw NetworkBrokerCredentialFailure.accessGroupUnavailable
        }
        accessGroup = "\(teamIdentifier).\(brokerCredentialAccessGroupSuffix)"
    }

    public init(accessGroup: String) throws {
        guard accessGroup.hasSuffix(".\(brokerCredentialAccessGroupSuffix)"),
              !accessGroup.contains("$"),
              accessGroup.utf8.count <= 128
        else {
            throw NetworkBrokerCredentialFailure.accessGroupUnavailable
        }
        self.accessGroup = accessGroup
    }

    public func loadCredential(now: Date = Date()) throws -> NetworkBrokerCredential {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: brokerCredentialService,
            kSecAttrAccount: brokerCredentialAccount,
            kSecAttrAccessGroup: accessGroup,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
            kSecUseAuthenticationContext: authenticationContext,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            throw NetworkBrokerCredentialFailure.itemNotFound
        }
        guard status == errSecSuccess else {
            throw NetworkBrokerCredentialFailure.keychain(status)
        }
        guard let data = result as? Data else {
            throw NetworkBrokerCredentialFailure.malformed
        }
        return try NetworkBrokerCredential.decode(data, now: now)
    }
}

public struct CommunityFileNetworkBrokerCredentialStore: NetworkBrokerCredentialLoading, Sendable {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public func loadCredential(now: Date = Date()) throws -> NetworkBrokerCredential {
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw NetworkBrokerCredentialFailure.itemNotFound
            }
            throw NetworkBrokerCredentialFailure.fileSystem(errno)
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_size > 0,
              metadata.st_size <= Int64(DeviceCredentialBounds.maximumEncodedBytes)
        else {
            throw NetworkBrokerCredentialFailure.malformed
        }
        let data: Data
        do {
            data = try file.read(upToCount: DeviceCredentialBounds.maximumEncodedBytes + 1) ?? Data()
        } catch {
            throw NetworkBrokerCredentialFailure.fileSystem(errno)
        }
        guard Int64(data.count) == metadata.st_size else {
            throw NetworkBrokerCredentialFailure.malformed
        }
        return try NetworkBrokerCredential.decode(data, now: now)
    }

    private static func defaultFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["AGENT_REMOTE_HOME"],
           override.hasPrefix("/")
        {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("device-broker-credential.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-remote", isDirectory: true)
            .appendingPathComponent("device-broker-credential.json")
    }
}

private enum DeviceCredentialBounds {
    static let maximumEncodedBytes = 8 * 1_024
}
