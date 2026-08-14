# Privacy

Quotakin is designed to show useful capacity and usage information without retaining conversation content.

## What stays on your Mac

Quotakin stores summary metadata such as provider, model, observation time, token counts, quota windows, and opaque hashed source identifiers. It does not store prompts, responses, transcript text, tool contents, raw source paths, credentials, or cookies.

- Local history reads token metadata already present in `~/.claude/projects` and `~/.codex/sessions`.
- Account checks begin only after you choose **Connect** or **Check**. They are read-only and never refresh or save provider credentials.
- The optional Claude status-line helper stores only quota percentages, reset times, and an observation timestamp. Installation and removal are user-initiated.
- Pricing estimates use the reviewed catalog bundled with the release. Quotakin does not download a mutable pricing feed at launch.

## Network requests

Quotakin can make consented, read-only requests to provider account-quota services. It also checks the public Claude and OpenAI service-status pages without authentication. These status requests contain no provider credential or local usage record, though the service can observe normal network metadata such as an IP address.

Choosing **Stop Account Checks** disables future account-quota requests while local history continues to work.

## Bug reports

**Report a Bug** opens a draft GitHub issue containing the Quotakin version and macOS version. Nothing is submitted until you review and submit it on GitHub.
