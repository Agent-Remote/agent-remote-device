import AppKit
import Foundation

@MainActor
public protocol WorkspaceVisibilityControlling: AnyObject {
    func restoreApplications() throws
    @discardableResult
    func restoreApplicationsFromPreviousRun() throws -> Int
}

@MainActor
public final class WorkspaceVisibilityController: WorkspaceVisibilityControlling {
    private let journal: VisibilityJournal

    public init(journalURL: URL? = nil) {
        journal = VisibilityJournal(fileURL: journalURL ?? VisibilityJournal.defaultURL())
    }

    public func restoreApplications() throws {
        try journal.remove()
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
        try journal.remove()
        return restoredCount
    }
}
