import Darwin
import DeviceProtocol
import Foundation

struct HiddenApplicationRecord: Codable, Equatable, Hashable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
}

enum VisibilityJournalFailure: Error, Equatable {
    case unsafeDirectory
    case unsafeFile
    case oversizedFile
    case encodingFailed
    case writeFailed
}

struct VisibilityJournal: Sendable {
    static let maximumBytes = 64 * 1024

    let fileURL: URL

    static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Agent Remote Device", isDirectory: true)
            .appendingPathComponent("hidden-applications.json", isDirectory: false)
    }

    func load() throws -> [HiddenApplicationRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw VisibilityJournalFailure.unsafeFile }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & 0o077 == 0
        else {
            throw VisibilityJournalFailure.unsafeFile
        }
        guard metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes else {
            throw VisibilityJournalFailure.oversizedFile
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw VisibilityJournalFailure.unsafeFile }
            if count == 0 { break }
            guard data.count <= Self.maximumBytes - count else {
                throw VisibilityJournalFailure.oversizedFile
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        do {
            try StrictJSON.validateUniqueObjectKeys(data, maximumDepth: 4)
            guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  records.allSatisfy({
                      Set($0.keys) == ["processIdentifier", "bundleIdentifier"]
                  })
            else {
                throw VisibilityJournalFailure.unsafeFile
            }
        } catch let failure as VisibilityJournalFailure {
            throw failure
        } catch {
            throw VisibilityJournalFailure.unsafeFile
        }
        return try JSONDecoder().decode([HiddenApplicationRecord].self, from: data)
    }

    func save(_ records: [HiddenApplicationRecord]) throws {
        if records.isEmpty {
            try remove()
            return
        }
        try prepareDirectory()
        let data = try JSONEncoder().encode(
            records.sorted { lhs, rhs in
                if lhs.processIdentifier == rhs.processIdentifier {
                    return lhs.bundleIdentifier < rhs.bundleIdentifier
                }
                return lhs.processIdentifier < rhs.processIdentifier
            }
        )
        guard data.count <= Self.maximumBytes else {
            throw VisibilityJournalFailure.encodingFailed
        }

        let temporaryURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            ".hidden-applications.\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw VisibilityJournalFailure.writeFailed }
        var writeSucceeded = false
        defer {
            close(descriptor)
            if !writeSucceeded {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        try data.withUnsafeBytes { bytes in
            guard var address = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, address, remaining)
                guard count > 0 else { throw VisibilityJournalFailure.writeFailed }
                remaining -= count
                address = address.advanced(by: count)
            }
        }
        guard fsync(descriptor) == 0 else { throw VisibilityJournalFailure.writeFailed }
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw VisibilityJournalFailure.writeFailed
        }
        writeSucceeded = true
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        _ = try secureMetadata(
            at: fileURL,
            expectedType: mode_t(S_IFREG),
            failure: .unsafeFile
        )
        try FileManager.default.removeItem(at: fileURL)
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = try secureMetadata(
            at: directory,
            expectedType: mode_t(S_IFDIR),
            failure: .unsafeDirectory
        )
    }

    private func secureMetadata(
        at url: URL,
        expectedType: mode_t,
        failure: VisibilityJournalFailure
    ) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(S_IFMT) == expectedType,
              metadata.st_mode & 0o077 == 0
        else {
            throw failure
        }
        return metadata
    }
}
