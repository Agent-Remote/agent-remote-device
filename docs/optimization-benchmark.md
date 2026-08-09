# Computer Use optimization benchmark

The managed proxy writes one bounded, owner-only, zero-content JSONL event per
device operation to `/tmp/agent-remote-device-optimization.jsonl`. A compact MCP
tool such as `input_text` can intentionally emit several device operations, so
the JSONL event count is not an MCP tool-call count. The Node fixes
this path in managed MCP configuration. The file stops accepting events at 16
MiB and is never uploaded by the proxy.

Events contain only schema version, execution path, action and observation enums,
success/error categories, node and removed counts, AX/image/bridge byte counts,
action and settle durations, image/fallback/stale booleans, retry count, and
manual-recovery status. They cannot contain AX text, title, value, URL, frame
coordinates, screenshots, input, clipboard data, state IDs, window titles, or
reversible content hashes.

The `action` field distinguishes keyboard, text, scroll, wait, drag, pointer
coordinate, and AX element operations. `coordinate` therefore means an actual
pointer action, while `coordinate_fallback` is true only when the action required
a model-visible screenshot. `ax_bytes` is the serialized AX observation size,
including JSON structure; the observation policy's `max_total_text_bytes` limits
only the combined AX text fields. `bridge_bytes` is transport payload volume, not
model-token usage.

## Fixed scenarios

The labelled activation and tool-selection corpus is committed at
`benchmark/computer-use-golden-prompts.json` and validated by
`protocol/schema/computer-use-golden-prompts.schema.json`. It is a prompt-routing
contract, not production user data. Replay it with the same model/runtime and record the
expected skill activation and first observation mode alongside the device trace.

Run the same non-sensitive task corpus once with the v1 compatibility surface and
once with the v2 compact surface. Use a fresh session generation for each run and
keep application versions, display layout, network conditions, and task inputs
fixed. The corpus must include:

1. Open a complete URL and wait for navigation.
2. Search with autocomplete and select a represented result.
3. Open, switch, and close browser tabs.
4. Fill a normal form without submitting, then submit as a separate checkpoint.
5. Scroll a represented container, paginate, and exercise infinite loading.
6. Observe a browser permission prompt and security warning without approving it.
7. Encounter a secure field and verify user hand-off.
8. Exercise canvas or AX-incomplete content and its coordinate fallback.
9. Move and resize the window, change displays, and resume after a turn stop.
10. Open and close same-page browser UI such as the Chrome find bar and a safe
    infobar; record both `elapsed_ms` and full-versus-diff selection for each
    direction.

Do not use real credentials, payments, private messages, personal files, or
production accounts in benchmark tasks.

## Compare traces

Preserve the JSONL files outside `/tmp` after each controlled run, then execute:

```sh
cargo run --manifest-path proxy/Cargo.toml \
  --example optimization_benchmark -- \
  --baseline /path/to/v1-run.jsonl \
  --candidate /path/to/v2-run.jsonl
```

Multiple `--baseline` and `--candidate` arguments may be supplied. The result
contains both summaries, image and bridge-byte reductions, p95 latency reduction,
success-rate delta, and `passes_recommended_targets`.

The JSONL file intentionally cannot measure model tokens. For every corpus run,
also preserve the model/runtime usage summary containing input tokens, image
inputs or image-token usage when available, output tokens, and MCP tool-call
count. Bind that summary to the same run ID and artifact digest outside the device
trace; never add prompts, responses, AX text, URLs, or images to this JSONL file.
When exact image-token accounting is unavailable, report model-visible image
count, dimensions, and encoded bytes separately and do not estimate a token
reduction from bridge-byte reduction.

The recommended target requires at least 70% fewer model-visible images, action
p95 at or below 1 second, settle p95 at or below 5 seconds, coordinate fallback
below 20%, no redundant full state for a same-context local UI add/remove, and no
call-success regression. A full state is not redundant after an explicit full
request, lost base, application/window/display change, or confirmed page-identity
replacement. These cost targets never override the zero wrong-target requirement,
confirmation policy, or production release gates.

## Skill and tool-selection regression

Maintain a labelled golden prompt set alongside the controlled task corpus. It
must include direct Computer Use requests, indirect GUI requests, browser tasks,
requests that should prefer a dedicated connector/API/CLI, and negative prompts
that must not activate device control. For each prompt record the expected skill,
tool surface, first observation mode, whether an image is expected, and required
confirmation checkpoint.

Replay the set after changing the skill description, MCP tool name/description,
server instructions, observation defaults, or browser reference. A candidate is
not eligible for rollout when it increases accidental Computer Use activation,
selects legacy tools despite a negotiated v2 context, requests screenshots for
ordinary represented controls, or skips a consequential checkpoint.
