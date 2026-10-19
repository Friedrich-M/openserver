# Architecture

How the code fits together: what `setup.sh` does in which order, how a
machine's profile and the user's settings reach every shell, and the three
ways a file reaches `$HOME`. Read [AGENTS.md](../AGENTS.md) first; paths are
relative to the repository root. The README describes the same system from
the user's side.

## setup.sh, step by step

`setup.sh` is the only entry point; every step is safe to repeat.

| Step | What it does | Code |
| --- | --- | --- |
| Move | Moves the bundle to `~/server` unless `--here`, then re-runs itself from there | `setup.sh` |
| What this machine is | Picks the profile and reports SLURM and modules | `lib/detect.sh` |
| Your settings | Renders `server.json` to `.srv-config.sh`; its answers fill unset flags | `lib/config.sh` |
| Configuration files | An include block at the top of `~/.gitconfig`; copies the git ignore; seeds `~/.p10k.zsh` once | `ensure_block --top`, `deploy`, `copy_once` |
| zsh, tmux, bash config | Adds the bundle's block to `~/.zshrc`, `~/.tmux.conf.local`, the login file when needed, and two to `~/.bashrc` (environment at the top, the rest at the end); installs gpakosz/.tmux | `ensure_block` |
| Secrets | Keeps `~/.secrets.env`, unlocks `secrets/secrets.enc`, or seeds the template | `secrets/secrets.sh` |
| Tools | Core installers (`zsh`, `tmux`, `nvim`, `cli`), then the optional ones named by `--with` / `setup.with` (`rclone`, `uv`, `claude`, `codex`); `--tools` / `setup.tools` replaces both lists | `tools/<x>.sh` |
| conda, Google Drive, GitHub | Asked, or answered by flags and `server.json` | `tools/conda.sh`, `tools/rclone.sh gdrive`, `tools/github.sh` |
| Pruning | First install with no git remote only: drops other machines' profiles and unused files; records `.srv-state` | `setup.sh` |
| Version control | Commits in a bundle with no remote (a zip install); installs the pre-push hook | `srv_commit` |

## From profile and settings to a shell

```
hosts/local/ + hosts/ ─┐                 ┌─ shell/env.sh ── every shell (bash, zsh, scripts, SLURM)
<name>.local.sh ────────┴─ lib/detect.sh ─┼─ shell/zshrc ── interactive zsh (modules, aliases, …)
server.json ── lib/config.sh ── .srv-config.sh ┘   shell/bashrc ── bash, then the hand-over to zsh
```

- `lib/detect.sh` reads every profile's `# hosts:`, `# domain:` and `# os:`
  header (first match wins; `hosts/local/` before `hosts/`, never a
  `.local.sh`), sources the profile and then its `.local.sh`.
  It runs at every shell start, so it stays POSIX sh and silent.
- `lib/config.sh` renders `server.json` once per `setup.sh` run, through
  python3, into plain `export SRV_CFG_<section>_<key>=…` lines; shells
  source that file and never parse JSON. A list becomes a space-separated
  string; a nested object (`claude.settings`) stays JSON for its tool.
  Re-rendering forgets the previous render's values first.
- `lib/common.sh` puts `~/.local/bin` and `~/software/nvim-linux64/bin` on
  `PATH` for every script, so a run from a shell that has not sourced
  `shell/env.sh` still finds what an earlier run installed.

## How a file reaches $HOME

| Helper | For | Behaviour |
| --- | --- | --- |
| `deploy` | Files the bundle owns (gpakosz `~/.tmux.conf`, the git ignore) | Copy; an identical file is left alone; a different one is moved to `~/.server-backup/<timestamp>/` first |
| `copy_once` | Files a tool rewrites (`~/.claude/settings.json`, `~/.codex/config.toml`, `~/.p10k.zsh`) | Seed when missing, never touch again; settings are then merged key by key (`tools/claude.sh`, `tools/codex.sh`) |
| `ensure_block` | Files that are the user's (`~/.bashrc`, `~/.zshrc`, `~/.gitconfig`, `~/.tmux.conf.local`, a login file) | A marked block at the end, or with `--top` the start, and `--name` for a second block in one file; only a complete block is replaced; every other line kept; rewritten only when stale or no longer last; the old file copied (not moved) to the backup folder |

Machines set up by earlier versions had whole copies of `~/.gitconfig`, `~/.zshrc`,
`~/.tmux.conf.local`, `~/.bashrc` and `~/.bash_profile`; `remove_old_copy`
and `restore_original` in `setup.sh` recognise them by their first line.

## The shell files

`shell/` is one configuration for every machine; a profile supplies the
values and the files run the same code everywhere.

| File | Role |
| --- | --- |
| `env.sh` | Sourced by bash and zsh, interactive or not: `$SRV_DIR`, `$SCRATCH`, the caches (Hugging Face, torch, uv, pip, wandb) and `$TMPDIR` on scratch, `PATH`, conda, `ulimit -c 0`, then `~/.secrets.env`. This is why `ssh host cmd`, `srun --pty bash -l` and a SLURM batch job see the same environment as the prompt |
| `zshrc` | Sourced from the block in `~/.zshrc`. Without a setup of the user's own: powerlevel10k and its instant prompt; oh-my-zsh with `git`, `z`, `extract`, `sudo`, `colored-man-pages`, `command-not-found`, autosuggestions and syntax highlighting; history and options. Always: the profile's modules, `TERM` repaired for terminals the host does not know, `fzf`, then `aliases`, `functions`, `slurm`, then `~/.zshrc.local` |
| `bashrc` | Sourced from the block at the end of `~/.bashrc` (a block at its top sources `env.sh` alone, for shells that return early): the environment, then `exec zsh` for an interactive shell on a terminal that zsh did not start (`SRV_NO_ZSH=1 bash` stays in bash) |
| `aliases.zsh`, `functions.zsh`, `slurm.zsh` | The everyday commands the README lists; `slurm.zsh` is a no-op without SLURM and pruned where there is none |
| `p10k.zsh` | The prompt, seeded to `~/.p10k.zsh` once |

A SLURM batch script reads no rc file at all: it gets the environment
because `sbatch` exports the submitting shell's, so submit from a shell this
bundle set up, or `source ~/.bashrc` at the top of the script.

## Copies, blocks and the bundle's own files

`$HOME` stays self-contained: a copied file works if `~/server` is moved or
deleted, and the shell then starts with one line saying so, losing only what
is read from `$SRV_DIR` at startup (`shell/env.sh`, `shell/zshrc`,
`shell/bashrc` and the zsh modules). Editing a copied file (the git
ignore, `~/.p10k.zsh`) does not edit the bundle: `srvpull` copies
them back. The bundle's share of the user's startup files lives in `shell/`
and `config/tmux/`. `setup.sh` never deletes anything of the user's: a file
it replaces is moved to `~/.server-backup/<timestamp>/` first.

## Pruning

Once a machine knows what it is, the profiles for other clusters are dead
weight, so `setup.sh` removes them: the other `hosts/*.sh` (the profile's
site fallback and `generic.sh` stay; a `.local.sh` and `hosts/local/` are never touched), `shell/slurm.zsh`
where there is no scheduler, `config/conda/` when conda was declined, and the
`server.zip` it was unpacked from. It commits the result in a bundle with no
git remote, so `git log` in `~/server` shows what went. It is a first-install
action, and two rules keep it from doing damage later:

- **Already pruned here**, recorded in `.srv-state`: otherwise every
  `srvsync` would delete profiles the `git pull` before it had restored.
- **The bundle has a git remote**: then it is the shared copy other machines
  pull from, and a local prune commit would also break `git pull --ff-only`.

`--prune` overrides both; `--keep-all` disables pruning. Build bundles on an
unpruned copy: `install/make-bundle.sh` warns when `.srv-state` records a
prune and lists what went.

## Vendored and cloned parts

`config/tmux/tmux.conf` is [gpakosz/.tmux](https://github.com/gpakosz/.tmux)
verbatim and marked do-not-edit upstream; it is vendored so every machine
runs the same version, and keeps its own licence header. The bundle's tmux
settings are `config/tmux/tmux.conf.local`, added as a block to the end of
the user's `~/.tmux.conf.local`, which gpakosz/.tmux reads last.
`~/.config/nvim` is a clone of kickstart.nvim that updates through its own
remote; oh-my-zsh, its plugins and TPM are clones too.

## Recipes

**A tool.** Write `tools/<x>.sh` from an existing one (`tools/uv.sh` is the
smallest): source `lib/common.sh`; `have` first; `updating` for
`--update`; a `SRV_DRY_RUN` path that says "would …"; `online` before any
download; Linux into `~/.local/bin`, macOS through Homebrew; exit 0 when
there is nothing to do. Add it to the core or optional list in `setup.sh`'s
Tools step, its row to the README table, and `x` to `check.sh`'s installer
loop.

**A machine.** Copy `hosts/example-cluster.sh` to `hosts/local/<name>.sh`
(git-ignored, read before `hosts/`), point its `# hosts:` line at the
machine, and fill in the site's values; a user's own values (an account, a
group's scratch) go in `hosts/local/<name>.local.sh`. A shipped profile is
for a generic case only, never a real person's machine.

**A setting.** Add it to `server.example.json`, read it with
`cfg section.key [default]` where it applies, and document it in the
README's settings table. Credential-shaped keys and values are refused by
the renderer by design: tokens belong in `~/.secrets.env`.

**A startup-file change.** The bundle's lines live in `shell/zshrc`,
`shell/bashrc` and `config/tmux/tmux.conf.local`; the user's files only hold the
block that reads them. Changing the block's own text rewrites it on every
machine at the next run: keep it to one line where possible.
