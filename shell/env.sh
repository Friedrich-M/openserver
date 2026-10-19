# shell/env.sh — environment shared by every shell on every server.
#
# Sourced by both ~/.bashrc and ~/.zshrc, and safe in non-interactive shells
# (SLURM job scripts, scp/rsync, `ssh <host> <cmd>`). Written in portable sh
# that behaves identically under bash and zsh: no arrays, no output, nothing
# interactive.
#
# Order: bundle root -> which machine (lib/detect.sh, which sources the host
#        profile) -> scratch -> caches -> PATH -> conda -> limits -> secrets.

SRV_DIR="${SRV_DIR:-$HOME/server}"
export SRV_DIR

# Safe to source again — `exec zsh` from .bashrc re-runs this file, and so
# does every `source ~/.zshrc`: each PATH entry is de-duplicated before it is
# added, the exports are plain assignments, and the conda hook loads only
# while no `conda` is defined. So re-sourcing re-reads ~/.secrets.env too,
# and an edited token takes effect without a new shell.


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# zsh does not word-split unquoted parameters the way sh does, so every loop
# over a space-separated SRV_* list goes through a function that turns the sh
# behaviour on locally (`local_options` restores it on return).

# _srv_first_dir "<space-separated candidates>" -> first that is a writable dir
_srv_first_dir() {
    [ -n "${ZSH_VERSION:-}" ] && setopt local_options sh_word_split
    local candidate
    for candidate in $1; do
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# _srv_first_existing "<space-separated candidates>" -> first that is a dir
# at all. For software roots: a site-wide conda install is readable, never
# writable, so the scratch test above would skip it.
_srv_first_existing() {
    [ -n "${ZSH_VERSION:-}" ] && setopt local_options sh_word_split
    local candidate
    for candidate in $1; do
        if [ -d "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# _srv_path_prepend <dir> : prepend if it exists and is not already on PATH
_srv_path_prepend() {
    [ -d "$1" ] || return 0
    case ":$PATH:" in
        *":$1:"*) return 0 ;;
    esac
    PATH="$1:$PATH"
}

# _srv_path_prepend_list "<space-separated dirs>" : lowest precedence first
_srv_path_prepend_list() {
    [ -n "${ZSH_VERSION:-}" ] && setopt local_options sh_word_split
    local dir
    for dir in $1; do
        _srv_path_prepend "$dir"
    done
}


# ---------------------------------------------------------------------------
# Your settings
# ---------------------------------------------------------------------------
# .srv-config.sh is server.json rendered by setup.sh (lib/config.sh): plain
# exports, so no JSON is parsed at shell start. The agent aliases read the
# model names from here.
if [ -r "$SRV_DIR/.srv-config.sh" ]; then
    . "$SRV_DIR/.srv-config.sh"
fi
[ -n "${SRV_CFG_claude_model:-}" ] && export SRV_CLAUDE_MODEL="$SRV_CFG_claude_model"
[ -n "${SRV_CFG_codex_model:-}" ]  && export SRV_CODEX_MODEL="$SRV_CFG_codex_model"


# ---------------------------------------------------------------------------
# Which machine is this
# ---------------------------------------------------------------------------
# lib/detect.sh picks the profile whose header claims this hostname and
# sources it. A profile is purely declarative — it sets SRV_* values and runs
# nothing — so all behaviour lives here, and every machine runs the same code
# with different inputs.
. "$SRV_DIR/lib/detect.sh"


# ---------------------------------------------------------------------------
# Scratch
# ---------------------------------------------------------------------------
# The profile's candidates first, then a $SCRATCH the site already set (as
# many centres do) unless it is only $HOME, then the common /scratch/$USER.
# Falls back to $HOME, so a laptop and a brand-new server whose scratch space
# has not been provisioned yet both still work.
_srv_site_scratch="${SCRATCH:-}"
[ "$_srv_site_scratch" = "$HOME" ] && _srv_site_scratch=""
SCRATCH=$(_srv_first_dir "${SRV_SCRATCH_CANDIDATES:-} $_srv_site_scratch /scratch/$USER") \
    || SCRATCH="$HOME"
unset _srv_site_scratch
export SCRATCH


# ---------------------------------------------------------------------------
# Caches
# ---------------------------------------------------------------------------
# /home is small and quota'd on the clusters, so anything that grows without
# bound is redirected to scratch. On a machine where $SCRATCH is $HOME this
# just puts them in their conventional place.
export HF_HOME="$SCRATCH/.cache/huggingface"
export HF_DATASETS_CACHE="$HF_HOME/datasets"
export TORCH_HOME="$SCRATCH/.cache/torch"
export UV_CACHE_DIR="$SCRATCH/.cache/uv"
export PIP_CACHE_DIR="$SCRATCH/.cache/pip"
export WANDB_DIR="$SCRATCH/wandb"

# Temp files follow the caches onto scratch — but only where a real scratch
# resolved. Where $SCRATCH fell back to $HOME (a laptop, a bare VM) the
# system's own TMPDIR is the better one: macOS gives each user a private,
# periodically cleaned /var/folders tree, and a ~/tmp nothing ever empties is
# worse than /tmp. Inside a SLURM job the scheduler's per-job TMPDIR (often
# fast node-local disk) stays. TMPDIR has to exist, or anything calling
# mkstemp() fails obscurely.
if [ "$SCRATCH" != "$HOME" ] && [ -z "${SLURM_JOB_ID:-}" ]; then
    export TMPDIR="$SCRATCH/tmp"
    [ -d "$TMPDIR" ] || mkdir -p "$TMPDIR" 2>/dev/null || export TMPDIR=/tmp
fi


# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------
# Thread count for OpenMP/MKL/NumPy. Left unset on unknown machines and on
# laptops so libraries size themselves to whatever hardware they find.
if [ -n "${SRV_OMP_NUM_THREADS:-}" ]; then
    export OMP_NUM_THREADS="$SRV_OMP_NUM_THREADS"
fi

# Blender's bundled Python, where a host profile points at one.
if [ -n "${SRV_BPY:-}" ] && [ -x "${SRV_BPY:-}" ]; then
    export BPY="$SRV_BPY"
fi


# ---------------------------------------------------------------------------
# PATH
# ---------------------------------------------------------------------------
_srv_path_prepend_list "${SRV_EXTRA_PATH:-}"
_srv_path_prepend "$HOME/bin"
_srv_path_prepend "$HOME/.local/bin"     # claude, codex, uv and friends
export PATH


# ---------------------------------------------------------------------------
# conda
# ---------------------------------------------------------------------------
# On the clusters the anaconda3 *module* (loaded from .zshrc) defines the
# `conda` shell function already. This block is the fallback that makes
# `conda activate` work everywhere else: non-interactive bash inside SLURM
# scripts, and machines with no module system at all.
if ! command -v conda >/dev/null 2>&1; then
    # A site that installs conda as a tree of releases (SRV_CONDA_TREE, one
    # directory per version) pins none of them here: the newest is used.
    if [ -z "${SRV_CONDA_ROOT:-}" ] && [ -n "${SRV_CONDA_TREE:-}" ] && [ -d "$SRV_CONDA_TREE" ]; then
        SRV_CONDA_ROOT=$(ls -d "$SRV_CONDA_TREE"/*/ 2>/dev/null | sort -V 2>/dev/null | tail -n 1)
        SRV_CONDA_ROOT="${SRV_CONDA_ROOT%/}"
    fi
    _srv_conda_root=$(_srv_first_existing "${SRV_CONDA_ROOT:-} \
        $HOME/miniconda3 $HOME/anaconda3 $HOME/mambaforge $HOME/miniforge3 \
        /opt/homebrew/Caskroom/miniconda/base") || true
    if [ -n "${_srv_conda_root:-}" ] && [ -r "$_srv_conda_root/etc/profile.d/conda.sh" ]; then
        . "$_srv_conda_root/etc/profile.d/conda.sh"
    fi
    unset _srv_conda_root
fi


# ---------------------------------------------------------------------------
# Resource limits
# ---------------------------------------------------------------------------
# No core dumps: a crash-looping VS Code extension host once wrote multi-GB
# core.* files into /home and blew the quota.
ulimit -c 0 2>/dev/null || true


# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
# API tokens live only in ~/.secrets.env (mode 600, never in this bundle).
# Sourced here rather than in .zshrc so SLURM jobs inherit the tokens too.
if [ -r "$HOME/.secrets.env" ]; then
    . "$HOME/.secrets.env"
fi

unset -f _srv_first_dir _srv_first_existing _srv_path_prepend _srv_path_prepend_list
true
