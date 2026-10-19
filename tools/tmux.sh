#!/usr/bin/env bash
# tools/tmux.sh — TPM, the tmux plugin manager.
#
# ~/.tmux.conf itself is vendored in this bundle (config/tmux/tmux.conf is
# gpakosz/.tmux verbatim) so every machine runs the identical version; only
# the plugin manager is fetched.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

if ! have tmux; then
    say "tmux is not installed here — skipping TPM"
    exit 0
fi

clone_if_missing https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm" || true
updating && git_refresh "$HOME/.tmux/plugins/tpm" TPM
say "note: start tmux, then press prefix + I, to install the plugins"
