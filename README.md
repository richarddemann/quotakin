<div align="center">
  <img src="docs/assets/quotakin-icon.png" width="128" alt="Quotakin app icon">
  <h1>Quotakin</h1>
  <p>Keep an eye on your Claude and Codex quota—with a little companion in the menu bar.</p>
</div>

Quotakin shows your five-hour and weekly capacity before it becomes a surprise. Open it for reset times, usage pace, token history, and estimated cost—all in a native Mac app.

## Install

```sh
brew install richarddemann/tap/quotakin
quotakin
```

Update anytime with `brew upgrade richarddemann/tap/quotakin`.

Quotakin currently supports macOS 26 or later and works with Claude Code, Codex, or both. The Homebrew release is built locally and requires Xcode 26.

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
