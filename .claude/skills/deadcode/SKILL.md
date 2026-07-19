---
name: deadcode
description: Sweep the TailRDP repo for dead code — unreachable/unused code, stale files or comments, unused dependencies, duplication, broken links, inconsistent names, confusing structure — then prove and apply the smallest verified cleanups. Use when asked to find dead code, remove cruft, clean up the repo, or run /deadcode.
---

# Dead-Code Sweep

Iterative find → prove → cut → verify loop over the TailRDP repo. Fable (main thread)
reasons, reviews, and orchestrates; **mechanical scanning is delegated to cheaper agents**
(haiku/sonnet Explore or cavecrew-investigator) so main-thread tokens go to judgment only.

## Scope

Hunt for, in this order of confidence:

1. **Unreachable / unused code** — private symbols with zero callers, functions never
   invoked, branches that can't execute, `#if` blocks for dead configs.
2. **Stale files** — sources not referenced by the build, orphaned assets, leftover
   scratch/experiment files.
3. **Stale comments** — comments describing code that no longer exists or behaves as stated.
4. **Unused dependencies** — Package.swift products never imported.
5. **Duplication** — near-identical functions/blocks that should collapse into one.
6. **Broken links** — dead file paths or URLs in docs/comments.
7. **Inconsistent names** — same concept under multiple names, or names contradicting behavior.
8. **Confusing structure** — files/types in surprising places (report only; restructuring
   needs approval).

## Protections (hard rules — never violate)

- **Uncommitted work**: `git status --porcelain` first. Never touch modified/untracked
  files the user is actively working on. Never `git checkout`/`stash`/`clean`.
- **Active code**: a symbol reachable via reflection, `@main`, SwiftUI previews, test
  targets, ObjC runtime, or CLI entry points is NOT dead. Public API of a library target
  counts as used.
- **Generated code**: skip anything build-generated or vendored.
- **Uncertain**: any candidate you cannot *prove* dead goes to the deferred list, not
  the chopping block. Doubt = defer.
- **Unrelated work**: never fold in refactors, style fixes, or improvements beyond
  removing the proven-dead item.

## Workflow

1. **Baseline** — record `git status`, confirm clean-enough tree, then run the full
   verification suite once (see below) so pass/fail deltas are attributable.
2. **Scan (delegated)** — spawn cheap read-only agents in parallel, one per category
   group (e.g. unused symbols via graph tools; stale files/links; dependency imports;
   duplication/naming). Prefer `code-review-graph` tools (`query_graph_tool`
   callers_of, `refactor_tool` dead-code, `get_impact_radius_tool`) over raw grep.
   Each agent returns `file:line — claim — evidence` only.
3. **Triage (main thread)** — Fable ranks candidates by confidence × risk. Pick ONE
   lowest-risk candidate first.
4. **Prove** — before deleting, show zero-caller evidence: graph query + grep for the
   symbol name (string refs, selectors, test names). For files: not in target sources,
   no imports. Paste the proof.
5. **Cut** — smallest coherent change. One candidate (or one tightly-coupled cluster)
   per iteration.
6. **Verify** — rerun ALL of:
   - `swift build` (use `.claude/skills/run-tailrdp/driver.sh` conventions)
   - `swift test`
   - runtime smoke check via the `run-tailrdp` skill if the change touches app code
   - `git diff` review — confirm the diff contains only the intended removal
7. **Keep or revert** — verification green → keep. Any failure → `git checkout -- <files>`
   for that change, move candidate to deferred, continue.
8. **Loop** — back to step 3 while proven candidates remain.

## Stop conditions

Stop and report when ANY holds:
- No proven candidates remain (only deferred/uncertain ones).
- Two consecutive iterations produced no keepable change (progress stalled).
- Verification unavailable (build/test broken at baseline, or environment missing) —
  do NOT delete anything on faith.
- A candidate requires user approval: public API removal, dependency removal,
  file/directory restructuring, anything with external consumers.

## Token discipline

- Main thread: triage, proofs review, diff review, final report only.
- Delegate scans to `Explore` or `caveman:cavecrew-investigator` with
  `model: haiku` where the work is enumeration; `sonnet` where light judgment needed.
- Batch: one agent per category group, launched in parallel, single message.
- Agents return compressed `file:line` tables, never file dumps.

## Output contract

1. **Result** — succeeded / partial / blocked.
2. **Changes kept** — per change: what was removed, why dead, proof line.
3. **Evidence** — build/test/runtime output (decisive lines only), final `git diff --stat`.
4. **Deferred candidates** — everything uncertain or approval-gated, each with
   `file:line — why suspected — why deferred`.
5. **Skipped** — categories not swept, with reason.

Never commit — leave changes staged in the working tree for the user to review.
