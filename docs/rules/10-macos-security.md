# 10 macOS Security

Read `docs/macos-security.md`, `docs/isolation-verification.md`, and `docs/release-signing.md` before changing permissions, XPC, credentials, network policy, signing, packaging, or release evidence.

- Approval must identify exact applications and control levels before activation.
- The Network Broker alone owns device authentication, the fixed endpoint, nested TLS, and control-plane revocation.
- The GUI Executor alone owns Accessibility, Screen Recording, CGEvent input, AX state, and clipboard access.
- XPC peers require the expected signed identity, versioned payloads, bounded replies, cancellation, and fail-closed invalidation.
- Stop, pause, session end, screen lock, user switch, sleep, network loss, and peer loss must release input and restore any remotely displaced user focus in the documented order while still attempting authenticated revocation.
- AX handles and coordinates are valid only for the exact approved application, window and display context, active generation, current model-visible state, and unexpired lease.
- Production activation requires the selected release profile's verifiable signing, policy, SBOM, provenance, vulnerability, and isolation evidence.

Unsigned SwiftPM builds validate logic only. They do not prove TCC, code-signature, XPC, hardened runtime, global input release, or installed application behavior.
