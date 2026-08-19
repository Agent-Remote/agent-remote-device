# 07 Quality And Security

The complete local gate and CI are mandatory. Do not weaken checks, lower coverage thresholds, remove negative tests, or replace security verification with string-only assertions to make a change pass.

- Treat relay frames, JSON, MCP arguments, images, AX data, paths, credential files, environment variables, archives, and XPC peers as untrusted.
- Enforce size, count, time, lease, sequence, generation, application, window, display, and coordinate bounds before use.
- Fail closed on certificate, code-signature, policy-attestor, XPC, cleanup, or identity failures.
- Preserve zero core-dump limits before loading credentials or session state.
- Never commit or log credentials, keys, signing P12 data, passwords, screenshots, clipboard values, AX content, URLs, titles, or user input.
- Keep filesystem credential fallback owner-only, atomic, bounded, symlink-safe, and unavailable to the GUI Executor.
- Keep action execution serialized per generation and never replay an action with unknown completion status.

Security boundary changes require updated threat or isolation documentation and focused failure-path tests.
