#!/usr/bin/env bash
# tools/zsh.sh — oh-my-zsh, the powerlevel10k theme and the two plugins that
# shell/zshrc expects to find. Nothing here is vendored: they are upstream
# repos that update themselves, so they are cloned rather than shipped.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ZSH_DIR="$HOME/.oh-my-zsh"

# oh-my-zsh first, and nothing else if it fails: cloning the theme and the
# plugins into a ~/.oh-my-zsh that does not exist would create it as a plain
# directory, which every later run would then refuse to touch.
if clone_if_missing https://github.com/ohmyzsh/ohmyzsh.git "$ZSH_DIR"; then
    clone_if_missing https://github.com/romkatv/powerlevel10k.git \
        "$ZSH_DIR/custom/themes/powerlevel10k" || true
    clone_if_missing https://github.com/zsh-users/zsh-autosuggestions.git \
        "$ZSH_DIR/custom/plugins/zsh-autosuggestions" || true
    clone_if_missing https://github.com/zsh-users/zsh-syntax-highlighting.git \
        "$ZSH_DIR/custom/plugins/zsh-syntax-highlighting" || true
fi
if updating; then
    git_refresh "$ZSH_DIR" oh-my-zsh
    git_refresh "$ZSH_DIR/custom/themes/powerlevel10k" powerlevel10k
    git_refresh "$ZSH_DIR/custom/plugins/zsh-autosuggestions" zsh-autosuggestions
    git_refresh "$ZSH_DIR/custom/plugins/zsh-syntax-highlighting" zsh-syntax-highlighting
fi

# zsh itself. It is the login shell on the clusters already; a fresh VM or a
# Mac may not have it, and we cannot install it without a package manager.
if ! have zsh; then
    warn "zsh is not installed — install it, then re-run setup.sh:"
    if [ "${SRV_OS:-linux}" = macos ]; then
        warn "  brew install zsh          (macOS ships one, but an old 5.x)"
    else
        warn "  sudo apt install zsh   |   sudo dnf install zsh"
    fi
fi
