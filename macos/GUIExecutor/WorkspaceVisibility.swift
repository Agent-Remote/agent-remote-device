import AppKit
import Foundation

@MainActor
public protocol WorkspaceVisibilityControlling: AnyObject {
    func unapprovedApplicationCount(approvedBundleIdentifiers: Set<String>) -> Int
    @discardableResult
    func hideUnapprovedApplications(approvedBundleIdentifiers: Set<String>) throws -> Int
    func restoreApplications() throws
    @discardableResult
    func restoreApplicationsFromPreviousRun() throws -> Int
}

@MainActor
public final class WorkspaceVisibilityController: WorkspaceVisibilityControlling {
    private let ownBundleIdentifier: String
    private let journal: VisibilityJournal
    private var hiddenApplications: Set<HiddenApplicationRecord> = []

    public init(
        ownBundleIdentifier: String = "dev.agentremote.device",
        journalURL: URL? = nil
    ) {
        self.ownBundleIdentifier = ownBundleIdentifier
        journal = VisibilityJournal(fileURL: journalURL ?? VisibilityJournal.defaultURL())
    }

    public func unapprovedApplicationCount(
        approvedBundleIdentifiers: Set<String>
    ) -> Int {
        unapprovedApplications(
            approvedBundleIdentifiers: approvedBundleIdentifiers
        ).count
    }

    @discardableResult
    public func hideUnapprovedApplications(
        approvedBundleIdentifiers: Set<String>
    ) throws -> Int {
        var hiddenCount = 0
        for application in unapprovedApplications(approvedBundleIdentifiers: approvedBundleIdentifiers) {
            guard let bundleIdentifier = application.bundleIdentifier else { continue }
            let record = HiddenApplicationRecord(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
            hiddenApplications.insert(record)
            try journal.save(Array(hiddenApplications))
            guard application.hide() else {
                hiddenApplications.remove(record)
                try journal.save(Array(hiddenApplications))
                continue
            }
            hiddenCount += 1
        }
        return hiddenCount
    }

    public func restoreApplications() throws {
        _ = try restore(records: Array(hiddenApplications))
    }

    @discardableResult
    public func restoreApplicationsFromPreviousRun() throws -> Int {
        try restore(records: journal.load())
    }

    private func restore(records: [HiddenApplicationRecord]) throws -> Int {
        let applications = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
                ($0.processIdentifier, $0)
            }
        )
        var restoredCount = 0
        for record in records {
            guard let application = applications[record.processIdentifier],
                  application.bundleIdentifier == record.bundleIdentifier
            else {
                continue
            }
            if application.unhide() {
                restoredCount += 1
            }
        }
        hiddenApplications.removeAll(keepingCapacity: false)
        try journal.remove()
        return restoredCount
    }

    private func unapprovedApplications(
        approvedBundleIdentifiers: Set<String>
    ) -> [NSRunningApplication] {
        let approved = Set(approvedBundleIdentifiers.map { $0.lowercased() })
        return NSWorkspace.shared.runningApplications.filter { application in
            guard application.activationPolicy == .regular,
                  !application.isHidden,
                  let bundleIdentifier = application.bundleIdentifier
            else {
                return false
            }
            let normalized = bundleIdentifier.lowercased()
            return normalized != ownBundleIdentifier.lowercased()
                && !approved.contains(normalized)
        }
    }
}
