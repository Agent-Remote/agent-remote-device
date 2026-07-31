import DeviceServices
import Foundation
import Testing

private let credentialDeviceID = "2cb933ce-b922-4ed7-b479-6ded90f09d2d"
private let credentialToken = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"

@Test func communityCredentialStoreReadsOnlyAnOwnerOnlyRegularFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "agent-remote-community-credential-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("credential.json")
    let data = Data(
        """
        {"schema_version":1,"server_url":"https://control.example.test","device_id":"\(credentialDeviceID)","access_token":"\(credentialToken)","expires_at_unix":1100}
        """.utf8
    )
    _ = FileManager.default.createFile(
        atPath: file.path,
        contents: data,
        attributes: [.posixPermissions: 0o600]
    )
    let store = CommunityFileNetworkBrokerCredentialStore(fileURL: file)
    let credential = try store.loadCredential(now: Date(timeIntervalSince1970: 1_000))
    #expect(credential.deviceID == credentialDeviceID)

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: NetworkBrokerCredentialFailure.malformed) {
        try store.loadCredential(now: Date(timeIntervalSince1970: 1_000))
    }
}

@Test func networkBrokerCredentialAcceptsOnlyTheFixedBoundedContract() throws {
    let data = try #require(
        """
        {
          "schema_version": 1,
          "server_url": "https://control.example.test:8443",
          "device_id": "\(credentialDeviceID)",
          "access_token": "\(credentialToken)",
          "expires_at_unix": 1100
        }
        """.data(using: .utf8)
    )
    let credential = try NetworkBrokerCredential.decode(
        data,
        now: Date(timeIntervalSince1970: 1_000)
    )
    #expect(credential.serverURL == "https://control.example.test:8443")
    #expect(credential.deviceID == credentialDeviceID)
}

@Test func networkBrokerCredentialRejectsEndpointOverridesAndUnknownFields() throws {
    for serverURL in [
        "http://control.example.test",
        "https://user@control.example.test",
        "https://control.example.test/api",
        "https://control.example.test?next=evil",
        "https://control.example.test/",
    ] {
        let data = try #require(
            """
            {"schema_version":1,"server_url":"\(serverURL)","device_id":"\(credentialDeviceID)","access_token":"\(credentialToken)","expires_at_unix":1100}
            """.data(using: .utf8)
        )
        #expect(throws: NetworkBrokerCredentialFailure.self) {
            try NetworkBrokerCredential.decode(data, now: Date(timeIntervalSince1970: 1_000))
        }
    }

    let unknown = try #require(
        """
        {"schema_version":1,"server_url":"https://control.example.test","device_id":"\(credentialDeviceID)","access_token":"\(credentialToken)","expires_at_unix":1100,"endpoint":"https://evil.test"}
        """.data(using: .utf8)
    )
    #expect(throws: NetworkBrokerCredentialFailure.self) {
        try NetworkBrokerCredential.decode(unknown, now: Date(timeIntervalSince1970: 1_000))
    }

    let duplicate = try #require(
        """
        {"schema_version":1,"server_url":"https://control.example.test","device_id":"\(credentialDeviceID)","access_token":"\(credentialToken)","access_token":"\(credentialToken)","expires_at_unix":1100}
        """.data(using: .utf8)
    )
    #expect(throws: NetworkBrokerCredentialFailure.self) {
        try NetworkBrokerCredential.decode(duplicate, now: Date(timeIntervalSince1970: 1_000))
    }
}

@Test func networkBrokerCredentialRejectsExpiredOrNoncanonicalBindings() throws {
    for (deviceID, expiry) in [
        (credentialDeviceID.uppercased(), UInt64(1_100)),
        (credentialDeviceID, UInt64(1_000)),
        (credentialDeviceID, UInt64(1_000 + 91 * 24 * 60 * 60)),
    ] {
        let data = try #require(
            """
            {"schema_version":1,"server_url":"https://control.example.test","device_id":"\(deviceID)","access_token":"\(credentialToken)","expires_at_unix":\(expiry)}
            """.data(using: .utf8)
        )
        #expect(throws: NetworkBrokerCredentialFailure.self) {
            try NetworkBrokerCredential.decode(data, now: Date(timeIntervalSince1970: 1_000))
        }
    }
}
