# hosts/generic.sh — a plain Linux box or cloud VM, and the template
# os: linux
#
# Deliberately minimal: no SLURM, no assumptions about shared
# filesystems. Anything that is not a known machine and not a Mac lands here
# and still gets a complete working shell. It is also the fallback when a
# preset SRV_HOST has no profile, so it is never pruned.
#
# To add a machine, copy hosts/example-cluster.sh (an HPC cluster) or this
# file to hosts/local/<name>.sh — your own profiles, git-ignored, read before
# the shipped ones — set its `# hosts:` line to shell patterns on the
# hostname, and fill in the values. Every profile carries exactly these
# variables, in this order.
#
# Values that are yours rather than the machine's — a lab's SLURM account, a
# group fileset, software under your own $HOME — go in <name>.local.sh beside
# the profile: sourced after it, ignored by git, shipped in your own
# server.zip.
# Per-machine shell tweaks that should not be synced at all belong in
# ~/.zshrc.local.

SRV_SITE=""                  # a family of machines sharing a fallback profile (hosts/<site>.sh)

SRV_SCRATCH_CANDIDATES=""    # writable dirs, best first; env.sh tries /scratch/$USER, then $HOME

SRV_MODULES="anaconda3|miniconda3|anaconda cudatoolkit|cuda"   # for interactive shells, unversioned; a|b = first that exists

SRV_CONDA_ROOT=""            # a fixed conda install, for shells with no module system
SRV_CONDA_TREE=""            # or a directory of conda releases: the newest is used

SRV_SLURM_ACCOUNT=""         # --account for shell/slurm.zsh; empty means SLURM's default
SRV_SLURM_GPU_PARTITION=""   # --partition for GPU allocations; empty means --gres alone
SRV_SLURM_WATCH_PARTITIONS="" # what `sgpu` reports on; empty means every partition

SRV_OMP_NUM_THREADS=""       # empty lets libraries size themselves to the machine
SRV_EXTRA_PATH="$HOME/software/nvim-linux64/bin"   # prepended to PATH, lowest precedence first
