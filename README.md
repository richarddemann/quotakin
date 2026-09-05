# Quotakin

A macOS menu-bar app for Claude Code and Codex usage.

Shows five-hour and weekly quota, reset times, and local usage history by day and model. You can choose which metrics appear in the menu bar and add a pet to the quota display.

<img width="300" src="https://github.com/user-attachments/assets/341e3ac7-e90f-47c5-bf68-d4e1a3d18986" alt="Quotakin showing remaining weekly quota">

## Install

Download [Quotakin.dmg](https://github.com/richarddemann/quotakin/releases/latest/download/Quotakin.dmg), or use Homebrew:

```sh
brew install --cask richarddemann/tap/quotakin
```

Requires macOS 26 or later. The app is not Apple-notarized. If macOS blocks the first launch, allow it in **System Settings → Privacy & Security → Open Anyway**. Managed Macs may prevent this.

Check for updates from the app’s More menu or Settings → Advanced. Automatic update checks are optional.

## Usage

Local history comes from Claude Code and Codex usage records on your Mac. Connect an account in **Settings → Connections** to see its account-wide quota. Stopping account checks leaves local history available.

History includes token counts, activity, and estimated costs. Cost estimates are not subscription charges or provider bills.

<img width="820" src="https://github.com/user-attachments/assets/5bb40ce9-8936-4cc7-938b-f89cb7adec98" alt="Usage history with token counts, estimated costs, and model breakdowns">

## Privacy

Quotakin stores usage summaries locally, without saving prompts, responses, credentials, or cookies. Account checks start when you choose Connect or Check. It also fetches public provider-status and model-pricing data. See [Privacy](docs/PRIVACY.md) for details.

## Development

Quotakin is built with Swift and SwiftUI. See [Building and testing](docs/BUILDING.md).

## License

[MIT](LICENSE)
