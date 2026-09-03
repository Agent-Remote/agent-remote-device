#!/usr/bin/env bash
set -euo pipefail

bash -n scripts/*.sh
bash -n tests/*.sh
plutil -lint macos/Entitlements/*.entitlements macos/Packaging/*.plist >/dev/null
bash tests/release_scripts_test.sh
bash tests/swift_dependency_audit_test.sh
ruby tests/release_workflow_contract_test.rb
ruby tests/localization_catalog_test.rb
ruby tests/logging_privacy_contract_test.rb
ruby tests/managed_skill_safety_contract_test.rb
ruby tests/swift_concurrency_contract_test.rb
ruby tests/isolation_evidence_verifier_test.rb
cargo fmt --all -- --check
cargo fmt --manifest-path fuzz/Cargo.toml -- --check
cargo clippy --workspace --all-targets -- -D warnings
if ! command -v cargo-deny >/dev/null 2>&1; then
  echo "cargo-deny is required for the Rust supply-chain gate" >&2
  exit 1
fi
cargo deny check
if ! command -v cargo-llvm-cov >/dev/null 2>&1; then
  echo "cargo-llvm-cov is required for the 75% Rust coverage gate" >&2
  exit 1
fi
cargo llvm-cov --workspace --fail-under-lines 75
cargo check --manifest-path fuzz/Cargo.toml
swift test --enable-code-coverage
scripts/check-swift-coverage.sh
git diff --check
