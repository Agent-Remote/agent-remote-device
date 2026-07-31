import Foundation

public enum StrictJSONFailure: Error, Equatable, Sendable {
    case invalidStructure
    case duplicateKey
    case nestingLimit
}

public enum StrictJSON {
    public static func validateUniqueObjectKeys(
        _ data: Data,
        maximumDepth: Int = 64
    ) throws {
        guard !data.isEmpty, maximumDepth > 0 else {
            throw StrictJSONFailure.invalidStructure
        }
        var parser = StrictJSONParser(data: data, maximumDepth: maximumDepth)
        try parser.parseDocument()
    }
}

private struct StrictJSONParser {
    private let bytes: [UInt8]
    private let maximumDepth: Int
    private var index = 0

    init(data: Data, maximumDepth: Int) {
        bytes = Array(data)
        self.maximumDepth = maximumDepth
    }

    mutating func parseDocument() throws {
        skipWhitespace()
        try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw StrictJSONFailure.invalidStructure }
    }

    private mutating func parseValue(depth: Int) throws {
        guard index < bytes.count else { throw StrictJSONFailure.invalidStructure }
        switch bytes[index] {
        case 0x7B:
            try parseObject(depth: depth + 1)
        case 0x5B:
            try parseArray(depth: depth + 1)
        case 0x22:
            _ = try parseString()
        case 0x74:
            try consumeLiteral("true")
        case 0x66:
            try consumeLiteral("false")
        case 0x6E:
            try consumeLiteral("null")
        case 0x2D, 0x30 ... 0x39:
            try parseNumber()
        default:
            throw StrictJSONFailure.invalidStructure
        }
    }

    private mutating func parseObject(depth: Int) throws {
        guard depth <= maximumDepth else { throw StrictJSONFailure.nestingLimit }
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }
        var keys = Set<String>()
        while true {
            let key = try parseString()
            guard keys.insert(key).inserted else { throw StrictJSONFailure.duplicateKey }
            skipWhitespace()
            guard consume(0x3A) else { throw StrictJSONFailure.invalidStructure }
            skipWhitespace()
            try parseValue(depth: depth)
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw StrictJSONFailure.invalidStructure }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        guard depth <= maximumDepth else { throw StrictJSONFailure.nestingLimit }
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try parseValue(depth: depth)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw StrictJSONFailure.invalidStructure }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        guard index < bytes.count, bytes[index] == 0x22 else {
            throw StrictJSONFailure.invalidStructure
        }
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                let encoded = Data(bytes[start ..< index])
                guard let decoded = try? JSONDecoder().decode(String.self, from: encoded) else {
                    throw StrictJSONFailure.invalidStructure
                }
                return decoded
            }
            if byte < 0x20 { throw StrictJSONFailure.invalidStructure }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { throw StrictJSONFailure.invalidStructure }
                if bytes[index] == 0x75 {
                    guard index + 4 < bytes.count,
                          bytes[(index + 1) ... (index + 4)].allSatisfy(isHexDigit)
                    else {
                        throw StrictJSONFailure.invalidStructure
                    }
                    index += 5
                    continue
                }
                guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74]
                    .contains(bytes[index])
                else {
                    throw StrictJSONFailure.invalidStructure
                }
            }
            index += 1
        }
        throw StrictJSONFailure.invalidStructure
    }

    private mutating func parseNumber() throws {
        if consume(0x2D), index == bytes.count {
            throw StrictJSONFailure.invalidStructure
        }
        if consume(0x30) {
            if index < bytes.count, isDigit(bytes[index]) {
                throw StrictJSONFailure.invalidStructure
            }
        } else {
            guard index < bytes.count, (0x31 ... 0x39).contains(bytes[index]) else {
                throw StrictJSONFailure.invalidStructure
            }
            index += 1
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if consume(0x2E) {
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw StrictJSONFailure.invalidStructure
            }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                index += 1
            }
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw StrictJSONFailure.invalidStructure
            }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
    }

    private mutating func consumeLiteral(_ literal: StaticString) throws {
        let expected = Array(String(describing: literal).utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index ..< index + expected.count]) == expected
        else {
            throw StrictJSONFailure.invalidStructure
        }
        index += expected.count
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }
}

private func isDigit(_ byte: UInt8) -> Bool {
    (0x30 ... 0x39).contains(byte)
}

private func isHexDigit(_ byte: UInt8) -> Bool {
    isDigit(byte) || (0x41 ... 0x46).contains(byte) || (0x61 ... 0x66).contains(byte)
}
