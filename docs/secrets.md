# Secrets

How API tokens and credential files reach a new machine, and how the
encrypted bundle protects them. The README's Secrets section is the short
version; paths are relative to the repository root.

## Where tokens live

API tokens live in `~/.secrets.env`, mode 600, sourced by `shell/env.sh` so
SLURM jobs and `ssh host cmd` get them too. `setup.sh` keeps a
`~/.secrets.env` that is already there; otherwise a new machine gets one of
three ways, tried in this order:

1. **Encrypted, inside the bundle** (below).
2. **Copied across out of band**, always available:
   `scp ~/.secrets.env <host>:~/.secrets.env && ssh <host> chmod 600 ~/.secrets.env`
3. **Typed in**: with neither, `setup.sh` seeds `~/.secrets.env` from
   `secrets/secrets.env.example` for you to fill in.

Plaintext secrets are never committed and never bundled: `.gitignore` blocks
them and `install/make-bundle.sh` refuses to build if anything token-shaped
other than `secrets/secrets.enc` has found its way in.

## The encrypted bundle

Lock once, then build a bundle:

```bash
srvlock                # or: srvlock --with-ssh
install/make-bundle.sh
```

`secrets/secrets.enc` is git-ignored: it travels in the zip you build, never
in the repository, so a public clone carries no one's credentials. It holds
more than the env file, because what makes a new machine immediately useful
is files rather than variables:

| Carried | Why |
| --- | --- |
| `~/.secrets.env` | The API tokens themselves |
| `~/.git-credentials` | HTTPS tokens for GitHub or the Hub. Git reads the file only through the `store` credential helper, which the bundle does not set ([below](#git-credentials)) |
| `~/.config/rclone/rclone.conf` | Moving data works on arrival |
| `~/.ssh/id_*` | **Opt-in** (`--with-ssh`). One key on every machine means one stolen machine burns them all; a per-machine key added to GitHub is better |

<a id="git-credentials"></a>**`~/.git-credentials` needs a helper.** The bundle sets no credential
helper, because a plaintext store is not a default worth sharing, and
without one git never reads the file. To have pushes work on arrival, opt
in once per machine:

```bash
git config --file ~/.gitconfig.local credential.helper store
```

`tools/github.sh` sets single keys in that file and keeps the rest, so the
line survives later runs. Otherwise use a per-machine SSH key or gh as the
helper (`tools/github.sh`, README "GitHub").

Deliberately left out: `~/.codex/auth.json` and `~/.claude.json` are session
credentials that expire (the latter is mostly project state) — `codex login`
and running `claude` once are quicker than debugging a stale copy. And
`~/.cache/huggingface/token` is redundant: `huggingface_hub` reads
`$HF_TOKEN`.

Unzipping on a new machine then asks for the passphrase and writes
`~/.secrets.env` (mode 600) itself. `srvunlock` does it later or again;
`--no-secrets` skips the prompt; `SRV_SECRETS_PASSPHRASE` covers unattended
runs.

## The format

A gzipped tar, AES-256-CBC with the key from PBKDF2-HMAC-SHA512 over
2,000,000 iterations — about a second to unlock, and what makes brute force
expensive. gzip's magic bytes plus a marker file inside make a wrong
passphrase fail loudly, because openssl alone hands back garbage. Everything
is staged and validated in a temporary directory before anything in `$HOME`
is touched, and modes are kept, so `~/.git-credentials` comes back 600.

## The passphrase

**The passphrase is the entire security boundary.** If the bundle is
reachable — a public URL, a repository that later goes public, a laptop that
leaves — assume someone has the ciphertext and can grind at it offline
forever. A generated passphrase or five random words makes that hopeless;
anything memorable does not. `srvlock` refuses passphrases under 12
characters and the shapes crackers try first (initials, a date, a symbol),
offers to generate one, and will not print a generated one inside a
coding-agent session, where it would land in a transcript. Rotate the tokens
periodically regardless.

**The choice is recorded, not re-asked.** Keep a weak passphrase over the
warning and `srvlock` marks the blob `strength: weak` in its header;
`install/make-bundle.sh` then leaves it out of the zip — "encrypted, but not
published" — and you carry it by hand:

```bash
scp ~/server/secrets/secrets.enc <host>:~/server/secrets/
```

`install/make-bundle.sh --with-secrets` puts it in anyway; `--no-secrets`
leaves a strong one out. The pre-push hook (`config/git/hooks/pre-push`)
refuses to push a weak blob from a fork that tracks it.
