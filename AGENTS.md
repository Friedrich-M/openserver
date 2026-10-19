# OpenServer Guidelines

OpenServer is an open-source bundle of shell, git, tmux, editor and
coding-agent configuration that `setup.sh` installs on any Linux or macOS
machine, from a laptop to an HPC login node, with one declarative profile
per host. Plain bash and POSIX sh: no package manager, no build step. The
README is the user's manual; this file is the contract for changing the
code; `docs/` holds the detail.

## Scope and Authority

- Read this file, then the reference doc for your task, then the README
  section and the file's header comment: every script and config starts
  with what it is for and what must not change.
- Run `git status` first and preserve unrelated work.
- The repository and its history are public. Never add personal
  information: a person's or lab's name, account, username, host alias,
  allocation, e-mail address or private path; the project's own repository
  address, in the README's install commands, is the one name it carries.
  Commit with a no-reply identity
  ([docs/releasing.md](docs/releasing.md#before-every-push)).
  Personal values live only in git-ignored files (`server.json`,
  `hosts/local/`, `hosts/*.local.sh`, `secrets/`) and in `$HOME`; shipped
  profiles are generic examples, never a real person's machines.
- Never print, decrypt or copy credentials: `secrets/secrets.enc`,
  `~/.secrets.env`, `~/.git-credentials`, rclone and ssh keys. Never run
  `secrets.sh lock` in an agent session (it prints a passphrase). Read a
  startup file's first line, not its body: it may hold a token.
- On your own machine run `tests/check.sh` and nothing else that installs
  or uses a scratch `$HOME`: on macOS Homebrew is machine-wide and a scratch
  `$HOME` sends git and gh to a missing Keychain, which blocks on a dialog
  ([docs/testing.md](docs/testing.md#where-things-may-run)).
- Touch a user's servers only when asked, dry run first
  ([docs/remote-servers.md](docs/remote-servers.md)).
- Commit, push, tag or publish only when asked; `tests/check.sh` passes
  before a push and CI after it.

## Layout

| Path | Role |
| --- | --- |
| `setup.sh`, `VERSION` | The only entry point (idempotent; flags in its header); the release version |
| `lib/common.sh` | Output, `run`, `deploy`, `backup`, `copy_once`, `ensure_block`, `clone_if_missing`, `install_script`, `fetch`, `online`; puts the bundle's bin folders on `PATH` |
| `lib/config.sh`, `server.example.json` | `server.json` rendered to `.srv-config.sh`; `cfg section.key` reads it |
| `lib/detect.sh` | Which machine: picks a profile by its header from `hosts/local/` then `hosts/`, then sources its `<name>.local.sh`; POSIX sh |
| `hosts/` | `generic.sh` (the template), `macos.sh`, `example-cluster.sh`; `local/` and `*.local.sh` are the user's own, git-ignored |
| `shell/` | `env.sh` (every shell), `zshrc` and `bashrc` (sourced from blocks in the user's own startup files), `aliases.zsh`, `functions.zsh`, `slurm.zsh`, `p10k.zsh` |
| `tools/` | One idempotent installer per tool, `tools/<x>.sh`; `github.sh` for identity and access |
| `config/git/`, `config/tmux/`, `config/conda/`, `config/claude/`, `config/codex/` | One configuration directory per tool; `config/tmux/tmux.conf` is vendored |
| `secrets/secrets.sh`, `secrets/` | Lock and unlock the encrypted credentials; the `~/.secrets.env` template |
| `install/make-bundle.sh`, `install/` | `server.zip` and `install.sh` for a hosted bundle; `bootstrap.sh` for a clone |
| `tests/`, `.github/workflows/check.yml` | `check.sh` (offline, any machine), `container.sh` (real install, disposable machines); CI runs both |
| `docs/`, `CONTRIBUTING.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/` | Reference docs; the contributor's entry point; vulnerability reports; the bug-report form |

## Reference Docs

| Doc | Covers |
| --- | --- |
| [README.md](README.md) | The user's manual: install routes, flags, `server.json`, what is installed and configured, shell files, machines, secrets, GitHub, the bundle |
| [docs/architecture.md](docs/architecture.md) | `setup.sh` step by step, profile and settings to shell, `deploy` / `copy_once` / `ensure_block`, recipes for a tool, machine, setting or startup-file change |
| [docs/testing.md](docs/testing.md) | Where each test may run and why, what each check proves, `container.sh`, CI, adding a check, what no test covers |
| [docs/releasing.md](docs/releasing.md) | The pre-push privacy and identity gate, versions and release notes, install routes, updating machines |
| [docs/secrets.md](docs/secrets.md) | How tokens reach a machine, the encrypted bundle's format and passphrase rules |
| [docs/remote-servers.md](docs/remote-servers.md) | Reusing a user's ssh connection, a remote shell that reads stdin, inspecting, installing, verifying and updating a server |

## Change Routing

Every change: `tests/check.sh` (on a Mac, `/bin/bash tests/check.sh`).

| Task | Edit | Also |
| --- | --- | --- |
| A machine | A user's machine: `hosts/local/<name>.sh`, never committed. A shipped profile only for a generic case (`generic`, `macos`, `example-cluster`) | [Recipe](docs/architecture.md#recipes); `srvinfo` on the host when asked |
| Shell behaviour | `shell/env.sh` (every shell), `shell/zshrc` (zsh), `shell/bashrc` (bash) | Keep the own-setup guard in `shell/zshrc` |
| A startup-file block | `setup.sh`'s configuration, zsh, tmux and bash steps; `ensure_block` | The bash, zsh/tmux and git sections of `check.sh` |
| tmux settings | `config/tmux/tmux.conf.local` | The tmux section |
| A tool | `tools/<x>.sh`, the core or optional list in `setup.sh`, the README table | [Recipe](docs/architecture.md#recipes); CI's install jobs |
| A setting | `server.example.json`, its consumer (`cfg`), the README table | The Settings section |
| Secrets format or files | `secrets/secrets.sh` `FILES`, the blob header, `install/make-bundle.sh` `LEAKS`, `.gitignore` together | `secrets.sh status`; `make-bundle.sh --no-secrets <out>.zip` |
| Install routes | `install/install.sh.template`, `install/bootstrap.sh`, `install/make-bundle.sh`, the README quick start | `bootstrap.sh OWNER/REPO --dry-run`; a test zip unpacks to `server/` |
| A test | `tests/check.sh` or `tests/container.sh` | [Adding a check](docs/testing.md#adding-a-check): reintroduce the bug, see it fail |
| A release | `VERSION`, a tag and its GitHub release notes | [docs/releasing.md](docs/releasing.md#versions) |

## Invariants

- `shell/env.sh` and `lib/detect.sh` are POSIX sh sourced by bash and zsh,
  interactive or not: no arrays, no output, no bashisms, no globbing of
  pattern lists; loops over `SRV_*` lists go through the helpers that set
  `sh_word_split`.
- Scripts run on bash 3.2 (macOS) and RHEL's bash: no `local -n`, no
  `${var,,}`, empty arrays as `${arr[@]+"${arr[@]}"}` under `set -u`,
  multi-line values reach awk through `ENVIRON`, not `-v` (BSD awk).
- A user's files stay theirs. `~/.zshrc`, `~/.tmux.conf.local` and, only
  when it does not read `~/.bashrc`, the login file get one marked block at
  the end; `~/.gitconfig` one at the top (an include, so the user's own
  settings win); `~/.bashrc` two (the environment at the top, for shells
  that return early; the rest at the end). `ensure_block` replaces only a
  complete block and never overwrites a backup; no other line changes. A
  block names the bundle `${SRV_DIR:-$HOME/server}` at `~/server` and by its
  real path anywhere else. A user's own `~/.tmux.conf` (not gpakosz/.tmux)
  and `~/.condarc` are left alone.
- `shell/zshrc` leaves the prompt, plugins, history and options to a user's
  own framework or prompt (oh-my-zsh, powerlevel10k, prezto, zinit,
  antidote, zim, starship, pure). The zsh hand-over in `shell/bashrc` fires
  only for an interactive shell on a terminal that zsh did not start.
- No alias or function takes a system command's name (`cc`, `ld`, `sg`, …);
  the permission-skipping agent shortcuts are `ca` and `cxa` only.
- Files the bundle owns (`~/.tmux.conf`, the git ignore) are copied, never
  symlinked; a replaced file is moved to `~/.server-backup/<timestamp>/`
  first. Nothing deletes a user's file.
- Core tools (`zsh`, `tmux`, `nvim`, `cli`) install by default; optional
  ones (`rclone`, `uv`, `claude`, `codex`) only when named by `--with` or
  `setup.with`. `--tools` runs exactly its list, and the questions only when
  answered yes. Lists arrive comma-separated from flags and space-separated
  from `server.json`.
- Every installer is idempotent, checks `have` first, has a `SRV_DRY_RUN`
  path that says "would …", degrades to a `warn` offline, and exits 0 when
  there is nothing to do; `setup.sh` finishes with one tool missing.
  `SRV_UPDATE=1` refreshes only what the bundle installed, never a module,
  system, Homebrew or npm copy. Linux installs into `~/.local/bin` and
  `~/software` (a build that does not run there is not installed); macOS
  uses Homebrew for Neovim, rclone and the CLI tools.
- tmux keeps `mouse on` and OSC 52 copy (`set-clipboard`, the `Ms`
  override) in `config/tmux/tmux.conf.local`, and sets the status line
  through `tmux_conf_theme_status_right`; `config/tmux/tmux.conf` is
  upstream, never edited.
- Environment modules load in interactive zsh only, wherever `module`
  exists (its init is sourced when a non-login zsh lacks it); an entry may
  list alternatives (`anaconda3|miniconda3`).
- A profile is declarative: `SRV_*` assignments only, the same names in the
  same order as `hosts/generic.sh`. `hosts/local/` is read before `hosts/`;
  a `.local.sh` is never a profile. Pruning keeps this machine's profile,
  its site's and `generic.sh`, and never removes a `.local.sh` or anything
  in `hosts/local/`.
- `$SCRATCH` a site set is used when no profile candidate exists; inside a
  SLURM job its `TMPDIR` stays.
- Rendering `server.json` starts from no values: a removed key, a missing or
  invalid file leaves nothing behind. Credential-shaped keys and values are
  refused.
- `setup.sh` commits only in a bundle with no git remote (a repository is
  what git says, worktrees included), as "server setup" when the machine has
  no git identity yet; `--no-github` touches nothing GitHub-related, not
  even a status probe; the bundle sets no credential helper.
- Tokens never reach a command line: `install/bootstrap.sh` passes
  `GITHUB_TOKEN` to git through its environment.
- `secrets/secrets.enc` stays git-ignored; `install/make-bundle.sh` refuses
  any plaintext credential and its zip always unpacks to `server/`;
  `install/install.sh` installs a new machine only; the pre-push hook checks
  every commit being pushed.

## Development

```sh
tests/check.sh                       # every change; /bin/bash tests/check.sh on a Mac
SRV_HOST=<profile> ./setup.sh --dry-run --here --no-conda --no-gdrive --no-github --no-secrets
install/make-bundle.sh --no-secrets /tmp/server-test.zip
git log --format='%an <%ae>' @{u}..  # identities about to be pushed
gh run list -L 3                     # CI after a push; gh run view <id> --log-failed
```

## Verification

- `tests/check.sh` proves syntax, publishability, profiles, control flow,
  the config copy, every startup-file block, the tool tiers and the tmux
  settings; it installs nothing. Real installs are `tests/container.sh` in
  CI: Ubuntu, Rocky Linux and macOS.
- Neither covers GitHub sign-in, secrets unlock, a real terminal's
  clipboard, modules, SLURM or a profile's paths on its cluster
  ([docs/testing.md](docs/testing.md#what-no-test-covers)).
- Report what ran, what it proved and what remains untested on a real host.

## Documentation

- The README is the user's document: every flag, tool, question and file
  `setup.sh` touches appears there. Update it with the change, and say in
  the commit message what a user will notice.
- `docs/` holds agent and contributor detail, one topic per file; this guide
  links to it rather than repeating it. Keep this guide under 200 lines.
- Header comments say what a file is for and what must not change; keep
  them current and do not narrate history. Edit `AGENTS.md`, never its
  `CLAUDE.md` shim.
