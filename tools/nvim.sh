#!/usr/bin/env bash
# tools/nvim.sh — Neovim plus the kickstart.nvim config.
#
# The cluster nvim is either absent or ancient, so a release tarball is
# unpacked into ~/software and the host profiles put it on PATH. The config is
# a clone rather than vendored: kickstart keeps itself up to date through its
# own git remote.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

NVIM_VERSION="${NVIM_VERSION:-stable}"

nvim_new_enough() {
    have nvim || return 1
    # kickstart.nvim needs 0.9+; anything older is worse than not having it.
    nvim --version 2>/dev/null | head -1 |
        awk '{ split($2, v, /[v.]/); exit !(v[2] > 0 || v[3] >= 9) }'
}

# Under --update, a Neovim this script unpacked into ~/software is replaced by
# the current release; a system or Homebrew copy is left to its own manager.
ours() { [ "$(command -v nvim 2>/dev/null)" = "$HOME/software/nvim-linux64/bin/nvim" ]; }
if nvim_new_enough && ! { updating && ours; }; then
    say "ok   $(nvim --version | head -1) ($(command -v nvim))"
elif [ "$SRV_DRY_RUN" = 1 ]; then
    say "would download Neovim $NVIM_VERSION into ~/software"
elif [ "${SRV_OS:-linux}" = macos ]; then
    if have brew; then
        run brew install neovim
    else
        warn "no Homebrew — install Neovim with: brew install neovim"
    fi
elif ! online; then
    warn "offline — skipping Neovim"
else
    case "$(uname -m)" in
        x86_64)          asset=nvim-linux-x86_64 ;;
        aarch64|arm64)   asset=nvim-linux-arm64  ;;
        *) warn "no Neovim build for $(uname -m) — skipping"; exit 0 ;;
    esac

    mkdir -p "$HOME/software"
    # try_build <url> : unpack into a staging folder and keep the build only
    # if it runs here. The official build needs a recent glibc; a binary that
    # cannot start would still take over vim, $EDITOR and git's editor.
    # The host profiles put ~/software/nvim-linux64/bin on PATH, so that one
    # name is kept whatever the tarball is called.
    try_build() {
        local stage
        stage="$(mktemp -d "$HOME/software/.nvim-stage.XXXXXX")" || return 1
        if fetch "$1" | tar -xz -C "$stage" 2>/dev/null &&
           "$stage/$asset/bin/nvim" --version >/dev/null 2>&1; then
            rm -rf "$HOME/software/nvim-linux64"
            mv "$stage/$asset" "$HOME/software/nvim-linux64"
            rm -rf "$stage"
            return 0
        fi
        rm -rf "$stage"
        return 1
    }
    official="https://github.com/neovim/neovim/releases/download/$NVIM_VERSION/$asset.tar.gz"
    # Neovim's own builds for older glibc (RHEL 8, Ubuntu 20.04), same names.
    older="https://github.com/neovim/neovim-releases/releases/latest/download/$asset.tar.gz"
    if try_build "$official"; then
        say "installed $("$HOME/software/nvim-linux64/bin/nvim" --version | head -1)"
    elif try_build "$older"; then
        say "installed $("$HOME/software/nvim-linux64/bin/nvim" --version | head -1) (the build for older glibc)"
    else
        warn "no Neovim build downloads and runs here (offline, or a C library too old) — keeping the system's editor"
    fi
fi

clone_if_missing https://github.com/nvim-lua/kickstart.nvim.git "$HOME/.config/nvim" || true
# An `if`, not `updating && …`: as the last command, a false `updating`
# would become the script's exit status and setup.sh would report a failure.
if updating; then
    git_refresh "$HOME/.config/nvim" "kickstart.nvim"
fi
