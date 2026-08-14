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
