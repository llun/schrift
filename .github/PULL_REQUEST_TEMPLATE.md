<!-- PR title must be a Conventional Commit (feat:/fix:/docs:/ci:/chore: …) —
     PRs are squash-merged, so the title becomes the commit subject on main
     that drives the release version (feat: → minor, feat!: → major,
     anything else → patch). -->

## Summary

<!-- What changed and why. -->

## Definition of done (see CLAUDE.md "Task workflow")

- [ ] `swift format --recursive --in-place Schrift SchriftTests` run
- [ ] Full test suite passes locally (`xcodebuild test -project Schrift.xcodeproj -scheme Schrift …`)
- [ ] New/changed behavior is covered by tests
- [ ] Affected docs updated in the same change (docs-lockstep rule)
- [ ] Agent work: the PR review loop has run and every review thread is resolved
- [ ] `Build & Test` is green on the latest pushed state
