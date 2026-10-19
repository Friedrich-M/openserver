# Security

OpenServer runs in your shell and handles credentials, so a security problem
in it matters. Please report one privately: use GitHub's **Report a
vulnerability** button on this repository's Security tab, rather than a
public issue. Say what is affected, how to reproduce it and what an attacker
could do; you will get an answer within a week.

Worth knowing before you report — these are documented choices, not bugs:

- `ca` and `cxa` start the coding agents with their permission prompts off
  (README, "Security notes").
- `~/.secrets.env` is exported to every process you start, so that SLURM
  jobs and `ssh host cmd` see your tokens.
- The encrypted bundle (`secrets/secrets.enc`) is AES-256-CBC with a
  PBKDF2-derived key and no separate MAC; its strength is the passphrase's
  (docs/secrets.md).

Supported: the latest release.
