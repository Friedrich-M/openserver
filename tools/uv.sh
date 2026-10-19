#!/usr/bin/env bash
# tools/uv.sh — uv, the Python package and environment manager.
#
# Installed rather than relied upon from a module: it is the one Python tool
# that has to behave identically on a cluster login node, inside a SLURM job
# and on a laptop. Its cache is pointed at $SCRATCH by shell/env.sh.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

if have uv && updating && [ "$(command -v uv)" = "$HOME/.local/bin/uv" ]; then
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would run: uv self update"
    elif uv self update >/dev/null 2>&1; then
        say "updated uv $(uv --version 2>/dev/null | awk '{print $2}')"
    else
        warn "uv self update failed (a module-provided uv cannot update itself) — left as is"
    fi
    exit 0
elif have uv; then
    say "ok   uv $(uv --version 2>/dev/null | awk '{print $2}') ($(command -v uv))"
    exit 0
fi
if [ "$SRV_DRY_RUN" = 1 ]; then
    say "would install uv from https://astral.sh/uv/install.sh"
    exit 0
fi
online || { warn "offline — skipping uv"; exit 0; }

# UV_INSTALL_DIR keeps it beside claude and codex in ~/.local/bin, which
# shell/env.sh already puts on PATH.
if install_script uv https://astral.sh/uv/install.sh \
        env UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh; then
    say "installed uv -> $HOME/.local/bin/uv"
else
    warn "see https://docs.astral.sh/uv/"
fi
