# hosts/example-cluster.sh — an HPC cluster, as an example to copy
# hosts: login*.cluster.example.edu *.cluster.example.edu
#
# Declarative only: set SRV_* values, run nothing. lib/detect.sh reads the
# `# hosts:` line above (shell patterns on the hostname, full or short) to
# know this file is for those machines; shell/env.sh and shell/zshrc act on
# the values, so every machine runs identical code. The pattern matches no
# real machine: copy this file to hosts/local/<name>.sh, point its `# hosts:`
# line at your login and compute nodes, and fill in your site's values —
# `module avail`, `sinfo -s` and `sacctmgr show assoc user=$USER` tell you
# them. Your account, a restricted partition and a group's scratch folder go
# in hosts/local/<name>.local.sh.

SRV_SITE=""                  # a family of machines sharing a fallback profile (hosts/<site>.sh)

# Writable folders, best first; $SCRATCH is the first that exists. Caches,
# temporary files and conda environments go there, off a small /home quota.
SRV_SCRATCH_CANDIDATES="/scratch/$USER /work/$USER"

# Environment modules for interactive zsh, without versions: the site
# default, or the newest installed where the site defines none; `a|b` loads
# the first that exists. Batch jobs load their own in their scripts.
SRV_MODULES="anaconda3|miniconda3 cudatoolkit|cuda"

SRV_CONDA_ROOT=""            # a fixed conda install, for shells with no module system
SRV_CONDA_TREE=""            # or a directory of conda releases: the newest is used

# Defaults for the SLURM commands in shell/slurm.zsh (loc, cloc, sgpu, …);
# empty means SLURM's own default.
SRV_SLURM_ACCOUNT=""
SRV_SLURM_GPU_PARTITION="gpu"
SRV_SLURM_WATCH_PARTITIONS="gpu"

SRV_OMP_NUM_THREADS=""       # empty lets libraries size themselves to the node
SRV_EXTRA_PATH="$HOME/software/nvim-linux64/bin"   # prepended to PATH, lowest precedence first
