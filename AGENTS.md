# AGENTS.md

**All agent and contributor guidance for this repository lives in
[`CLAUDE.md`](CLAUDE.md). Read it first and follow it exactly.**

Everything applies to *every* agent and new contributor — not just Claude Code:
the coding conventions, the build/test/release workflow (XcodeGen ➜ `project.yml`,
fastlane + GitHub Actions, Xcode Cloud via `ci_scripts/`), the testing rules, the
"keep the docs in lockstep with the code" rule, and the non‑negotiable **Safety**
rules that must never be crossed without explicit human sign‑off.

This file is intentionally a **thin pointer**, not a second copy of the rules. It
exists so tools that look for `AGENTS.md` (Codex, Cursor, and other agents) are
sent to the same single source of truth. To avoid two documents drifting apart,
**never duplicate guidance here — put it in [`CLAUDE.md`](CLAUDE.md) and update it
there.**

If an `AGENTS.override.md` is added later, it layers **on top of** this file and
`CLAUDE.md` (it augments them; it does not wholesale replace them).
