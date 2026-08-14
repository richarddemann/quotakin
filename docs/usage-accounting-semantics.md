# Usage accounting semantics

UsageBar normalizes transcript events before persistence, aggregation, or pricing. `TranscriptTokenTotals` defines token meaning and `TranscriptUsageRecord` carries identity and provenance; downstream code must not reconstruct different meanings from provider payloads.

## Token buckets

The additive buckets are mutually exclusive:

- `uncachedInputTokens`: input not served from a cache. If a provider reports input inclusive of cache reads, subtract `cachedInputTokens` first.
- `cachedInputTokens`: input served from a cache.
- `cacheCreationInputTokens`: input written to a provider cache.
- `outputTokens`: all generated output, including reasoning output when reported.

`reasoningOutputTokens` is a labelled subset of `outputTokens`. It is useful for explanation and diagnostics but is never added to or priced in addition to output. The canonical processed total is:

```
uncached input + cached input + cache creation input + output
```

A provider-reported total is retained only as evidence. A mismatch creates a diagnostic; it does not override the canonical total.

## Identity and deduplication

`logicalDedupeKey`, scoped by provider, is the global semantic deduplication key. Prefer provider request ID, then message/event ID. If no stable provider identifier exists, collectors may derive a deterministic digest from non-content event metadata. A source path, filename, byte offset, or observation timestamp alone is not a logical identity.

`TranscriptPhysicalIdentity` (`sourceID`, source generation, and byte offset) is separate and source-local. It supports cursors and provenance but is not part of the deduplication key. Source IDs must be opaque: do not persist transcript paths, prompts, responses, or account identifiers.

The same semantic identity found in two files contributes once. Distinct identities contribute separately even when their token counts and timestamps match.

## Cost provenance

Every presented cost carries `UsageCostProvenance`: `providerReported`, `modelPriced(catalogID:effectiveDate:)`, or `unpriced`. Provider-reported costs and catalog estimates must not be silently combined. Transcript records retain provider-reported USD separately; later pricing code must attach its catalog identity and effective date to estimates.

Reasoning tokens use the output rate only through the inclusive `outputTokens` bucket. Charging `reasoningOutputTokens` separately is double charging.

## Diagnostics

Accounting diagnostics are fixed issue codes and aggregate counts. They must not contain arbitrary provider payloads, transcript content, filesystem paths, model responses, credentials, or account identity.

The initial contract detects negative token counts, reasoning larger than output, provider-total mismatches, and duplicate semantic identities. Parsers should reject invalid records at their boundary; summaries retain diagnostics so reindex and import jobs can report excluded or questionable data without exposing source material.
