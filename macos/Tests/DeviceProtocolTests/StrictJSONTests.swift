import DeviceProtocol
import Foundation
import Testing

@Test func strictJSONRejectsLiteralEscapedAndNestedDuplicateKeys() throws {
    try StrictJSON.validateUniqueObjectKeys(Data(#"{"a":1,"nested":{"b":2}}"#.utf8))

    for value in [
        #"{"a":1,"a":2}"#,
        #"{"a":1,"\u0061":2}"#,
        #"{"outer":{"value":1,"value":2}}"#,
    ] {
        #expect(throws: StrictJSONFailure.duplicateKey) {
            try StrictJSON.validateUniqueObjectKeys(Data(value.utf8))
        }
    }
}

@Test func strictJSONRejectsInvalidGrammarAndExcessiveNesting() {
    for value in [#"{"a":01}"#, #"{"a":"\x"}"#, #"[true,]"#] {
        #expect(throws: StrictJSONFailure.self) {
            try StrictJSON.validateUniqueObjectKeys(Data(value.utf8))
        }
    }
    #expect(throws: StrictJSONFailure.nestingLimit) {
        try StrictJSON.validateUniqueObjectKeys(Data("[[[]]]".utf8), maximumDepth: 2)
    }
}

@Test func strictJSONBoundedRandomInputNeverTraps() {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    for length in 0 ..< 512 {
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        for _ in 0 ..< length {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            bytes.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        _ = try? StrictJSON.validateUniqueObjectKeys(Data(bytes))
    }
}
