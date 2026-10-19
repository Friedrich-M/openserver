# hosts/macos.sh — a personal Mac
# os: macos
#
# No module system, no SLURM, no shared scratch: $SCRATCH resolves to $HOME
# and the caches land under it. Homebrew is on PATH for both the Apple-silicon
# (/opt/homebrew) and Intel (/usr/local) prefixes; the one that does not exist
# is skipped.

SRV_SITE=""

SRV_SCRATCH_CANDIDATES=""    # env.sh falls back to $HOME

SRV_MODULES=""

SRV_CONDA_ROOT=""            # env.sh probes ~/miniconda3, ~/anaconda3, ~/miniforge3 …
SRV_CONDA_TREE=""

SRV_SLURM_ACCOUNT=""
SRV_SLURM_GPU_PARTITION=""
SRV_SLURM_WATCH_PARTITIONS=""

# Leave OMP alone: on a laptop the library's own default is better than a
# number pinned to some cluster's core count.
SRV_OMP_NUM_THREADS=""

SRV_EXTRA_PATH="/usr/local/bin /opt/homebrew/bin"
