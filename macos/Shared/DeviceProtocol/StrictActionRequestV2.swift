import Foundation

public extension ActionRequestV2 {
    static func decodeStrict(
        _ data: Data,
        requiresLowercaseIdentifiers: Bool = false
    ) throws -> ActionRequestV2 {
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
            Set(object.keys) == ["version", "request_id", "context", "lease_until", "observation", "action"],
            let context = object["context"] as? [String: Any],
            Set(context.keys) == [
                "user_id", "device_id", "tool_session_id", "device_session_id", "node_id",
                "platform", "generation", "monotonic_sequence", "current_state_generation",
                "current_screenshot_generation", "base_state_id",
            ],
            let observation = object["observation"] as? [String: Any],
            Set(observation.keys) == [
                "mode", "max_nodes", "max_depth", "max_text_per_node",
                "max_total_text_bytes", "max_visible_rows_per_container", "settle",
                "settle_timeout_ms", "image_profile", "region",
            ],
            let action = object["action"] as? [String: Any],
            validV2ActionKeys(action)
        else {
            throw ActionRequestDecodingFailure.invalidStructure
        }
        try validateV2Identifier(
            object["request_id"],
            requiresLowercase: requiresLowercaseIdentifiers
        )
        for key in ["user_id", "device_id", "tool_session_id", "device_session_id", "node_id"] {
            try validateV2Identifier(context[key], requiresLowercase: requiresLowercaseIdentifiers)
        }
        if context["base_state_id"] is String {
            try validateV2Identifier(
                context["base_state_id"],
                requiresLowercase: requiresLowercaseIdentifiers
            )
        } else if !(context["base_state_id"] is NSNull) {
            throw ActionRequestDecodingFailure.invalidIdentifier
        }
        if let target = action["target"] as? [String: Any] {
            guard Set(target.keys) == [
                "state_id", "state_generation", "application_digest", "window_id",
                "display_fingerprint", "element_index",
            ] else {
                throw ActionRequestDecodingFailure.invalidStructure
            }
            try validateV2Identifier(
                target["state_id"],
                requiresLowercase: requiresLowercaseIdentifiers
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = parseV2ISO8601(value) else {
                throw ActionRequestDecodingFailure.invalidDate
            }
            return date
        }
        let request = try decoder.decode(ActionRequestV2.self, from: data)
        guard request.version == protocolVersionV2,
              (1 ... maximumActiveDeviceSessionGeneration).contains(request.context.generation),
              request.context.monotonicSequence > 0,
              request.observation.hasValidParameters,
              request.action.hasValidParameters
        else {
            throw ActionRequestDecodingFailure.invalidStructure
        }
        return request
    }
}

private func validateV2Identifier(_ value: Any?, requiresLowercase: Bool) throws {
    guard let value = value as? String,
          let identifier = UUID(uuidString: value),
          identifier.uuidString.lowercased() == value.lowercased(),
          !requiresLowercase || value == value.lowercased()
    else {
        throw ActionRequestDecodingFailure.invalidIdentifier
    }
}

private func validV2ActionKeys(_ action: [String: Any]) -> Bool {
    guard let kind = action["type"] as? String else { return false }
    let keys = Set(action.keys)
    switch kind {
    case "observe":
        return keys == ["type"] || keys == ["type", "application"]
    case "coordinate":
        guard keys == ["type", "action"],
              let nested = action["action"] as? [String: Any]
        else { return false }
        return validV1ActionKeys(nested)
    case "press":
        return keys == ["type", "target"]
    case "set_value":
        return keys == ["type", "target", "value"]
    case "select_text":
        return keys == ["type", "target", "text", "selection_type"]
            || keys == ["type", "target", "text", "selection_type", "prefix"]
            || keys == ["type", "target", "text", "selection_type", "suffix"]
            || keys == ["type", "target", "text", "selection_type", "prefix", "suffix"]
    case "scroll_element":
        return keys == ["type", "target", "direction", "pages"]
    case "secondary_action":
        return keys == ["type", "target", "action_name"]
    case "read_clipboard":
        return keys == ["type"]
    default:
        return false
    }
}

private func validV1ActionKeys(_ action: [String: Any]) -> Bool {
    guard let kind = action["type"] as? String else { return false }
    let keys = Set(action.keys)
    switch kind {
    case "screenshot", "read_clipboard", "left_mouse_down", "left_mouse_up":
        return keys == ["type"]
    case "screenshot_application":
        return keys == ["type", "application"]
    case "left_click", "mouse_move", "right_click", "middle_click", "double_click", "triple_click":
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

private func parseV2ISO8601(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return fractional.date(from: value) ?? plain.date(from: value)
}
