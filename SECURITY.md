# Security

Please report vulnerabilities privately through GitHub:
**Security → Report a vulnerability** on this repository. Do not open a
public issue for them.

Relevant here are ways to make a reviewer escape its restrictions (run
other commands, write files, reach the network, read outside what the
README states), to make `scripts/review.sh` report a verdict the reviewer
did not give, or to leave reviewer processes running after a timeout.

The trust model is described in the README under "Where your code goes":
the reviewer runs live in your working tree and may run your test command.
Behavior that follows from that model is not a vulnerability, but reports
that the README understates a risk are welcome.
