import CoreGraphics
import DeviceProtocol
import Foundation
@testable import GUIExecutor
import Testing

@Test func accessibilityActionsExcludeProtocolUnsafeSystemMetadata() {
    #expect(AccessibilityTraversal.protocolSafeActions([
        "AXPress",
        "AXShowMenu",
        "AXCustom\nAction",
        "AXCustom\u{0000}Action",
        "",
        String(repeating: "A", count: 129),
    ]) == ["AXPress", "AXShowMenu"])
}

@MainActor
@Test func editableFocusFallsBackToPressOnlyForNativeAppleApplications() {
    #expect(AccessibilityRuntime.shouldFallbackEditableTextFocusToPress(
        applicationBundleIdentifier: "com.apple.Maps",
        actions: ["AXPress", "AXShowMenu"]
    ))
    #expect(!AccessibilityRuntime.shouldFallbackEditableTextFocusToPress(
        applicationBundleIdentifier: "com.apple.Maps",
        actions: ["AXShowMenu"]
    ))
    #expect(!AccessibilityRuntime.shouldFallbackEditableTextFocusToPress(
        applicationBundleIdentifier: "com.google.Chrome",
        actions: ["AXPress"]
    ))
    #expect(!AccessibilityRuntime.shouldFallbackEditableTextFocusToPress(
        applicationBundleIdentifier: nil,
        actions: ["AXPress"]
    ))
}

@MainActor
@Test func accessibilityValueFreshnessTreatsMissingEmptyValueAsCleared() {
    #expect(AccessibilityRuntime.valueMatches(nil, expectedValue: ""))
    #expect(AccessibilityRuntime.valueMatches("", expectedValue: ""))
    #expect(!AccessibilityRuntime.valueMatches(nil, expectedValue: "text"))
    #expect(!AccessibilityRuntime.valueMatches("old", expectedValue: ""))
    #expect(AccessibilityRuntime.valueMatches("text", expectedValue: "text"))
    #expect(AccessibilityRuntime.valueMatches(
        "\nWork with ChatGPT",
        expectedValue: "",
        placeholder: "Work with ChatGPT"
    ))
    #expect(!AccessibilityRuntime.valueMatches(
        "existing text",
        expectedValue: "",
        placeholder: "Work with ChatGPT"
    ))
    #expect(!AccessibilityRuntime.valueMatches(
        "Work with ChatGPT",
        expectedValue: "different text",
        placeholder: "Work with ChatGPT"
    ))
}

@MainActor
@Test func accessibilityDiffUsesStableIndexesAndResetsLargeChanges() {
    let original = [
        axNode(index: 0, title: "Window"),
        axNode(index: 1, title: "Back"),
        axNode(index: 2, title: "Continue"),
    ]
    let updated = [
        axNode(index: 0, title: "Window"),
        axNode(index: 1, title: "Back"),
        axNode(index: 2, title: "Next"),
    ]
    let diff = AccessibilityRuntime.diff(
        previous: original,
        current: updated,
        truncated: false
    )
    #expect(diff.kind == .diff)
    #expect(diff.nodes.map(\.index) == [2])
    #expect(diff.removed.isEmpty)

    let reset = AccessibilityRuntime.diff(
        previous: [
            axNode(index: 0, role: "AXWindow", title: "Chrome"),
            axNode(index: 1, parentIndex: 0, role: "AXWebArea", title: "Before", url: "https://before.test"),
            axNode(index: 2, parentIndex: 1, role: "AXHeading", title: "Before"),
        ],
        current: [
            axNode(index: 0, role: "AXWindow", title: "Chrome"),
            axNode(index: 1, parentIndex: 0, role: "AXWebArea", title: "After", url: "https://after.test"),
        ],
        truncated: true
    )
    #expect(reset.kind == .full)
    #expect(reset.reset)
    #expect(reset.truncated)
    #expect(reset.removed.isEmpty)
}

@MainActor
@Test func truncatedDiffCarriesBoundedNavigationAnchors() {
    let previous = [
        axNode(index: 0, role: "AXWindow", title: "Chrome"),
        axNode(
            index: 1,
            parentIndex: 0,
            role: "AXWebArea",
            title: "Search results",
            url: "https://example.test/search"
        ),
        axNode(index: 2, parentIndex: 1, role: "AXHeading", title: "Search results"),
        axNode(index: 3, parentIndex: 0, role: "AXTextField", title: "Address"),
    ]
    let current = previous.enumerated().map { offset, node in
        offset == 3
            ? axNode(index: 3, parentIndex: 0, role: "AXTextField", title: "Address focused")
            : node
    }

    let diff = AccessibilityRuntime.diff(
        previous: previous,
        current: current,
        truncated: true
    )

    #expect(diff.kind == .diff)
    #expect(!diff.reset)
    #expect(diff.truncated)
    #expect(diff.nodes.map(\.index) == [1, 2, 3])
}

@MainActor
@Test func largeChromeUiChangeStaysDiffWhenPageIdentityIsStable() {
    let previous = [
        axNode(index: 0, role: "AXWindow", title: "Chrome"),
        axNode(index: 1, parentIndex: 0, role: "AXWebArea", title: "Results", url: "https://example.test/results"),
        axNode(index: 2, parentIndex: 0, role: "AXTextField", title: "Address"),
        axNode(index: 3, parentIndex: 1, role: "AXHeading", title: "Results"),
    ]
    let focused = [
        previous[0], previous[1], previous[3],
        axNode(index: 4, parentIndex: 0, role: "AXTextField", title: "Address focused"),
        axNode(index: 5, parentIndex: 0, role: "AXList", title: "Suggestions"),
        axNode(index: 6, parentIndex: 5, role: "AXStaticText", title: "Suggestion"),
    ]

    let diff = AccessibilityRuntime.diff(previous: previous, current: focused, truncated: true)

    #expect(diff.kind == .diff)
    #expect(!diff.reset)
    #expect(diff.removed == [2])
}

@MainActor
@Test func largeOverlayDismissalStaysDiffWhenBoundedStateOmitsPageIdentity() {
    let previous = [
        axNode(index: 0, role: "AXWindow", title: "Chrome"),
        axNode(index: 1, parentIndex: 0, role: "AXGroup", title: "Find bar"),
        axNode(index: 2, parentIndex: 1, role: "AXTextField", title: "Find"),
        axNode(index: 3, parentIndex: 1, role: "AXButton", title: "Close"),
    ]
    let current = [previous[0]]

    let diff = AccessibilityRuntime.diff(
        previous: previous,
        current: current,
        truncated: true
    )

    #expect(diff.kind == .diff)
    #expect(!diff.reset)
    #expect(diff.nodes.isEmpty)
    #expect(diff.removed == [1, 2, 3])
}

@MainActor
@Test func largeOverlayAppearanceStaysDiffWhenBoundedStateOmitsPageAndWindowIdentity() {
    let previous = [
        axNode(index: 0, role: "AXWindow", title: "Example Domain - Google Chrome"),
        axNode(index: 1, parentIndex: 0, role: "AXWebArea", title: "Example Domain", url: "https://example.com"),
        axNode(index: 2, parentIndex: 1, role: "AXHeading", title: "Example Domain"),
        axNode(index: 3, parentIndex: 1, role: "AXStaticText", title: "Example text"),
    ]
    let current = [
        axNode(index: 0, role: "AXGroup", title: "Find bar"),
        axNode(index: 1, parentIndex: 0, role: "AXTextField", title: "Find"),
        axNode(index: 2, parentIndex: 0, role: "AXButton", title: "Previous match"),
        axNode(index: 3, parentIndex: 0, role: "AXButton", title: "Next match"),
        axNode(index: 4, parentIndex: 0, role: "AXButton", title: "Close"),
    ]

    let diff = AccessibilityRuntime.diff(
        previous: previous,
        current: current,
        truncated: true
    )

    #expect(diff.kind == .diff)
    #expect(!diff.reset)
    #expect(diff.nodes == current)
    #expect(diff.removed.isEmpty)
}

@MainActor
@Test func largePageReplacementResetsWhenPageIdentityChanges() {
    let previous = [
        axNode(index: 0, role: "AXWindow", title: "Chrome"),
        axNode(index: 1, parentIndex: 0, role: "AXWebArea", title: "Before", url: "https://before.test"),
        axNode(index: 2, parentIndex: 1, role: "AXHeading", title: "Before"),
        axNode(index: 3, parentIndex: 1, role: "AXLink", title: "Before link"),
    ]
    let current = [
        previous[0],
        axNode(index: 1, parentIndex: 0, role: "AXWebArea", title: "After", url: "https://after.test"),
        axNode(index: 2, parentIndex: 1, role: "AXHeading", title: "After"),
        axNode(index: 3, parentIndex: 1, role: "AXLink", title: "After link"),
    ]

    let reset = AccessibilityRuntime.diff(
        previous: previous,
        current: current,
        truncated: true
    )

    #expect(reset.kind == .full)
    #expect(reset.reset)
    #expect(reset.nodes == current)
    #expect(reset.removed.isEmpty)
}

@MainActor
@Test func pageIdentityMetadataRequiresATitledOrAddressedWebArea() {
    #expect(!AccessibilityRuntime.hasPageIdentity(in: []))
    #expect(!AccessibilityRuntime.hasPageIdentity(in: [
        axNode(index: 0, role: "AXWindow", title: "Chrome"),
        axNode(index: 1, parentIndex: 0, role: "AXWebArea", title: ""),
    ]))
    #expect(AccessibilityRuntime.hasPageIdentity(in: [
        axNode(index: 0, role: "AXWebArea", title: "Example Domain"),
    ]))
    #expect(AccessibilityRuntime.hasPageIdentity(in: [
        axNode(index: 0, role: "AXWebArea", title: "", url: "https://example.com"),
    ]))
}

@Test func chromeTabElisionKeepsSelectedAndWebContentRadios() {
    #expect(AccessibilityTraversal.shouldPruneInactiveBrowserChromeSubtree(
        applicationBundleIdentifier: "com.google.Chrome",
        role: "AXRadioButton",
        selected: false,
        insideWebArea: false
    ))
    #expect(!AccessibilityTraversal.shouldPruneInactiveBrowserChromeSubtree(
        applicationBundleIdentifier: "com.google.Chrome",
        role: "AXRadioButton",
        selected: true,
        insideWebArea: false
    ))
    #expect(!AccessibilityTraversal.shouldPruneInactiveBrowserChromeSubtree(
        applicationBundleIdentifier: "com.google.Chrome",
        role: "AXRadioButton",
        selected: false,
        value: "1",
        insideWebArea: false
    ))
    #expect(!AccessibilityTraversal.shouldPruneInactiveBrowserChromeSubtree(
        applicationBundleIdentifier: "com.google.Chrome",
        role: "AXRadioButton",
        selected: false,
        insideWebArea: true
    ))
    #expect(!AccessibilityTraversal.shouldPruneInactiveBrowserChromeSubtree(
        applicationBundleIdentifier: "com.apple.Safari",
        role: "AXRadioButton",
        selected: false,
        insideWebArea: false
    ))
}

@Test func chromePrunesTopBookmarkToolbarWithoutDroppingEssentialBrowserControls() {
    let window = CGRect(x: 0, y: 25, width: 1_800, height: 1_044)
    #expect(AccessibilityTraversal.shouldPruneLowValueBrowserChromeSubtree(
        applicationBundleIdentifier: "com.google.Chrome",
        role: "AXToolbar",
        label: "Bookmarks",
        frame: CGRect(x: 0, y: 86, width: 1_800, height: 34),
        windowFrame: window,
        insideWebArea: false
    ))
    #expect(!AccessibilityTraversal.shouldPruneLowValueBrowserChromeSubtree(
        applicationBundleIdentifier: "com.google.Chrome",
        role: "AXToolbar",
        label: nil,
        frame: CGRect(x: 0, y: 46, width: 1_800, height: 34),
        windowFrame: window,
        insideWebArea: false
    ))
    #expect(!AccessibilityTraversal.shouldPruneLowValueBrowserChromeSubtree(
        applicationBundleIdentifier: "com.google.Chrome",
        role: "AXToolbar",
        label: "Downloads",
        frame: CGRect(x: 1_200, y: 86, width: 400, height: 34),
        windowFrame: window,
        insideWebArea: false
    ))
    #expect(!AccessibilityTraversal.shouldPruneLowValueBrowserChromeSubtree(
        applicationBundleIdentifier: "com.google.Chrome",
        role: "AXToolbar",
        label: "Page toolbar",
        frame: CGRect(x: 0, y: 130, width: 1_800, height: 34),
        windowFrame: window,
        insideWebArea: true
    ))
}

@Test func accessibilityTraversalBoundsPreferredQueueStarvation() {
    #expect(!AccessibilityTraversal.shouldVisitStandardQueue(
        preferredQueueBurstCount: 3,
        hasStandardElements: true
    ))
    #expect(AccessibilityTraversal.shouldVisitStandardQueue(
        preferredQueueBurstCount: 4,
        hasStandardElements: true
    ))
    #expect(!AccessibilityTraversal.shouldVisitStandardQueue(
        preferredQueueBurstCount: 4,
        hasStandardElements: false
    ))
}

@Test func accessibilityTraversalDoesNotInjectFocusedWebAreaAheadOfWindowRoot() {
    #expect(!AccessibilityTraversal.shouldPrioritizeFocusedElement(role: "AXWebArea"))
    #expect(AccessibilityTraversal.shouldPrioritizeFocusedElement(role: "AXTextArea"))
    #expect(AccessibilityTraversal.shouldPrioritizeFocusedElement(role: "AXTextField"))
}

@MainActor
@Test func navigationFingerprintIgnoresChromeUiNoiseButTracksPageIdentity() {
    let baseline = [
        axNode(
            index: 0,
            role: "AXWebArea",
            title: "Wikipedia",
            url: "https://www.wikipedia.org/"
        ),
        axNode(index: 1, role: "AXRadioButton", title: "Memory 100 MB"),
    ]
    let chromeNoise = [
        axNode(
            index: 0,
            role: "AXWebArea",
            title: "Wikipedia",
            url: "https://www.wikipedia.org/"
        ),
        axNode(index: 1, role: "AXRadioButton", title: "Memory 110 MB"),
    ]
    let navigated = [
        axNode(
            index: 0,
            role: "AXWebArea",
            title: "Search results",
            url: "https://example.test/results"
        ),
        axNode(index: 1, role: "AXRadioButton", title: "Memory 110 MB"),
    ]

    let before = AccessibilityRuntime.stabilityFingerprint(nodes: baseline, truncated: false)
    let noisy = AccessibilityRuntime.stabilityFingerprint(nodes: chromeNoise, truncated: false)
    let after = AccessibilityRuntime.stabilityFingerprint(nodes: navigated, truncated: false)
    #expect(before.content == noisy.content)
    #expect(before.meaningful == noisy.meaningful)
    #expect(before.content != after.content)
    #expect(before.meaningful != after.meaningful)
}

@MainActor
@Test func navigationSettleFingerprintIgnoresLatePeripheralAndDeepPageChurn() {
    let baseline = [
        axNode(index: 0, role: "AXWindow", title: "Chrome"),
        axNode(index: 1, parentIndex: 0, role: "AXToolbar", title: "Bookmarks"),
        axNode(index: 2, parentIndex: 0, role: "AXWebArea", title: "Results", url: "https://example.test/results"),
        axNode(index: 3, parentIndex: 2, role: "AXHeading", title: "Results"),
    ] + (0 ..< 24).map {
        axNode(index: UInt32($0 + 4), parentIndex: 2, role: "AXStaticText", title: "lead-\($0)")
    }
    let lateChurn = baseline + [
        axNode(index: 40, parentIndex: 1, role: "AXRadioButton", title: "Memory 110 MB"),
        axNode(index: 41, parentIndex: 2, role: "AXStaticText", title: "lazy footer"),
    ]
    let headingChanged = baseline.map { node in
        node.index == 3
            ? axNode(index: 3, parentIndex: 2, role: "AXHeading", title: "Updated results")
            : node
    }

    let before = AccessibilityRuntime.stabilityFingerprint(nodes: baseline, truncated: false)
    let noisy = AccessibilityRuntime.stabilityFingerprint(nodes: lateChurn, truncated: false)
    let updated = AccessibilityRuntime.stabilityFingerprint(nodes: headingChanged, truncated: false)
    #expect(before.content == noisy.content)
    #expect(before.content != updated.content)
}

@MainActor
@Test func settleFingerprintTracksPressedElementDisappearanceWithoutTreatingPeripheralChurnAsNavigation() {
    let baseline = [
        axNode(index: 0, role: "AXWindow", title: "Chrome"),
        axNode(index: 1, parentIndex: 0, role: "AXWebArea", title: "Example", url: "https://example.test/"),
        axNode(index: 2, parentIndex: 0, role: "AXButton", title: "Close"),
    ]
    let afterPress = baseline.filter { $0.index != 2 }

    let before = AccessibilityRuntime.stabilityFingerprint(
        nodes: baseline,
        truncated: false,
        trackingElementIndex: 2
    )
    let after = AccessibilityRuntime.stabilityFingerprint(
        nodes: afterPress,
        truncated: false,
        trackingElementIndex: 2
    )

    #expect(before.content == after.content)
    #expect(before.meaningful == after.meaningful)
    #expect(before.trackedElementPresent == true)
    #expect(after.trackedElementPresent == false)
    #expect(before.trackedElementContent != nil)
    #expect(after.trackedElementContent == nil)
}

@MainActor
@Test func settleFingerprintTracksPressedElementSemanticChange() {
    let baseline = [
        axNode(index: 0, role: "AXWebArea", title: "Settings", url: "https://example.test/"),
        axNode(index: 1, parentIndex: 0, role: "AXCheckBox", title: "Enabled", value: "0"),
    ]
    let toggled = [
        baseline[0],
        axNode(index: 1, parentIndex: 0, role: "AXCheckBox", title: "Enabled", value: "1"),
    ]

    let before = AccessibilityRuntime.stabilityFingerprint(
        nodes: baseline,
        truncated: false,
        trackingElementIndex: 1
    )
    let after = AccessibilityRuntime.stabilityFingerprint(
        nodes: toggled,
        truncated: false,
        trackingElementIndex: 1
    )

    #expect(before.content == after.content)
    #expect(before.meaningful == after.meaningful)
    #expect(before.trackedElementPresent == true)
    #expect(after.trackedElementPresent == true)
    #expect(before.trackedElementContent != after.trackedElementContent)
}

@Test func keyParserAcceptsCommandBracketAliases() throws {
    let command = try KeyParser.parse("cmd+[")
    let superAlias = try KeyParser.parse("super+[")
    #expect(command.keyCode == 33)
    #expect(command.flags.contains(.maskCommand))
    #expect(superAlias == command)
}

@Test func keyParserAcceptsPageNavigationAliases() throws {
    #expect(try KeyParser.parse("Page Up").keyCode == 116)
    #expect(try KeyParser.parse("PageUp").keyCode == 116)
    #expect(try KeyParser.parse("Page Down").keyCode == 121)
    #expect(try KeyParser.parse("PageDown").keyCode == 121)
    #expect(try KeyParser.parse("Home").keyCode == 115)
    #expect(try KeyParser.parse("End").keyCode == 119)
}

@Test func keyParserAcceptsBacktickBackspaceAndModifierOnlyKeys() throws {
    #expect(try KeyParser.parse("CMD+`") == ParsedKey(keyCode: 50, flags: .maskCommand))
    #expect(try KeyParser.parse("Backspace").keyCode == 51)
    let modifiers: [(String, CGKeyCode, CGEventFlags)] = [
        ("Shift", 56, .maskShift),
        ("Command", 55, .maskCommand),
        ("Control", 59, .maskControl),
        ("Option", 58, .maskAlternate),
    ]
    for (key, keyCode, flag) in modifiers {
        let parsed = try KeyParser.parse(key)
        #expect(parsed.keyCode == keyCode)
        #expect(parsed.keyDownFlags == flag)
        #expect(parsed.keyUpFlags.isEmpty)
    }
    let commandShift = try KeyParser.parse("CMD+SHIFT")
    #expect(commandShift.keyDownFlags == [.maskCommand, .maskShift])
    #expect(commandShift.keyUpFlags == .maskCommand)
    #expect(throws: ExecutionFailure.unsupportedKey) {
        try KeyParser.parse("NotAKey")
    }
}

@Test func onlyTransientAccessibilityFailuresAreRetriedDuringSettle() {
    #expect(AccessibilityFailure.windowUnavailable.isTransientDuringSettle)
    #expect(AccessibilityFailure.operationFailed.isTransientDuringSettle)
    #expect(!AccessibilityFailure.permissionMissing.isTransientDuringSettle)
    #expect(!AccessibilityFailure.staleTarget.isTransientDuringSettle)
}

@Test func accessibilityVisibilityRejectsHiddenAndOffWindowContent() {
    let window = CGRect(x: 100, y: 100, width: 800, height: 600)

    #expect(AccessibilityVisibility.isVisible(
        hidden: false,
        frame: CGRect(x: 120, y: 120, width: 40, height: 20),
        windowFrame: window,
        ancestorVisible: true
    ))
    #expect(!AccessibilityVisibility.isVisible(
        hidden: true,
        frame: CGRect(x: 120, y: 120, width: 40, height: 20),
        windowFrame: window,
        ancestorVisible: true
    ))
    #expect(!AccessibilityVisibility.isVisible(
        hidden: false,
        frame: CGRect(x: 1_000, y: 1_000, width: 40, height: 20),
        windowFrame: window,
        ancestorVisible: true
    ))
    #expect(!AccessibilityVisibility.isVisible(
        hidden: false,
        frame: nil,
        windowFrame: window,
        ancestorVisible: false
    ))
}

@MainActor
@Test func accessibilityWindowMatchingToleratesBrowserFrameDifferences() {
    let screenCaptureFrame = CGRect(x: 0, y: 39, width: 1_800, height: 1_069)
    let accessibilityFrame = CGRect(x: 0, y: 25, width: 1_800, height: 1_083)

    #expect(AccessibilityRuntime.windowMatchScore(
        screenCaptureFrame,
        accessibilityFrame
    ) > 0.95)
}

@MainActor
@Test func accessibilityWindowMatchingRanksTheExpectedWindowFirst() {
    let expected = CGRect(x: 100, y: 80, width: 1_200, height: 800)
    let sameWindow = CGRect(x: 100, y: 58, width: 1_200, height: 822)
    let otherWindow = CGRect(x: 750, y: 120, width: 900, height: 700)

    #expect(AccessibilityRuntime.windowMatchScore(sameWindow, expected)
        > AccessibilityRuntime.windowMatchScore(otherWindow, expected))
}

@MainActor
@Test func accessibilityWindowMatchingRejectsUnrelatedAndNestedWindows() {
    let expected = CGRect(x: 100, y: 80, width: 1_200, height: 800)
    let unrelated = CGRect(x: 1_500, y: 80, width: 1_200, height: 800)
    let dialog = CGRect(x: 400, y: 250, width: 500, height: 300)

    #expect(AccessibilityRuntime.windowMatchScore(unrelated, expected) == 0)
    #expect(AccessibilityRuntime.windowMatchScore(dialog, expected) < 0.7)
}

@MainActor
@Test func accessibilityWindowMatchingDisambiguatesIdenticalFramesByTitle() {
    let frame = CGRect(x: 100, y: 80, width: 1_200, height: 800)

    #expect(AccessibilityRuntime.windowMatchScore(
        frame,
        frame,
        title: "New Incognito Tab - Google Chrome",
        expectedTitle: "  New Incognito Tab  -  Google Chrome  "
    ) == 1)
    #expect(AccessibilityRuntime.windowMatchScore(
        frame,
        frame,
        title: "Agent Remote - Google Chrome",
        expectedTitle: "New Incognito Tab - Google Chrome"
    ) == 0)
    #expect(AccessibilityRuntime.windowMatchScore(
        frame,
        frame,
        title: "Agent Remote - Google Chrome",
        expectedTitle: nil
    ) == 1)
    #expect(AccessibilityRuntime.windowMatchScore(
        frame,
        frame,
        title: "Agent Remote - Google Chrome",
        expectedTitle: "Agent Remote"
    ) == 1)
    #expect(AccessibilityRuntime.windowMatchScore(
        frame,
        frame,
        title: "Agent Remote",
        expectedTitle: "Agent"
    ) == 0)
}

@MainActor
@Test func accessibilityWindowMatchingPrefersTheExactNumericWindowID() {
    let frame = CGRect(x: 100, y: 80, width: 1_200, height: 800)

    #expect(AccessibilityRuntime.windowMatchScore(
        frame,
        frame,
        windowID: 42,
        expectedWindowID: 42,
        title: "AX title format",
        expectedTitle: "ScreenCaptureKit title format"
    ) == 1)
    #expect(AccessibilityRuntime.windowMatchScore(
        frame,
        frame,
        windowID: 43,
        expectedWindowID: 42,
        title: "Matching title",
        expectedTitle: "Matching title"
    ) == 0)
    #expect(AccessibilityRuntime.windowMatchScore(
        frame,
        frame,
        windowID: nil,
        expectedWindowID: 42,
        title: "Matching title",
        expectedTitle: "Matching title"
    ) == 1)
}

@MainActor
@Test func accessibilityWindowSelectionPrefersAnExactIDOverAnIDLessAmbiguousMatch() {
    let candidates: [(windowID: CGWindowID?, score: CGFloat)] = [
        (windowID: 42, score: 1),
        (windowID: nil, score: 1),
    ]

    #expect(AccessibilityRuntime.preferredWindowMatchIndex(
        candidates: candidates,
        expectedWindowID: 42
    ) == 0)
    #expect(AccessibilityRuntime.preferredWindowMatchIndex(
        candidates: [
            (windowID: 43, score: 1),
            (windowID: nil, score: 1),
        ],
        expectedWindowID: 42
    ) == nil)
}

@MainActor
@Test func focusedAccessibilityWindowFallbackRequiresMatchingIdentityWhenAvailable() {
    let frame = CGRect(x: 0, y: 40, width: 1_800, height: 1_070)

    #expect(AccessibilityRuntime.focusedWindowCanRepresent(
        frame: frame,
        expectedFrame: frame,
        windowID: nil,
        expectedWindowID: 222_315
    ))
    #expect(AccessibilityRuntime.focusedWindowCanRepresent(
        frame: frame,
        expectedFrame: frame,
        windowID: 222_315,
        expectedWindowID: 222_315
    ))
    #expect(!AccessibilityRuntime.focusedWindowCanRepresent(
        frame: frame,
        expectedFrame: frame,
        windowID: 221_756,
        expectedWindowID: 222_315
    ))
    #expect(!AccessibilityRuntime.focusedWindowCanRepresent(
        frame: CGRect(x: 500, y: 500, width: 400, height: 300),
        expectedFrame: frame,
        windowID: nil,
        expectedWindowID: 222_315
    ))
}

@Test func accessibilityTraversalPrefersBoundedBrowserAndRowChildren() {
    #expect(AccessibilityTraversal.childAttributes(
        role: "AXWebArea",
        hasRows: false,
        hasVisibleChildren: true
    ) == ["AXVisibleChildren", "AXRows", "AXContents"])
    #expect(AccessibilityTraversal.childAttributes(
        role: "AXTable",
        hasRows: true,
        hasVisibleChildren: true
    ) == ["AXRows", "AXVisibleChildren", "AXContents"])
    #expect(AccessibilityTraversal.childAttributes(
        role: "AXWindow",
        hasRows: false,
        hasVisibleChildren: false
    ) == ["AXChildren", "AXRows", "AXContents", "AXVisibleChildren"])
    #expect(AccessibilityTraversal.usesRowBudget(role: "AXBrowser"))
    #expect(!AccessibilityTraversal.usesRowBudget(role: "AXWebArea"))
    #expect(AccessibilityTraversal.usesVisibleChildren(role: "AXWebArea"))
    #expect(!AccessibilityTraversal.usesVisibleChildren(role: "AXGroup"))
}

@Test func accessibilityTraversalElidesSemanticallyEmptyWrappers() {
    #expect(AccessibilityTraversal.shouldElideWrapper(
        role: "AXGroup",
        hasSemanticText: false,
        isSettable: false,
        actions: [],
        childCount: 1
    ))
    #expect(!AccessibilityTraversal.shouldElideWrapper(
        role: "AXGroup",
        hasSemanticText: true,
        isSettable: false,
        actions: [],
        childCount: 1
    ))
    #expect(!AccessibilityTraversal.shouldElideWrapper(
        role: "AXGroup",
        hasSemanticText: false,
        isSettable: false,
        actions: ["AXPress"],
        childCount: 1
    ))
    #expect(!AccessibilityTraversal.shouldElideWrapper(
        role: "AXWebArea",
        hasSemanticText: false,
        isSettable: false,
        actions: [],
        childCount: 1
    ))
    #expect(AccessibilityTraversal.shouldElideWrapper(
        role: "AXUnknown",
        hasSemanticText: false,
        isSettable: false,
        actions: [],
        childCount: 2
    ))
    #expect(!AccessibilityTraversal.shouldElideWrapper(
        role: "AXGroup",
        hasSemanticText: false,
        isSettable: false,
        actions: [],
        childCount: 0
    ))
}

@Test func accessibilityTraversalReservesTextForInteractiveControls() {
    #expect(AccessibilityTraversal.exposedActions(
        ["AXShowMenu", "AXScrollToVisible"],
        role: "AXStaticText"
    ).isEmpty)
    #expect(AccessibilityTraversal.exposedActions(
        ["AXPress", "AXShowMenu"],
        role: "AXButton"
    ) == ["AXPress", "AXShowMenu"])
    #expect(!AccessibilityTraversal.shouldIncludeFrame(isSettable: false, actions: []))
    #expect(AccessibilityTraversal.shouldIncludeFrame(isSettable: true, actions: []))
    #expect(AccessibilityTraversal.shouldIncludeFrame(
        isSettable: false,
        actions: ["AXPress"]
    ))
    #expect(AccessibilityTraversal.isInteractionPriority(
        role: "AXTextArea",
        isSettable: false,
        actions: []
    ))
    #expect(AccessibilityTraversal.isInteractionPriority(
        role: "AXGroup",
        isSettable: true,
        actions: []
    ))
    #expect(!AccessibilityTraversal.isInteractionPriority(
        role: "AXStaticText",
        isSettable: false,
        actions: []
    ))
    #expect(AccessibilityTraversal.supportsSettableValue(role: "AXTextArea"))
    #expect(AccessibilityTraversal.supportsSettableValue(role: "AXSlider"))
    #expect(!AccessibilityTraversal.supportsSettableValue(role: "AXGroup"))
    #expect(AccessibilityTraversal.supportsSettableValue(
        role: "AXGroup",
        contentPriority: 2
    ))
    #expect(AccessibilityTraversal.textPriority(
        role: "AXStaticText",
        isSettable: false,
        actions: []
    ) == .structural)
    #expect(AccessibilityTraversal.textPriority(
        role: "AXButton",
        isSettable: false,
        actions: ["AXPress"]
    ) == .interactive)
    #expect(AccessibilityTraversal.textPriority(
        role: "AXTextArea",
        isSettable: true,
        actions: []
    ) == .editable)
    #expect(AccessibilityTraversal.textBudgetLimit(
        totalBytes: 16 * 1_024,
        priority: .structural
    ) == 12 * 1_024)
    #expect(AccessibilityTraversal.textBudgetLimit(
        totalBytes: 16 * 1_024,
        priority: .interactive
    ) == 14 * 1_024)
    #expect(AccessibilityTraversal.textBudgetLimit(
        totalBytes: 16 * 1_024,
        priority: .editable
    ) == 16 * 1_024)
}

@Test func accessibilityTraversalBoundsRequiredTextByUTF8Bytes() {
    #expect(AccessibilityTraversal.boundedText(
        "AXButton",
        maximumCharacters: 80,
        maximumBytes: 4
    ) == "AXBu")
    #expect(AccessibilityTraversal.boundedText(
        "按钮",
        maximumCharacters: 80,
        maximumBytes: 3
    ) == "按")
    #expect(AccessibilityTraversal.boundedText(
        "AXButton",
        maximumCharacters: 80,
        maximumBytes: 0
    ) == nil)
}

@Test func accessibilityTraversalKeepsBothEndsOfBoundedContainers() {
    #expect(AccessibilityTraversal.childTraversalLimit(
        count: 200,
        maximumPerContainer: 20,
        role: "AXList"
    ) == 20)
    #expect(AccessibilityTraversal.childTraversalLimit(
        count: 200,
        maximumPerContainer: 20,
        role: "AXGroup"
    ) == 200)
    #expect(AccessibilityTraversal.boundedChildOffsets(count: 4, maximum: 4) == [3, 0, 2, 1])
    #expect(AccessibilityTraversal.boundedChildOffsets(count: 8, maximum: 5) == [7, 0, 6, 1, 5])
    #expect(AccessibilityTraversal.boundedChildOffsets(count: 0, maximum: 5).isEmpty)
}

@Test func accessibilityTraversalProcessesSiblingFrontiersBeforeDescendants() {
    var pending = ["root"]
    var cursor = 0
    var visited: [String] = []
    let children = [
        "root": ["sidebar", "main"],
        "sidebar": ["history-1", "history-2"],
        "main": ["composer"],
    ]
    while cursor < pending.count {
        let value = pending[cursor]
        cursor += 1
        visited.append(value)
        pending.append(contentsOf: children[value] ?? [])
    }

    #expect(visited == ["root", "sidebar", "main", "history-1", "history-2", "composer"])
    #expect(visited.firstIndex(of: "main")! < visited.firstIndex(of: "history-1")!)
}

@Test func accessibilityTraversalPrioritizesPrimaryContentButNotWindowOrSidebar() {
    let window = CGRect(x: 0, y: 40, width: 1_280, height: 800)
    #expect(AccessibilityTraversal.contentPriority(
        window,
        windowFrame: window,
        depth: 0
    ) == 0)
    #expect(AccessibilityTraversal.contentPriority(
        CGRect(x: 0, y: 40, width: 275, height: 800),
        windowFrame: window,
        depth: 2
    ) == 0)
    #expect(AccessibilityTraversal.contentPriority(
        CGRect(x: 275, y: 46, width: 1_005, height: 787),
        windowFrame: window,
        depth: 2
    ) == 1)
    #expect(AccessibilityTraversal.contentPriority(
        CGRect(x: 0, y: 140, width: 1_280, height: 700),
        windowFrame: window,
        depth: 2
    ) == 1)
    #expect(AccessibilityTraversal.contentPriority(
        CGRect(x: 410, y: 719, width: 736, height: 98),
        windowFrame: window,
        depth: 6
    ) == 2)
}

@MainActor
@Test func textInsertionDoesNotMaterializeAccessibilityPlaceholder() {
    #expect(ActionExecutor.insertionValue(
        current: "Work with ChatGPT",
        placeholder: "Work with ChatGPT",
        text: "hello"
    ) == "hello")
    #expect(ActionExecutor.insertionValue(
        current: "\nWork with ChatGPT",
        placeholder: "Work with ChatGPT",
        text: "hello"
    ) == "hello")
    #expect(ActionExecutor.insertionValue(
        current: "existing ",
        placeholder: "Work with ChatGPT",
        text: "hello"
    ) == "existing hello")
    #expect(ActionExecutor.insertionValue(
        current: "https://old.example/path",
        placeholder: nil,
        text: "https://example.com",
        selectedRange: NSRange(location: 0, length: 24)
    ) == "https://example.com")
    #expect(ActionExecutor.insertionValue(
        current: "beforeafter",
        placeholder: nil,
        text: " ",
        selectedRange: NSRange(location: 6, length: 0)
    ) == "before after")
}

@Test func accessibilityTextNormalizationSuppressesMaterializedPlaceholders() {
    #expect(AccessibilityTextNormalization.placeholder(
        nil,
        value: "\nWork with ChatGPT",
        label: "Work with ChatGPT",
        role: "AXTextArea",
        isSettable: true
    ) == "Work with ChatGPT")
    #expect(AccessibilityTextNormalization.placeholder(
        nil,
        value: "existing text",
        label: "Work with ChatGPT",
        role: "AXTextArea",
        isSettable: true
    ) == nil)
    #expect(AccessibilityTextNormalization.placeholder(
        nil,
        value: "Work with ChatGPT",
        label: "Work with ChatGPT",
        role: "AXStaticText",
        isSettable: false
    ) == nil)
    #expect(AccessibilityTextNormalization.value(
        "\nWork with ChatGPT",
        placeholder: "Work with ChatGPT"
    ) == nil)
    #expect(AccessibilityTextNormalization.value(
        "existing Work with ChatGPT",
        placeholder: "Work with ChatGPT"
    ) == "existing Work with ChatGPT")
    #expect(AccessibilityTextNormalization.value(
        "existing text",
        placeholder: nil
    ) == "existing text")
}

private func axNode(
    index: UInt32,
    parentIndex: UInt32? = nil,
    role: String? = nil,
    title: String,
    url: String? = nil,
    value: String? = nil
) -> AccessibilityNode {
    AccessibilityNode(
        index: index,
        parentIndex: parentIndex ?? (index == 0 ? nil : 0),
        depth: index == 0 ? 0 : 1,
        role: role ?? (index == 0 ? "AXWindow" : "AXButton"),
        title: title,
        label: nil,
        value: value,
        placeholder: nil,
        url: url,
        frame: [0, 0, 20, 20],
        settable: false,
        actions: index == 0 ? [] : ["AXPress"]
    )
}
@MainActor
@Test func editableTextRolesUseTheShortFocusSettlePath() {
    #expect(AccessibilityRuntime.isEditableTextRole("AXTextField", settable: true))
    #expect(AccessibilityRuntime.isEditableTextRole("AXTextArea", settable: true))
    #expect(AccessibilityRuntime.isEditableTextRole("AXSearchField", settable: true))
    #expect(!AccessibilityRuntime.isEditableTextRole("AXButton", settable: true))
    #expect(!AccessibilityRuntime.isEditableTextRole("AXTextField", settable: false))
}

@MainActor
@Test func editablePressUsesDirectFocusInsteadOfAXPress() {
    #expect(AccessibilityRuntime.shouldFocusEditableTextDirectly(
        role: "AXTextArea",
        settable: true
    ))
    #expect(AccessibilityRuntime.shouldFocusEditableTextDirectly(
        role: "AXSearchField",
        settable: true
    ))
    #expect(!AccessibilityRuntime.shouldFocusEditableTextDirectly(
        role: "AXButton",
        settable: false
    ))
}

@MainActor
@Test func pageScrollFallbackUsesVisibleContentRatioAndDirection() throws {
    let down = try #require(AccessibilityRuntime.pageScrollValue(
        current: 0.2,
        minimum: 0,
        maximum: 1,
        viewportExtent: 400,
        contentExtent: 1_600,
        direction: .down,
    ))
    #expect(abs(down - 0.5) < 0.000_001)

    let up = try #require(AccessibilityRuntime.pageScrollValue(
        current: 0.5,
        minimum: 0,
        maximum: 1,
        viewportExtent: 400,
        contentExtent: 1_600,
        direction: .up
    ))
    #expect(abs(up - 0.2) < 0.000_001)
}

@MainActor
@Test func pageScrollFallbackUsesBoundedDefaultAndRecognizesBoundary() throws {
    let right = try #require(AccessibilityRuntime.pageScrollValue(
        current: 0.95,
        minimum: 0,
        maximum: 1,
        viewportExtent: 400,
        contentExtent: nil,
        direction: .right
    ))
    #expect(right == 1)
    let boundary = try #require(AccessibilityRuntime.pageScrollValue(
        current: 1,
        minimum: 0,
        maximum: 1,
        viewportExtent: 400,
        contentExtent: nil,
        direction: .down
    ))
    #expect(boundary == 1)
    #expect(AccessibilityRuntime.pageScrollValue(
        current: 0,
        minimum: 0,
        maximum: 0,
        viewportExtent: 400,
        contentExtent: 1_600,
        direction: .down
    ) == nil)
}

@MainActor
@Test func wheelFallbackMapsWindowRelativeFrameIntoScreenCoordinates() throws {
    let window = CGRect(x: 600, y: 200, width: 800, height: 600)
    let screen = try #require(AccessibilityRuntime.visibleScreenFrame(
        relativeFrame: [20, 50, 300, 400],
        windowFrame: window
    ))
    #expect(screen == CGRect(x: 620, y: 250, width: 300, height: 400))
    #expect(AccessibilityRuntime.visibleScreenFrame(
        relativeFrame: [900, 0, 100, 100],
        windowFrame: window
    ) == nil)
}

@MainActor
@Test func verifiedScrollPositionHandlesMovementAndBoundaries() {
    let middle = AccessibilityScrollPosition(value: 40, minimum: 0, maximum: 100)
    #expect(!middle.isAtBoundary(for: .down))
    #expect(!middle.isAtBoundary(for: .up))
    #expect(AccessibilityScrollPosition(value: 70, minimum: 0, maximum: 100)
        .moved(from: middle, in: .down))
    #expect(AccessibilityScrollPosition(value: 10, minimum: 0, maximum: 100)
        .moved(from: middle, in: .up))
    #expect(!AccessibilityScrollPosition(value: 40, minimum: 0, maximum: 100)
        .moved(from: middle, in: .down))
    #expect(AccessibilityScrollPosition(value: 0, minimum: 0, maximum: 100)
        .isAtBoundary(for: .up))
    #expect(AccessibilityScrollPosition(value: 100, minimum: 0, maximum: 100)
        .isAtBoundary(for: .down))

    let geometryBefore = AccessibilityScrollPosition(
        value: 20,
        minimum: 0,
        maximum: 100,
        movementValue: 280
    )
    #expect(AccessibilityScrollPosition(
        value: 18,
        minimum: 0,
        maximum: 100,
        movementValue: 310
    ).moved(from: geometryBefore, in: .down))
    #expect(!AccessibilityScrollPosition(
        value: 18,
        minimum: 0,
        maximum: 100,
        movementValue: 310
    ).moved(from: geometryBefore, in: .up))
}
