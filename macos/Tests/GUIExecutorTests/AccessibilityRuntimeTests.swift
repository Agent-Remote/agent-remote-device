import DeviceProtocol
import Foundation
@testable import GUIExecutor
import Testing

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
        previous: original,
        current: [axNode(index: 0, title: "Replacement")],
        truncated: true
    )
    #expect(reset.kind == .full)
    #expect(reset.reset)
    #expect(reset.truncated)
    #expect(reset.removed.isEmpty)
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
}

@Test func accessibilityTraversalElidesOnlySemanticallyEmptySingleChildWrappers() {
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
    #expect(!AccessibilityTraversal.shouldElideWrapper(
        role: "AXUnknown",
        hasSemanticText: false,
        isSettable: false,
        actions: [],
        childCount: 2
    ))
}

@MainActor
@Test func textInsertionDoesNotMaterializeAccessibilityPlaceholder() {
    #expect(ActionExecutor.insertionValue(
        current: "Work with ChatGPT",
        placeholder: "Work with ChatGPT",
        text: "hello"
    ) == "hello")
    #expect(ActionExecutor.insertionValue(
        current: "existing ",
        placeholder: "Work with ChatGPT",
        text: "hello"
    ) == "existing hello")
}

private func axNode(index: UInt32, title: String) -> AccessibilityNode {
    AccessibilityNode(
        index: index,
        parentIndex: index == 0 ? nil : 0,
        depth: index == 0 ? 0 : 1,
        role: index == 0 ? "AXWindow" : "AXButton",
        title: title,
        label: nil,
        value: nil,
        placeholder: nil,
        url: nil,
        frame: [0, 0, 20, 20],
        settable: false,
        actions: index == 0 ? [] : ["AXPress"]
    )
}
