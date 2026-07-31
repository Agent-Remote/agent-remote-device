import Foundation
import Testing
@testable import DeviceProtocol

@Test func decodesCrossLanguageVector() throws {
    let url = try #require(Bundle.module.url(forResource: "action-request-valid", withExtension: "json", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)
    let request = try ActionRequest.decodeStrict(data)
    #expect(request.version == protocolVersion)
    #expect(request.context.monotonicSequence == 7)
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
