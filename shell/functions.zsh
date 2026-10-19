# shell/functions.zsh — general-purpose helpers (non-SLURM).

# mkcd <dir> : create a directory and enter it
mkcd() {
    mkdir -p -- "${1:?Usage: mkcd <dir>}" && cd -- "$1"
}

# tb <logdir> [port] : tensorboard on a given (or random high) port
tb() {
    local logdir="${1:?Usage: tb <logdir> [port]}"
    local port="${2:-$(shuf -i 6000-9999 -n 1 2>/dev/null || echo 6006)}"
    echo "tensorboard -> http://$(hostname -s):$port"
    tensorboard --logdir "$logdir" --port "$port"
}


# ---------------------------------------------------------------------------
# This bundle
# ---------------------------------------------------------------------------

# srvinfo : what this shell actually resolved to on this machine
#
# The first thing to run after setting up a new server. Everything in this
# bundle degrades rather than failing, so this is how you see what degraded:
# which profile matched, which modules were missing, whether the tokens loaded.
srvinfo() {
    local ok="ok" no="—"

    print -r -- "openserver  : $(<"$SRV_DIR/VERSION" 2>/dev/null || print unknown)  ($SRV_DIR)"
    print -r -- "machine     : $SRV_HOST${SRV_SITE:+  [site: $SRV_SITE]}  [$SRV_OS]  ($(hostname -f 2>/dev/null || hostname))"
    if [[ "$SRV_HOST" == generic || "$SRV_PROFILE" != "$SRV_DIR/hosts/generic.sh" ]]; then
        print -r -- "profile     : ${SRV_PROFILE#$SRV_DIR/}"
    else
        print -r -- "profile     : no profile named $SRV_HOST — using ${SRV_PROFILE#$SRV_DIR/}"
    fi
    print -r -- "scratch     : $SCRATCH"
    print -r -- "tmpdir      : $TMPDIR"

    if [[ -n "$SRV_MODULES" ]] && ! command -v module >/dev/null 2>&1; then
        print -r -- "modules     : (no module command here)"
    elif [[ -n "$SRV_MODULES" ]]; then
        print -r -- "modules     : $SRV_MODULES"
        (( ${#SRV_MODULES_MISSING} )) &&
            print -r -- "              unavailable here: ${SRV_MODULES_MISSING[*]}"
    else
        print -r -- "modules     : (none for this profile)"
    fi

    if [[ -n "$SRV_SLURM_GPU_PARTITION" || -n "$SRV_SLURM_ACCOUNT" ]]; then
        print -r -- "slurm       : account=${SRV_SLURM_ACCOUNT:-(default)}" \
                    "gpu-partition=${SRV_SLURM_GPU_PARTITION:-(default)}"
    elif command -v squeue >/dev/null 2>&1; then
        print -r -- "slurm       : present, no defaults set for this profile"
    else
        print -r -- "slurm       : $no"
    fi

    # `command -v` on a shell function just echoes the name back, which reads
    # like a broken path; conda from a cluster module is always a function.
    local t where
    for t in conda python uv rclone claude codex git zsh tmux nvim; do
        where="$(command -v $t 2>/dev/null)"
        [[ -z "$where" ]] && where="$no"
        [[ "$where" == "$t" ]] && where="(shell function)"
        printf '%-12s: %s\n' "$t" "$where"
    done

    if [[ -r ~/.secrets.env ]]; then
        # The template setup.sh seeds has only empty exports; say so rather
        # than "loaded", which is what the first srvinfo after setup shows.
        if grep -h -E '^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=' ~/.secrets.env 2>/dev/null |
           sed -E 's/^[^=]*=//; s/[[:space:]]+#.*$//; s/^["'"'"']//; s/["'"'"']$//' | grep -q '[^[:space:]]'; then
            print -r -- "secrets     : loaded"
        else
            print -r -- "secrets     : template only — fill in ~/.secrets.env"
        fi
    elif [[ -r "$SRV_DIR/secrets/secrets.enc" ]]; then
        print -r -- "secrets     : locked in the bundle — run: srvunlock"
    else
        print -r -- "secrets     : MISSING — cp $SRV_DIR/secrets/secrets.env.example ~/.secrets.env"
    fi
    if [[ -r ~/.zshrc.local ]]; then
        print -r -- "local       : ~/.zshrc.local loaded"
    fi
}

# srvsync : bring this machine up to date with the bundle
#
# Pulls if there is a remote to pull from — a fresh machine set up from
# server.zip has a local repo and no remote, and that is not an error — then
# re-runs setup.sh, which is idempotent.
srvsync() {
    if ! git -C "$SRV_DIR" remote 2>/dev/null | grep -q .; then
        print -r -- "no git remote on $SRV_DIR — re-running setup only"
    elif ! git -C "$SRV_DIR" symbolic-ref -q HEAD >/dev/null; then
        # Installed at a release tag (bootstrap.sh --ref): stay on it.
        print -r -- "$SRV_DIR is pinned to $(git -C "$SRV_DIR" describe --tags 2>/dev/null || print a commit) — re-running setup only"
        print -r -- "a newer release: git -C $SRV_DIR fetch --tags && git -C $SRV_DIR checkout <tag>"
    else
        git -C "$SRV_DIR" pull --ff-only || return 1
    fi
    "$SRV_DIR/setup.sh" "$@" || return 1
    print -r -- "reload with: exec zsh"
}

# srvupdate : srvsync, and bring every tool this bundle installed to its latest
# release (Claude Code, Codex, uv, the CLI tools, Neovim, rclone, the zsh and
# tmux plugin clones). Tools a module or Homebrew provides are left to them.
srvupdate() { srvsync --update "$@" }

# srvpull : copy this machine's live configs back into the bundle
#
# The counterpart to setup.sh for the files it copies into $HOME (the git
# ignore, the powerlevel10k prompt): edited in place, they do not touch the
# bundle — this is how those edits get back in, before `srvsync` or
# `install/make-bundle.sh`. ~/.zshrc, ~/.bashrc, ~/.gitconfig and
# ~/.tmux.conf.local are yours, with the bundle's block in them; edit
# shell/ and config/ for the bundle.
srvpull() {
    local -A files=(
        [.p10k.zsh]=shell/p10k.zsh         [.config/git/ignore]=config/git/ignore
    )
    local home_file bundle_file
    for home_file bundle_file in ${(kv)files}; do
        [[ -f "$HOME/$home_file" ]] || continue
        if cmp -s "$HOME/$home_file" "$SRV_DIR/$bundle_file"; then
            print -r -- "  ok   $bundle_file"
        else
            cp "$HOME/$home_file" "$SRV_DIR/$bundle_file"
            print -r -- "  pull $bundle_file  <- ~/$home_file"
        fi
    done
    print -r -- "review with: git -C $SRV_DIR diff"
}

# srvlock / srvunlock : the API tokens, in and out of the bundle
#
# lock   ~/.secrets.env  -> ~/server/secrets/secrets.enc  (git-ignored: it travels
#        in a zip you build, or by scp)
# unlock the reverse, which is what setup.sh offers on a new machine.
srvlock()   { "$SRV_DIR/secrets/secrets.sh" lock   "$@" }
srvunlock() { "$SRV_DIR/secrets/secrets.sh" unlock "$@" }
