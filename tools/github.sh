#!/usr/bin/env bash
# tools/github.sh — git identity and GitHub access on this machine.
#
#   ./tools/github.sh                       # ask for what is missing, set it up
#   ./tools/github.sh --name "Ada Lovelace" --email ada@example.com
#   ./tools/github.sh --protocol https      # token through gh instead of SSH
#   ./tools/github.sh --status [--quiet]    # report; exit 1 if anything is missing
#
# Three things a new machine needs before `git push` works, all per-machine
# and none of them in the bundle:
#
#   identity   user.name and user.email, written to ~/.gitconfig.local (the
#              synced config/git/gitconfig includes it and carries no identity).
#   sign-in    `gh auth login` by device code, which works on a headless
#              cluster: a URL and an eight-character code to type on any
#              browser. $GITHUB_TOKEN in ~/.secrets.env counts as signed in.
#   access     SSH by default: an ed25519 key generated here, never copied in
#              from elsewhere, and registered on the account under this
#              machine's name — one stolen box then burns one key, not all of
#              them. With --protocol https, gh becomes the credential helper
#              and the token signs pushes instead.
#
# Safe to run twice: every step checks before it changes anything.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
. "$SRV_DIR/lib/config.sh"

NAME="" EMAIL="" PROTOCOL="" STATUS=0 QUIET=0
# `--name Ada` and `--name=Ada` both work.
while [ $# -gt 0 ]; do
    case "$1" in
        --name=*)     NAME="${1#*=}" ;;
        --email=*)    EMAIL="${1#*=}" ;;
        --protocol=*) PROTOCOL="${1#*=}" ;;
        --name)       NAME="${2:-}"; shift ;;
        --email)      EMAIL="${2:-}"; shift ;;
        --protocol)   PROTOCOL="${2:-}"; shift ;;
        --status)     STATUS=1 ;;
        --quiet)      QUIET=1 ;;
        -h|--help)    sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done
# server.json fills what the command line did not.
NAME="${NAME:-$(cfg git.name)}"
EMAIL="${EMAIL:-$(cfg git.email)}"
PROTOCOL="${PROTOCOL:-$(cfg github.protocol)}"
case "$PROTOCOL" in
    ""|ssh|https) ;;
    *) echo "--protocol must be ssh or https" >&2; exit 2 ;;
esac

LOCAL="$HOME/.gitconfig.local"
KEY="$HOME/.ssh/id_ed25519"
MACHINE="$(hostname -s 2>/dev/null || hostname)"

# A token in the environment (or in ~/.secrets.env, which no shell has
# sourced yet when setup.sh runs this on a fresh machine) is a sign-in.
if [ -z "${GITHUB_TOKEN:-}" ] && [ -r "$HOME/.secrets.env" ]; then
    . "$HOME/.secrets.env"
fi

tell() { [ "$QUIET" = 1 ] || say "$@"; }
tty_ok() { [ -t 0 ]; }

# ---------------------------------------------------------------------------
# What is already here
# ---------------------------------------------------------------------------
# --includes: the identity sits in ~/.gitconfig.local behind the include in
# ~/.gitconfig, and a plain --global read does not follow it on every git.
current_name()  { git config --global --includes user.name 2>/dev/null || true; }
current_email() { git config --global --includes user.email 2>/dev/null || true; }

signed_in() {
    have gh || return 1
    gh auth status --hostname github.com >/dev/null 2>&1
}

# The account the sign-in belongs to, or nothing.
login_name() {
    have gh || return 0
    gh api user -q .login 2>/dev/null || true
}

key_registered() {
    [ -r "$KEY.pub" ] || return 1
    have gh || return 1
    # Compare the key body (type + base64), not the comment.
    local body
    body="$(awk '{print $1" "$2}' "$KEY.pub")"
    gh ssh-key list 2>/dev/null | grep -qF "$body"
}

# SSH to GitHub answers on stderr and exits 1 even when it works; the message
# is the check. BatchMode so a missing key cannot hang on a passphrase prompt.
ssh_works() {
    [ -r "$KEY" ] || return 1
    ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        git@github.com 2>&1 | grep -q "successfully authenticated"
}

# ---------------------------------------------------------------------------
# --status
# ---------------------------------------------------------------------------
if [ "$STATUS" = 1 ]; then
    missing=0
    n="$(current_name)"; e="$(current_email)"
    if [ -n "$n" ] && [ -n "$e" ]; then
        tell "identity : $n <$e>"
    else
        tell "identity : not set (user.name/user.email) — run tools/github.sh"; missing=1
    fi
    if ! have gh; then
        tell "gh       : not installed (tools/cli.sh, or brew install gh)"; missing=1
    elif signed_in; then
        tell "gh       : signed in as $(login_name)${GITHUB_TOKEN:+ (GITHUB_TOKEN)}"
    else
        tell "gh       : not signed in"; missing=1
    fi
    if [ -r "$KEY.pub" ]; then
        if key_registered; then
            tell "ssh key  : $KEY, registered on the account"
        else
            tell "ssh key  : $KEY, not registered on the account"
            # Only a problem when nothing else can push.
            signed_in || missing=1
        fi
    elif git config --global --get-regexp '^credential\.https://github\.com\.helper' >/dev/null 2>&1; then
        tell "ssh key  : none; gh is the HTTPS credential helper"
    else
        tell "ssh key  : none"; missing=1
    fi
    exit $missing
fi

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
step "Git identity"
n="$(current_name)"; e="$(current_email)"
if [ -n "$NAME" ] || [ -n "$EMAIL" ] || [ -z "$n" ] || [ -z "$e" ]; then
    if [ -z "$NAME" ] && [ -z "$n" ]; then
        if tty_ok; then
            # The GitHub account's display name, when signed in, is the usual answer.
            default="$(login_name)"
            printf '   Name for commits%s: ' "${default:+ [$default]}" >&2
            IFS= read -r NAME; NAME="${NAME:-$default}"
        else
            warn "no terminal — pass --name and --email, or write ~/.gitconfig.local"
        fi
    fi
    if [ -z "$EMAIL" ] && [ -z "$e" ] && tty_ok; then
        printf '   Email for commits (a GitHub noreply address is fine): ' >&2
        IFS= read -r EMAIL
    fi
    # Only what differs from the identity already in effect is written.
    [ "$NAME" = "$n" ] && NAME=""
    [ "$EMAIL" = "$e" ] && EMAIL=""
    if [ -z "$NAME$EMAIL" ]; then
        :
    elif [ "$SRV_DRY_RUN" = 1 ]; then
        say "would set${NAME:+ user.name=$NAME}${EMAIL:+ user.email=$EMAIL} in ~/.gitconfig.local"
    else
        if [ -n "$NAME" ]; then git config -f "$LOCAL" user.name "$NAME"; fi
        if [ -n "$EMAIL" ]; then git config -f "$LOCAL" user.email "$EMAIL"; fi
        chmod 600 "$LOCAL" 2>/dev/null || true
    fi
fi
n="$(current_name)"; e="$(current_email)"
if [ -n "$n" ] && [ -n "$e" ]; then
    say "ok   $n <$e>  (~/.gitconfig.local)"
else
    warn "identity still incomplete — commits will fail until user.name and user.email are set"
fi

# ---------------------------------------------------------------------------
# gh and the sign-in
# ---------------------------------------------------------------------------
step "GitHub sign-in"
if ! have gh; then
    if [ "${SRV_OS:-linux}" = macos ]; then
        warn "gh is not installed — brew install gh, then re-run"
    else
        warn "gh is not installed — tools/cli.sh installs it; re-run after"
    fi
    exit 0
fi

PROTOCOL="${PROTOCOL:-ssh}"
if signed_in; then
    say "ok   signed in as $(login_name)${GITHUB_TOKEN:+ (via GITHUB_TOKEN)}"
elif [ "$SRV_DRY_RUN" = 1 ]; then
    say "would run: gh auth login --hostname github.com --git-protocol $PROTOCOL --web"
elif tty_ok; then
    say "a one-time code and a URL follow; open the URL on any browser and type the code"
    # admin:public_key lets the key below be registered from here; the login
    # flow's own key upload is skipped in favour of the idempotent step below.
    gh auth login --hostname github.com --git-protocol "$PROTOCOL" --web \
        --skip-ssh-key --scopes admin:public_key </dev/tty || {
        warn "sign-in did not complete — run: gh auth login"; exit 0; }
    say "ok   signed in as $(login_name)"
else
    warn "no terminal to sign in from — run: gh auth login --git-protocol $PROTOCOL --web"
    warn "or put a token in ~/.secrets.env as GITHUB_TOKEN"
    exit 0
fi

# ---------------------------------------------------------------------------
# How git authenticates
# ---------------------------------------------------------------------------
if [ "$PROTOCOL" = https ]; then
    step "HTTPS credentials"
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would run: gh auth setup-git"
    else
        gh auth setup-git --hostname github.com >/dev/null 2>&1 &&
            say "ok   gh answers git's credential prompts for github.com" ||
            warn "gh auth setup-git failed — pushes will ask for a token"
    fi
else
    step "SSH key for this machine"
    if [ -r "$KEY" ]; then
        say "ok   $KEY"
    elif [ "$SRV_DRY_RUN" = 1 ]; then
        say "would generate $KEY"
    else
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        ssh-keygen -q -t ed25519 -N "" -C "$e@$MACHINE" -f "$KEY"
        say "generated $KEY (no passphrase: it is this machine's key, nothing else's)"
    fi
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would register the key on the account as '$MACHINE'"
    elif key_registered; then
        say "ok   registered on the account"
    elif gh ssh-key add "$KEY.pub" --title "$MACHINE" >/dev/null 2>&1; then
        say "registered on the account as '$MACHINE'"
    else
        warn "could not register the key — the token may lack the admin:public_key scope:"
        warn "  gh auth refresh -s admin:public_key && gh ssh-key add $KEY.pub --title $MACHINE"
    fi
    if [ "$SRV_DRY_RUN" != 1 ]; then
        if ssh_works; then
            say "ok   ssh -T git@github.com"
        else
            warn "GitHub did not accept the key yet (propagation takes a moment) — check with: ssh -T git@github.com"
        fi
    fi
fi

if [ "$PROTOCOL" = https ]; then
    say "done — clone with https://github.com/<owner>/<repo>.git"
else
    say "done — clone with git@github.com:<owner>/<repo>.git"
fi
true
