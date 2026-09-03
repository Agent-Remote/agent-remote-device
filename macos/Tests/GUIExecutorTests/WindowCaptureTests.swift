import AppKit
import CoreGraphics
import DeviceProtocol
import DeviceSecurity
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GUIExecutor

@Test func dynamicApplicationResolutionRejectsAmbiguousAndExcludedTargets() async throws {
    let first = InstalledApplicationTarget(
        identity: ApplicationIdentity(
            bundleIdentifier: "com.example.First",
            signingIdentifier: "com.example.First"
        ),
        bundleURL: URL(fileURLWithPath: "/Applications/First.app")
    )
    let second = InstalledApplicationTarget(
        identity: ApplicationIdentity(
            bundleIdentifier: "com.example.Second",
            signingIdentifier: "com.example.Second"
        ),
        bundleURL: URL(fileURLWithPath: "/Applications/Second.app")
    )
    #expect(throws: CaptureFailure.applicationAmbiguous) {
        try ApplicationResolver.uniqueInstalledApplication([first, second])
    }
    let duplicateIdentity = InstalledApplicationTarget(
        identity: first.identity,
        bundleURL: URL(fileURLWithPath: "/Applications/First Copy.app")
    )
    #expect(throws: CaptureFailure.applicationAmbiguous) {
        try ApplicationResolver.uniqueInstalledApplication([first, duplicateIdentity])
    }
    let samePath = try ApplicationResolver.uniqueInstalledApplication([first, first])
    #expect(samePath.bundleURL == first.bundleURL)
    #expect(throws: CaptureFailure.applicationNotFound) {
        try ApplicationResolver.uniqueInstalledApplication([])
    }
    await #expect(throws: CaptureFailure.protectedApplication) {
        try await MainActor.run {
            try ApplicationResolver.installedApplication(
                matching: "dev.agentremote.device",
                excludedBundleIdentifiers: ["dev.agentremote.device"]
            )
        }
    }
    for bundleIdentifier in [
        "com.apple.authorizationhost",
        "com.apple.CoreServicesUIAgent",
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.UserConsentDialog",
    ] {
        await #expect(throws: CaptureFailure.protectedApplication) {
            try await MainActor.run {
                try ApplicationResolver.installedApplication(
                    matching: bundleIdentifier,
                    excludedBundleIdentifiers: []
                )
            }
        }
    }
}

@Test func dynamicApplicationResolutionExcludesBundleAndSigningIdentityNamespaces() {
    let exclusions: Set<String> = ["dev.agentremote.device"]
    #expect(ApplicationResolver.isExcluded(
        ApplicationIdentity(
            bundleIdentifier: "dev.agentremote.device.helper",
            signingIdentifier: "com.example.Helper"
        ),
        exclusions: exclusions
    ))
    #expect(ApplicationResolver.isExcluded(
        ApplicationIdentity(
            bundleIdentifier: "com.example.Disguised",
            signingIdentifier: "dev.agentremote.device.gui-executor"
        ),
        exclusions: exclusions
    ))
    #expect(!ApplicationResolver.isExcluded(
        ApplicationIdentity(
            bundleIdentifier: "com.example.Eligible",
            signingIdentifier: "com.example.Eligible"
        ),
        exclusions: exclusions
    ))
}

@Test func installedApplicationDiscoveryFindsNestedAppsAndFailsClosedAtItsBound() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? manager.removeItem(at: root) }
    let nested = root.appendingPathComponent("Vendor/Product.app", isDirectory: true)
    let second = root.appendingPathComponent("Second.app", isDirectory: true)
    try manager.createDirectory(at: nested, withIntermediateDirectories: true)
    try manager.createDirectory(at: second, withIntermediateDirectories: true)

    let applications = try ApplicationResolver.installedApplicationURLs(
        in: [root],
        maximumApplications: 2
    )
    #expect(Set(applications.map { $0.resolvingSymlinksInPath() }) == [
        nested.resolvingSymlinksInPath(),
        second.resolvingSymlinksInPath(),
    ])
    #expect(throws: CaptureFailure.applicationAmbiguous) {
        try ApplicationResolver.installedApplicationURLs(
            in: [root],
            maximumApplications: 1
        )
    }
}

@Test func launchedWindowResolutionRequiresTheExactValidatedProcess() throws {
    let candidates: [(processID: pid_t, signingIdentifier: String?)] = [
        (101, "com.example.Target"),
        (202, "com.example.Target"),
        (303, "com.example.Other"),
    ]
    #expect(try WindowCapture.matchingProcessIDs(
        candidates,
        expectedSigningIdentifier: "com.example.Target",
        requiredProcessID: nil
    ) == [101, 202])
    #expect(try WindowCapture.matchingProcessIDs(
        candidates,
        expectedSigningIdentifier: "com.example.Target",
        requiredProcessID: 202
    ) == [202])
    #expect(throws: CaptureFailure.approvedApplicationNotRunning) {
        try WindowCapture.matchingProcessIDs(
            candidates,
            expectedSigningIdentifier: "com.example.Target",
            requiredProcessID: 404
        )
    }
    #expect(throws: CaptureFailure.signingIdentifierMismatch) {
        try WindowCapture.matchingProcessIDs(
            candidates,
            expectedSigningIdentifier: "com.example.Target",
            requiredProcessID: 303
        )
    }
}

@Test @MainActor func captureOperationTimeoutReturnsWithoutWaitingForHungWork() async throws {
    let started = ContinuousClock.now
    do {
        let _: Int = try await WindowCapture.withOperationTimeout(.milliseconds(20)) {
            try await Task.sleep(for: .seconds(10))
            return 1
        }
        Issue.record("Expected the capture operation to time out")
    } catch {
        #expect(error as? CaptureFailure == .operationTimedOut)
    }
    #expect(ContinuousClock.now - started < .seconds(1))
}

@Test @MainActor func captureOperationTimeoutSurvivesSynchronouslyBlockedOperation() async throws {
    let started = ContinuousClock.now
    do {
        let _: Int = try await WindowCapture.withOperationTimeout(.milliseconds(20)) {
            synchronouslyBlock(for: 2)
            return 1
        }
        Issue.record("Expected the blocked capture operation to time out")
    } catch {
        #expect(error as? CaptureFailure == .operationTimedOut)
    }
    #expect(ContinuousClock.now - started < .seconds(1))
}

private func synchronouslyBlock(for seconds: Double) {
    _ = DispatchSemaphore(value: 0).wait(timeout: .now() + seconds)
}

@Test @MainActor func captureOperationReturnsBeforeTimeout() async throws {
    let value = try await WindowCapture.withOperationTimeout(.seconds(1)) { 42 }
    #expect(value == 42)
}

@Test func preferredWindowSkipsTinyFrontmostBrowserUtilityWindow() {
    let selected = WindowCapture.preferredWindowID(
        candidates: [
            (windowID: 10, frame: CGRect(x: 10, y: 50, width: 66, height: 20)),
            (windowID: 20, frame: CGRect(x: 0, y: 39, width: 1_800, height: 1_069)),
        ],
        frontToBackWindowIDs: [10, 20]
    )

    #expect(selected == 20)
}

@Test func preferredWindowUsesFrontmostSubstantialWindow() {
    let selected = WindowCapture.preferredWindowID(
        candidates: [
            (windowID: 10, frame: CGRect(x: 0, y: 0, width: 1_400, height: 900)),
            (windowID: 20, frame: CGRect(x: 300, y: 200, width: 500, height: 300)),
        ],
        frontToBackWindowIDs: [20, 10]
    )

    #expect(selected == 20)
}

@Test func preferredWindowFallsBackToLargestCandidateWithoutZOrder() {
    let selected = WindowCapture.preferredWindowID(
        candidates: [
            (windowID: 10, frame: CGRect(x: 0, y: 0, width: 200, height: 100)),
            (windowID: 20, frame: CGRect(x: 0, y: 0, width: 300, height: 200)),
        ],
        frontToBackWindowIDs: []
    )

    #expect(selected == 20)
}

@Test func preferredWindowUsesTheRequiredBoundWindowInsteadOfZOrder() {
    let candidates: [(windowID: CGWindowID, frame: CGRect)] = [
        (windowID: 10, frame: CGRect(x: 0, y: 0, width: 1_400, height: 900)),
        (windowID: 20, frame: CGRect(x: 100, y: 100, width: 900, height: 700)),
    ]

    #expect(WindowCapture.preferredWindowID(
        candidates: candidates,
        frontToBackWindowIDs: [10, 20],
        requiredWindowID: 20
    ) == 20)
    #expect(WindowCapture.preferredWindowID(
        candidates: candidates,
        frontToBackWindowIDs: [10, 20],
        requiredWindowID: 30
    ) == nil)
}

@Test func preferredWindowSelectsTheFrontmostSurfaceAcrossApplicationInstances() {
    let candidates = WindowCapture.matchingWindowCandidates(
        [
            WindowCandidate(
                windowID: 10,
                frame: CGRect(x: 0, y: 0, width: 1_400, height: 900),
                processID: 100
            ),
            WindowCandidate(
                windowID: 20,
                frame: CGRect(x: 1_500, y: 0, width: 1_200, height: 800),
                processID: 200
            ),
            WindowCandidate(
                windowID: 30,
                frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
                processID: 300
            ),
            WindowCandidate(
                windowID: 40,
                frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                processID: 100
            ),
        ],
        processIDs: [100, 200]
    )
    let selected = WindowCapture.preferredWindowID(
        candidates: candidates.map { ($0.windowID, $0.frame) },
        frontToBackWindowIDs: [20, 10]
    )

    #expect(candidates.map(\.windowID) == [10, 20])
    #expect(selected == 20)
}

@Test func preferredWindowUsesWindowServerOrderBeforeFocusedWindow() {
    let candidates: [(windowID: CGWindowID, frame: CGRect)] = [
        (windowID: 7, frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)),
        (windowID: 8, frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)),
    ]

    #expect(WindowCapture.preferredWindowID(
        candidates: candidates,
        frontToBackWindowIDs: [7, 8],
        focusedWindowID: 8
    ) == 7)
}

@Test func preferredWindowUsesScreenCaptureKitActiveWindow() {
    let candidates: [(windowID: CGWindowID, frame: CGRect)] = [
        (windowID: 7, frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)),
        (windowID: 8, frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)),
    ]

    #expect(WindowCapture.preferredWindowID(
        candidates: candidates,
        frontToBackWindowIDs: [],
        activeWindowIDs: [8, 7],
        shareableWindowIDs: [7, 8]
    ) == 8)
}

@Test func preferredWindowUsesWindowServerOrderBeforeFocusedAndActiveWindows() {
    let candidates: [(windowID: CGWindowID, frame: CGRect)] = [
        (windowID: 7, frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)),
        (windowID: 8, frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)),
    ]

    #expect(WindowCapture.preferredWindowID(
        candidates: candidates,
        frontToBackWindowIDs: [7, 8],
        activeWindowIDs: [7],
        focusedWindowID: 8
    ) == 7)
}

@Test func preferredWindowUsesFocusedWindowWhenWindowServerOrderIsUnavailable() {
    let candidates: [(windowID: CGWindowID, frame: CGRect)] = [
        (windowID: 7, frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)),
        (windowID: 8, frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)),
    ]

    #expect(WindowCapture.preferredWindowID(
        candidates: candidates,
        frontToBackWindowIDs: [],
        activeWindowIDs: [7],
        focusedWindowID: 8
    ) == 8)
}

@Test func preferredWindowUsesShareableOrderWhenVisibilityAndFocusAreUnavailable() {
    let candidates: [(windowID: CGWindowID, frame: CGRect)] = [
        (windowID: 7, frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)),
        (windowID: 8, frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)),
    ]

    #expect(WindowCapture.preferredWindowID(
        candidates: candidates,
        frontToBackWindowIDs: [],
        shareableWindowIDs: [8, 7]
    ) == 8)
}

@Test func selectionCandidatesIncludesVisibleWindowsMissingFromShareableContent() {
    let old = WindowCandidate(
        windowID: 7,
        frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
        processID: 42
    )
    let newlyVisible = WindowCandidate(
        windowID: 8,
        frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
        processID: 42
    )

    let candidates = WindowCapture.selectionCandidates(
        shareable: [old],
        visible: [newlyVisible, old]
    )

    #expect(candidates == [old, newlyVisible])
    #expect(WindowCapture.preferredWindowID(
        candidates: candidates.map { ($0.windowID, $0.frame) },
        frontToBackWindowIDs: [8, 7]
    ) == 8)
}

@Test func passiveWindowResolutionRetainsOffScreenSpaceCandidates() {
    let offScreen = WindowCandidate(
        windowID: 7,
        frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
        processID: 42,
        isOnScreen: false
    )

    #expect(WindowCapture.selectionCandidates(
        shareable: [offScreen],
        visible: []
    ) == [offScreen])
}

@Test @MainActor func coordinateContextResolutionRequiresAnOnScreenWindow() {
    #expect(ActionExecutor.requiresOnScreenWindowList(
        frameValidation: .exact,
        requireFrontmost: true
    ))
    #expect(!ActionExecutor.requiresOnScreenWindowList(
        frameValidation: .identityOnly,
        requireFrontmost: true
    ))
    #expect(!ActionExecutor.requiresOnScreenWindowList(
        frameValidation: .exact,
        requireFrontmost: false
    ))
}

@Test @MainActor func keyRoutingUsesNormalHIDOnlyForWindowManagementShortcuts() {
    for key in ["CMD+N", "CMD+SHIFT+N", "CMD+`", "COMMAND+SHIFT+`"] {
        #expect(ActionExecutor.usesFrontmostHIDRouting(for: key))
    }
    for key in ["CMD+A", "CMD+TAB", "CMD+ALT+N", "N"] {
        #expect(!ActionExecutor.usesFrontmostHIDRouting(for: key))
    }
}

@Test @MainActor func secureInputBlocksInteractiveActionsButNotPassiveOperations() {
    #expect(ActionExecutor.requiresSecureInputClear(.type("text")))
    #expect(ActionExecutor.requiresSecureInputClear(.leftClick(Point(x: 1, y: 1))))
    #expect(!ActionExecutor.requiresSecureInputClear(.wait(1)))
    #expect(!ActionExecutor.requiresSecureInputClear(Action.readClipboard))

    let target = ElementTarget(
        stateID: UUID(),
        stateGeneration: 1,
        applicationDigest: String(repeating: "a", count: 64),
        windowID: 1,
        displayFingerprint: String(repeating: "b", count: 64),
        elementIndex: 1
    )
    #expect(ActionExecutor.requiresSecureInputClear(.press(target)))
    #expect(!ActionExecutor.requiresSecureInputClear(.observe(application: nil)))
    #expect(!ActionExecutor.requiresSecureInputClear(.launchApplication("com.apple.TextEdit")))
    #expect(!ActionExecutor.requiresSecureInputClear(ActionV2.readClipboard))
    #expect(ExecutionFailure.protectedSystemSurface.diagnosticCode == "protected_system_surface")
}

@Test @MainActor func clipboardTextDistinguishesEmptyNonTextAndOversizedContent() throws {
    let pasteboard = NSPasteboard(name: .init("device-tests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    #expect(throws: ExecutionFailure.clipboardEmpty) {
        try ActionExecutor.clipboardText(from: pasteboard, maximumBytes: 64 * 1_024)
    }

    let binaryType = NSPasteboard.PasteboardType("dev.agentremote.tests.binary")
    pasteboard.setData(Data([0x01]), forType: binaryType)
    #expect(throws: ExecutionFailure.clipboardNonText) {
        try ActionExecutor.clipboardText(from: pasteboard, maximumBytes: 64 * 1_024)
    }

    pasteboard.clearContents()
    let unavailableItem = NSPasteboardItem()
    let unavailableProvider = EmptyPasteboardProvider()
    unavailableItem.setDataProvider(unavailableProvider, forTypes: [.string])
    #expect(pasteboard.writeObjects([unavailableItem]))
    #expect(throws: ExecutionFailure.clipboardUnavailable) {
        try ActionExecutor.clipboardText(from: pasteboard, maximumBytes: 64 * 1_024)
    }

    pasteboard.clearContents()
    #expect(pasteboard.setString("clipboard text", forType: .string))
    #expect(try ActionExecutor.clipboardText(
        from: pasteboard,
        maximumBytes: 64 * 1_024
    ) == "clipboard text")

    pasteboard.clearContents()
    #expect(pasteboard.setString("", forType: .string))
    #expect(throws: ExecutionFailure.clipboardEmpty) {
        try ActionExecutor.clipboardText(from: pasteboard, maximumBytes: 64 * 1_024)
    }

    pasteboard.clearContents()
    #expect(pasteboard.setString("large", forType: .string))
    #expect(throws: ExecutionFailure.clipboardTooLarge) {
        try ActionExecutor.clipboardText(from: pasteboard, maximumBytes: 4)
    }
    pasteboard.clearContents()
}

private final class EmptyPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(
        _: NSPasteboard?,
        item _: NSPasteboardItem,
        provideDataForType _: NSPasteboard.PasteboardType
    ) {}
}

@Test func captureScalingPreservesAspectRatioWithoutUpscaling() {
    #expect(WindowCapture.scaledSize(
        sourceWidth: 2_000,
        sourceHeight: 1_000,
        maximumWidth: 1_000,
        maximumHeight: 1_000
    ) == (1_000, 500))
    #expect(WindowCapture.scaledSize(
        sourceWidth: 400,
        sourceHeight: 300,
        maximumWidth: 1_000,
        maximumHeight: 1_000
    ) == (400, 300))
    #expect(WindowCapture.scaledSize(
        sourceWidth: 0,
        sourceHeight: 300,
        maximumWidth: 1_000,
        maximumHeight: 1_000
    ) == (0, 0))
}

@Test func coordinateMappingUsesImageRelativeCoordinates() throws {
    let point = try #require(CoordinateMapper.screenPoint(
        imagePoint: .init(x: 500, y: 250),
        pixelWidth: 1_000,
        pixelHeight: 500,
        windowFrame: CGRect(x: 100, y: 200, width: 2_000, height: 1_000)
    ))
    #expect(point == CGPoint(x: 1_100, y: 700))
    #expect(CoordinateMapper.screenPoint(
        imagePoint: .init(x: 1_000, y: 0),
        pixelWidth: 1_000,
        pixelHeight: 500,
        windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
    ) == nil)
}

@Test @MainActor func frameChangesOnlyInvalidateGeometryBoundActions() {
    let expected = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    let fullScreenTransition = CGRect(x: 0, y: 24, width: 1_920, height: 1_032)

    #expect(!ActionExecutor.windowFrameMatches(
        fullScreenTransition,
        expected: expected,
        validation: .exact
    ))
    #expect(ActionExecutor.windowFrameMatches(
        fullScreenTransition,
        expected: expected,
        validation: .identityOnly
    ))
}

@Test func displaySelectionUsesLargestWindowIntersectionIndependentOfInputOrder() {
    let displays: [(displayID: CGDirectDisplayID, frame: CGRect)] = [
        (20, CGRect(x: 0, y: 0, width: 1_000, height: 800)),
        (10, CGRect(x: -1_000, y: 0, width: 1_000, height: 800)),
    ]
    let window = CGRect(x: -200, y: 100, width: 600, height: 400)

    #expect(WindowCapture.selectedDisplayID(for: window, from: displays) == 20)
    #expect(WindowCapture.selectedDisplayID(for: window, from: Array(displays.reversed())) == 20)
}

@Test func displaySelectionUsesStableIDForEqualIntersectionsAndRejectsEdgeContact() {
    let displays: [(displayID: CGDirectDisplayID, frame: CGRect)] = [
        (20, CGRect(x: 0, y: 0, width: 1_000, height: 800)),
        (10, CGRect(x: -1_000, y: 0, width: 1_000, height: 800)),
    ]

    #expect(WindowCapture.selectedDisplayID(
        for: CGRect(x: -100, y: 100, width: 200, height: 200),
        from: displays
    ) == 10)
    #expect(WindowCapture.selectedDisplayID(
        for: CGRect(x: 1_000, y: 100, width: 200, height: 200),
        from: displays
    ) == nil)
}

@Test func displayLocalCaptureRectAccountsForNonZeroDisplayOrigins() {
    let display = CGRect(x: 1_920, y: -200, width: 1_920, height: 1_080)
    let visibleWindow = CGRect(x: 2_020, y: -100, width: 800, height: 600)

    #expect(WindowCapture.displayLocalRect(visibleWindow, displayFrame: display) == CGRect(
        x: 100,
        y: 100,
        width: 800,
        height: 600
    ))
}

@Test func zoomCropProducesANewImageRelativeCoordinateFrame() throws {
    let application = ApplicationIdentity(
        bundleIdentifier: "dev.example.App",
        signingIdentifier: "dev.example.App"
    )
    let capture = CapturedWindow(
        pngData: try testPNG(width: 4, height: 4),
        pixelWidth: 4,
        pixelHeight: 4,
        windowID: 1,
        windowFrame: CGRect(x: 100, y: 200, width: 40, height: 40),
        coordinateFrame: CGRect(x: 100, y: 200, width: 40, height: 40),
        processID: 2,
        application: application,
        displayFingerprint: "display",
        windowTitle: "Agent Remote"
    )

    let cropped = try WindowCapture.cropped(
        capture,
        to: Region(x: 1, y: 1, width: 2, height: 2)
    )

    #expect(cropped.pixelWidth == 2)
    #expect(cropped.pixelHeight == 2)
    #expect(cropped.windowFrame == capture.windowFrame)
    #expect(cropped.windowTitle == capture.windowTitle)
    #expect(cropped.coordinateFrame == CGRect(x: 110, y: 210, width: 20, height: 20))
    let source = try #require(CGImageSourceCreateWithData(cropped.pngData as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 2)
    #expect(image.height == 2)
}

@Test func jpegEncodingPreservesDimensionsAndAdvertisesItsExactMimeType() throws {
    let png = try testPNG(width: 64, height: 40)
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let encoding = CaptureImageEncoding.jpeg(quality: 0.72)
    let jpeg = try #require(WindowCapture.encodedData(image, encoding: encoding))
    let encodedSource = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
    let encodedImage = try #require(CGImageSourceCreateImageAtIndex(encodedSource, 0, nil))

    #expect(encoding.mimeType == "image/jpeg")
    #expect(CGImageSourceGetType(encodedSource) as String? == UTType.jpeg.identifier)
    #expect(encodedImage.width == 64)
    #expect(encodedImage.height == 40)
}

@Test func escapeMonitorRecognizesOnlyTheGlobalEscapeKeyCode() {
    #expect(GlobalStopMonitor.isEscape(keyCode: 53))
    #expect(!GlobalStopMonitor.isEscape(keyCode: 36))
    #expect(!GlobalStopMonitor.isEscape(keyCode: 0))
}

@Test func visibilityJournalUsesOwnerOnlyFileAndRoundTripsBoundedRecords() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = VisibilityJournal(
        fileURL: directory.appendingPathComponent("hidden-applications.json")
    )
    let records = [
        HiddenApplicationRecord(processIdentifier: 42, bundleIdentifier: "dev.example.App"),
    ]

    try journal.save(records)
    #expect(try journal.load() == records)
    let attributes = try FileManager.default.attributesOfItem(atPath: journal.fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try journal.remove()
    #expect(!FileManager.default.fileExists(atPath: journal.fileURL.path))
}

@Test func visibilityJournalRejectsGroupReadableFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let fileURL = directory.appendingPathComponent("hidden-applications.json")
    FileManager.default.createFile(
        atPath: fileURL.path,
        contents: Data("[]".utf8),
        attributes: [.posixPermissions: 0o640]
    )
    let journal = VisibilityJournal(fileURL: fileURL)

    #expect(throws: VisibilityJournalFailure.unsafeFile) {
        try journal.load()
    }
}

@Test func visibilityJournalRejectsDuplicateAndUnknownRecordFields() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let fileURL = directory.appendingPathComponent("hidden-applications.json")
    let journal = VisibilityJournal(fileURL: fileURL)
    for data in [
        Data("[{\"processIdentifier\":42,\"processIdentifier\":43,\"bundleIdentifier\":\"dev.example.App\"}]".utf8),
        Data("[{\"processIdentifier\":42,\"bundleIdentifier\":\"dev.example.App\",\"title\":\"secret\"}]".utf8),
    ] {
        try data.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        #expect(throws: VisibilityJournalFailure.unsafeFile) {
            try journal.load()
        }
    }
}

@Test func visibilityJournalRejectsSymbolicLinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let targetURL = directory.appendingPathComponent("target.json")
    let linkURL = directory.appendingPathComponent("hidden-applications.json")
    FileManager.default.createFile(
        atPath: targetURL.path,
        contents: Data("[]".utf8),
        attributes: [.posixPermissions: 0o600]
    )
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

    #expect(throws: VisibilityJournalFailure.unsafeFile) {
        try VisibilityJournal(fileURL: linkURL).load()
    }
}

@Test func visibilityJournalRejectsFilesThatExceedTheReadLimit() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let fileURL = directory.appendingPathComponent("hidden-applications.json")
    FileManager.default.createFile(
        atPath: fileURL.path,
        contents: Data(repeating: 0x20, count: VisibilityJournal.maximumBytes + 1),
        attributes: [.posixPermissions: 0o600]
    )

    #expect(throws: VisibilityJournalFailure.oversizedFile) {
        try VisibilityJournal(fileURL: fileURL).load()
    }
}

private func testPNG(width: Int, height: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
