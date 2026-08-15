# Releasing Quotakin

The packaging scripts create the same two artifacts commonly offered by native macOS projects:

- `Quotakin-VERSION.zip`, containing the app for direct installation.
- `Quotakin-VERSION.dmg`, containing the app and an Applications shortcut.

CI validates the universal app and both containers with an ad-hoc signature. The tag release workflow publishes the same prebuilt app for users who accept macOS's first-launch confirmation. Release archives are additionally signed with Quotakin's Sparkle Ed25519 update key.

This is intentionally an unnotarized distribution while the project has no Apple Developer Program membership. Never describe these artifacts as notarized or as Gatekeeper-trusted.

## Optional Apple prerequisites

For a warning-free first launch, the release owner must be enrolled in the Apple Developer Program and create:

- A **Developer ID Application** certificate with its private key.
- Notarization credentials for the same Apple developer team.

Keep the certificate, private key, and notarization credentials outside the repository. They are not required for the current transparent ad-hoc release channel.

## Automated tag release

Store the Sparkle private key as the `SPARKLE_PRIVATE_KEY` GitHub Actions secret. Pushing an incremented `vMAJOR.MINOR.PATCH` tag runs tests, builds the universal app, creates DMG and ZIP artifacts, signs the ZIP update, generates `appcast.xml`, records checksums, and publishes the GitHub release.

The workflow derives a monotonically increasing `CFBundleVersion` as `major × 1,000,000 + minor × 1,000 + patch`; release components must therefore stay below 1,000. After publication, update the Homebrew Cask to the release ZIP and its SHA-256.

## Build a signed app

```sh
./scripts/build-release-app.sh \
  --version 0.2.0 \
  --build-number 2 \
  --output /absolute/path/to/Quotakin.app \
  --identity "Developer ID Application: Your Name (TEAMID)"
```

The script builds a universal `arm64`/`x86_64` executable, assembles the app bundle, enables the hardened runtime during signing, and verifies the signature and bundle metadata.

## Notarize and package

Submit a ZIP containing the signed app with `xcrun notarytool`, wait for acceptance, then staple and validate the app before creating the public containers:

```sh
xcrun stapler staple /absolute/path/to/Quotakin.app
xcrun stapler validate /absolute/path/to/Quotakin.app

./scripts/create-release-assets.sh \
  --app /absolute/path/to/Quotakin.app \
  --version 0.2.0 \
  --output-dir /absolute/path/to/release \
  --identity "Developer ID Application: Your Name (TEAMID)"
```

Submit the DMG to the notary service as well, staple its accepted ticket, and validate both the app and DMG with Gatekeeper before uploading them to GitHub Releases. Record SHA-256 checksums for both assets.

If this optional Developer ID path is adopted later, update the Homebrew Cask to the notarized ZIP after publication. For the current ad-hoc channel, point the Cask to the transparently unnotarized ZIP produced by the automated tag workflow.
