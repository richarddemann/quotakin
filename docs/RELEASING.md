# Releasing Quotakin

The packaging scripts create the same two artifacts commonly offered by native macOS projects:

- `Quotakin-VERSION.zip`, containing the app for direct installation.
- `Quotakin-VERSION.dmg`, containing the app and an Applications shortcut.

CI validates the universal app and both containers with an ad-hoc signature. Do not publish those validation artifacts: a public release must use a Developer ID Application certificate and Apple notarization.

## Apple prerequisites

The release owner must be enrolled in the Apple Developer Program and create:

- A **Developer ID Application** certificate with its private key.
- Notarization credentials for the same Apple developer team.

Keep the certificate, private key, and notarization credentials outside the repository.

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

After publication, update the Homebrew tap's Cask URL, version, and SHA-256 to the notarized ZIP. Keep the source-building Formula available until the Cask passes installation testing on a clean Mac.
