# Browser Workflows

Load this reference only for browser tasks.

Use a dedicated browser connector or structured integration when the task needs repeatable data access and does not depend on the user's existing local browser state. Use this Computer Use path for rendered UI, existing signed-in sessions, browser chrome, or visual verification. Do not enable CDP, remote debugging, DOM injection, profile access, or cookie access as an implicit fallback.

## Navigate And Search

1. Call `observe` with the browser name or bundle identifier.
2. For a known destination, prefer one `input_text` call with either the latest address-field AX target or the browser address-bar shortcut, complete URL, and Return. Both avoid an extra focus call and remain AX-first because they use no coordinate.
3. Use a state-bound address-field action only when the browser shortcut is unavailable or the returned state requires an intermediate decision.
4. Read the returned AX state. Same-page changes normally return a diff; a real navigation may correctly return a bounded full state with `reset=true`. Do not add a fixed wait or another observation unless settle timed out or the result is insufficient.

For browser shortcuts and Back/Forward, call `act` with `type=key` and `key` only. Use macOS key names with `+` modifiers, such as `cmd+Left`, `cmd+Right`, `cmd+[`, or `cmd+]`. Do not attach the prior state fields to a keyboard action. Use `press` with the latest state binding for AX links and buttons.

Use a complete URL when the destination is known. Do not expose browser profiles, cookies, debugging ports, or DOM endpoints.

## Handle Dynamic UI

- Inspect autocomplete, permission prompts, downloads, and validation messages before selecting them.
- Prefer fresh AX element indexes for tab switching, buttons, links, and form controls.
- If a WebArea is truncated or a canvas lacks AX semantics, request a compact screenshot first; use standard or region only when coordinates or fine detail require it.
- After navigation, use the returned state whether it is a diff or a required full reset. Request `ax_full` only when the diff base was lost or reset/truncation hides the target; `full(reset=true)` alone is not a failure or warning.
- For infinite scroll or pagination, use `scroll_element` only when that exact node exposes the matching `AXScroll...ByPage` action. Otherwise use a bounded context `scroll` without a coordinate and inspect its returned state.
- If the same browser view repeatedly lacks actionable AX semantics, stop retrying AX for that decision and request the smallest useful image profile.

## Fill Forms

- Use `set_value` for ordinary text controls and `press` for represented choices.
- Use `clear_value` to clear an ordinary editable AX control in one state-bound call; do not send an empty `set_value` argument.
- Use `input_text` for a deterministic sequence of bound focus/select/type steps when AX setting is unavailable.
- When an editable AX element is available, pass its latest `state_id`, `state_generation`, and `element_index` directly to `input_text`. Never derive a coordinate from the AX frame or combine the AX target with a coordinate.
- Stop before an autocomplete choice, file picker, permission prompt, validation decision, or consequential submission.
- Never populate secure/password/credential fields through AX. Hand control to the user when required by the Computer Use confirmation policy.

## Keep State Valid

- Every browser action can invalidate prior element indexes even when the page looks unchanged.
- Browser tab, window, display, externally changed content, and turn changes require a fresh named observation. Merely operating another eligible application does not invalidate the browser's retained latest binding.
- A screenshot is valid only for its returned dimensions and coordinate frame. Never scale remembered coordinates yourself.
