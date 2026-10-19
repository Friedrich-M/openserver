# OpenServer

Turn a bare machine into one you can work on, with one command: zsh with a
good prompt, git, tmux with mouse and clipboard, Neovim, fast command-line
tools and, if you want them, the coding agents. The same setup behaves
correctly on a laptop, a cloud VM and an HPC login node.

- **No sudo.** Everything installs into your home directory.
- **Your files stay yours.** `~/.bashrc`, `~/.zshrc`, `~/.gitconfig` and
  `~/.tmux.conf.local` keep every line; OpenServer adds a marked block to
  each, which you can delete to opt out.
- **One profile per machine.** Scratch space, environment modules and SLURM
  defaults come from a small file per cluster, picked by hostname.
- **Safe to run again.** Anything it replaces is backed up first; a second
  run changes nothing.
- **Linux and macOS**, tested on Ubuntu, Rocky Linux and macOS on every push.

**Contents:** [Quick start](#quick-start) · [Requirements](#requirements) · [What you get](#what-you-get) · [Everyday use](#everyday-use) · [Settings](#settings) · [Machines](#machines) · [Secrets](#secrets) · [GitHub](#github) · [Security notes](#security-notes) · [Troubleshooting](#troubleshooting) · [Uninstall](#uninstall) · [Layout](#layout) · [Contributing](#contributing)

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/Friedrich-M/openserver/v1.0.0/install/bootstrap.sh | bash -s -- Friedrich-M/openserver --ref=v1.0.0
```

Then start a new shell and see what it found:

```bash
exec zsh        # or log out and back in
srvinfo
```

That installs release v1.0.0; replace both `v1.0.0` with `main` for the
latest code. It clones this repository into `~/server` and runs `setup.sh`,
which asks at most four questions (GitHub sign-in, conda, Google Drive, and
unlocking bundled credentials if there are any) and does the rest by
itself. The project is OpenServer; on a machine it lives in `~/server` and
its commands start with `srv`.

**See what it would do first:**

```bash
git clone --branch v1.0.0 https://github.com/Friedrich-M/openserver ~/server
~/server/setup.sh --dry-run      # every change it would make; makes none
~/server/setup.sh                # then for real
```

(`setup.sh` moves a checkout from anywhere else to `~/server`; `--here`
configures from where it is instead.)

**Unattended** (a fresh VM, CI, a provisioning script): put the answers
after the repository name, for example
`… | bash -s -- Friedrich-M/openserver --ref=v1.0.0 --yes --no-github --no-conda --no-gdrive`.
**The coding agents and other optional tools**: add
`--with=claude,codex,uv,rclone`.

**Your own fork**, private: give the script a token that can read it.

```bash
export GITHUB_TOKEN=...   # a fine-grained token with Contents: read on the repo
curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://raw.githubusercontent.com/OWNER/openserver/main/install/bootstrap.sh | bash -s -- OWNER/openserver
```

**From a zip** you built for your own machines
([docs/releasing.md](docs/releasing.md#how-users-install-it)). A zip carries
your `server.json`, `hosts/local/` and encrypted credentials: keep it to
your own machines.

```bash
scp server.zip host:~/ && ssh -t host 'unzip -q server.zip && ./server/setup.sh'
```

## Requirements

- Linux (x86_64 or aarch64) or macOS; bash 3.2 or newer.
- git, and curl or wget. python3 to read `server.json`. unzip for the zip
  route.
- zsh for the zsh setup. Clusters have it; on a bare VM install it with your
  package manager (`setup.sh` prints the command), and bash works meanwhile.
- macOS: Homebrew for Neovim, rclone and the command-line tools.

## What you get

**Installed**, into your home directory, at the latest release (`srvupdate`
refreshes them later). The core comes on every machine; the optional tools
when named with `--with=…` or `setup.with`:

| | Tool | Linux | macOS |
| --- | --- | --- | --- |
| core | oh-my-zsh, powerlevel10k, autosuggestions, syntax highlighting | `~/.oh-my-zsh` | same |
| core | tmux plugin manager (TPM) | `~/.tmux/plugins/tpm` | same |
| core | Neovim with kickstart.nvim | `~/software/nvim-linux64` (a build for older systems when the current one cannot run), `~/.config/nvim` | Homebrew |
| core | `fzf`, `rg`, `fd`, `bat`, `eza`, `gh`, `git-lfs` | `~/.local/bin` | Homebrew |
| optional | `rclone` | `~/.local/bin` | Homebrew |
| optional | `uv` | `~/.local/bin` | same |
| optional | Claude Code, Codex CLI | `~/.local/bin` (official installers, no Node) | same |

Anything already installed — by the system, a module or Homebrew — is left
alone.

**Configured:**

| | |
| --- | --- |
| zsh | A block at the end of your `~/.zshrc` loads the bundle's zsh: prompt, plugins and history — unless you already use oh-my-zsh, powerlevel10k, prezto, zinit, antidote, zim, starship or pure, which then stay in charge — plus the environment, modules, aliases and SLURM helpers. `~/.p10k.zsh` is seeded once. |
| bash | Two blocks in your `~/.bashrc`: at the top the environment, so `ssh host cmd`, scp, rsync and SLURM jobs get it even where `~/.bashrc` returns early; at the end the rest, which switches an interactive login to zsh. Your login file is touched only if it does not read `~/.bashrc`. |
| git | A block at the top of your `~/.gitconfig` includes the bundle's settings (aliases, LFS, a global ignore), so anything you set below it wins. No credential helper and no editor are imposed. Your identity stays per machine ([GitHub](#github)). |
| tmux | gpakosz/.tmux as `~/.tmux.conf`, and a block in your `~/.tmux.conf.local`: the mouse wheel scrolls history, a drag copies, and copies reach your own computer's clipboard even over ssh. A `~/.tmux.conf` of your own is left alone. |
| Caches | Hugging Face, torch, pip, uv, wandb and `$TMPDIR` on the machine's scratch space (a `$SCRATCH` your site sets is used), so a small home quota does not fill up. |
| conda | `~/.condarc` keeping environments and packages on scratch, when conda is there or being installed; a `~/.condarc` of your own is kept. |
| Agents | With `--with=claude,codex`: `~/.claude/settings.json` and `~/.codex/config.toml` seeded once, with your settings from `server.json`. |

**Asked**, each once, each answerable up front:

| Question | Flags |
| --- | --- |
| Install conda (Miniforge, about 500 MB)? | `--conda` / `--no-conda` |
| Set up Google Drive (rclone)? Needs a browser consent once. | `--gdrive` / `--no-gdrive` |
| Set up GitHub (identity, sign-in, a key for this machine)? | `--github` / `--no-github` |
| Unlock the bundled credentials? Needs your passphrase. | `--secrets` / `--no-secrets` |

**Left to you**, because it cannot be automatic: installing zsh itself on a
bare VM, pressing `prefix + I` once in tmux for its plugins, and signing in
to the agents (`claude`, `codex login`).

## Everyday use

| Command | Does |
| --- | --- |
| `srvinfo` | What resolved on this machine: version, profile, scratch, modules, SLURM, tools, tokens |
| `srvsync` | Pull the latest OpenServer (when `~/server` follows a branch) and re-run setup |
| `srvupdate` | The same, plus every tool it installed to its latest release |
| `srvpull` | Copy edits to the git ignore and `~/.p10k.zsh` back into `~/server` |
| `srvlock` / `srvunlock` | Encrypt your credentials into the bundle / restore them ([Secrets](#secrets)) |
| `ll`, `la`, `lt`, `cat`, `vim` | eza, bat and Neovim where installed, the plain tools where not |
| `srv`, `scratch`, `gpus`, `quota`, `duh`, `mkcd`, `tb` | Go to `~/server` or scratch, show GPUs, your quota, folder sizes; make and enter a folder; TensorBoard on a free port |
| `ca`, `cx`, `cxa` | Claude Code and Codex; **`ca` and `cxa` turn every permission prompt off** ([Security notes](#security-notes)) |
| `sq`, `sqa`, `sgpu`, `loc`, `cloc`, `sr`, `sj` | SLURM: queues, GPUs per user, interactive GPU and CPU jobs, a shell in a job, a job's efficiency (only where SLURM exists) |

For one machine only, `~/.zshrc.local` runs last and overrides anything;
`SRV_CLAUDE_MODEL` and `SRV_CODEX_MODEL` there move the agents' models.

## Settings

`server.json`, beside `setup.sh`, holds what is yours rather than the
machine's, so a new machine comes up configured with nothing typed. Copy
`server.example.json`; every key is optional:

```json
{
  "git":    { "name": "Ada Lovelace", "email": "12345+ada@users.noreply.github.com" },
  "github": { "protocol": "ssh" },
  "claude": { "model": "claude-fable-5-1", "settings": { "theme": "dark-ansi" } },
  "codex":  { "model": "gpt-6-astra", "model_reasoning_effort": "high" },
  "setup":  { "conda": false, "gdrive": false, "github": true, "secrets": true,
              "with": ["rclone", "uv", "claude", "codex"] }
}
```

| Key | Effect |
| --- | --- |
| `git.name`, `git.email` | Your commit identity, written to `~/.gitconfig.local` instead of being asked |
| `github.protocol` | `ssh` (a key for this machine) or `https` (gh as credential helper) |
| `claude.model`, `claude.settings` | The model `ca` runs; settings merged into `~/.claude/settings.json` |
| `codex.model`, `codex.model_reasoning_effort` | Set in `~/.codex/config.toml` |
| `setup.conda`, `.gdrive`, `.github`, `.secrets` | The answers to the questions; a flag still wins |
| `setup.with`, `setup.tools` | Optional tools to add; or exactly which installers to run |

`server.json` is git-ignored and must hold no token (a token-shaped value is
refused). It reaches a new machine inside a zip you build, or by
`scp ~/server/server.json host:~/server/` before `setup.sh` runs.

**Flags** for `setup.sh` (and after the repository name in the one-liner):

| Flag | Effect |
| --- | --- |
| `--dry-run` | Show every change, make none |
| `--with=claude,codex` | Also install these optional tools: `rclone`, `uv`, `claude`, `codex` |
| `--tools=nvim,cli` | Run only these installers (and only the questions answered yes) |
| `--config-only` | Configure, install nothing |
| `--update` | Bring every installed tool to its latest release |
| `--conda`, `--gdrive`, `--github`, `--secrets` | Answer yes up front; `--no-…` answers no |
| `--yes`, `-y` | Accept every prompt (unattended) |
| `--here` | Configure from where the files are instead of `~/server` |
| `--keep-all` / `--prune` | Never / always remove other machines' profiles ([details](docs/architecture.md#pruning)) |
| `--version`, `--help` | Print the version, or every flag |

`install/bootstrap.sh` adds `--ref=<tag or branch>` for the version to clone.

## Machines

Each machine has a profile picked by a header line:

```
# hosts: login*.cluster.example.edu    shell patterns on the hostname
# domain: *.example.edu                a site's fallback, tried after every hosts: line
# os: macos                            the last resort, by operating system
```

First match wins; an unknown machine gets `hosts/generic.sh`. The
repository ships `generic.sh` (any Linux), `macos.sh` and
`example-cluster.sh`, an HPC cluster to copy. **Your own profiles go in
`hosts/local/`**, which is git-ignored, read before `hosts/`, and carried
by a bundle you build. A profile only sets values — every machine runs the
same code:

| Value | Meaning |
| --- | --- |
| `SRV_SITE` | A family of machines sharing a fallback profile, `<site>.sh` |
| `SRV_SCRATCH_CANDIDATES` | Writable folders, best first; `$SCRATCH` is the first that exists, else a `$SCRATCH` the site set, else `$HOME` |
| `SRV_MODULES` | Environment modules for interactive zsh, without versions; `a\|b` loads the first that exists; skipped where there is no `module` |
| `SRV_CONDA_ROOT`, `SRV_CONDA_TREE` | A fixed conda install, or a folder of releases of which the newest is used |
| `SRV_SLURM_ACCOUNT`, `SRV_SLURM_GPU_PARTITION`, `SRV_SLURM_WATCH_PARTITIONS` | Defaults for the SLURM commands; empty means SLURM's own |
| `SRV_OMP_NUM_THREADS`, `SRV_EXTRA_PATH` | Thread count, and extra `PATH` entries |

**Adding a machine:** copy `hosts/example-cluster.sh` to
`hosts/local/<name>.sh`, point its `# hosts:` line at the machine, fill in
the values (`module avail`, `sinfo -s` and `sacctmgr show assoc
user=$USER` tell you), then run `srvsync` there. Values that are yours
rather than the site's — your SLURM account, a group's scratch folder — go
in `hosts/local/<name>.local.sh`, read right after the profile.

## Secrets

API tokens live in `~/.secrets.env` (mode 600), which every shell and SLURM
job reads. On a new machine `setup.sh` keeps the one already there, or
unlocks them from an encrypted file you carry in your bundle, or you copy
the file across, or it gives you a template to fill in. `srvlock` encrypts
them, with your git and rclone credentials, into `secrets/secrets.enc`,
which never enters the repository. How it works and how to choose a
passphrase: [docs/secrets.md](docs/secrets.md).

## GitHub

`~/server/tools/github.sh` (or the GitHub question in `setup.sh`) sets up
this machine: your commit identity in `~/.gitconfig.local`, a `gh` sign-in
by a one-time code that works on a headless server, and an SSH key made for
this machine and registered on your account — one lost machine then costs
one key. The key has no passphrase (it is this machine's alone), and the
sign-in asks for the `admin:public_key` scope to register it.
`--protocol https` uses gh as git's credential helper instead, and
`--status` shows what is set up.

## Security notes

- **Pin a release.** The quick start installs a tagged release; read
  `install/bootstrap.sh` first if you prefer, or use the dry-run route.
- **`ca` and `cxa` run the agents with every permission prompt off.** The
  agent then runs any command and edits any file as you, and can read every
  token in your environment. Use `claude` and `cx` for the prompts.
- **Tokens in `~/.secrets.env` reach every process you start.** Prefer
  fine-grained tokens limited to what you need.
- **Credentials in the encrypted bundle are only as safe as the
  passphrase** ([docs/secrets.md](docs/secrets.md#the-passphrase)); report
  a vulnerability as [SECURITY.md](SECURITY.md) describes.

## Troubleshooting

- **What did it pick up here?** `srvinfo`: profile, scratch, modules,
  SLURM defaults, tools, tokens.
- **What would it change?** `~/server/setup.sh --dry-run`.
- **Stay in bash** for one session: `SRV_NO_ZSH=1 bash`; for good, delete
  the end block in `~/.bashrc`.
- **"~/server already exists"**: a checkout elsewhere was about to move
  there. Move the old one aside, or run with `--here`.
- **A tool is missing**: `~/server/setup.sh --tools=<name>` re-runs one
  installer and says why it could not install.
- **Something else**: open an issue with the output of `setup.sh --dry-run`
  and `srvinfo`, anything personal removed.

## Uninstall

1. Delete the marked blocks (`# >>> server … >>>` to `# <<< server <<<`)
   from `~/.bashrc`, `~/.zshrc`, `~/.gitconfig`, `~/.tmux.conf.local` and
   your login file, if one has one.
2. Files it replaced are in `~/.server-backup/<timestamp>/`: copy back any
   you want (`~/.tmux.conf`, the git ignore, an old `~/.zshrc` copy).
3. Remove what it installed: `~/server`, `~/.tmux.conf`, `~/.oh-my-zsh`, `~/.tmux/plugins`,
   `~/software/nvim-linux64`, `~/.config/nvim`, and in `~/.local/bin` the
   tools named in [What you get](#what-you-get). `~/.secrets.env` is yours:
   delete it only if you mean to.

## Layout

```
setup.sh           the entry point
VERSION            the release version (setup.sh --version, srvinfo)
server.example.json  copy to server.json for your settings (git-ignored)
lib/               helpers the scripts source: common, config, detect
shell/             what bash and zsh load: env.sh, zshrc, bashrc, aliases, functions, slurm
hosts/             generic.sh, macos.sh, example-cluster.sh; local/ for your own (git-ignored)
tools/             one installer per tool
config/            claude, codex, conda, git, tmux: what lands in $HOME
secrets/           the credentials tool and template; your secrets.enc (git-ignored)
install/           bootstrap.sh (the one-liner), make-bundle.sh and install.sh.template for a zip
tests/             check.sh (offline) and container.sh (a real install); CI runs both
docs/              architecture, testing, releasing, remote servers, secrets
```

## Contributing

Issues and pull requests are welcome; start with
[CONTRIBUTING.md](CONTRIBUTING.md). Coding agents read [AGENTS.md](AGENTS.md).
`tests/check.sh` runs every offline check on a scratch copy and installs
nothing; CI installs for real on Ubuntu, Rocky Linux and macOS
([docs/testing.md](docs/testing.md)).

## License

MIT ([LICENSE](LICENSE)). `config/tmux/tmux.conf` is
[gpakosz/.tmux](https://github.com/gpakosz/.tmux) and keeps its own licence.
