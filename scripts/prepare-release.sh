#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 0.2.11" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

version="${1#v}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]]; then
  echo "invalid semantic version: $1" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

python3 - "$version" <<'PY'
from pathlib import Path
import re
import stat
import sys
import tempfile

version = sys.argv[1]

script_path = Path("scripts/prepare-release.sh")
script = script_path.read_text(encoding="utf-8")
script = re.sub(r"Example: \$0 [0-9A-Za-z.+-]+", f"Example: $0 {version}", script)
mode = stat.S_IMODE(script_path.stat().st_mode)
with tempfile.NamedTemporaryFile(
    mode="w", encoding="utf-8", dir=script_path.parent, delete=False
) as temporary:
    temporary.write(script)
replacement = Path(temporary.name)
replacement.chmod(mode)
replacement.replace(script_path)

cargo_path = Path("Cargo.toml")
cargo = cargo_path.read_text(encoding="utf-8")
updated, count = re.subn(
    r'(?m)^(version = ")[^"]+("\s*)$',
    rf'\g<1>{version}\2',
    cargo,
    count=1,
)
if count != 1:
    raise SystemExit("workspace package version was not updated exactly once")
cargo_path.write_text(updated, encoding="utf-8")

lock_path = Path("Cargo.lock")
lock = lock_path.read_text(encoding="utf-8")
updated, count = re.subn(
    r'(?s)(\[\[package\]\]\nname = "agent-remote-device-proxy"\nversion = ")[^"]+("\n)',
    rf'\g<1>{version}\2',
    lock,
    count=1,
)
if count != 1:
    raise SystemExit("proxy lockfile version was not updated exactly once")
lock_path.write_text(updated, encoding="utf-8")

fuzz_lock_path = Path("fuzz/Cargo.lock")
fuzz_lock = fuzz_lock_path.read_text(encoding="utf-8")
updated, count = re.subn(
    r'(?s)(\[\[package\]\]\nname = "agent-remote-device-proxy"\nversion = ")[^"]+("\n)',
    rf'\g<1>{version}\2',
    fuzz_lock,
    count=1,
)
if count != 1:
    raise SystemExit("fuzz proxy lockfile version was not updated exactly once")
fuzz_lock_path.write_text(updated, encoding="utf-8")

readme_path = Path("README.md")
readme = readme_path.read_text(encoding="utf-8")
readme, count = re.subn(
    r"VERSION=[0-9A-Za-z._+-]+ scripts/package-proxy-release\.sh",
    f"VERSION={version} scripts/package-proxy-release.sh",
    readme,
)
if count != 1:
    raise SystemExit("English README release example was not updated exactly once")
readme_path.write_text(readme, encoding="utf-8")

readme_cn_path = Path("README.zh-CN.md")
readme_cn = readme_cn_path.read_text(encoding="utf-8")
readme_cn, count = re.subn(
    r"VERSION=[0-9A-Za-z._+-]+ scripts/package-proxy-release\.sh",
    f"VERSION={version} scripts/package-proxy-release.sh",
    readme_cn,
)
if count != 1:
    raise SystemExit("Chinese README release example was not updated exactly once")
readme_cn_path.write_text(readme_cn, encoding="utf-8")
PY

cargo metadata --format-version=1 --no-deps >/dev/null
resolved=$(cargo metadata --format-version=1 --no-deps | python3 -c \
  'import json,sys; data=json.load(sys.stdin); print(next(p["version"] for p in data["packages"] if p["name"] == "agent-remote-device-proxy"))')
if [ "$resolved" != "$version" ]; then
  echo "prepared Rust package version does not match requested version" >&2
  exit 1
fi

fuzz_resolved=$(cargo metadata --manifest-path fuzz/Cargo.toml --format-version=1 --locked | python3 -c \
  'import json,sys; data=json.load(sys.stdin); print(next(p["version"] for p in data["packages"] if p["name"] == "agent-remote-device-proxy"))')
if [ "$fuzz_resolved" != "$version" ]; then
  echo "prepared fuzz proxy version does not match requested version" >&2
  exit 1
fi

scripts/update-changelog.sh "$version"

echo "Prepared agent-remote-device v${version}"
