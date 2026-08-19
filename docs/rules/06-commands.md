# 06 Commands

## Complete Quality Gate

```sh
scripts/run-quality-checks.sh
```

The gate includes shell syntax, plist validation, release and privacy contracts, Rust formatting and Clippy, dependency policy, Rust coverage, fuzz-package checks, Swift tests and coverage, and whitespace checks. It requires `cargo-deny` and `cargo-llvm-cov`.

Useful focused commands:

```sh
cargo test --workspace
swift test
bash tests/release_scripts_test.sh
ruby tests/release_workflow_contract_test.rb
```

Use `cargo fmt --all` and `swift format` only where already supported. Build development apps with `scripts/build-development-app.sh`; use synthetic data only. Run production packaging only when the task requires release artifacts, and never commit `dist/`, `.build/`, `target/`, credentials, or signing material.
