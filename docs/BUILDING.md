# Building Quotakin

Quotakin requires macOS 26 or later and Swift 6.2 with a compatible Xcode 26 toolchain.

Run the test suite:

```sh
./scripts/test.sh
```

Build or run with Swift Package Manager:

```sh
swift build
swift run Quotakin
```

Install a local app bundle:

```sh
./scripts/install-app.sh
```

The installer creates an ad-hoc-signed `~/Applications/Quotakin.app`. It is intended for local source builds and does not create a Developer ID-signed or notarized distribution.

Provider interfaces can change or become temporarily unavailable. Quotakin labels stale and last-known values and does not invent quota when a provider returns no usable window. Cost figures are estimates based on the catalog bundled with the release; provider pricing and billing adjustments can differ.
