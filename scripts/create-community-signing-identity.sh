#!/usr/bin/env bash
set -euo pipefail

output=${1:-dist/community-signing-identity}
identity="Agent Remote Community Code Signing"

if [ -e "$output" ]; then
  echo "output path already exists: $output" >&2
  exit 1
fi
mkdir -m 0700 -p "$output"

password=$(openssl rand -base64 36 | tr -d '\n')
key="$output/private-key.pem"
certificate="$output/certificate.pem"
p12="$output/community-signing.p12"

openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
  -subj "/CN=$identity/OU=ARLOCAL001/O=Agent Remote Community" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout "$key" \
  -out "$certificate"
openssl pkcs12 -export -legacy \
  -name "$identity" \
  -inkey "$key" \
  -in "$certificate" \
  -out "$p12" \
  -passout "pass:$password"

certificate_sha1=$(
  openssl x509 -in "$certificate" -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]'
)
certificate_sha256=$(
  openssl x509 -in "$certificate" -outform DER \
    | shasum -a 256 | awk '{print $1}'
)

printf '%s\n' "$password" > "$output/p12-password.txt"
printf '%s\n' "$identity" > "$output/signing-identity.txt"
printf '%s\n' "$certificate_sha1" > "$output/certificate-sha1.txt"
printf '%s\n' "$certificate_sha256" > "$output/certificate-sha256.txt"
chmod 0600 "$output"/*

printf 'Community signing identity created at %s\n' "$output"
printf 'Back up this directory securely before configuring GitHub.\n'

