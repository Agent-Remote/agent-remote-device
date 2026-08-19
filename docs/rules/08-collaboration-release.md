# 08 Collaboration And Release

Use short-lived `feature/`, `fix/`, `refactor/`, `chore/`, or `docs/` branches with lowercase descriptive topics.

Commits follow Conventional Commits: `type(scope): subject` or `type: subject`. Allowed types are `feat`, `fix`, `refactor`, `chore`, `docs`, `perf`, `test`, `build`, `ci`, and `style`. Use a concise lowercase English imperative subject, no trailing period, and at most 120 characters.

Pull requests must describe protocol compatibility, macOS permission and isolation impact, privacy impact, release-profile impact, cross-repository assumptions, and test coverage.

Use `.github/workflows/prepare-release.yml` to prepare a version. It updates every repository-owned version reference and `CHANGELOG.md`, verifies the source, commits `chore: release vX.Y.Z`, creates the immutable tag, and dispatches `.github/workflows/release.yml`. The release workflow must build only the exact tagged source and preserve signatures, SBOMs, vulnerability reports, provenance, protected environments, and published verification evidence.

Never manually edit one version file or publish an artifact from an uncommitted tree. Never reuse, rotate, or expose signing material as part of a source change.

The Device version and release cadence belong only to this repository. Preparing a Device release
must not require or rewrite another component's version. Node chooses an embedded proxy through its
own immutable `release-dependencies.json`; the root `agent-remote` manifest separately certifies a
supported production composition. Version equality across repositories is not a compatibility
contract.
