import Foundation

public enum ActionRequestDecodingFailure: Error, Equatable, Sendable {
    case invalidStructure
    case invalidIdentifier
    case invalidDate
}

public extension ActionRequest {
    static func decodeStrict(
        _ data: Data,
        requiresLowercaseIdentifiers: Bool = false
    ) throws -> ActionRequest {
        guard data.count <= maximumFrameBytes else {
            throw ActionRequestDecodingFailure.invalidStructure
        }
        do {
            try StrictJSON.validateUniqueObjectKeys(data)
        } catch {
            throw ActionRequestDecodingFailure.invalidStructure
        }
        guard
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "request_id", "context", "lease_until", "action"],
              let context = object["context"] as? [String: Any],
              Set(context.keys) == [
                  "user_id", "device_id", "tool_session_id", "device_session_id", "node_id",
                  "platform", "generation", "monotonic_sequence",
                  "current_screenshot_generation",
              ],
              let action = object["action"] as? [String: Any],
              validActionKeys(action)
        else {
            throw ActionRequestDecodingFailure.invalidStructure
        }
        try validateCanonicalIdentifier(
            object["request_id"],
            requiresLowercase: requiresLowercaseIdentifiers
        )
        for key in ["user_id", "device_id", "tool_session_id", "device_session_id", "node_id"] {
            try validateCanonicalIdentifier(
                context[key],
                requiresLowercase: requiresLowercaseIdentifiers
            )
        }

        let decoder = JSONDecoder()
        if object["lease_until"] is String {
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                guard let date = parseISO8601(value) else {
                    throw ActionRequestDecodingFailure.invalidDate
                }
                return date
            }
        }
        let request = try decoder.decode(ActionRequest.self, from: data)
        guard request.version == protocolVersion,
              (1 ... maximumActiveDeviceSessionGeneration).contains(request.context.generation),
              request.context.monotonicSequence > 0,
              request.action.hasValidParameters
        else {
            throw ActionRequestDecodingFailure.invalidStructure
        }
        return request
    }
}

private func validateCanonicalIdentifier(
    _ value: Any?,
    requiresLowercase: Bool
) throws {
    guard let value = value as? String,
          let identifier = UUID(uuidString: value),
          identifier.uuidString.lowercased() == value.lowercased(),
          !requiresLowercase || value == value.lowercased()
    else {
        throw ActionRequestDecodingFailure.invalidIdentifier
    }
}

private func validActionKeys(_ action: [String: Any]) -> Bool {
    guard let kind = action["type"] as? String else { return false }
    let keys = Set(action.keys)
    switch kind {
    case "screenshot", "left_mouse_down", "left_mouse_up":
        return keys == ["type"]
    case "left_click", "mouse_move", "right_click", "middle_click", "double_click",
         "triple_click":
        return keys == ["type", "coordinate"]
    case "type":
        return keys == ["type", "text"]
    case "key":
        return keys == ["type", "key"]
    case "scroll":
        return keys == ["type", "delta_x", "delta_y"]
            || keys == ["type", "delta_x", "delta_y", "coordinate"]
    case "left_click_drag":
        return keys == ["type", "start", "end"]
            || keys == ["type", "start", "end", "duration_ms"]
    case "hold_key":
        return keys == ["type", "key", "duration_ms"]
    case "wait":
        return keys == ["type", "duration_ms"]
    case "zoom":
        return keys == ["type", "region"]
    default:
        return false
    }
}

private func parseISO8601(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return fractional.date(from: value) ?? plain.date(from: value)
}
