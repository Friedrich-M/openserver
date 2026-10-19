#!/usr/bin/env bash
# secrets.sh — carry the credentials between machines, encrypted.
#
#   secrets/secrets.sh lock [--with-ssh] [--accept-weak]
#   secrets/secrets.sh unlock              secrets/secrets.enc -> $HOME
#   secrets/secrets.sh list                what is in the blob
#   secrets/secrets.sh status
#
# Not just ~/.secrets.env: the things that make a new machine immediately
# useful are files, not environment variables. `git push` needs
# ~/.git-credentials, moving data needs rclone.conf. Those go in too.
#
# WHAT IS DELIBERATELY LEFT OUT
#   ~/.ssh/id_*        opt-in (--with-ssh). Copying one private key to every
#                      machine means one stolen machine burns them all; a
#                      per-machine key added to GitHub is strictly better.
#   ~/.codex/auth.json, ~/.claude.json
#                      session credentials that expire, and .claude.json is
#                      mostly project state. `codex login` and running
#                      `claude` once are quicker than debugging a stale copy.
#   ~/.cache/huggingface/token
#                      redundant — huggingface_hub reads $HF_TOKEN.
#
# THREAT MODEL. If the bundle is published, treat the ciphertext as public:
# an attacker fetches it once and grinds offline forever on any hardware they
# care to rent. Passphrase entropy is the only thing that stops them, which is
# why `lock` checks the shape of what you type and offers to generate one.
#
# Format: a gzipped tar of the collected files, encrypted AES-256-CBC with the
# key from PBKDF2-HMAC-SHA512 over a random salt, base64 armoured. gzip's
# magic bytes are what make a wrong passphrase fail loudly instead of
# returning garbage; a marker file inside is the second check.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ENC_FILE="$SRV_DIR/secrets/secrets.enc"
MARKER=".srv-secrets-v2"

# Paths are relative to $HOME. Missing ones are skipped without complaint —
# not every machine has an rclone remote configured.
FILES=(
    .secrets.env
    .git-credentials
    .config/rclone/rclone.conf
)
SSH_FILES=(.ssh/id_ed25519 .ssh/id_ed25519.pub .ssh/id_rsa .ssh/id_rsa.pub)

# ~1s on a 2026 CPU. Paid once per machine, and the only thing standing
# between a mediocre passphrase and a GPU cluster.
ITER=2000000
CIPHER="-aes-256-cbc -md sha512 -pbkdf2 -iter $ITER -salt -a"

WITH_SSH=0
ACCEPT_WEAK=0
SRV_STRENGTH=strong

# ---------------------------------------------------------------------------
# Temp files
# ---------------------------------------------------------------------------
# A trap fires at shell exit, in a scope where the function that set it has
# already returned and its locals are gone — under `set -u` that is an error,
# not a silent no-op. So anything a trap must clean up is registered here, as
# a global, and removed by one handler.
SRV_TMP=()
_srv_cleanup() { [ ${#SRV_TMP[@]} -gt 0 ] && rm -rf "${SRV_TMP[@]}"; return 0; }
trap _srv_cleanup EXIT

# These take the name of the variable to fill rather than echoing the path:
# `x="$(mktmp)"` would run the body in a command-substitution subshell, where
# the append to SRV_TMP lands in a copy the parent never sees, and the file
# then survives the cleanup handler.
mktmp() {
    local __out="$1" p
    p="$(umask 077; mktemp "${TMPDIR:-/tmp}/srvsec.XXXXXX")"
    SRV_TMP+=("$p"); printf -v "$__out" '%s' "$p"
}
mktmpdir() {
    local __out="$1" p
    p="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/srvsec.XXXXXX")"
    SRV_TMP+=("$p"); printf -v "$__out" '%s' "$p"
}


# ---------------------------------------------------------------------------
# An openssl that can actually do PBKDF2
# ---------------------------------------------------------------------------
# macOS ships LibreSSL as /usr/bin/openssl and its `enc` has historically
# lagged on these flags, so the capability is probed rather than assumed.
find_openssl() {
    local candidate
    for candidate in openssl /usr/bin/openssl /opt/homebrew/opt/openssl@3/bin/openssl \
                     /usr/local/opt/openssl@3/bin/openssl; do
        command -v "$candidate" >/dev/null 2>&1 || continue
        if echo probe | "$candidate" enc -aes-256-cbc -md sha512 -pbkdf2 -iter 2 -a \
                -pass pass:probe >/dev/null 2>&1; then
            printf '%s\n' "$candidate"; return 0
        fi
    done
    return 1
}
OPENSSL="$(find_openssl)" || {
    warn "no openssl with PBKDF2 support found."
    warn "macOS: brew install openssl@3    Linux: install the openssl package"
    exit 1
}


# ---------------------------------------------------------------------------
# Passphrase
# ---------------------------------------------------------------------------
# $SRV_SECRETS_PASSPHRASE lets provisioning run unattended; it is read from
# the environment and never written anywhere.
read_passphrase() {
    local prompt="$1" __var="$2" value
    if [ -n "${SRV_SECRETS_PASSPHRASE:-}" ]; then
        printf -v "$__var" '%s' "$SRV_SECRETS_PASSPHRASE"; return 0
    fi
    if [ ! -t 0 ]; then
        warn "no terminal to read a passphrase from"
        warn "set SRV_SECRETS_PASSPHRASE, or run this from a shell"
        return 1
    fi
    printf '   %s' "$prompt" >&2
    IFS= read -rs value; printf '\n' >&2
    printf -v "$__var" '%s' "$value"
}

ask_yn() {
    local reply
    [ -t 0 ] || return 1
    printf '%s [%s] ' "$1" "$([ "$2" = y ] && echo 'Y/n' || echo 'y/N')" >&2
    read -r reply; reply="${reply:-$2}"
    [[ "$reply" =~ ^[Yy] ]]
}

# Length is a bad proxy on its own. The passphrases that fall are not short,
# they are *shaped* — a name and a birthday and a punctuation mark, which is
# the first thing every cracking ruleset tries.
#
# Scale, for the messages below: against PBKDF2-SHA512 at 2,000,000 iterations
# a rented ~100-GPU rig manages order 10^5 guesses/second.
#   initials + date + symbol   ~10^8 candidates  -> about an hour
#   five random words          ~10^19            -> longer than the species
# Sets SRV_STRENGTH to strong|weak as a side effect. The verdict is recorded
# in the blob's header so make-bundle.sh can refuse to publish a weak one
# without being told twice — the decision is made once, here, and remembered.
check_strength() {
    local pass="$1" length=${#1} words shape=""
    SRV_STRENGTH=strong
    words=$(printf '%s' "$pass" | tr -cs '[:alnum:]' ' ' | wc -w)
    # Character classes present. A generated string mixes three or four and
    # has no word structure to model; the word count alone would call a
    # random 14-character token "one or two words".
    local classes=0
    [[ "$pass" == *[[:lower:]]* ]] && classes=$((classes + 1))
    [[ "$pass" == *[[:upper:]]* ]] && classes=$((classes + 1))
    [[ "$pass" == *[[:digit:]]* ]] && classes=$((classes + 1))
    [[ "$pass" == *[^[:alnum:]]* ]] && classes=$((classes + 1))

    if (( length < 12 )); then
        warn "that is $length characters. Refusing: this file may end up public."
        warn "use 5+ random words, or let this script generate one."
        return 1
    fi
    if [[ "$pass" =~ ^[A-Za-z]{1,12}[0-9]{4,10}[^A-Za-z0-9]{0,3}$ ]]; then
        shape="a name or initials followed by a number"
    elif [[ "$pass" =~ (19|20)[0-9]{2} ]] && (( words < 3 )); then
        shape="a year, with too little else around it"
    elif (( words < 3 && length < 20 && classes < 3 )); then
        shape="one or two words"
    fi
    if [[ -n "$shape" ]]; then
        warn "that looks like $shape."
        warn "against a published file that is worth roughly an hour of rented GPUs;"
        warn "five random words would be worth longer than the species has existed."
        warn ""
        warn "to keep this passphrase, keep the ciphertext off the web:"
        warn "  install/make-bundle.sh --no-secrets     and copy secrets.enc by scp"
        # --accept-weak is how you say "yes, I decided this already" without a
        # terminal to say it at: re-locking after editing a token has to work
        # from a script, and the answer does not change between runs.
        if (( ACCEPT_WEAK )); then
            say "accepted (--accept-weak)"
        else
            ask_yn "   Use it anyway?" n || return 1
        fi
        SRV_STRENGTH=weak
    fi
    return 0
}


# ---------------------------------------------------------------------------
# lock
# ---------------------------------------------------------------------------
# Fills the global FOUND rather than a nameref: `local -n` needs bash 4.3,
# and macOS still ships 3.2 — the machine a bundle is most often built on.
FOUND=()
collect() {
    local f
    FOUND=()
    for f in "${FILES[@]}"; do [ -f "$HOME/$f" ] && FOUND+=("$f"); done
    if (( WITH_SSH )); then
        for f in "${SSH_FILES[@]}"; do [ -f "$HOME/$f" ] && FOUND+=("$f"); done
    fi
}

cmd_lock() {
    collect
    # A plain copy: bash 3.2 rejects "${FOUND[@]}" on an empty array under
    # `set -u`, so the count is checked first and the copy comes after.
    [ ${#FOUND[@]} -gt 0 ] || { warn "nothing to encrypt — no ~/.secrets.env and no credential files"; exit 1; }
    local -a found=("${FOUND[@]}")


    # Refuse the untouched template: it would look like real secrets crossed
    # over when they did not. Values may be quoted or bare.
    # A trailing comment after an empty value is not a value.
    if [ -f "$HOME/.secrets.env" ] &&
       ! grep -E '^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=' "$HOME/.secrets.env" |
         sed -E 's/^[^=]*=//; s/[[:space:]]+#.*$//; s/^["'"'"']//; s/["'"'"']$//' | grep -q '[^[:space:]]'; then
        # shellcheck disable=SC2088  # a message, not a path
        warn "~/.secrets.env has no filled-in values — fill it in first"
        exit 1
    fi

    step "Collecting"
    local f
    for f in "${found[@]}"; do
        say "$(printf '%-34s %s' "$f" "$(stat -c '%a  %s bytes' "$HOME/$f" 2>/dev/null ||
                                          stat -f '%Lp  %z bytes' "$HOME/$f")")"
    done
    (( WITH_SSH )) || say "(ssh keys excluded — add them with: $0 lock --with-ssh)"

    printf '\n'
    local pass1 pass2 generated
    if [ -t 0 ] && [ -z "${SRV_SECRETS_PASSPHRASE:-}" ] &&
       ask_yn "   Generate a strong passphrase instead of choosing one?" y; then
        # The passphrase is about to be printed. If this terminal belongs to a
        # coding agent, that print lands in a saved transcript — the one place
        # a fresh passphrase must never be. Only this branch prints one, so
        # the check belongs here rather than at the top of the command.
        if [ -n "${CLAUDECODE:-}${AI_AGENT:-}" ]; then
            warn "this is an agent session — whatever is printed here is recorded."
            warn "run 'srvlock' from a plain terminal instead."
            ask_yn "   Print one anyway?" n || exit 1
        fi

        generated="$("$OPENSSL" rand -base64 18)"
        printf '\n   Passphrase — put it in your password manager NOW, it is not saved:\n\n'
        printf '     %s\n\n' "$generated"
        ask_yn "   Saved it?" y || { warn "aborted, nothing written"; exit 1; }
        pass1="$generated"; SRV_STRENGTH=strong
    else
        read_passphrase "Passphrase: " pass1 || exit 1
        check_strength "$pass1" || exit 1
        if [ -z "${SRV_SECRETS_PASSPHRASE:-}" ]; then
            read_passphrase "Again     : " pass2 || exit 1
            [ "$pass1" = "$pass2" ] || { warn "they do not match"; exit 1; }
        fi
    fi

    local stage tmp
    mktmpdir stage
    mktmp tmp

    date -u +%Y-%m-%dT%H:%M:%SZ > "$stage/$MARKER"

    mkdir -p "$(dirname "$ENC_FILE")"
    {
        printf '# server encrypted credentials\n'
        printf '# aes-256-cbc, pbkdf2-hmac-sha512, %s iterations, gzip, base64\n' "$ITER"
        printf '# locked on %s at %s\n' "$(hostname -s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '# holds: %s\n' "${found[*]}"
        printf '# strength: %s\n' "$SRV_STRENGTH"
        printf '# unlock with: ~/server/secrets/secrets.sh unlock (srvunlock)\n'
        # -p keeps the modes, so ~/.git-credentials comes back 600 without
        # anyone having to remember to chmod it.
        tar -czf - -p -C "$HOME" "${found[@]}" -C "$stage" "$MARKER" |
            SRV_PASS="$pass1" $OPENSSL enc $CIPHER -pass env:SRV_PASS
    } > "$tmp"

    mv "$tmp" "$ENC_FILE"
    chmod 644 "$ENC_FILE"

    printf '\n'
    say "locked ${#found[@]} file(s) -> secrets/secrets.enc  [passphrase: $SRV_STRENGTH]"
    if [ "$SRV_STRENGTH" = weak ]; then
        warn "marked weak — make-bundle.sh will leave it out of the zip."
        warn "copy it to a new machine by hand instead:"
        warn "  scp ~/server/secrets/secrets.enc <host>:~/server/secrets/"
    fi
    say "next: $SRV_DIR/install/make-bundle.sh (the blob is git-ignored; it travels in the zip or by scp)"
}


# ---------------------------------------------------------------------------
# unlock / list
# ---------------------------------------------------------------------------
# Decrypts into a staging directory and validates before touching $HOME, so a
# wrong passphrase or a truncated download cannot leave a half-restored set of
# credentials behind.
decrypt_to() {
    local stage="$1" attempts=3 pass tmp
    mktmp tmp

    while (( attempts-- > 0 )); do
        read_passphrase "Passphrase for the bundled credentials: " pass || return 1
        # A fresh stage per attempt: a wrong passphrase that decrypts to
        # something tar partially unpacks must not leave files a later,
        # successful attempt would then copy into $HOME.
        find "$stage" -mindepth 1 -delete

        # Comment lines are the human-readable header; openssl gets the body.
        grep -v '^#' "$ENC_FILE" |
            SRV_PASS="$pass" $OPENSSL enc -d $CIPHER -pass env:SRV_PASS \
            > "$tmp" 2>/dev/null || true

        if tar -tzf "$tmp" >/dev/null 2>&1 &&
           tar -xzf "$tmp" -p -C "$stage" 2>/dev/null &&
           [ -f "$stage/$MARKER" ]; then
            return 0
        fi

        if [ -n "${SRV_SECRETS_PASSPHRASE:-}" ]; then
            warn "SRV_SECRETS_PASSPHRASE is wrong for this file"; break
        fi
        (( attempts > 0 )) && warn "wrong passphrase — $attempts attempt(s) left"
    done
    return 1
}

cmd_unlock() {
    [ -r "$ENC_FILE" ] || { warn "no secrets/secrets.enc in this bundle"; return 1; }

    local stage; mktmpdir stage

    decrypt_to "$stage" || {
        warn "could not decrypt. Copy the files across out of band instead:"
        warn "  scp <other-host>:~/.secrets.env ~/.secrets.env && chmod 600 ~/.secrets.env"
        return 1
    }
    rm -f "$stage/$MARKER"

    local rel dst
    while IFS= read -r rel; do
        dst="$HOME/$rel"
        if [ -e "$dst" ] && ! cmp -s "$stage/$rel" "$dst"; then
            backup "$dst"
        fi
        mkdir -p "$(dirname "$dst")"
        cp -p "$stage/$rel" "$dst"
        say "$(printf '%-34s mode %s' "$rel" "$(stat -c '%a' "$dst" 2>/dev/null || stat -f '%Lp' "$dst")")"
    done < <(cd "$stage" && find . -type f | sed 's|^\./||')

    say "credentials restored"
}

cmd_list() {
    [ -r "$ENC_FILE" ] || { warn "no secrets/secrets.enc in this bundle"; return 1; }
    grep '^#' "$ENC_FILE" | sed 's/^# /   /'
}


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
cmd_status() {
    if [ -r "$ENC_FILE" ]; then
        say "bundled  : secrets/secrets.enc"
        grep -E '^# (locked on|holds)' "$ENC_FILE" | sed 's/^# /           /'
    else
        say "bundled  : none — run '$0 lock' to create one"
    fi

    step "On this machine"
    local f mode
    for f in "${FILES[@]}" "${SSH_FILES[@]}"; do
        if [ -f "$HOME/$f" ]; then
            mode="$(stat -c '%a' "$HOME/$f" 2>/dev/null || stat -f '%Lp' "$HOME/$f")"
            say "$(printf '%-34s present (mode %s)' "$f" "$mode")"
        else
            say "$(printf '%-34s —' "$f")"
        fi
    done
    say "openssl  : $OPENSSL ($($OPENSSL version 2>/dev/null))"
}


cmd="${1:-status}"; shift || true
for arg in "$@"; do
    case "$arg" in
        --with-ssh)    WITH_SSH=1 ;;
        --accept-weak) ACCEPT_WEAK=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

case "$cmd" in
    lock)   cmd_lock ;;
    unlock) cmd_unlock ;;
    list)   cmd_list ;;
    status) cmd_status ;;
    *) echo "usage: ${0##*/} [lock [--with-ssh]|unlock|list|status]" >&2; exit 2 ;;
esac
