# txehq/txe PR 4024 at 3d9840757, as the failed `codex-review` run saw it

The hold TXE-4786 fixes, first measurement. Run 39242893011 attempt 1 (job 118027717843) polled
until 2026-10-19T11:15:33Z and printed, in this order:

```text
PR #4024 head: 3d9840757246a2459c526c4a93735649c08bc2dc
connector state: {"code_review":{"commit_sha":"3d9840757246a2459c526c4a93735649c08bc2dc","has_any_findings":true,"has_unresolved_findings":null,"status":"completed"},"security_review":{"commit_sha":"3d9840757246a2459c526c4a93735649c08bc2dc","has_any_findings":null,"has_unresolved_findings":null,"status":"running"}}
FAIL: the connector's state block reports findings on 3d9840757246a2459c526c4a93735649c08bc2dc but no connector review of 3d9840757246a2459c526c4a93735649c08bc2dc and no clean-pass receipt for it were found — re-run this check
```

The PR merged later (2026-10-19T11:40:23Z), so these files are the API's answers read on
2026-10-21, cut back to that moment. `ops/ci/test-codex-review-check.sh` expects a FAIL naming
P1 thread 4312476492.

## Recorded on 2026-10-21

```bash
gh api repos/txehq/txe/pulls/4024                                      # pull.json, trimmed
gh api --paginate 'repos/txehq/txe/issues/4024/comments?per_page=100'  # issue-comments.json
gh api --paginate 'repos/txehq/txe/issues/4024/events?per_page=100'    # issue-events.json
gh api --paginate 'repos/txehq/txe/pulls/4024/reviews?per_page=100'    # reviews.json
gh api --paginate 'repos/txehq/txe/pulls/4024/comments?per_page=100'   # review-comments.json
gh api graphql --paginate -F owner=txehq -F name=txe -F pr=4024 -f query="$THREADS_QUERY" | jq -s .  # review-threads.json
```

`THREADS_QUERY` is the one in `ops/ci/codex-review-check.sh`. Each list is joined into one array.

## Reconstructed, and from what

- **The cut.** Every comment, event, review and review comment created after 11:15:34Z is
  dropped: review 5570917125, the connector's review of 3d9840757 at 11:34:40Z after the
  `@codex review` at 11:29:50Z, and its thread 4313319954 go with it.
- **The state block** is replaced by the one the run printed, above. The summary comment is
  rewritten in place on every pass, so the recorded one is the 11:34:43Z pass's. Its two rows'
  times are set to 11:15:33Z, when the failed run first read the state as completed: an upper
  bound, not the connector's own time. No receipt in this recording names a code review, so the
  check does not read that time here.
- **The threads' resolution.** On 2026-10-21 all nine remaining threads read
  `isResolved: true, resolvedBy: connorwang`. The author resolved them during the recovery, after
  the failed run and before the `@codex review` (TXE-4786's account). The review comments in this
  recording are the threads' ids; each thread is set `isResolved: false, resolvedBy: null`.
- **Kept as read:** `isOutdated`, and each first comment's `commit.oid`. The head on 2026-10-21
  is still 3d9840757, the head the run saw, so a thread's position and outdatedness are the same
  answers GraphQL gave then. Thread 4312476492's first comment sits at 3d9840757 and is not
  outdated.
