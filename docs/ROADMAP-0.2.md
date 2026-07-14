# Roadmap — 0.2.0

> **Status: shipped in v0.2.0.** All four phases (1a, 1b, 2a, 2b) landed. Cost
> estimation and live rate-limit bars were investigated and deliberately omitted
> (not reliably derivable from local data — see the notes below). The
> pay-as-you-go API-key path remains backlog.

Two features, planned. Target release **0.2.0**. Sequence: `1a → 1b → 2a → 2b`.

## Feature 1 — Claude status

Surface `/status`-style information: per-session detail **and** a global
environment panel.

### Data sources (verified present)

- **Per-session — from the transcript we already tail** (no new sources):
  `message.model` (→ friendly, e.g. "Opus 4.8"), envelope `version` (CC version),
  `gitBranch`, `message.usage` (context ≈ `cache_read + cache_creation + input`;
  `output`), `permissionMode`, `entrypoint`.
- **Global — read-only config:**
  - `~/.claude.json → oauthAccount`: `emailAddress`, `displayName`,
    `organizationName`, `organizationRole`, `billingType`,
    `hasAvailableSubscription`, `installMethod`.
  - `~/.claude/settings.json`: `theme`, `enabledPlugins`.
  - CC version: `claude --version`, else newest transcript.

> **Guardrail:** `~/.claude.json` also contains oauth tokens + cache. Read only
> the `oauthAccount` display fields; never write the file; never surface secrets.
> Consistent with the project anti-patterns.

### Changes

- `TranscriptParser`: also capture last-seen `model`, CC `version`, `gitBranch`,
  a `usage` snapshot, `permissionMode`. Expose as a `SessionDetail`.
- `Session`: add `detail: SessionDetail?`; `SessionScanner` fills it for live rows.
- New `EnvironmentStatus` loader (background, cached) for the global fields.
- UI: per-session → expandable/disclosure row → detail grid. Global → footer
  "Claude Status" popover (mirrors the legend `?`) and/or a slim header strip.

### Phasing

- **1a — per-session detail** (transcript-only, self-contained). *Start here.*
- **1b — global environment panel** (read-only config parsing).

## Feature 2 — Generic callbacks / aggregate busylight

Drive a single physical indicator (busylight) — and any user-defined callback —
from an **aggregate** state, defined generically so callbacks are configurable.

### Aggregation

- Derive one aggregate state from live sessions with its own **urgency order**
  (distinct from the list-sort priority): **Attention > Working > Ready > Idle >
  none**. No live sessions → a `none` state that fires an off/clear callback.

### Engine (`CallbackEngine`)

- Observes `SessionStore.sessions`, computes the aggregate, **debounces** (~400ms)
  to avoid flapping, runs the configured command on change.
- Off-main via `Process`, PATH augmented (like the hook installer, so `busylight`
  resolves), logs failures, never crashes. Fires current state on launch and the
  clear-callback on quit.

### Config

- `~/Library/Application Support/CCStatusLight/callbacks.json` (our dir → clean
  uninstall). Schema: `enabled` + `state → { command }` with placeholders
  `{state} {color} {count} {name}`, incl. a `none` key. Ship a commented
  busylight example; a default state→color map provides `{color}`.

### Preferences UI

- New Preferences window (`⌘,`) — the app has none today. Per-state command rows,
  enable toggle, placeholder help, per-row **Test** button, "Reveal config", and
  it can absorb the footer "All Spaces" toggle. Config file stays source of truth.

### Migration

- An app-driven busylight **supersedes** the current `SessionStart→on blue` /
  `SessionEnd→off` hooks (the app can color by real state). Those hooks would
  fight the app, so recommend removing them once the app drives the light.
- Anti-patterns hold: no LaunchAgent, no `~/.claude.json`/`settings.json` writes.

### Phasing

- **2a — engine + JSON config** (busylight works headless).
- **2b — Preferences UI.**

## Backlog / future

- **Real usage & cost for pay-as-you-go (API) accounts.** The Max *subscription*
  rate-limit bars aren't reachable, but users on an **Anthropic API (Console)**
  account could opt in by storing an **API key** locally; the documented
  **Usage & Cost Admin API** (`/v1/organizations/usage_report/messages`,
  `.../cost_report`) returns real per-model token usage and cost to draw bars
  from. This is a *separate account/billing* from a Max subscription and would
  not reproduce `/status`, so it's an opt-in for API users only — not a default.

## Open decisions

1. Busylight urgency order — confirm **Attention beats Working** for the light.
2. Global-status presentation — footer popover vs. header strip vs. both.
3. Auto-offer to remove the old busylight hooks during Feature 2.
