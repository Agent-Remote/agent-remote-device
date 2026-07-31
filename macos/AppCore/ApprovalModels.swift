import DeviceProtocol
import DeviceSecurity
import Foundation

public enum ApprovalModelFailure: Error, Equatable, Sendable {
    case emptyApplications
    case duplicateApplication
    case invalidGeneration
}

public struct ApprovalCandidate: Identifiable, Equatable, Sendable {
    public let application: ApplicationIdentity
    public let displayName: String
    public let requestedControlLevel: ControlLevel
    public let classification: ApplicationClassification
    public let clipboardRequested: Bool

    public var id: String { application.stableDigest }

    public var effectiveControlLevel: ControlLevel {
        classification.controlLevel ?? requestedControlLevel
    }

    public init(
        application: ApplicationIdentity,
        displayName: String,
        requestedControlLevel: ControlLevel,
        classification: ApplicationClassification,
        clipboardRequested: Bool
    ) {
        self.application = application
        self.displayName = displayName
        self.requestedControlLevel = requestedControlLevel
        self.classification = classification
        self.clipboardRequested = clipboardRequested
    }
}

public struct ApprovalPresentation: Equatable, Sendable {
    public let generation: UInt64
    public let applications: [ApprovalCandidate]
    public let hiddenApplicationCount: Int

    public init(
        generation: UInt64,
        applications: [ApprovalCandidate],
        hiddenApplicationCount: Int
    ) throws {
        guard (1 ... maximumActiveDeviceSessionGeneration).contains(generation) else {
            throw ApprovalModelFailure.invalidGeneration
        }
        guard !applications.isEmpty else { throw ApprovalModelFailure.emptyApplications }
        guard Set(applications.map(\.id)).count == applications.count else {
            throw ApprovalModelFailure.duplicateApplication
        }
        self.generation = generation
        self.applications = applications
        self.hiddenApplicationCount = max(0, hiddenApplicationCount)
    }

    public func approvals(
        applicationSelections: Set<String>,
        clipboardSelections: Set<String>,
        controlLevelSelections: [String: ControlLevel]
    ) -> [LocalApproval] {
        applications.compactMap { candidate in
            guard applicationSelections.contains(candidate.id) else { return nil }
            return LocalApproval(
                application: candidate.application,
                controlLevel: candidate.classification.controlLevel
                    ?? controlLevelSelections[candidate.id]
                    ?? .viewOnly,
                clipboardAllowed: candidate.clipboardRequested
                    && clipboardSelections.contains(candidate.id),
                generation: generation
            )
        }
    }

    public func updatingHiddenApplicationCount(_ count: Int) -> ApprovalPresentation {
        ApprovalPresentation(
            validatedGeneration: generation,
            applications: applications,
            hiddenApplicationCount: count
        )
    }

    private init(
        validatedGeneration: UInt64,
        applications: [ApprovalCandidate],
        hiddenApplicationCount: Int
    ) {
        generation = validatedGeneration
        self.applications = applications
        self.hiddenApplicationCount = max(0, hiddenApplicationCount)
    }
}
