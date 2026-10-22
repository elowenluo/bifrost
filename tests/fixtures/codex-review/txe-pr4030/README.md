# txehq/txe PR 4030 at d3025fd29, as the failed `codex-review` run saw it

The hold TXE-4786 fixes, second measurement. Run 39449987893 attempt 2 (job 118727110258)
printed at 2026-10-20T15:46:45Z:

```text
PR #4030 head: d3025fd29d8a34d0a65f39fda2850bc94c760f5d
connector state: {"code_review":{"commit_sha":"d3025fd29d8a34d0a65f39fda2850bc94c760f5d","has_any_findings":true,"has_unresolved_findings":false,"status":"completed"},"security_review":{"commit_sha":"d3025fd29d8a34d0a65f39fda2850bc94c760f5d","has_any_findings":false,"has_unresolved_findings":false,"status":"completed"}}
FAIL: the connector's state block reports findings on d3025fd29d8a34d0a65f39fda2850bc94c760f5d but no connector review of d3025fd29d8a34d0a65f39fda2850bc94c760f5d and no clean-pass receipt for it were found — re-run this check
```

Attempt 1 (job 118722425044) printed the same state and verdict at 15:41:08Z. The receipt for
d3025fd29 (comment 6295043234) came at 15:52:06Z, 4 min 35 s after an `@codex review` at
15:47:31Z. The PR was later force-pushed (16:54:12Z) and merged at 58b951c02, so these files are
the API's answers read on 2026-10-21, cut back to 15:46:46Z. `ops/ci/test-codex-review-check.sh`
expects a PASS: every live thread is a resolved P2.

## Recorded on 2026-10-21

The same six reads as `../pr4024/README.md`, for PR 4030.

## Reconstructed, and from what

- **The cut.** Every comment, event, review and review comment created after 15:46:46Z is
  dropped, the receipt 6295043234 with them. The threads kept are those whose first comment is
  in the cut review comments.
- **The head.** `pull.json`'s head is d3025fd29, the run's.
- **The state block** is replaced by the one the run printed, its rows' short sha set to
  `d3025fd`, and their times to 15:41:07Z, when attempt 1 first read the state as completed: an
  upper bound, not the connector's own time.
- **Positions.** GraphQL gives a comment's `commit` as the last commit it sat on. Read on
  2026-10-21:
  - Thread 4325960050 sat at d3025fd29 and is outdated now, so it was outdated by a later push
    and was live at d3025fd29. It is set `isOutdated: false`.
  - Threads 4326055923 and 4326703373 sit at 58b951c02, live through the final head. They are
    set at d3025fd29, live. That is the worst case for the check: it counts them.
  - The other seven sit at commits reviewed before d3025fd29 and are kept as read, outdated.
- **Kept as read:** every thread's resolution. All ten read `isResolved: true, resolvedBy:
  connorwang`. The connector's own `has_unresolved_findings: false` in the printed state says the
  same at 15:46Z.
