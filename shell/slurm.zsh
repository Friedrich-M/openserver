# shell/slurm.zsh — SLURM helpers.
#
# Defaults (account, partitions) come from hosts/<host>.sh, so the same
# functions work on every cluster. Every function takes overrides as
# arguments, so nothing here has to be edited for a one-off job.
#
# The whole file is a no-op on machines without SLURM.

command -v squeue >/dev/null 2>&1 || return 0

# Column layout shared by the queue views.
typeset -g _SQ_FMT="%.12i %.9P %.32j %.9u %.5C %.14b %.8m %.9T %.11M %.11l %20R"


# sq [user] : my queue, or someone else's
sq() {
    squeue -u "${1:-$USER}" -o "$_SQ_FMT"
}

# sqa [partition ...] : everything queued on a partition
sqa() {
    local partition="${1:-${SRV_SLURM_GPU_PARTITION:-}}"
    if [[ -z "$partition" ]]; then
        squeue -o "$_SQ_FMT"
    else
        squeue -p "$partition" -o "$_SQ_FMT"
    fi
}

# sgpu [partition ...] : running GPUs per user, busiest first (not `sg`,
# which is the system's run-as-another-group command)
sgpu() {
    local partition="${1:-${SRV_SLURM_WATCH_PARTITIONS:-${SRV_SLURM_GPU_PARTITION:-}}}"
    local -a filter
    [[ -n "$partition" ]] && filter=(-p "$partition")

    print -r -- "Running GPUs by user (partition: ${partition:-all})"
    printf '%-15s %s\n' USER GPUS
    print -r -- '----------------------'

    # %b is the "tres-per-node" field, e.g. gres:gpu:a100:4 — take the count
    # off the end of the gpu spec, defaulting to 0 when there is none.
    squeue "${filter[@]}" -h -t RUNNING -o '%u %b' |
        awk '{
            n = 0
            if (match($2, /gpu(:[^:]+)?:[0-9]+/)) {
                spec = substr($2, RSTART, RLENGTH)
                k = split(spec, parts, ":")
                n = parts[k] + 0
            }
            gpus[$1] += n
            total += n
        }
        END {
            for (u in gpus) printf "%-15s %d\n", u, gpus[u] | "sort -k2 -nr"
            close("sort -k2 -nr")
            print "----------------------"
            printf "%-15s %d\n", "TOTAL", total + 0
        }'
}

# loc [gpus=1] [hours=1] [partition] : interactive GPU allocation
#      12 CPUs and 64G of RAM per GPU, matching the usual node ratios.
loc() {
    local gpus="${1:-1}" hours="${2:-1}"
    local partition="${3:-${SRV_SLURM_GPU_PARTITION:-}}"
    local -a args=(--nodes=1 --ntasks=1)

    # Both flags are omitted on hosts that have no allocation or no named
    # GPU partition, so SLURM falls back to its own defaults.
    [[ -n "${SRV_SLURM_ACCOUNT:-}" ]] && args+=(--account="$SRV_SLURM_ACCOUNT")
    [[ -n "$partition" ]] && args+=(--partition="$partition")

    local walltime cpus mem
    printf -v walltime '%02d:00:00' "$hours"
    cpus=$(( gpus * 12 ))
    mem="$(( gpus * 64 ))G"

    print -r -- "salloc: ${partition:-<default>} | ${gpus} GPU | ${cpus} CPU | ${mem} RAM | ${walltime}"
    salloc "${args[@]}" \
           --gres=gpu:"$gpus" \
           --cpus-per-task="$cpus" \
           --mem="$mem" \
           --time="$walltime"
}

# cloc [cpus=12] [hours=10] : interactive CPU-only allocation, 4G per CPU
cloc() {
    local cpus="${1:-12}" hours="${2:-10}"
    local -a args=(--nodes=1 --ntasks=1)

    [[ -n "${SRV_SLURM_ACCOUNT:-}" ]] && args+=(--account="$SRV_SLURM_ACCOUNT")

    local walltime mem
    printf -v walltime '%02d:00:00' "$hours"
    mem="$(( cpus * 4 ))G"

    print -r -- "salloc: CPU only | ${cpus} CPU | ${mem} RAM | ${walltime}"
    salloc "${args[@]}" \
           --cpus-per-task="$cpus" \
           --mem="$mem" \
           --time="$walltime"
}

# sr <jobid> : open a shell inside a running job
sr() {
    srun --jobid="${1:?Usage: sr <jobid>}" --pty bash -l
}

# sj <jobid> : efficiency report for a finished or running job
sj() {
    jobstats "${1:?Usage: sj <jobid>}" 2>/dev/null \
        || seff "${1}" 2>/dev/null \
        || scontrol show job "${1}"
}
