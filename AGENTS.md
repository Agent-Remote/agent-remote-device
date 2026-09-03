# AGENTS.md

This document is the primary instruction set for AI agents and automated coding tools working in this repository. Repository-local rules take precedence over general assumptions.

## Task-To-Documentation Mapping

Before making changes, identify the task domain and read the matching rule document.

| Task Domain | Primary Reference |
| --- | --- |
| Project purpose and repository boundary | `docs/rules/01-project-overview.md` |
| Swift, Rust, XPC, and process boundaries | `docs/rules/02-architecture.md` |
| Toolchains and dependency policy | `docs/rules/03-tech-stack.md` |
| Swift and Rust code style and tests | `docs/rules/04-code-style.md` |
| Comments, logs, localization, and documentation | `docs/rules/05-comments-logging-i18n.md` |
| Local commands and developer workflow | `docs/rules/06-commands.md` |
| Quality, privacy, and security gates | `docs/rules/07-quality-security.md` |
| Git, commits, releases, and pull requests | `docs/rules/08-collaboration-release.md` |
| Device protocol and cross-language contracts | `docs/rules/09-protocol-compatibility.md` |
| macOS permissions, XPC, signing, and isolation | `docs/rules/10-macos-security.md` |

## Mandatory Gates

- Shell and plist checks, release contract tests, Rust formatting and Clippy, dependency policy, Rust coverage, fuzz-package checks, Swift tests and coverage, and `git diff --check` must pass before commit.
- Protocol changes must update schemas, test vectors, Swift and Rust implementations, compatibility behavior, and focused tests together.
- User-facing text must remain available in English and Simplified Chinese; README workflow changes must update both README files.
- Security boundary or release profile changes must update the relevant design and signing documents before implementation.
- Commit messages must follow Conventional Commits.
- Device credentials, private keys, signing P12 files and passwords, clipboard data, screenshots, AX content, URLs, titles, and typed input must never be committed or logged.

## Implementation Rules

- Keep device authentication and network transport in the Network Broker; keep TCC-backed GUI operations in the GUI Executor.
- Preserve code-signature-validated, versioned XPC boundaries and fail closed on peer loss, timeout, identity mismatch, or incomplete cleanup.
- Treat every remote frame, identifier, coordinate, image, path, credential file, and release artifact as untrusted input.
- Bind actions to the current session authorization, exact resolved application identity, session generation,
  monotonic sequence, current lease, and model-visible state.
- Preserve protocol v1 fallback whenever v2 capabilities are not fully negotiated.
- Prefer narrow, explicit types and existing modules over speculative abstractions.

## Quality Gate

Run the complete local gate:

```sh
scripts/run-quality-checks.sh
```

## Conflict Resolution

If existing code conflicts with these rules:

1. Stop before editing the conflicting area.
2. Identify the file and rule that disagree.
3. Ask for the intended current standard.
