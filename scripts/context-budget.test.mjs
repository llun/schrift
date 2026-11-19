import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { check, historyHit, parseAdded, routeLinks, sectionBytes, slug } from "./context-budget.mjs";

test("history in an added line is caught, ordinary text is not", () => {
  for (const line of ["Fixed in (#2837).", "see PR 15b", "phase 2 of the editor", "since 19 November 2026", "since Nov 19, 2026", "since 2026-11-19"])
    assert.ok(historyHit(line), line);
  for (const line of ["Use `#agents-surfaces`.", "HTTP 404 means gone", "colour #0b6a69", "since the save finished", "a phased rollout"])
    assert.ok(!historyHit(line), line);
});

test("a section runs from its anchor to the next heading at its level or above", () => {
  const text = ["# A", "", '<a id="x"></a>', "### X", "body", "#### sub", "more", "### Y", "other"].join("\n");
  assert.equal(sectionBytes(text, "x"), Buffer.byteLength(['<a id="x"></a>', "### X", "body", "#### sub", "more"].join("\n")));
  assert.equal(sectionBytes(text, "y"), Buffer.byteLength(["### Y", "other"].join("\n")));
  assert.equal(sectionBytes(text, "missing"), null);
  assert.equal(slug("Status Posts & Actions"), "status-posts--actions");
});

test("route links resolve against the route file and skip web links", () => {
  assert.deepEqual(routeLinks("| a | [G](docs/g.md#s), [H](https://x.dev/h.md) |", "AGENTS.md"), [{ line: 1, links: [{ file: "docs/g.md", anchor: "s" }] }]);
});

test("a file over its ceiling fails, and a ceiling left above a shrunk file must come down", () => {
  const root = mkdtempSync(join(tmpdir(), "budget-"));
  writeFileSync(join(root, "A.md"), "x".repeat(100));
  assert.equal(check(root, { target: 50, files: { "A.md": 100 } }).errors.length, 0);
  assert.match(check(root, { target: 50, files: { "A.md": 90 } }).errors[0], /over its ceiling/);
  const high = check(root, { target: 50, files: { "A.md": 150 } });
  assert.match(high.errors[0], /must come down to 100/);
  assert.equal(high.ceilings["A.md"], 100);
  assert.equal(check(root, { target: 200, files: { "A.md": 200 } }).errors.length, 0);
});

test("added history fails only with a base to compare against", () => {
  const root = mkdtempSync(join(tmpdir(), "budget-"));
  writeFileSync(join(root, "A.md"), "rule\n");
  const config = { target: 100, files: { "A.md": 100 } };
  const diff = () => [{ file: "A.md", line: 2, text: "Changed in PR 12." }];
  assert.match(check(root, config, { base: "main", diff }).errors[0], /adds history/);
  assert.equal(check(root, config, { diff }).errors.length, 0);
});

test("a line moved from another file is not an added line", () => {
  const diff = ["diff --git a/A.md b/A.md", "--- a/A.md", "+++ b/A.md", "@@ -3,1 +2,0 @@", "-Moved in PR 12.", "diff --git a/B.md b/B.md", "--- /dev/null", "+++ b/B.md", "@@ -0,0 +1,2 @@", "+Moved in PR 12.", "+New in PR 13."].join("\n");
  assert.deepEqual(parseAdded(diff, ["B.md"]), [{ file: "B.md", line: 2, text: "New in PR 13." }]);
});
