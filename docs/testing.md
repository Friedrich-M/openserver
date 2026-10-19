# Testing

What each test proves, where it may run, and how to add one. Read
[AGENTS.md](../AGENTS.md) first; paths are relative to the repository root.

## Where things may run

| Where | What may run | Why |
| --- | --- | --- |
| The workstation (an agent's own machine) | `tests/check.sh` only | It works on a scratch copy and a scratch `$HOME` with a system-only `PATH`; nothing else here is isolated |
| CI (`.github/workflows/check.yml`) | `check.sh`, then `container.sh` | Every runner and container is thrown away afterwards |
| A disposable container or VM | `SRV_TEST_DISPOSABLE=1 tests/container.sh` | It installs for real into that machine's `$HOME` |
| A user's servers | Only when asked, per [docs/remote-servers.md](remote-servers.md) | They are in daily use |

Never run `setup.sh`, an installer, or any program under a scratch `$HOME`
on the workstation outside `check.sh`. Two things a scratch `$HOME` does not
contain on macOS:

- **Homebrew is machine-wide.** `tools/nvim.sh`, `tools/rclone.sh` and
  `tools/cli.sh` install with `brew` on macOS; a "sandboxed" run installs
  into the real Homebrew.
- **The Keychain belongs to the real `$HOME`.** git's `osxkeychain` helper
  (named in the system gitconfig) and `gh` look for a Keychain under the
  scratch `$HOME`, find none, and macOS raises a "keychain not found"
  dialog that blocks the process until someone answers it. Its "Reset To
  Defaults" button resets the real login keychain.

`check.sh` avoids both: after its lint steps it exports
`GIT_CONFIG_NOSYSTEM=1`, `GIT_TERMINAL_PROMPT=0`, a scratch `GH_CONFIG_DIR`,
`HOMEBREW_NO_AUTO_UPDATE=1`, no `ZDOTDIR` (zsh would read this machine's own
`~/.zshrc` from it) and `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so no
dry run reaches this machine's `claude`, `codex`, `gh`, `rclone` or `brew`.
Its tmux check strips the `@plugin` lines, without which the vendored
config clones TPM and every plugin from GitHub as tmux starts.

## tests/check.sh

Offline apart from the CLI installer's reachability probe; about 20 s.
Runs on macOS's `/bin/bash` 3.2 as well as Linux bash, which is half of
what it checks: run it as `/bin/bash tests/check.sh` on a Mac before a push.

| Section | Proves |
| --- | --- |
| Syntax, shellcheck | Every script parses under bash, zsh and dash (POSIX files); no shellcheck warnings |
| Publishable | No tracked file holds an e-mail address (beyond documentation placeholders), a home-directory path or a token-shaped string |
| Profiles | `hosts/local/` read first; a `.local.sh` never a profile; every `hosts/*.sh` sets the `generic.sh` names in its order; every value is the same under bash and zsh; `shell/env.sh` is silent in both |
| Module loader | `a\|b` alternatives, the newest-version fallback, the missing list, a machine with no `module` |
| Settings | `server.example.json` renders; credential-shaped keys and values are refused |
| deploy | Copies, skips identical files, backs up what it replaces |
| Installers, dry run | Every `tools/*.sh` exits 0, plain and `SRV_UPDATE=1` |
| setup.sh, dry run | Every profile, plain and `--update`: exit 0, no step fails, nothing written; pruning keeps the machine's and its site's profiles and never a `.local.sh` |
| `--config-only`, for real | Configs land in a scratch `$HOME`; a fresh bundle is pruned and committed with no git identity; a second run is a no-op |
| bash | Your `~/.bashrc` lines kept between the two blocks; an Ubuntu-style early `return` still gives `ssh host cmd` the environment; blocks carry the real path away from `~/server`; a lone marker keeps the lines after it; an upgrade loses no line; `~/.profile` respected; a bare home works |
| zsh and tmux | Your `~/.zshrc` kept with one last block; a setup of your own (oh-my-zsh or powerlevel10k) keeps its history and is not loaded twice; an old bundle copy set aside; your `~/.p10k.zsh` kept; your `~/.tmux.conf.local` kept under the block; a non-gpakosz `~/.tmux.conf` untouched |
| Core and optional tools | Core installers run by default and optional ones only when named (`--with`, `setup.with`); `setup.tools` lists from `server.json`; `--tools` with `--github`; no inherited stale setting |
| git, conda and command names | Your `~/.gitconfig` kept under the bundle's include, yours winning; no credential helper; your `~/.condarc` kept; no alias takes a system command's name |
| tmux | Mouse, wheel, drag-to-copy, OSC 52 settings winning over a `mouse off` of yours, and a real copy read back from the buffer, in a private tmux server |

It copies the bundle from `git ls-files` (tracked plus untracked, not
ignored), so uncommitted edits are tested and the user's `server.json`,
`*.local.sh` and secrets are not.

## tests/container.sh

A zip-style install (a copy with no `.git`) into the machine's real `$HOME`,
refused without `SRV_TEST_DISPOSABLE=1`, with every optional tool
(`--with=rclone,uv,claude,codex`). It checks that `setup.sh` exits 0
with every step clean, the bundle is pruned and committed, each tool is on
`PATH` in `bash -lc` and `zsh -ic`, `~/.bashrc`, `~/.zshrc` and (under
gpakosz/.tmux) `~/.tmux.conf.local` end with exactly one block,
`srvinfo` exits 0, and a second run from a shell that sourced nothing
changes nothing.

## CI

`offline` runs `check.sh` on `ubuntu-latest` and on `macos-latest` under
`/bin/bash`; `install` then runs `container.sh` in `ubuntu:24.04` and
`rockylinux:9` containers (Rocky stands in for the clusters' RHEL) and on a
`macos-latest` runner (Homebrew); `quickstart` runs the README's
one-command install on a bare `ubuntu:24.04` with no checkout, at the
branch being tested (`--ref`), with a token while the repository is
private and the answers for an unattended run.
Read a failure with
`gh run view <id> --log-failed`; a job's raw log through
`gh api repos/<owner>/<repo>/actions/jobs/<job>/logs`. Use the `gh` account
that owns the repository (`gh auth status`, `gh auth switch -u <account>`).

## Adding a check

- Offline-testable behaviour goes in `check.sh`; what needs a network or a
  real install goes in `container.sh`.
- Prove the check can fail: reintroduce the bug, see the FAIL line, restore.
- Under `set -euo pipefail`: capture a child's output with
  `out="$(…)" || out="<exit $?>"` before testing it, never
  `cmd | grep -q` (an early `grep -q` exit is a SIGPIPE failure), and give a
  `find` or `ls` over a directory that may be missing its own guard.
- One `section` per behaviour, closed with `passed "<summary>"`; `fail`
  says what broke and with which input.

## What no test covers

GitHub sign-in (`gh auth login` needs a browser code), unlocking
`secrets/secrets.enc` (needs the passphrase), OSC 52 reaching a real
terminal's clipboard, environment modules and SLURM (CI has neither), and
any host profile's paths on its real cluster. Say so when a change touches
them, and check on a real host when asked.
