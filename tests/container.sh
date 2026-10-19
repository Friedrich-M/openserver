#!/usr/bin/env bash
# tests/container.sh — a real install on a disposable machine, then checks.
#
#   SRV_TEST_DISPOSABLE=1 tests/container.sh
#
# Installs everything for real into this machine's $HOME — and on macOS
# through the system's Homebrew — so it refuses to run without
# SRV_TEST_DISPOSABLE=1: a container or a CI runner (Ubuntu, Rocky Linux,
# macOS), a throwaway VM, never the machine you work on. Needs network; a
# GITHUB_TOKEN in the environment keeps tools/cli.sh clear of the API's
# anonymous rate limit.
#
# The bundle is installed as a zip install would be: a copy with no .git, so
# setup.sh prunes it and records it in a fresh local repo. Checks: setup.sh
# exits 0 with every step clean; the bundle was pruned and committed; the
# tools are on PATH in a bash login shell and an interactive zsh; srvinfo
# runs; a second run, from a shell that has not sourced anything, changes
# nothing.

set -euo pipefail

if [ "${SRV_TEST_DISPOSABLE:-}" != 1 ]; then
    echo "refusing: this installs into \$HOME — run it in a container or VM with SRV_TEST_DISPOSABLE=1" >&2
    exit 2
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Core and every optional tool, so CI installs all of them.
FLAGS=(--yes --no-conda --no-gdrive --no-github --no-secrets "--with=rclone,uv,claude,codex")
FAILED=0
fail() { printf '  FAIL %s\n' "$*"; FAILED=1; }

# A copy owned by whoever runs this (a container's root, not the checkout's
# owner, which git would call dubious), without the repository's history.
if [ "$REPO" != "$HOME/server" ]; then
    rm -rf "$HOME/server"
    cp -R "$REPO" "$HOME/server"
fi
rm -rf "$HOME/server/.git"

printf '\n== First run\n'
LOG="$(mktemp)"
if ! "$HOME/server/setup.sh" "${FLAGS[@]}" </dev/null 2>&1 | tee "$LOG"; then
    fail "setup.sh exited non-zero"
fi
if grep -q 'did not finish cleanly' "$LOG"; then
    fail "a step did not finish: $(grep 'did not finish cleanly' "$LOG" | tr '\n' ' ')"
fi

printf '\n== The bundle\n'
git -C "$HOME/server" log --oneline -1 2>/dev/null | grep -q 'Import bundle' ||
    fail "the bundle was not recorded in a local repo"
[ ! -e "$HOME/server/hosts/example-cluster.sh" ] || fail "the first run did not prune the other machines' profiles"
[ -z "$(git -C "$HOME/server" status --porcelain 2>/dev/null)" ] || fail "the bundle has uncommitted changes after setup"

printf '\n== Installed\n'
# Both ways a user meets these: a bash login shell (what `ssh host cmd`, scp
# and SLURM's `bash -l` run) and an interactive zsh (the prompt). The last
# line only: an interactive zsh may print its own startup notes first.
for sh in "bash -lc" "zsh -ic"; do
    for cmd in nvim rg fd fzf bat eza gh git-lfs rclone uv claude codex; do
        where="$($sh "command -v $cmd" </dev/null 2>/dev/null | tail -n 1)" || where=""
        case "$where" in
            /*) [ "$sh" = "zsh -ic" ] && printf '  ok   %-8s %s\n' "$cmd" "$where" ;;
            *)  fail "$cmd is not on PATH in \`$sh\`" ;;
        esac
    done
done
for f in .zshrc .bashrc .gitconfig .tmux.conf .tmux.conf.local \
         .secrets.env .claude/settings.json .codex/config.toml \
         .oh-my-zsh/oh-my-zsh.sh .config/nvim/init.lua; do
    [ -e "$HOME/$f" ] || fail "\$HOME/$f is missing"
done

# Startup files stay the machine's own, each ending with one bundle block.
# (~/.tmux.conf.local only under gpakosz/.tmux: a tmux config of the
# machine's own is left alone.)
files=".bashrc .zshrc"
grep -q gpakosz "$HOME/.tmux.conf" 2>/dev/null && files="$files .tmux.conf.local"
for f in $files; do
    [ "$(grep -c '^# >>> server ' "$HOME/$f" 2>/dev/null)" = 1 ] &&
        [ "$(tail -n 1 "$HOME/$f")" = '# <<< server <<<' ] || fail "\$HOME/$f does not end with exactly one server block"
done
# TPM only where there is a tmux to use it (tools/tmux.sh skips otherwise).
if command -v tmux >/dev/null 2>&1; then
    [ -d "$HOME/.tmux/plugins/tpm" ] || fail "tmux is here but TPM was not cloned"
fi
[ "$(stat -c %a "$HOME/.secrets.env" 2>/dev/null || stat -f %Lp "$HOME/.secrets.env")" = 600 ] ||
    fail "\$HOME/.secrets.env is not mode 600"

printf '\n== srvinfo\n'
zsh -ic 'srvinfo' </dev/null || fail "srvinfo exited non-zero in an interactive zsh"

printf '\n== Second run changes nothing\n'
# How many backup snapshots exist; 0 when there is no backup directory.
backups() {
    [ -d "$HOME/.server-backup" ] || { echo 0; return 0; }
    find "$HOME/.server-backup" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '
}
backups_before="$(backups)"
LOG2="$(mktemp)"
# This shell sourced nothing the bundle wrote, like the first run on a new
# machine: what was installed must still be found, not fetched again.
"$HOME/server/setup.sh" "${FLAGS[@]}" </dev/null >"$LOG2" 2>&1 || fail "the second setup.sh run exited non-zero"
[ "$backups_before" = "$(backups)" ] || fail "the second run backed files up again (it replaced something)"
if grep -E '^   (copy|back|seed|clone|installed|updated|drop|committed) ' "$LOG2"; then
    fail "the second run changed something (above)"
fi
if grep -q 'did not finish cleanly' "$LOG2"; then
    fail "a step of the second run did not finish: $(grep 'did not finish cleanly' "$LOG2" | tr '\n' ' ')"
fi

echo
if (( FAILED )); then
    echo "FAILED"; exit 1
fi
echo "install checks passed"
