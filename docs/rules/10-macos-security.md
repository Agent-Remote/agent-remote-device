# 10 macOS Security

Read `docs/macos-security.md`, `docs/isolation-verification.md`, and `docs/release-signing.md` before changing permissions, XPC, credentials, network policy, signing, packaging, or release evidence.

- A local session selection grants only the explicit, versioned `session_full_trust` authorization for that complete
  DeviceSession binding. Unknown modes, scopes, policy versions, or incomplete capabilities fail closed.
- The Network Broker alone owns device authentication, the fixed endpoint, nested TLS, and control-plane revocation.
- The GUI Executor alone owns Accessibility, Screen Recording, CGEvent input, AX state, and clipboard access.
- XPC peers require the expected signed identity, versioned payloads, bounded replies, cancellation, and fail-closed invalidation.
- Stop, pause, session end, screen lock, user switch, sleep, network loss, and peer loss must release input and restore any remotely displaced user focus in the documented order while still attempting authenticated revocation.
- Every observation and GUI action must resolve and revalidate the exact signed application, window and display context.
  AX handles and coordinates are valid only for that context, the active generation, current model-visible state, and
  unexpired lease. Device processes and protected system surfaces are always excluded.
- `launch_application` accepts only a validated Bundle ID or unambiguous installed GUI application name. It never
  accepts paths, URLs, arguments, scripts, commands, or environment variables.
- Global clipboard reads require an active full-trust binding and exact sequence but no application or observation;
  only plain UTF-8 text up to 64 KiB may cross the encrypted channel and content must never be logged.
- Production activation requires the selected release profile's verifiable signing, policy, SBOM, provenance, vulnerability, and isolation evidence.

Unsigned SwiftPM builds validate logic only. They do not prove TCC, code-signature, XPC, hardened runtime, global input release, or installed application behavior.
