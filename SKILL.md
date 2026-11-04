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
  `response=` path from the most recent round with a valid verdict: exit
  0/10/20/30) and, after the human answered questions,
  `HUMAN_ANSWERS="<their answers, verbatim>"`. Keep that reference unchanged
  when retrying exit 6/7/8; never pass a malformed or partial failure response
  as the previous review. Omit it if no valid round has completed yet.

**A review takes minutes.** Run the command with a long tool timeout (≥ 20
min) or in the background and wait for it. Do not edit files while it runs —
the reviewer reads the live working tree.

**Codex as implementer:** the script calls the Claude CLI, which needs
network access. Run it outside the sandbox (request escalated permissions
for this command).

The review is printed on stdout; exits 7/8 leave stdout empty. The last
stderr line is the status:

```
agent-review: verdict=CONCERNS questions=0 changed=no response=<path>
```

## What to do with the result

| Exit | Meaning | Action |
|------|---------|--------|
| `0` | APPROVE | Done only if `changed=no`. Otherwise follow the change check below and run another round. |
| `10` | CONCERNS | Triage every finding (below). If you changed code or `changed` is not `no`, run the next round; otherwise you are done. |
| `20` | BLOCK | Fix the blocking findings, triage the rest, run the next round. |
| `30` | Questions for the human | **Stop the loop.** Pass the questions to the human verbatim, wait for the answer, then run the next round with `HUMAN_ANSWERS`. The verdict is in the status line; handle its findings in the same round. |
| `6` | Malformed response | Retry the same round once. If it fails again, report to the human. |
| `7` | Reviewer timed out | Inspect the saved output and the time limit. Retry once if a transient failure or an insufficient limit explains it; otherwise report the cause to the human. |
| `8` | Reviewer CLI failed | Inspect the saved output. Retry once only for a plausibly transient failure; follow the authentication rule below. If it fails again, report the error output to the human. |
| `1`, `2` | Usage / setup error | Fix the call or snapshot error (wrong base, nothing to review, CLI missing); do not count it as a round. |

Every dispatched run, including timeout and CLI failure, gets a status line
and a saved response. With logging enabled, the directory containing the
`response=` path also contains `cli.log`, `prompt.md`, `review.diff`, and
`meta` (script exit, CLI exit, elapsed seconds, and snapshot hashes).
Failure statuses use `verdict=TIMEOUT` or `verdict=CLI_FAILED`; partial
responses from those runs are not verdicts. `ARL_LOG=0` keeps only the response.
If saving fails, the script warns and retains temporary output at the
reported path instead; the original review/CLI exit code is preserved.

**Authentication errors:** if the output clearly says the reviewer is not
logged in or has an expired/revoked token or invalid OAuth grant, stop the
loop and ask the human to log in to that reviewer CLI. Include the error and
saved output path. Do not repeat the same call before authentication has
changed. A transient connection or server failure can justify one retry.

**Changes during a run:** these checks apply even after timeout or CLI
failure. With `changed=yes`, inspect the changes against the recorded
snapshot. The comparison proves that files changed, not who changed them.
Only undo specific unintended changes you can confidently attribute to the
reviewer, and tell the human. Preserve changes of uncertain origin; ask the
human only if their ownership or intent needs a decision. After checking the
changes, review the current tree again. With `changed=unknown`, resolve the
snapshot failure and repeat the review. Neither state permits a clean final
summary, even with APPROVE or exit 0. These verdict rounds still count
toward the usual round limits when `changed=yes` or `changed=unknown`.

### Triage

For each finding decide:

- **Fix** — it is right. When an automated regression test is appropriate,
  add it and confirm that it reproduces the finding before fixing the code;
  then make the fix and rerun the relevant checks.
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
   APPROVE with `changed=no` or a CONCERNS round with `changed=no` that
   needed no further changes, or
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
