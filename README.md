<div align="center">
  <img src="docs/assets/quotakin-icon.png" width="128" alt="Quotakin app icon">
  <h1>Quotakin</h1>
  <p>Keep an eye on your Claude and Codex quota—with a little companion in the menu bar.</p>
  <p><strong>For macOS 26 or later.</strong></p>
</div>

Quotakin shows your five-hour and weekly capacity before it becomes a surprise. Open it for reset times, usage pace, token history, and estimated cost—all in a native Mac app.

## Install

### Download for Mac

**[Download Quotakin for macOS](https://github.com/richarddemann/quotakin/releases/latest/download/Quotakin.dmg)**

Open the downloaded `.dmg`, then drag Quotakin into Applications. The first time you launch it, right-click Quotakin and choose **Open**. If macOS still blocks it, use **System Settings → Privacy & Security → Open Anyway**. Managed Macs may prohibit unnotarized apps entirely.

### Homebrew

```sh
brew install --cask richarddemann/tap/quotakin
```

Update anytime with `brew upgrade richarddemann/tap/quotakin`.

Quotakin currently supports macOS 26 or later and works with Claude Code, Codex, or both. Releases are prebuilt; installing Quotakin does not require Xcode.

Quotakin is independently distributed without Apple Developer Program notarization. macOS therefore asks you to confirm the first launch. Release archives and in-app updates are cryptographically signed by Quotakin's Sparkle update key.

## At a glance

- See short- and long-window quota together, including reset timing and pace.
- Browse daily history, activity, model usage, tokens, and estimated cost.
- Choose a small quota companion for the menu bar, or a simpler display.
- Get optional alerts before capacity becomes tight.

## Private by design

Your prompts and responses stay out of Quotakin. It keeps summary usage data on your Mac, does not copy provider credentials or cookies, and only checks account quota after you ask it to connect.

[Read the privacy details](docs/PRIVACY.md)

## Build from source

Quotakin is a native Swift app. See [Building and testing](docs/BUILDING.md) to run it from a checkout.

## License

[MIT](LICENSE)
