#!/usr/bin/env bash
# tools/rclone.sh — rclone, and the Google Drive remote when asked for.
#
#   tools/rclone.sh install      the binary only (setup.sh --with=rclone)
#   tools/rclone.sh gdrive       also configure the `gdrive` remote
#   tools/rclone.sh status       0 if the remote is configured, 1 if not
#
# The binary is user-local, a static build from rclone.org: the clusters'
# system copy is old or absent, and there is no sudo.
#
# The remote is the part that cannot be entirely automatic — Google Drive
# needs an OAuth consent in a browser, once. So it is a choice, never a
# default (setup.sh asks, or takes --gdrive / --no-gdrive), and there are
# three routes, tried in this order:
#   1. ~/.config/rclone/rclone.conf already has the remote: restored from the
#      encrypted bundle by secrets.sh, or copied across. Nothing to do.
#   2. This machine has a browser: `rclone config create` opens it.
#   3. Headless (a cluster): rclone prints an `rclone authorize "drive"`
#      command to run on a laptop and asks for the token that prints.
# Afterwards `srvlock` carries the finished remote to every other machine,
# which is how route 1 comes to exist.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

BIN="$HOME/.local/bin"
REMOTE="${SRV_RCLONE_REMOTE:-gdrive}"

# --------------------------------------------------------------------------
# The binary
# --------------------------------------------------------------------------
install_rclone() {
    if have rclone && updating && [ "$(command -v rclone)" = "$BIN/rclone" ]; then
        if [ "$SRV_DRY_RUN" = 1 ]; then
            say "would run: rclone selfupdate"
        elif rclone selfupdate >/dev/null 2>&1; then
            say "updated $(rclone version 2>/dev/null | head -1)"
        else
            warn "rclone selfupdate failed — left as is"
        fi
        return 0
    fi
    if have rclone; then
        say "ok   $(rclone version 2>/dev/null | head -1) ($(command -v rclone))"
        return 0
    fi
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would install rclone into $BIN"
        return 0
    fi
    if [ "${SRV_OS:-linux}" = macos ]; then
        if have brew; then run brew install rclone
        else warn "no Homebrew — install rclone with: brew install rclone"; fi
        return 0
    fi
    online || { warn "offline — skipping rclone"; return 0; }
    have unzip || { warn "unzip is not installed — cannot unpack rclone"; return 0; }

    local arch
    case "$(uname -m)" in
        x86_64)        arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) warn "no rclone build for $(uname -m) — skipping"; return 0 ;;
    esac

    # rclone.org's own "current" link, so no release lookup and no GitHub
    # API call from a shared login node.
    local url="https://downloads.rclone.org/rclone-current-linux-$arch.zip" tmp found
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/srvrclone.XXXXXX")"
    if fetch "$url" > "$tmp/rclone.zip" && unzip -q "$tmp/rclone.zip" -d "$tmp"; then
        found="$(find "$tmp" -type f -name rclone | head -1)"
        if [ -n "$found" ]; then
            mkdir -p "$BIN" && install -m 755 "$found" "$BIN/rclone"
            say "installed $("$BIN/rclone" version | head -1) -> $BIN/rclone"
        else
            warn "no rclone binary inside $url"
        fi
    else
        warn "could not download $url — skipping rclone"
    fi
    rm -rf "$tmp"
}

# --------------------------------------------------------------------------
# The remote
# --------------------------------------------------------------------------
remote_configured() {
    have rclone && rclone listremotes 2>/dev/null | grep -qx "$REMOTE:"
}

configure_gdrive() {
    if remote_configured; then
        say "ok   $REMOTE: is configured"
        return 0
    fi
    if ! have rclone; then
        warn "rclone is not installed — skipping the $REMOTE: remote"
        return 0
    fi
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would configure the $REMOTE: remote (Google Drive)"
        return 0
    fi
    if [ ! -t 0 ]; then
        warn "no terminal — the Google Drive consent needs one. Later, run:"
        warn "  $0 gdrive"
        return 0
    fi

    # A browser here, or not. A Mac and a Linux desktop can open the consent
    # page themselves; a cluster login node cannot, and config_is_local=false
    # is how rclone is told so — it then prints the command to run on a
    # laptop and asks for the token that prints.
    local -a opts=(scope=drive)
    if [ "${SRV_OS:-linux}" = macos ] || [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        say "a browser will open for the Google consent"
    else
        say "no browser here: rclone will print an 'rclone authorize' command —"
        say "run it on your laptop and paste the token it prints"
        opts+=(config_is_local=false)
    fi

    if ! rclone config create "$REMOTE" drive "${opts[@]}" >/dev/null; then
        warn "the remote was not created — try by hand: rclone config"
        return 0
    fi
    if rclone about "$REMOTE:" >/dev/null 2>&1; then
        say "ok   $REMOTE: reaches Google Drive"
    else
        warn "$REMOTE: is written but did not answer — check with: rclone about $REMOTE:"
    fi
    say "next: srvlock — carries rclone.conf to the other machines, encrypted"
}

case "${1:-install}" in
    install) install_rclone ;;
    gdrive)  install_rclone && configure_gdrive ;;
    status)  remote_configured ;;
    *) echo "usage: ${0##*/} [install|gdrive|status]" >&2; exit 2 ;;
esac
