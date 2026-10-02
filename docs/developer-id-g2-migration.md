# Developer ID G2 migration — 2026-10-02

## Status

Preparation complete; signing and publication are waiting for the shared G2 certificate. No G2 release has been published. The current public version remains [1.4.5](https://github.com/globa-me/Link2Download/releases/tag/v1.4.5), with a Universal 2 app in `Link2Download-Installer.dmg` and `SHA256SUMS.txt`.

The only usable Developer ID Application identity found in this machine's Keychain on 2026-10-02 is:

- Team: `BN3D9H4C7J`
- SHA-1: `0B4AEF20C0E48C3D8A6C1A7B9A82330EBA64806F`
- Issuer OU: `Apple Certification Authority` (previous Sub-CA)
- Expiry: 2027-02-01 22:12:15 UTC

The shared certificate is being obtained by the GZWhisper task “Разобрать сбой транскрибации” (`01a0f1a1-bc8d-7f02-a85b-b96f520a34fd`). That task was interrupted when last inspected. Do not create or revoke shared certificates in this project. Do not use the old certificate as a substitute for G2.

New G2 leaf SHA-1 and expiry: **pending installation and verification**. Only public certificate metadata belongs in this document; never commit a private key, P12, password or notarization credentials.

## Changes prepared

- Signed builds require `SIGNING_CERT_SHA1` and use that exact leaf fingerprint with `codesign`.
- `scripts/check_release_signing.sh` checks Keychain identity/private-key availability, issuer OU `G2`, team and expiry before signed build outputs are replaced.
- App and DMG signatures are checked for the same leaf, team and secure timestamp. Existing hardened-runtime entitlements and nested signing remain in place.
- Notarization checks the selected certificate even with `SKIP_BUILD=1`, preventing reuse of an old signed app.
- GitHub CI runs checks only; `.github/workflows/ci.yml` does not import a signing certificate or perform releases. No signing secrets need updating in the current workflow.

Preparation verification: `bash -n scripts/*.sh` and `git diff --check` passed. Selecting the actual old leaf above was rejected by the G2 check. `SKIP_BUILD=1` notarization was also rejected before any build or submission, so an old app cannot be reused as a G2 release. Successful G2 signing and timestamp checks still require the new certificate.

## Resume after G2 is installed

1. Verify `security find-identity -v -p codesigning` and the **leaf** certificate issuer; record its SHA-1 and expiry above.
2. Run `SIGNING_CERT_SHA1='<G2 leaf SHA-1>' ./scripts/check_release_signing.sh`.
3. Prepare a patch release (planned `1.4.6`), updating version defaults, README and CHANGELOG. Keep the Universal 2 DMG and checksum asset names and both supported architectures.
4. Run the regression checks and build/notarize using `SIGNING_CERT_SHA1='<G2 leaf SHA-1>' APP_VERSION=1.4.6 ./scripts/notarize_release.sh`.
5. Verify native Apple Silicon and Intel under Rosetta, the app and DMG issuer/fingerprint/timestamp, notarization, Gatekeeper and application launch.
6. Publish the new GitHub release after validation. Download the uploaded DMG and checksum into a separate directory and verify those actual downloaded bytes and the mounted app.
7. Record the final release URL, checksum, certificate metadata and verification results here and in `macos-release.md`.

The installed application and public 1.4.5 assets have not been replaced during preparation.

Reference: [Apple replacement instructions](https://developer.apple.com/help/account/certificates/replace-developer-id-certificates).
