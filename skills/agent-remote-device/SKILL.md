---
name: agent-remote-device
description: Operate approved macOS applications through the agent-remote-device MCP tools. Use for screenshots, clicking, pointer movement, scrolling, dragging, keyboard input, zooming, waiting, clipboard reads, multi-application workflows, and recovery from device action errors.
---

# Agent Remote Device

Use the live MCP tool schemas as the authority for tool names and arguments. Follow the workflow and state rules below instead of duplicating parameter definitions.

## Operate From Fresh Visual State

1. Start with `screenshot`, passing the application name or bundle identifier when the user names a target or multiple applications are approved.
2. Locate controls only from the returned image. Never guess coordinates from memory, a prior session, or another application.
3. Perform one logical action at a time unless a short key sequence is unambiguous.
4. Treat the screenshot returned by a successful action as the new coordinate source. Do not keep using older image coordinates.
5. Verify consequential actions from the returned screenshot before continuing.

A turn boundary, resumed session, changed window, or `fresh_screenshot_required` response invalidates prior coordinates. Take a new screenshot before another input action.

## Handle Applications

- Use a named `screenshot` to bring an approved application to the foreground and bind subsequent actions to it.
- In multi-application workflows, take a named screenshot whenever switching targets.
- Do not act on one application using a screenshot captured from another.
- Prefer a bundle identifier when an application display name is ambiguous.
- Expect the device to reactivate the screenshot-bound application before each input operation.

## Handle Images And Zoom

- Interpret all input coordinates relative to the latest returned image.
- After `zoom`, interpret coordinates relative to the zoomed image; the device maps them back to the corresponding screen region.
- Use the live `zoom` schema. A zoom argument is a region, not a point coordinate.
- If a window moves, resizes, closes, changes display, or changes application identity, take a new named screenshot rather than retrying stale coordinates.

## Handle Text And Clipboard

- Click and visually confirm the intended text field before typing.
- Use key combinations only in formats accepted by the live tool schema.
- Call `read_clipboard` only after a successful screenshot has bound the approved application.
- Clipboard reads require explicit clipboard approval for that application. They return bounded text without changing the clipboard or producing a new screenshot.
- Preserve clipboard whitespace and line breaks when the user requests exact content. Do not claim a direct read succeeded when only copy-and-paste verification was performed.

## Recover From Errors

- `fresh_screenshot_required`, `approved_application_changed`, `approved_window_changed`, or `display_layout_changed`: take a fresh named screenshot and re-locate the target.
- `control_level_denied`: stop the requested input sequence and report that the session needs the appropriate local control approval.
- `clipboard_access_denied`: report that clipboard access must be selected during local approval.
- `accessibility_permission_missing` or `screen_recording_permission_missing`: stop and report the exact missing macOS permission.
- Application-not-running, activation-rejected, activation-timeout, or identity-mismatch errors: stop and report the exact code; do not substitute another application.
- Parameter or unsupported-key errors: inspect the live schema, correct the request, and retry only when the intended operation is unchanged.
- Transport EOF, TLS failure, or a dropped device connection is a channel failure, not a coordinate error. Report it separately and avoid replaying an action whose execution status is unknown.

Preserve the complete device error code and message in failure reports. Do not replace a concrete device error with a generic statement.

## Respect User Intent

- Do not send, submit, delete, purchase, publish, or confirm destructive actions unless the user explicitly requested that outcome.
- Stop after the first failed step when the user requests a strict test sequence.
- Summarize actual tool results, not inferred success.
