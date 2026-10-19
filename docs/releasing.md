# Releasing and deploying

How a change reaches the public repository and then people's machines.
Read [AGENTS.md](../AGENTS.md) and [docs/testing.md](testing.md) first;
paths are relative to the repository root. Push, tag or publish only when
asked.

## Before every push

The repository is public, and so is its whole history: a file, an old
version of a file, and every commit's author and committer.

1. `tests/check.sh` passes (on a Mac, `/bin/bash tests/check.sh`). Its
   Publishable section fails on an e-mail address, a home-directory path
   or a token-shaped string in any tracked file.
2. Nothing personal in what you add: no person's or lab's name, account,
   username, host alias, cluster allocation or private path. Profiles hold
   public site facts; personal values belong in the ignored
   `hosts/*.local.sh`, `server.json` and `secrets/`.
3. Commits carry a no-reply identity. Check `git log --format='%an <%ae>'`
   on the commits you are pushing; set the repository's identity with
   `git config user.email <id>+<login>@users.noreply.github.com` (the id
   from `gh api user -q .id`). A commit made with a personal address is
   rewritten before it is pushed, never after.
4. `git status --ignored` shows `server.json`, `hosts/*.local.sh` and
   `secrets/secrets.enc` as ignored, never staged.

After the push, CI (`.github/workflows/check.yml`) must pass:
`gh run list -L 1`, and `gh run view <id> --log-failed` when it does not.

## Versions

- The repository keeps no change log; a commit message says what a user
  would notice (a new or removed tool, flag, setting or default, anything
  that changes what lands in `$HOME`), and a release's notes collect them.
- `VERSION` holds the version (`MAJOR.MINOR.PATCH`); `setup.sh --version`
  and `srvinfo` print it. Semantic versioning: a change that rewrites users'
  files or removes a flag is major; a new tool, flag or setting is minor; a
  fix is a patch.
- A release: set `VERSION` in its own commit, push, wait for CI, then tag
  that commit and publish the notes:
  `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z` and
  `gh release create vX.Y.Z --title vX.Y.Z --notes-file <notes.md>`.
- The notes follow one shape: an opening sentence on what the release is,
  then `## Highlights` (what users notice, one bullet each), `## Requirements`
  (systems and commands it needs), `## Install and upgrade` (the quick start
  link; `srvsync` for an existing machine, and anything an upgrade changes in
  `$HOME`), and `## Notes` (caveats). The notes are public: the privacy gate
  above applies to them too.

## How users install it

Three routes, all ending in `setup.sh` (the README's quick start):

- **From GitHub**: `install/bootstrap.sh OWNER/openserver --ref=vX.Y.Z`
  clones that release into `~/server` and runs `setup.sh`; without `--ref`,
  the default branch. A public repository needs no token; a private one
  takes `GITHUB_TOKEN`, passed to git through its environment. The README's
  quick start names the latest release: update both places it appears when
  you tag a new one.
- **From a hosted zip**: `SRV_SITE_URL=https://host install/make-bundle.sh`
  builds `server.zip` (always unpacking to `server/`) and an `install.sh`
  with that URL; both are uploaded side by side. `install/make-bundle.sh` refuses a
  plaintext credential and leaves a weak-passphrase `secrets.enc` out.
- **By hand**: clone or copy, then `~/server/setup.sh`.

A zip is built from the working tree, so it carries the builder's
`server.json`, `hosts/local/` and `hosts/*.local.sh`: build one for your own machines, never
for publication; a public release is the tagged repository.

## Updating machines

`srvsync` pulls (when `~/server` has a remote) and re-runs `setup.sh`;
`srvupdate` also brings every tool the bundle installed to its latest
release. A machine installed from a zip has no remote until one is added
([docs/remote-servers.md](remote-servers.md#updating-a-server)).
