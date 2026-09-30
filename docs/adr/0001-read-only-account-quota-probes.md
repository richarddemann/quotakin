# Use read-only account quota probes with explicit local fallbacks

UsageBar must report capacity for all clients using the same subscription account, not merely this Mac's local transcripts. We will use verified read-only account-level quota probes for Claude and Codex, never write or refresh credentials during background or manual quota probes, and retain a clearly aged local observation only as a fallback. This deliberately accepts an undocumented Codex integration, protected by bounded refresh, backoff, explicit source labelling, and no claim of account-level freshness after the probe fails.

An explicit user-initiated **Connect** action may launch the provider's own installed CLI login command. The provider CLI owns any credential creation or refresh; UsageBar neither receives nor persists the authentication response. Login output is discarded, and the connection is verified afterward through the same read-only quota probe.

Claude credential discovery considers the credentials file, the legacy `Claude Code-credentials` service, and current hash-suffixed services in modification order. If one candidate is expired or rejected, the read-only probe can try the next candidate. Background probes never allow Keychain interaction. A denied Keychain read remains silenced until the user explicitly chooses **Grant Access**. UsageBar never refreshes or writes Claude-owned OAuth credentials.

Successful Claude account probes are limited to one network request per fifteen minutes, even across app relaunches and when the general live-quota timer is configured more aggressively. Manual connection checks bypass that success interval. Failed checks retain their existing bounded backoff and preserve last-known account quota; a usable local Claude observation is presented as an optional local fallback rather than a failed setup.

## Considered Options

- Local files only: private and simple, but cannot describe cross-device account capacity.
- Interactive Codex status automation: depends on an interactive client and is too fragile for recurring monitoring.
- Account-level read-only probes: selected because they are the only route that can meet the account-level contract while retaining a clear fallback.

## Consequences

The account probes require source-specific health/backoff tests and may need revision if provider interfaces change. A local session log or status-line snapshot is never rendered as global live quota.

## 2026-09-29: Claude-owned authentication

The live Claude provider now uses Claude Code's stream-json control protocol (`initialize`, then `get_usage`), matching current T3 Code's usage integration. No user message is sent. The CLI owns Keychain access and renewal of its existing login; Quotakin does not independently rotate tokens, avoiding refresh-token races and bundle-signature-dependent Keychain grants. The older direct OAuth provider remains available as library code, but is no longer used by the app.

Checks run in an isolated temporary working directory, with settings sources, hooks, tools, MCP servers, and session persistence disabled. They have a 30-second deadline and discard stderr and provider error text. Simultaneous manual/background checks share one completed provider check. General session and weekly windows are decoded independently; inactive windows with no reset time are omitted rather than given an invented reset.

The default Claude automatic-check minimum is five minutes. Existing account consent and refresh preferences are preserved. Connection checks no longer ask Quotakin for access to Claude's Keychain item after login.
