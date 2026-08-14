# Quotakin

Quotakin ("quota-kin") is a native macOS menu bar companion for Claude and Codex capacity. It keeps five-hour and weekly quota, reset timing, pace, local token history, and estimated cost close at hand without storing conversation content.

The v0.1 app includes:

- A compact menu bar status and popover.
- Native history charts, activity, and provider/model breakdowns.
- Consent-gated, read-only account quota checks.
- Local Claude and Codex transcript accounting.
- Optional quota alerts and provider-specific pets.
- Guided provider setup and reversible Claude status-line fallback controls.

## Privacy

Quotakin stores only summary metadata: provider, model, observation time, token counts, quota windows, and opaque hashed source identifiers. It does not store prompts, responses, transcript text, tool contents, raw source paths, credentials, or cookies.

- Local history reads token metadata already present in `~/.claude/projects` and `~/.codex/sessions`.
- Account checks begin only after you choose **Connect** or **Check**. They are read-only and never refresh or save provider credentials.
- The optional Claude status-line helper stores only quota percentages, reset times, and an observation timestamp. Installation and removal are user-initiated.
- Public Claude and OpenAI service status checks are unauthenticated and contain no local usage data.
- Pricing estimates use the reviewed catalog bundled with this release; Quotakin does not download a mutable pricing feed at launch.
- **Report a Bug** opens a draft GitHub issue containing only the app and macOS versions. You decide whether to submit it.

## Requirements

- macOS 26 or later
- Swift 6.2 / Xcode 26 to build from source
- Claude Code and/or Codex CLI for their local history and account-quota features

## Build

Install with Homebrew (builds locally from the audited source release):

```sh
brew install richarddemann/tap/quotakin
quotakin
```

Upgrade later with `brew upgrade richarddemann/tap/quotakin`.

### Build from a checkout

Run the full test suite:

```sh
./scripts/test.sh
```

Build or run with SwiftPM:

```sh
swift build
swift run Quotakin
```

Install a local app bundle:

```sh
./scripts/install-app.sh
```

The installer creates an ad-hoc-signed `~/Applications/Quotakin.app`. It does not produce a notarized distribution or prebuilt release.

## Limitations

Provider interfaces can change or become unavailable. Quotakin labels stale and last-known values and does not invent quota when a provider returns no usable window. Cost figures are estimates based on the bundled catalog effective `2026-06-01`; provider pricing and billing adjustments can differ.

## License and Attribution

Quotakin is available under the [MIT License](LICENSE).

Usage accounting and parts of the Usage screen were adapted from [T3 Code](https://github.com/pingdotgg/t3code). Provider icons are from [Lobe Icons](https://github.com/lobehub/lobe-icons). Both are used under the MIT License; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
