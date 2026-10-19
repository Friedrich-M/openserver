#!/usr/bin/env bash
# tools/conda.sh — conda, only if this machine wants it.
#
# Never run unattended: setup.sh asks first, because most machines already
# have conda one way or another. On a cluster it arrives with a module that
# hosts/<name>.sh loads (SRV_MODULES), and installing a second copy
# into $HOME wastes several GB of a small quota. Elsewhere there may already
# be a system or Homebrew install, or the project may use uv instead.
#
# `condarc` renders ~/.condarc alone, for a conda that is already here;
# `install` renders it after a successful install. It keeps environments off
# /home and on scratch.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# $SCRATCH comes from shell/env.sh. On a fresh machine setup.sh runs before
# any shell has sourced it, so resolve it here the same way a login shell
# would — falling back to $HOME would silently put every conda env on /home.
if [ -z "${SCRATCH:-}" ]; then
    . "$SRV_DIR/shell/env.sh"
fi

# --------------------------------------------------------------------------
# Install
# --------------------------------------------------------------------------
# Miniforge rather than Miniconda: conda-forge by default and no commercial
# licence terms on the default channels, which matters on university hardware.
install_conda() {
    local prefix="${CONDA_PREFIX_DIR:-$HOME/miniforge3}"

    if [ -d "$prefix" ]; then
        say "keep $prefix (already there)"
        return 0
    fi
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would install Miniforge into $prefix"
        return 0
    fi
    online || { warn "offline — cannot install conda"; return 1; }

    local kernel machine url installer
    kernel="$(uname -s)"; machine="$(uname -m)"
    url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-${kernel}-${machine}.sh"
    # mktemp, not a name built from $$: /tmp is shared and the pid is
    # guessable, and the file is about to be executed. The X's must be last:
    # BSD/macOS mktemp does not substitute them in front of a suffix, and bash
    # does not need the file to end in .sh. The trap covers a Ctrl-C mid-download.
    installer="$(mktemp "${TMPDIR:-/tmp}/miniforge.XXXXXX")"
    # shellcheck disable=SC2064  # expand now: $installer is a local
    trap "rm -f '$installer'" EXIT

    say "downloading Miniforge3-${kernel}-${machine}"
    if ! fetch "$url" > "$installer"; then
        warn "no Miniforge build for ${kernel}-${machine} — skipping"
        rm -f "$installer"
        return 1
    fi

    # -b batch, -p prefix. No shell init: shell/env.sh already finds any conda
    # under $HOME and sources its profile.d hook, so a `conda initialize`
    # block in ~/.zshrc would only be a second, conflicting copy.
    if bash "$installer" -b -p "$prefix" >/dev/null 2>&1; then
        say "installed conda -> $prefix"
    else
        warn "Miniforge installer failed"
        rm -f "$installer"
        return 1
    fi
    rm -f "$installer"
}

# --------------------------------------------------------------------------
# ~/.condarc
# --------------------------------------------------------------------------
# envs_dirs needs a real absolute path, so this one is rendered rather than
# copied verbatim. $SCRATCH is whatever shell/env.sh resolved for this machine
# — a real scratch filesystem on a cluster, $HOME on a laptop.
render_condarc() {
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would render ~/.condarc with envs_dirs -> $SCRATCH/envs"
        return 0
    fi
    # A ~/.condarc of your own (channels, proxies, mirrors) stays yours.
    if [ -e "$HOME/.condarc" ] && \
       ! grep -q "rendered by server/tools/conda.sh" "$HOME/.condarc" 2>/dev/null; then
        say "keep ~/.condarc (yours); to keep environments off /home add:"
        say "  envs_dirs: [$SCRATCH/envs]    pkgs_dirs: [$SCRATCH/.conda/pkgs]"
        return 0
    fi
    sed "s|__SCRATCH__|$SCRATCH|g" "$SRV_DIR/config/conda/condarc.template" > "$HOME/.condarc"
    say "wrote ~/.condarc (envs_dirs and pkgs_dirs on $SCRATCH)"
}


case "${1:-install}" in
    install)  install_conda && render_condarc ;;
    condarc)  render_condarc ;;                # configure only, do not install
    *) echo "usage: ${0##*/} [install|condarc]" >&2; exit 2 ;;
esac
