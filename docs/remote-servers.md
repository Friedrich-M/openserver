# Remote servers

How an agent inspects, installs and updates the bundle on one of the user's
servers over ssh. Read [AGENTS.md](../AGENTS.md) and
[docs/testing.md](testing.md) first; paths are relative to the repository
root. Act on a server only when the user asks, and show the dry run before
the real run.

## Getting a connection

Cluster logins take a password and a second factor, which an agent cannot
answer. The user opens one shared connection in their own terminal; the
agent reuses it without touching `~/.ssh/config`:

```sh
# The user, once (expires after 2 hours):
ssh -fN -o ControlMaster=yes -o ControlPath=~/.ssh/cm-%r@%h:%p -o ControlPersist=2h <host>
# The agent, every command:
ssh -o ControlPath=~/.ssh/cm-%r@%h:%p <host> '<command>'
ssh -o ControlPath=~/.ssh/cm-%r@%h:%p -O check <host>   # is it open?
ssh -o ControlPath=~/.ssh/cm-%r@%h:%p -O exit <host>    # close it
```

`ssh -o BatchMode=yes <host> true` failing with `keyboard-interactive` means
there is no connection to reuse yet: ask the user. Use only hosts that log
in as the user's own account.

## The remote shell may read your input

A non-interactive ssh command still runs the remote `~/.bashrc`, and a
`~/.bashrc` can start another shell before the command — a bare `zsh` line
did on one cluster. That shell reads ssh's stdin and executes it, so data
piped to the command is run as shell code, line by line, before the command
starts. Until a host is known to be safe:

- Run every command with `ssh -n` (stdin from `/dev/null`).
- Probe before piping data: `echo probe | ssh … 'cat'` must print `probe`.
- A command line is one argument to the remote `bash -c`, capped at 128 KiB
  on Linux: larger payloads go over stdin, after the probe passes, with a
  checksum compared on both ends.

The bundle's own block hands over to zsh only for an interactive shell on a
terminal (`shell/bashrc`); a bare `zsh` elsewhere in the user's
`~/.bashrc` is theirs to remove — point it out, do not edit it unasked.

## Inspect first

Read-only, before any change: the hostname and login shell; whether
`~/server` exists, its `git log -1`, remote, uncommitted changes and
`.srv-state`; the first line and size of each startup file (`~/.bashrc`,
`~/.bash_profile`, `~/.profile`, `~/.zshrc`, `~/.tmux.conf`,
`~/.tmux.conf.local`) — first lines only, since a startup file can hold a
token; `~/.server-backup`; which of zsh, tmux, git, python3, nvim, gh,
claude, codex, uv and `module` exist; the home quota. Send the script with
`ssh -n … 'bash -s' < script` only after the stdin probe, or as the command.

## Installing

1. Build a zip-style bundle on the workstation: `git archive` of `HEAD`,
   plus the user's `server.json` and `hosts/*.local.sh` — never
   `secrets/secrets.enc`, never `.git`. On macOS build the tarball with
   `COPYFILE_DISABLE=1 tar --no-mac-metadata` so Linux tar sees no
   extended headers.
2. Dry run from a scratch folder on the server
   (`~/.cache/srv-dryrun/server/setup.sh --dry-run --here </dev/null`) and
   show the user what it would replace, add and install. Delete the folder.
3. On the user's go-ahead, refuse if `~/server` exists, unpack into `~`, and
   run `~/server/setup.sh </dev/null`; `server.json` answers the questions.
4. Report what changed: replaced files (and their backup folder), the
   `~/.bashrc` block, installed tools, values `server.json` overrode (git
   identity, models), and what still needs the user (GitHub sign-in,
   tokens, tmux `prefix + I`).

## Verifying

- An interactive login: `(sleep 6; printf 'srvinfo; exit\n'; sleep 8) | ssh -tt …`
  — the shell is zsh, the profile, modules and SLURM defaults are right.
- `bash -lc 'command -v rg uv codex'` finds the tools without zsh.
- `~/.bashrc` ends with exactly one server block.
- A private tmux server (`tmux -L <name> -f ~/.tmux.conf`) shows `mouse`
  and `set-clipboard` on; kill it afterwards.
- `srvinfo`'s `scratch` line: `$HOME` means no profile candidate exists or
  is writable on that host — report it.

## Updating a server

A server installed from a bundle has no remote: `srvsync` re-runs setup but
pulls nothing. Once the server is signed in to GitHub
(`tools/github.sh`, which the user completes in a browser), point
`~/server` at the repository and `srvsync` pulls updates:
`git -C ~/server remote add origin <url> && git -C ~/server fetch origin`,
then reset only after showing the user what local commits would go.
