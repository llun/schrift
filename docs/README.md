# Schrift documentation

Project documentation for the Schrift iOS app. These are **living documents** —
keep them current with the code, in the same change that alters behavior (see the
"Docs & plans convention" in [`../CLAUDE.md`](../CLAUDE.md)).

Agent- and contributor-facing conventions, workflow, and safety rules live in
[`../CLAUDE.md`](../CLAUDE.md), which is the single source of truth for "how we
write code here." The documents below capture the architecture and design
rationale that `CLAUDE.md` only summarizes.

## Design & architecture

- [`architecture.md`](architecture.md) — the full architecture and design
  rationale: app structure, networking, the on-device Yjs save path, screens, and
  the endpoint surface.
- [`offline-and-sync.md`](offline-and-sync.md) — the on-device content and list
  caches, background revalidation, and the invariants that keep a full-overwrite
  save from ever eating content.
- [`design-system.md`](design-system.md) — the design-system refresh: adaptive
  dark theme, in-app localization, layout fidelity, and read-only version history.

## Build, CI & release

- [`ci.md`](ci.md) — how the PR build/test checks work and how the merge guard is
  configured.
- [`testflight-setup.md`](testflight-setup.md) — the TestFlight release pipeline
  and one-time signing setup.
