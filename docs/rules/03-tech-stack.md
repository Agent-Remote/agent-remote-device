# 03 Tech Stack

- Swift 6 and Swift Package Manager are authoritative for macOS code; supported deployment starts at macOS 14.
- Stable Rust 1.88 or newer with the 2021 edition is authoritative for the managed proxy.
- Cargo owns Rust resolution and both `Cargo.lock` files; SwiftPM owns `Package.resolved`.
- Network.framework owns Swift network transport; XPC owns privileged local process communication.
- Tokio and rustls own asynchronous proxy transport; Serde owns Rust wire serialization.
- Swift Codable models and strict decoders own the macOS wire boundary.

Use platform and standard libraries before adding dependencies. Pin security-sensitive dependencies, keep features narrow, update lockfiles with manifests, and extend `deny.toml` or the Swift audit policy deliberately. Never replace certificate or code-signature verification with permissive development behavior in production paths.
