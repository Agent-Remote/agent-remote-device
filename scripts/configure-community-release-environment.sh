#!/usr/bin/env bash
set -euo pipefail

identity_directory=${1:-dist/community-signing-identity}
repository=${GITHUB_REPOSITORY:-Agent-Remote/agent-remote-device}
environment=production-community-release

for file in \
  community-signing.p12 \
  p12-password.txt \
  signing-identity.txt \
  certificate-sha1.txt; do
  path="$identity_directory/$file"
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    echo "missing or unsafe identity input: $path" >&2
    exit 1
  fi
done

gh api --method PUT "repos/$repository/environments/$environment" >/dev/null
base64 < "$identity_directory/community-signing.p12" | tr -d '\n' \
  | gh secret set COMMUNITY_SIGNING_P12_BASE64 \
    --env "$environment" --repo "$repository"
gh secret set COMMUNITY_SIGNING_P12_PASSWORD \
  --env "$environment" --repo "$repository" \
  < "$identity_directory/p12-password.txt"
gh secret set COMMUNITY_SIGNING_IDENTITY \
  --env "$environment" --repo "$repository" \
  < "$identity_directory/signing-identity.txt"
gh variable set COMMUNITY_SIGNER_CERTIFICATE_SHA1 \
  --env "$environment" --repo "$repository" \
  --body "$(tr -d '[:space:]' < "$identity_directory/certificate-sha1.txt")"

printf 'Configured %s for %s\n' "$environment" "$repository"

