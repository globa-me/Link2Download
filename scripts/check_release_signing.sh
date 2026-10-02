#!/usr/bin/env bash
set -euo pipefail

# Select the leaf certificate by fingerprint: old and G2 certificates can have
# identical names. This script never exports a private key.
: "${SIGNING_CERT_SHA1:?Set SIGNING_CERT_SHA1 to the G2 Developer ID Application leaf SHA-1}"
certificate_sha="$(printf '%s' "$SIGNING_CERT_SHA1" | tr '[:lower:]' '[:upper:]')"
if [[ ! "$certificate_sha" =~ ^[0-9A-F]{40}$ ]]; then
  echo 'SIGNING_CERT_SHA1 must be a 40-character hexadecimal SHA-1.' >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | awk -v sha="$certificate_sha" '
  index($0, " " sha " ") && $0 !~ /CSSMERR/ { usable = 1 }
  END { exit usable ? 0 : 1 }
'; then
  echo "No usable signing identity/private key for $certificate_sha in Keychain." >&2
  exit 1
fi
certificate_pem="$(security find-certificate -a -Z -p -c 'Developer ID Application' | awk -v sha="$certificate_sha" '
  $0 == "SHA-1 hash: " sha && !done { selected = 1 }
  selected && /-----BEGIN CERTIFICATE-----/ { copying = 1 }
  copying { print }
  copying && /-----END CERTIFICATE-----/ { copying = 0; selected = 0; done = 1 }
')"
if [[ -z "$certificate_pem" ]]; then
  echo 'The selected Developer ID Application certificate was not found.' >&2
  exit 1
fi

verify_certificate() {
  local pem="$1" issuer subject fingerprint
  issuer="$(printf '%s\n' "$pem" | openssl x509 -noout -issuer -nameopt RFC2253)"
  subject="$(printf '%s\n' "$pem" | openssl x509 -noout -subject -nameopt RFC2253)"
  fingerprint="$(printf '%s\n' "$pem" | openssl x509 -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
  if [[ "$fingerprint" != "$certificate_sha" || "$issuer" != *",OU=G2,"* ||
        "$issuer" != *"CN=Developer ID Certification Authority"* ||
        "$subject" != *",OU=BN3D9H4C7J,"* || "$subject" != *"CN=Developer ID Application:"* ]]; then
    echo "The certificate must be Developer ID Application from G2 for team BN3D9H4C7J; found $issuer" >&2
    exit 1
  fi
  printf '%s\n' "$pem" | openssl x509 -checkend 0 -noout >/dev/null
  printf '%s\n' "$issuer"
  printf '%s\n' "$pem" | openssl x509 -noout -enddate -fingerprint -sha1
}
verify_certificate "$certificate_pem"

if [[ $# -gt 0 ]]; then
  artifact="$1"
  codesign --verify --deep --strict "$artifact"
  signature="$(codesign -dvvv "$artifact" 2>&1)"
  if [[ "$signature" != *"TeamIdentifier=BN3D9H4C7J"* || "$signature" != *"Timestamp="* ]]; then
    echo "Missing expected team or secure timestamp: $artifact" >&2
    exit 1
  fi
  certificate_dir="$(mktemp -d /tmp/link2download-signature.XXXXXX)"
  trap 'rm -rf "$certificate_dir"' EXIT
  codesign -d --extract-certificates="$certificate_dir/leaf" "$artifact" >/dev/null 2>&1
  signed_pem="$(openssl x509 -inform DER -in "$certificate_dir/leaf0" -outform PEM)"
  verify_certificate "$signed_pem"
  printf '%s\n' "$signature" | grep '^Timestamp='
  echo "Verified G2 signature: $artifact"
fi
