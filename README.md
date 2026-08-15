<div align="center">
  <img src="docs/assets/quotakin-icon.png" width="80" alt="Quotakin app icon">
  <h1>Quotakin</h1>
</div>

<p align="center">Your Claude and Codex usage, living quietly in the menu bar.</p>

## Know your usage before it becomes a surprise

<img align="right" hspace="40" width="260" src="https://github.com/user-attachments/assets/341e3ac7-e90f-47c5-bf68-d4e1a3d18986" alt="Quotakin showing the remaining weekly quota in the macOS menu bar">

Both providers' limits in one place, updated as you work.

- See five-hour and weekly limits.
- Know when each window resets, and your pace.
- Browse activity, models, tokens, and cost.
- Pick a small companion for the menu bar!

<br clear="all">

## Download

Get **[Quotakin.dmg](https://github.com/richarddemann/quotakin/releases/latest/download/Quotakin.dmg)**, or install it with Homebrew:

```sh
brew install --cask richarddemann/tap/quotakin
```

Requires macOS 26 or later. Quotakin checks for new versions inside the app; releases are signed with its Sparkle update key.

> **Quotakin is not Apple-notarized!**
> On first launch, right-click the app and choose **"Open"**.
> If macOS still blocks it, go to **"System Settings" → "Privacy & Security" → "Open Anyway"**.
> Managed Macs **may not permit** unnotarized apps.

## See where the tokens went

Quotakin reads local Claude Code and Codex usage records to build a daily history. Connect either provider (or both) when you also want live account quota.

<p align="center">
  <img src="https://github.com/user-attachments/assets/5bb40ce9-8936-4cc7-938b-f89cb7adec98" width="820" alt="Quotakin usage history with cost, token, activity, and provider breakdowns">
</p>

## Privacy

Your prompts and responses stay out of Quotakin. Summary usage data stays on your Mac, provider credentials and cookies are not copied, and account checks only begin after you choose **Connect** or **Check**.

[Privacy details](docs/PRIVACY.md)

## Build from source

Quotakin is a native Swift app. See [Building and testing](docs/BUILDING.md) to run it from source.

## License

[MIT](LICENSE)
