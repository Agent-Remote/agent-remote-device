# Browser Workflows

Load this reference only for browser tasks.

Use a dedicated browser connector or approved structured integration when the task needs repeatable data access and does not depend on the user's existing local browser state. Use this Computer Use path for rendered UI, existing approved sessions, browser chrome, or visual verification. Do not enable CDP, remote debugging, DOM injection, profile access, or cookie access as an implicit fallback.

## Navigate And Search

1. Call `observe` with the browser name or bundle identifier.
2. If the address field appears in AX, use `act` with `set_value`, then a separate `key` action for Return when navigation is intended.
3. Otherwise use one `input_text` call with the address-bar shortcut, complete URL or query, and Return.
4. Read the returned AX diff. Do not add a fixed wait or another observation unless settle timed out or the result is insufficient.

Use a complete URL when the destination is known. Do not expose browser profiles, cookies, debugging ports, or DOM endpoints.

## Handle Dynamic UI

- Inspect autocomplete, permission prompts, downloads, and validation messages before selecting them.
- Prefer fresh AX element indexes for tab switching, buttons, links, and form controls.
- If a WebArea is truncated or a canvas lacks AX semantics, request a compact screenshot first; use standard or region only when coordinates or fine detail require it.
- After navigation, use the returned diff. Request `ax_full` only when the diff base was lost or the result reports reset/truncation that hides the target.
- For infinite scroll or pagination, use `scroll_element` on the represented container; otherwise use a bounded coordinate scroll and inspect its returned state.
- If the same browser view repeatedly lacks actionable AX semantics, stop retrying AX for that decision and request the smallest useful image profile.

## Fill Forms

- Use `set_value` for ordinary text controls and `press` for represented choices.
- Use `input_text` for a deterministic sequence of focus/select/type steps when AX setting is unavailable.
- Stop before an autocomplete choice, file picker, permission prompt, validation decision, or consequential submission.
- Never populate secure/password/credential fields through AX. Hand control to the user when required by the Computer Use confirmation policy.

## Keep State Valid

- Every browser action can invalidate prior element indexes even when the page looks unchanged.
- Browser tab, window, application, display, and turn changes require a fresh named observation.
- A screenshot is valid only for its returned dimensions and coordinate frame. Never scale remembered coordinates yourself.
