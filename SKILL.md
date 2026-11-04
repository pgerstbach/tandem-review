---
name: agent-review-loop
description: Have the other coding agent (Claude Code or Codex) review your current changes and iterate on its findings autonomously, only involving the human for real decisions or when the loop does not converge. Use when the user asks for a review by Claude/Codex, a second opinion from another agent, "let the other agent check this", a cross-agent or peer review, or before declaring a non-trivial change done when the user has asked for agent reviews.
---

# Agent review loop

You are the **implementer**. You made a change; another agent reviews it live
in this repository, can read any file and run the configured test command.
You fix what is right, reject what is wrong with a reason, and repeat until
the review is clean — without bothering the human unless it is needed.

Nothing has to be committed. The script reviews the working tree as it is.

## Running one round

```bash
SUMMARY="What changed and why, 1-3 sentences" \
FOCUS="What the reviewer should look at" \
ROUND=1 \
<skill-dir>/scripts/review.sh auto [base-ref]
```

- `auto` picks the other agent (Claude → Codex, Codex → Claude). Name
  `claude` or `codex` to choose; reviewing with your own model works but
  says so in a warning, and you must tell the human.
- `base-ref` defaults to `HEAD` = only uncommitted changes. Use `main` (or the
  branch point) when the change spans commits.
- Test command: `TEST_CMD="npm test"`, or a `test_cmd=npm test` line in
  `.agent-review` at the repo root. Without one, a Claude reviewer cannot run
  tests at all, so set it whenever the project has tests.
- Re-review rounds also pass `ROUND=<n>`, `PREV_RESPONSE=<path>` (the
  `response=` path from the previous round's status line) and, after the
  human answered questions, `HUMAN_ANSWERS="<their answers, verbatim>"`.

**A review takes minutes.** Run the command with a long tool timeout (≥ 20
min) or in the background and wait for it. Do not edit files while it runs —
the reviewer reads the live working tree.

**Codex as implementer:** the script calls the Claude CLI, which needs
network access. Run it outside the sandbox (request escalated permissions
for this command).

The review is printed on stdout. The last stderr line is the status:

```
agent-review: verdict=CONCERNS questions=0 changed=no response=<path>
```

## What to do with the result

| Exit | Meaning | Action |
|------|---------|--------|
| `0` | APPROVE | Done. Give the final summary. |
| `10` | CONCERNS | Triage every finding (below). If you changed code, run the next round; if you changed nothing, you are done. |
| `20` | BLOCK | Fix the blocking findings, triage the rest, run the next round. |
| `30` | Questions for the human | **Stop the loop.** Pass the questions to the human verbatim, wait for the answer, then run the next round with `HUMAN_ANSWERS`. The verdict is in the status line; handle its findings in the same round. |
| `6` | Malformed response | Retry the same round once. If it fails again, report to the human. |
| `7` | Reviewer timed out | Retry once. If it fails again, report to the human. |
| `8` | Reviewer CLI failed | Retry once. If it fails again, report the error output to the human. |
| `1`, `2` | Usage / setup error | Fix the call (wrong base, nothing to review, CLI missing); do not count it as a round. |

If the status line says `changed=yes`, the working tree changed during the
review. Check what changed (the warning lists it); if the reviewer modified
files, revert that and tell the human.

### Triage

For each finding decide:

- **Fix** — it is right. Fix it.
- **Reject** — it is wrong or not worth it. Write down one sentence why. Put
  the rejection and its reason into `SUMMARY` of the next round, so the
  reviewer can weigh it instead of repeating itself.

Suggestions are optional. Do not fix things you were not asked to fix just
to make the reviewer happy, and do not reject a correct finding because the
fix is inconvenient.

## Limits — when to stop and ask the human

Count the rounds yourself. A round is one call of `review.sh` that returned a
verdict (exits 0/10/20/30); retries after 6/7/8 and setup errors do not count.
Keep the count in your notes across context compaction; the round number is
also in every recorded prompt under `.git/agent-review/`.

Escalate to the human — stop and give a short list of the open points with
both positions — when:

1. you reach the round limit, `ARL_MAX_ROUNDS` (default **3**), without an
   APPROVE or a CONCERNS round that needed no code changes, or
2. you and the reviewer disagree on the same finding twice: you rejected it
   with a reason, and the reviewer raised it again in two later rounds.

## Final summary for the human

When the loop ends, for whatever reason, tell the human briefly:

- reviewer, rounds, final verdict (and if it was a self-review)
- what was fixed, one line per finding
- what was deliberately rejected, with the reason
- open points or escalations, if any
- whether the reviewer ran the tests, and the result

## Files

| File | Purpose |
|------|---------|
| `scripts/review.sh` | Runs one review round. Options and exit codes in its header. |
| `templates/request.md` | Instructions sent to the reviewer. |
| `templates/response.md` | Response format the reviewer must use. |
| `tests/run-tests.sh` | Tests with fake reviewer CLIs. |
