#!/usr/bin/env bash
# tools/cli.sh — the small fast CLI tools, installed user-local.
#
# These matter more on a cluster than on a laptop: there is no sudo, the
# system binaries are whatever RHEL shipped years ago, and the filesystem is a
# slow shared one where `grep -r` across a source tree is genuinely painful.
# Each of these is a single static binary that drops into ~/.local/bin, which
# shell/env.sh already has on PATH.
#
#   fzf   fuzzy finder — Ctrl-R over history, Ctrl-T over files
#   rg    ripgrep, the fast recursive grep
#   fd    a sane `find`
#   bat   `cat` with syntax highlighting and paging
#   eza   `ls` with a tree mode and git status
#   gh    the GitHub CLI — PRs, issues, `gh auth login` for HTTPS credentials
#   git-lfs
#         config/git/gitconfig marks the LFS filter `required`, so without the binary
#         a checkout of any LFS repo fails outright instead of leaving pointer
#         files behind. The clusters' system git has no lfs.
#
# Skipped, on purpose: zoxide, because oh-my-zsh's `z` plugin is already
# loaded in shell/zshrc and running both means two directory databases
# disagreeing about where you have been.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

BIN="$HOME/.local/bin"

# The GitHub token is read from ~/.secrets.env when no shell has exported it
# yet: on a fresh machine this runs from setup.sh, before any shell has
# sourced env.sh, and the first install is exactly when the shared limit
# below bites.
if [ -z "${GITHUB_TOKEN:-}" ] && [ -r "$HOME/.secrets.env" ]; then
    . "$HOME/.secrets.env"
fi

# On a Mac, Homebrew installs and updates these, as tools/nvim.sh and
# tools/rclone.sh leave Neovim and rclone to it.
if [ "${SRV_OS:-linux}" = macos ]; then
    missing=()
    for pair in fzf:fzf rg:ripgrep fd:fd bat:bat eza:eza gh:gh git-lfs:git-lfs; do
        if have "${pair%%:*}"; then
            say "ok   ${pair%%:*} ($(command -v "${pair%%:*}"))"
        else
            missing+=("${pair#*:}")
        fi
    done
    if [ ${#missing[@]} -eq 0 ]; then
        :
    elif ! have brew; then
        warn "no Homebrew — install these with: brew install ${missing[*]}"
    else
        run brew install "${missing[@]}" || warn "brew install ${missing[*]} failed"
    fi
    exit 0
fi

case "$(uname -m)" in
    x86_64)        ARCH=x86_64;  FZF_ARCH=amd64 ;;
    aarch64|arm64) ARCH=aarch64; FZF_ARCH=arm64 ;;
    *) say "no prebuilt binaries for $(uname -m) — skipping"; exit 0 ;;
esac

# api_get <url> : GET with the token when there is one — curl or wget, like
# fetch. The empty-array expansion is spelled out for bash < 4.4 under set -u.
api_get() {
    local -a auth=()
    if have curl; then
        [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
        curl -fsSL ${auth[@]+"${auth[@]}"} "$1" 2>/dev/null
    elif have wget; then
        [ -n "${GITHUB_TOKEN:-}" ] && auth=(--header="Authorization: Bearer $GITHUB_TOKEN")
        wget -qO- ${auth[@]+"${auth[@]}"} "$1" 2>/dev/null
    else
        return 1
    fi
}

# latest_tag <owner/repo> : the tag /releases/latest redirects to — no API call
latest_tag() {
    if have curl; then
        curl -fsSLI -o /dev/null -w '%{url_effective}' \
            "https://github.com/$1/releases/latest" 2>/dev/null | sed 's#.*/tag/##'
    elif have wget; then
        wget -qS --spider "https://github.com/$1/releases/latest" 2>&1 |
            sed -n 's#^ *Location: .*/tag/##p' | tail -n 1 | tr -d '\r '
    fi
}

# latest_asset <owner/repo> <extended-regex matching the asset name> [template]
#
# Resolved through the API rather than the /releases/latest/download/ path,
# because every one of these embeds its version in the filename. $GITHUB_TOKEN
# is used when set: unauthenticated GitHub allows 60 calls an hour per IP, and
# on a cluster login node that IP is shared with everyone else — so the limit
# is routinely exhausted. When the API says no, the version is read instead
# from where github.com/<repo>/releases/latest redirects to (no API, no
# limit) and dropped into <template>, where {V} stands for the version
# without its leading v.
latest_asset() {
    local repo="$1" pattern="$2" template="${3:-}" url tag
    url="$(api_get "https://api.github.com/repos/$repo/releases/latest" |
        grep -oE '"browser_download_url": *"[^"]+"' |
        sed -E 's/.*"(https[^"]+)"/\1/' |
        grep -E "$pattern" | head -1)" || true
    if [ -z "$url" ] && [ -n "$template" ]; then
        tag="$(latest_tag "$repo")" || true
        [ -n "$tag" ] && url="https://github.com/$repo/releases/download/$tag/${template//\{V\}/${tag#v}}"
    fi
    [ -n "$url" ] && printf '%s\n' "$url"
}

# install_tool <command> <owner/repo> <asset regex> <basename inside archive> [template]
install_tool() {
    local cmd="$1" repo="$2" pattern="$3" member="$4" template="${5:-}" url tmp

    # Only a copy this script put in ~/.local/bin is ever replaced: a system
    # or module-provided one is not ours to update.
    local refresh=0
    if have "$cmd"; then
        if updating && [ "$(command -v "$cmd")" = "$BIN/$cmd" ]; then
            refresh=1
        else
            say "ok   $cmd ($(command -v "$cmd"))"
            return 0
        fi
    fi
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would $( ((refresh)) && echo update || echo install ) $cmd from $repo"
        return 0
    fi

    url="$(latest_asset "$repo" "$pattern" "$template")" || true
    if [ -z "${url:-}" ]; then
        warn "could not find a $cmd release asset for $ARCH (rate-limited, or offline)"
        return 0
    fi

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/srvcli.XXXXXX")"
    if fetch "$url" | tar -xz -C "$tmp" 2>/dev/null; then
        local found
        found="$(find "$tmp" -type f -name "$member" -perm -u+x | head -1)"
        if [ -n "$found" ]; then
            mkdir -p "$BIN" && install -m 755 "$found" "$BIN/$cmd"
            say "$( ((refresh)) && echo updated || echo installed ) $cmd -> $BIN/$cmd"
        else
            warn "$member not found inside the $cmd archive"
        fi
    else
        warn "could not unpack $cmd from $url"
    fi
    rm -rf "$tmp"
}

online || { warn "offline — skipping the CLI tools"; exit 0; }

MUSL="${ARCH}-unknown-linux-musl"
install_tool fzf junegunn/fzf       "linux_${FZF_ARCH}\.tar\.gz$"  fzf  "fzf-{V}-linux_${FZF_ARCH}.tar.gz"
install_tool rg  BurntSushi/ripgrep "${MUSL}\.tar\.gz$"           rg   "ripgrep-{V}-${MUSL}.tar.gz"
install_tool fd  sharkdp/fd         "${MUSL}\.tar\.gz$"           fd   "fd-v{V}-${MUSL}.tar.gz"
install_tool bat sharkdp/bat        "${MUSL}\.tar\.gz$"           bat  "bat-v{V}-${MUSL}.tar.gz"
# eza builds a static musl binary for x86_64 only; aarch64 is gnu.
EZA="$MUSL"; [ "$ARCH" = aarch64 ] && EZA="aarch64-unknown-linux-gnu"
install_tool eza eza-community/eza  "eza_${EZA}\.tar\.gz$"       eza  "eza_${EZA}.tar.gz"
install_tool gh  cli/cli            "linux_${FZF_ARCH}\.tar\.gz$"  gh   "gh_{V}_linux_${FZF_ARCH}.tar.gz"
install_tool git-lfs git-lfs/git-lfs "linux-${FZF_ARCH}-v[0-9.]+\.tar\.gz$" git-lfs "git-lfs-linux-${FZF_ARCH}-v{V}.tar.gz"

have fzf && say "note: Ctrl-R searches history, Ctrl-T inserts a file path"
true
