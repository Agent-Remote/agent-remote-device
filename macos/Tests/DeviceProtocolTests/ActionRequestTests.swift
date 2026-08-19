import Foundation
import Testing
@testable import DeviceProtocol

@Test func onlyInteractiveActionsRequireTheApprovedApplicationToBeForeground() {
    #expect(!Action.screenshot.requiresForegroundApplication)
    #expect(!Action.screenshotApplication("com.apple.Safari").requiresForegroundApplication)
    #expect(!Action.readClipboard.requiresForegroundApplication)
    #expect(!Action.wait(50).requiresForegroundApplication)
    #expect(!Action.zoom(Region(x: 0, y: 0, width: 1, height: 1)).requiresForegroundApplication)
    #expect(Action.key("return").requiresForegroundApplication)
    #expect(Action.leftClick(Point(x: 0, y: 0)).requiresForegroundApplication)
}

@Test func decodesCrossLanguageVector() throws {
    let url = try #require(Bundle.module.url(forResource: "action-request-valid", withExtension: "json", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)
    let request = try ActionRequest.decodeStrict(data)
    #expect(request.version == protocolVersion)
    #expect(request.context.monotonicSequence == 7)
}

@Test func decodesCrossLanguageV2VectorAndRejectsUnknownFields() throws {
    let url = try #require(Bundle.module.url(
        forResource: "action-request-v2-valid",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    let data = try Data(contentsOf: url)
    let request = try ActionRequestV2.decodeStrict(data)
    #expect(request.version == protocolVersionV2)
    #expect(request.context.monotonicSequence == 8)
    #expect(request.observation.hasValidParameters)
    #expect(request.action.hasValidParameters)

    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var observation = try #require(object["observation"] as? [String: Any])
    observation["unbounded"] = true
    object["observation"] = observation
    #expect(throws: ActionRequestDecodingFailure.invalidStructure) {
        try ActionRequestV2.decodeStrict(JSONSerialization.data(withJSONObject: object))
    }
}

@Test func decodesCrossLanguageV2ResponseVector() throws {
    let url = try #require(Bundle.module.url(
        forResource: "action-response-v2-valid",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    let response = try JSONDecoder().decode(ActionResponseV2.self, from: Data(contentsOf: url))

    #expect(response.status == .success)
    #expect(response.monotonicSequence == 8)
    #expect(response.stateGeneration == 4)
    #expect(response.observation?.kind == .diff)
    #expect(response.observation?.nodes.first?.title == "Continue")
}

@Test func v2SetValueAcceptsAnEmptyStringForClearingEditableControls() throws {
    let target = ElementTarget(
        stateID: UUID(),
        stateGeneration: 1,
        applicationDigest: String(repeating: "a", count: 64),
        windowID: 1,
        displayFingerprint: "display",
        elementIndex: 0
    )

    #expect(ActionV2.setValue(target: target, value: "").hasValidParameters)

    let url = try #require(Bundle.module.url(
        forResource: "action-request-v2-valid",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    let data = try Data(contentsOf: url)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["action"] = [
        "type": "set_value",
        "target": [
            "state_id": target.stateID.uuidString.lowercased(),
            "state_generation": target.stateGeneration,
            "application_digest": target.applicationDigest,
            "window_id": target.windowID,
            "display_fingerprint": target.displayFingerprint,
            "element_index": target.elementIndex,
        ],
        "value": "",
    ]
    let decoded = try ActionRequestV2.decodeStrict(
        JSONSerialization.data(withJSONObject: object)
    )
    #expect(decoded.action == .setValue(target: target, value: ""))
}

@Test func strictRequestDecoderRejectsUnknownFieldsAndNoncanonicalIdentifiers() throws {
    let url = try #require(Bundle.module.url(
        forResource: "action-request-valid",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    let data = try Data(contentsOf: url)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["endpoint"] = "https://evil.test"
    #expect(throws: ActionRequestDecodingFailure.invalidStructure) {
        try ActionRequest.decodeStrict(JSONSerialization.data(withJSONObject: object))
    }

    object.removeValue(forKey: "endpoint")
    var context = try #require(object["context"] as? [String: Any])
    context["generation"] = maximumDeviceSessionGeneration
    object["context"] = context
    #expect(throws: ActionRequestDecodingFailure.invalidStructure) {
        try ActionRequest.decodeStrict(JSONSerialization.data(withJSONObject: object))
    }

    context["generation"] = 3
    object["context"] = context
    object["request_id"] = "10000000-0000-4000-8000-00000000000A"
    #expect(throws: ActionRequestDecodingFailure.invalidIdentifier) {
        try ActionRequest.decodeStrict(
            JSONSerialization.data(withJSONObject: object),
            requiresLowercaseIdentifiers: true
        )
    }
}

@Test func rejectsPointWithExtraCoordinate() throws {
    let data = Data("[1,2,3]".utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Point.self, from: data) }
}

@Test func roundTripsEveryPublicAction() throws {
    let point = Point(x: 120, y: 240)
    let actions: [Action] = [
        .screenshot,
        .screenshotApplication("ChatGPT"),
        .readClipboard,
        .leftClick(point),
        .type("hello"),
        .key("CMD+S"),
        .mouseMove(point),
        .scroll(deltaX: 0, deltaY: -300, coordinate: point),
        .leftClickDrag(start: point, end: Point(x: 300, y: 400), durationMilliseconds: 500),
        .rightClick(point),
        .middleClick(point),
        .doubleClick(point),
        .tripleClick(point),
        .leftMouseDown,
        .leftMouseUp,
        .holdKey(key: "SHIFT", durationMilliseconds: 250),
        .wait(100),
        .zoom(Region(x: 10, y: 20, width: 300, height: 200)),
    ]
    for action in actions {
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(Action.self, from: data) == action)
        #expect(action.hasValidParameters)
    }
}

@Test func rejectsOutOfBoundsActionParameters() throws {
    let decoder = JSONDecoder()
    #expect(throws: DecodingError.self) {
        try decoder.decode(Action.self, from: Data(#"{"type":"wait","duration_ms":49}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(Action.self, from: Data(#"{"type":"zoom","region":[0,0,0,10]}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(Action.self, from: Data(#"{"type":"key","key":"CMD/DELETE"}"#.utf8))
    }
}
@Test func pageNavigationKeyAliasesPassProtocolValidation() {
    for key in ["Page Up", "PageUp", "Page Down", "PageDown", "Home", "End"] {
        #expect(Action.key(key).hasValidParameters)
    }
    #expect(Action.key("CMD+[").hasValidParameters)
}
