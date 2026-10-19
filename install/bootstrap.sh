#!/usr/bin/env bash
# install/bootstrap.sh — one command from a bare machine to a configured one,
# straight from the git repository (no zip, no website).
#
#   curl -fsSL https://raw.githubusercontent.com/OWNER/openserver/main/install/bootstrap.sh \
#       | bash -s -- OWNER/openserver [--ref=<tag or branch>] [setup.sh flags]
#
# Clones the repository into ~/server (at --ref, a release tag such as
# v1.0.0, when given; the default branch otherwise) and runs setup.sh. For a private
# repository, hand it a token: GitHub's raw endpoint and the clone both take
# it from $GITHUB_TOKEN (a fine-grained token with Contents: read is enough),
#
#   GITHUB_TOKEN=... bash -c 'curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
#       https://raw.githubusercontent.com/OWNER/openserver/main/install/bootstrap.sh \
#       | bash -s -- OWNER/openserver'
#
# The token reaches git through its environment (GIT_CONFIG_COUNT), never on
# a command line another user could read with ps, and never in
# ~/server/.git/config; tools/github.sh sets up this machine's own access
# afterwards. --dry-run prints the plan and changes nothing.

set -euo pipefail

say() { printf '  %s\n' "$*"; }
die() { printf '  ! %s\n' "$*" >&2; exit 1; }

REPO="${1:-}"
[ -n "$REPO" ] || die "usage: bootstrap.sh OWNER/REPO [--ref=<tag or branch>] [setup.sh flags]"
shift
DEST="$HOME/server"
DRY=0 REF=""
# --ref is this script's; every other argument goes to setup.sh.
args=()
for arg in "$@"; do
    case "$arg" in
        --ref=*) REF="${arg#*=}" ;;
        *) [ "$arg" = --dry-run ] && DRY=1; args+=("$arg") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

command -v git >/dev/null 2>&1 || die "git is not installed (ask an administrator, or: sudo apt install git)"

# git_auth <git args...> : git, with $GITHUB_TOKEN as HTTP Basic auth (the
# x-access-token user) passed in the environment. GIT_CONFIG_COUNT needs git
# 2.31; an older git gets the header on its command line instead.
git_auth() {
    [ -n "${GITHUB_TOKEN:-}" ] || { git "$@"; return; }
    local auth
    auth="Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
    if git version 2>/dev/null |
       awk '{ split($3, v, "."); exit !(v[1] > 2 || (v[1] == 2 && v[2] >= 31)) }'; then
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="$auth" git "$@"
    else
        say "git older than 2.31: the token is passed on git's command line for this clone"
        git -c http.extraheader="$auth" "$@"
    fi
}

printf '\n== Cloning\n'
if [ -e "$DEST/.git" ]; then
    [ -z "$REF" ] || die "$DEST is already a clone — to change version: git -C $DEST checkout $REF"
    say "$DEST is already a clone — pulling"
    (( DRY )) || git_auth -C "$DEST" pull --ff-only || die "pull failed; resolve it in $DEST and re-run"
elif [ -e "$DEST" ]; then
    die "$DEST exists and is not a clone — move it aside first"
else
    url="https://github.com/$REPO.git"
    say "$url${REF:+ at $REF} -> $DEST"
    if (( DRY )); then
        say "(dry run: not cloning)"
    else
        git_auth -c advice.detachedHead=false clone -q ${REF:+--branch "$REF"} "$url" "$DEST" ||
            die "clone failed — no such repository${REF:+ or ref $REF}, or a private one without GITHUB_TOKEN"
    fi
fi

if (( DRY )); then
    say "would run: $DEST/setup.sh $*"
    exit 0
fi
[ -x "$DEST/setup.sh" ] || die "$DEST/setup.sh missing — is $REPO this project?"
# server.json is not in the repository: a copy put beside setup.sh before
# this runs (scp from another machine) answers every question.
[ -r "$DEST/server.json" ] || say "no server.json yet — setup.sh will ask; scp yours to $DEST/ to skip the questions"

# Piped into bash, this script *is* stdin; setup.sh needs the terminal back
# for its questions. Open /dev/tty for real (see install/install.sh.template).
printf '\n== Setting up\n'
if (exec 3< /dev/tty) 2>/dev/null; then
    exec "$DEST/setup.sh" --here "$@" < /dev/tty
else
    say "no controlling terminal — running non-interactively"
    exec "$DEST/setup.sh" --here "$@" < /dev/null
fi
