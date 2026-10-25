# Developer ID G2 migration

## Status

G2 signing is available and verified on this Mac. Installed previews were signed, notarized and stapled on 2026-10-23 and 2026-10-24. Public release 1.5.0 is being prepared on 2026-10-25; its final publication and verification results belong in [macos-release.md](macos-release.md).

- Certificate: `Developer ID Application: Gennadiy Zakharov (BN3D9H4C7J)`.
- Team: `BN3D9H4C7J`.
- G2 leaf SHA-1: `6E99F92E9A1BA1273CD084FAFE940A7280DB0A30`.
- Issuer: `Developer ID Certification Authority`, OU `G2`.
- Expiry: 2031-09-17 00:00:00 UTC.
- Existing notarization Keychain profile: `GZB-notary`.

Select the certificate by SHA-1, since an older certificate has the same display name. Its private key is already in Keychain; do not export it, create/revoke shared certificates, or substitute another identity. Only public certificate metadata belongs in documentation; never commit a private key, P12, password or notarization credentials.

Targeted verification on 2026-10-25 passed:

```bash
SIGNING_CERT_SHA1=6E99F92E9A1BA1273CD084FAFE940A7280DB0A30 ./scripts/check_release_signing.sh
xcrun notarytool history --keychain-profile GZB-notary
```

## Initial state — 2026-10-02

At the start of the migration, signing and publication were waiting for G2 and the public version was [1.4.5](https://github.com/globa-me/Link2Download/releases/tag/v1.4.5). The only usable identity found then was:

- Team: `BN3D9H4C7J`
- SHA-1: `0B4AEF20C0E48C3D8A6C1A7B9A82330EBA64806F`
- Issuer OU: `Apple Certification Authority` (previous Sub-CA)
- Expiry: 2027-02-01 22:12:15 UTC

The G2 identity above subsequently replaced that dependency. Do not use the old certificate as a substitute for G2.

## Changes prepared

- Signed builds require `SIGNING_CERT_SHA1` and use that exact leaf fingerprint with `codesign`.
- `scripts/check_release_signing.sh` checks Keychain identity/private-key availability, issuer OU `G2`, team and expiry before signed build outputs are replaced.
- App and DMG signatures are checked for the same leaf, team and secure timestamp. Existing hardened-runtime entitlements and nested signing remain in place.
- Notarization checks the selected certificate even with `SKIP_BUILD=1`, preventing reuse of an old signed app.
- GitHub CI runs checks only; `.github/workflows/ci.yml` does not import a signing certificate or perform releases. No signing secrets need updating in the current workflow.

Preparation verification passed shell syntax and diff checks. Selecting the old leaf above was rejected by the G2 check. `SKIP_BUILD=1` notarization was also rejected before any build or submission, so an old app could not be reused as a G2 release. Successful G2 signing, timestamp, notarization and Gatekeeper checks are recorded in the release runbook.

## Continue distribution

1. Verify the known G2 leaf and existing `GZB-notary` profile directly with the commands above.
2. Update version defaults, README and CHANGELOG. Keep the Universal 2 DMG and checksum asset names and both supported architectures.
3. Run the regression checks from the README.
4. Build/notarize using `SIGNING_CERT_SHA1=6E99F92E9A1BA1273CD084FAFE940A7280DB0A30 APP_VERSION=1.5.0 ./scripts/notarize_release.sh`.
5. Verify native Apple Silicon and Intel under Rosetta, the app and DMG issuer/fingerprint/timestamp, notarization, Gatekeeper and application launch.
6. Publish the new GitHub release after validation. Download the uploaded DMG and checksum into a separate directory and verify those actual downloaded bytes and the mounted app.
7. Record the final release URL, checksum, certificate metadata and verification results here and in `macos-release.md`.

The older release assets remain part of the release history; do not replace their bytes when publishing a new version.

Reference: [Apple replacement instructions](https://developer.apple.com/help/account/certificates/replace-developer-id-certificates).
