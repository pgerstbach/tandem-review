# Working on agent-review-loop

This repository is a skill for Claude Code and Codex: one agent has the other
review its working tree and iterates on the findings. `SKILL.md` is what an
agent follows when using it; `scripts/review.sh` does one review round.

When you change this repository:

- Keep it small. A feature has to earn its lines.
- Shell scripts must pass `bash -n` and `shellcheck`, and `tests/run-tests.sh`
  must pass. Add a test for every behavior change in `review.sh`.
- Exit codes and environment variables are an interface. Do not change
  existing ones; when you add one, update the header of `scripts/review.sh`,
  `SKILL.md` and `README.md` together.
- Keep the reviewer's restrictions: prompt on stdin; Claude with
  `--restricted`, no MCP, prompts auto-denied and Bash limited to exact
  commands (no wildcards that admit extra flags); Codex in its permission
  profile (repository and private temp writable, a fixed list readable, no
  network, never together with `-s`, which disables the profile). Do not
  hand the reviewer write or edit tools.
- Be honest in commit messages about what was tested and what was not.
