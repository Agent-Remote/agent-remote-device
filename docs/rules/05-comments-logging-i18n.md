# 05 Comments, Logging, And Localization

Public modules and non-obvious public APIs should have concise Swift or Rust documentation comments. Inline comments explain security invariants, compatibility constraints, concurrency decisions, or platform workarounds; they must not restate the code.

Logs and telemetry must never contain screenshots, AX text or values, window titles, URLs, clipboard data, typed input, coordinates, credentials, private keys, certificates with private material, or reversible content hashes. Use the bounded privacy-preserving metrics documented in `docs/macos-security.md` and `docs/optimization-benchmark.md`.

User-visible application text belongs in the localization catalogs and must be available in English and Simplified Chinese. Tests protect catalog parity. User workflow and release instruction changes must update both `README.md` and `README.zh-CN.md`.
