#!/usr/bin/env bash
# setup.sh — configure this machine from the bundle. The only entry point.
#
#   unzip -q server.zip && ./server/setup.sh
#
# Safe to run twice: it detects what this machine is, copies the configs that
# apply into $HOME (backing up anything it displaces), installs the tools that
# are missing, and deletes the parts of the bundle that this machine will
# never use.
#
# Options
#   --dry-run          print every action, change nothing
#   --config-only      copy configs, install nothing
#   --update           also bring every installed tool to its latest release
#   --with=a,b         also install these optional tools: rclone, uv, claude, codex
#   --tools=a,b,c      run only these installers from tools/
#   --conda            install conda without asking
#   --no-conda         do not install conda and do not ask
#   --gdrive           configure the gdrive rclone remote without asking
#   --no-gdrive        do not configure it and do not ask
#   --github           set up git identity and GitHub access without asking
#   --no-github        do not set them up and do not ask
#   --keep-all         never prune; keep every host profile
#   --prune            prune even when the rules below would skip it
#   --secrets          unlock the bundled encrypted secrets without asking
#   --no-secrets       do not try to unlock the bundled encrypted secrets
#   --yes              accept every prompt (for unattended runs)
#   --here             configure from where the bundle is, do not move it
#   --version          print OpenServer's version (the VERSION file)

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/server"

DRY_RUN=0 CONFIG_ONLY=0 UPDATE=0 PRUNE=1 PRUNE_FORCED=0 MOVE=1 ASSUME_YES=0
CONDA_CHOICE=ask
GDRIVE_CHOICE=ask
GITHUB_CHOICE=ask
SECRETS_CHOICE=ask
TOOLS_REQUESTED=""
WITH_REQUESTED=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=1 ;;
        --config-only) CONFIG_ONLY=1 ;;
        --update)      UPDATE=1 ;;
        --tools=*)     TOOLS_REQUESTED="${arg#*=}" ;;
        --with=*)      WITH_REQUESTED="${arg#*=}" ;;
        --conda)       CONDA_CHOICE=yes ;;
        --no-conda)    CONDA_CHOICE=no ;;
        --gdrive)      GDRIVE_CHOICE=yes ;;
        --no-gdrive)   GDRIVE_CHOICE=no ;;
        --github)      GITHUB_CHOICE=yes ;;
        --no-github)   GITHUB_CHOICE=no ;;
        --keep-all)    PRUNE=0 ;;
        --prune)       PRUNE=1; PRUNE_FORCED=1 ;;
        --no-secrets)  SECRETS_CHOICE=no ;;
        --secrets)     SECRETS_CHOICE=yes ;;
        --yes|-y)      ASSUME_YES=1 ;;
        --here)        MOVE=0 ;;
        # The comment block above, up to the first non-comment line.
        -h|--help)     sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
        --version)     printf 'OpenServer %s\n' "$(cat "$(dirname "$0")/VERSION" 2>/dev/null || echo unknown)"; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done


# ---------------------------------------------------------------------------
# Move the bundle to ~/server
# ---------------------------------------------------------------------------
# Unzipping in $HOME already puts it there; unzipping anywhere else, or
# cloning under a different name, does not. Everything downstream — the
# $SRV_DIR in the shell configs, srvsync — expects the one path.
if (( MOVE )) && ! [[ "$SRC" -ef "$DEST" ]]; then
    if [[ -e "$DEST" ]]; then
        echo "$DEST already exists and is not this bundle." >&2
        echo "Move it aside, or re-run with --here to configure from $SRC." >&2
        exit 1
    fi
    if (( DRY_RUN )); then
        echo "would move $SRC -> $DEST"
    else
        mv "$SRC" "$DEST"
        exec bash "$DEST/setup.sh" "$@"     # re-exec from the new location
    fi
fi

export SRV_DIR="${SRC}"
if (( MOVE )) && [[ -d "$DEST" ]]; then export SRV_DIR="$DEST"; fi
export SRV_DRY_RUN="$DRY_RUN"
# Installers skip a tool that is present; with --update they fetch its latest
# release instead (each tools/<x>.sh reads this).
export SRV_UPDATE="$UPDATE"
SRV_BACKUP_DIR="$HOME/.server-backup/$(date +%Y%m%d-%H%M%S)"
export SRV_BACKUP_DIR

# shellcheck source=lib/common.sh
. "$SRV_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
. "$SRV_DIR/lib/config.sh"

# ask <question> [default:y|n] : prompt, or fall back to the default when
# there is no terminal to prompt at (a piped install, CI, a provisioning run).
ask() {
    local question="$1" default="${2:-n}" reply
    if (( ASSUME_YES )); then return 0; fi
    if [[ ! -t 0 ]]; then
        say "no terminal — assuming '$default' for: $question"
        [[ "$default" == y ]]
        return
    fi
    read -r -p "   $question [$( [[ $default == y ]] && echo 'Y/n' || echo 'y/N' )] " reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}


# ---------------------------------------------------------------------------
step "What this machine is"
# ---------------------------------------------------------------------------
# lib/detect.sh is the single source of truth: it picks the profile whose
# header claims this hostname and sources it, so every SRV_* value the steps
# below read (SRV_SITE) comes from the profile, hosts/local/ or hosts/.
# shellcheck source=lib/detect.sh
. "$SRV_DIR/lib/detect.sh"

HAS_SLURM=0; have sbatch && HAS_SLURM=1
HAS_MODULES=0; [[ -d /etc/modulefiles || -d /usr/share/Modules || -n "${MODULEPATH:-}" ]] && HAS_MODULES=1

say "version  : OpenServer $(cat "$SRV_DIR/VERSION" 2>/dev/null || echo unknown)"
say "hostname : $(hostname -f 2>/dev/null || hostname)"
say "profile  : ${SRV_PROFILE#"$SRV_DIR"/}${SRV_SITE:+  (site: $SRV_SITE)}  on $SRV_OS"
say "slurm    : $( ((HAS_SLURM)) && echo yes || echo no )   modules: $( ((HAS_MODULES)) && echo yes || echo no )"

if [[ "$SRV_HOST" != generic && "$SRV_PROFILE" == "$SRV_DIR/hosts/generic.sh" ]]; then
    warn "no profile named $SRV_HOST in hosts/local/ or hosts/ — falling back to hosts/generic.sh"
    warn "add a profile for this machine if you will use it regularly"
elif [[ "$SRV_HOST" == generic ]]; then
    say "no profile claims this hostname — copy hosts/example-cluster.sh to hosts/local/<name>.sh to add one"
fi


# ---------------------------------------------------------------------------
step "Your settings"
# ---------------------------------------------------------------------------
# server.json (lib/config.sh): git identity, the GitHub protocol, the agent
# models, and the answers below. A flag on the command line still wins over
# the file; the file wins over a question.
if srv_config_render; then
    say "ok   $(basename "$SRV_CONFIG") -> $(basename "$SRV_CONFIG_RENDERED")"
    [[ "$CONDA_CHOICE"   == ask ]] && CONDA_CHOICE="$(cfg setup.conda ask)"
    [[ "$GDRIVE_CHOICE"  == ask ]] && GDRIVE_CHOICE="$(cfg setup.gdrive ask)"
    [[ "$GITHUB_CHOICE"  == ask ]] && GITHUB_CHOICE="$(cfg setup.github ask)"
    [[ "$SECRETS_CHOICE" == ask ]] && SECRETS_CHOICE="$(cfg setup.secrets ask)"
    [[ -z "$TOOLS_REQUESTED" ]] && TOOLS_REQUESTED="$(cfg setup.tools)"
    [[ -z "$WITH_REQUESTED" ]] && WITH_REQUESTED="$(cfg setup.with)"
else
    say "none — copy server.example.json to server.json to answer the questions once,"
    say "or bring yours: scp <other-host>:~/server/server.json $SRV_DIR/"
fi


# ---------------------------------------------------------------------------
step "Configuration files"
# ---------------------------------------------------------------------------
# remove_old_copy <file> <first line of the bundle's old copy> : earlier
# versions of this bundle copied the whole file in. Move that copy aside, so
# the file holds the bundle's block alone.
remove_old_copy() {
    [[ -f "$HOME/$1" && "$(head -n 1 "$HOME/$1")" == "$2" ]] || return 0
    backup "$HOME/$1"
}

# Where the blocks below find the bundle. At ~/server the block names it as
# ${SRV_DIR:-$HOME/server}, the same text on every machine; anywhere else
# (--here) the block carries the real path, or a new shell would look in
# ~/server and find nothing.
if [[ "$SRV_DIR" -ef "$HOME/server" ]]; then
    # shellcheck disable=SC2016  # expanded by the shell that reads the block
    SRV_REF='${SRV_DIR:-$HOME/server}'; SRV_SET=''
    # shellcheck disable=SC2088  # git expands ~ in an include path itself
    GIT_REF='~/server'
else
    SRV_REF="$SRV_DIR"; SRV_SET="export SRV_DIR=\"$SRV_DIR\"; "
    GIT_REF="$SRV_DIR"
fi

# git: your ~/.gitconfig keeps its lines; the bundle's settings come in by an
# include at its top, so anything you set below it (or `gh auth setup-git`
# writes) wins. Your identity lives in ~/.gitconfig.local (tools/github.sh).
remove_old_copy .gitconfig "# git/gitconfig — synced git configuration."
ensure_block --top .gitconfig "[include]
	path = $GIT_REF/config/git/gitconfig"
deploy config/git/ignore           .config/git/ignore
# Seeded once: `p10k configure` rewrites it, and a prompt you have stays.
copy_once shell/p10k.zsh    .p10k.zsh

# The rest of shell/ (env.sh, bashrc, zshrc, aliases, functions, slurm) is
# sourced from $SRV_DIR at startup rather than copied; the startup files that
# source it stay yours (the zsh, tmux and bash steps below).


# ---------------------------------------------------------------------------
step "zsh config"
# ---------------------------------------------------------------------------
# Like bash below: your ~/.zshrc keeps every line, and a block at its end
# sources shell/zshrc, which leaves the prompt, plugins and history to a
# setup of your own when it finds one (oh-my-zsh or powerlevel10k loaded).
remove_old_copy .zshrc "# shell/zshrc — interactive zsh, identical on every server."
ensure_block .zshrc \
    "${SRV_SET}[[ -r \"$SRV_REF/shell/zshrc\" ]] && source \"$SRV_REF/shell/zshrc\""


# ---------------------------------------------------------------------------
step "tmux config"
# ---------------------------------------------------------------------------
# ~/.tmux.conf is gpakosz/.tmux, vendored and replaced whole: it is upstream
# code, not settings. Settings live in ~/.tmux.conf.local, which keeps your
# lines and gets the bundle's as a block at its end. A ~/.tmux.conf that is
# not gpakosz/.tmux is yours, and both files are left alone.
if [[ ! -e "$HOME/.tmux.conf" ]] || grep -q 'gpakosz' "$HOME/.tmux.conf"; then
    deploy config/tmux/tmux.conf .tmux.conf
    remove_old_copy .tmux.conf.local "# tmux/tmux.conf.local — the overrides on top of the vendored gpakosz .tmux."
    ensure_block .tmux.conf.local "$(cat "$SRV_DIR/config/tmux/tmux.conf.local")"
else
    say "keep .tmux.conf (yours, not gpakosz/.tmux); for the bundle's mouse and copy settings add to it:"
    say "  source-file $SRV_DIR/config/tmux/tmux.conf.local"
fi


# ---------------------------------------------------------------------------
step "bash config"
# ---------------------------------------------------------------------------
# bash keeps your own startup files: ~/.bashrc gets a marked block at its
# end that sources shell/bashrc (the environment, then the hand-over to zsh),
# and the login file only has to read ~/.bashrc. Nothing else in either file
# changes (lib/common.sh, ensure_block).

# restore_original <file> <first line of the bundle's old copy> : earlier
# versions of this bundle replaced the file outright. Put back the newest
# backup that is not that copy, so your own lines come back.
restore_original() {
    local file="$1" marker="$2" b original=""
    [[ -f "$HOME/$file" && "$(head -n 1 "$HOME/$file")" == "$marker" ]] || return 0
    for b in "$HOME"/.server-backup/*/"$file"; do      # timestamped: oldest first
        [[ -f "$b" && "$(head -n 1 "$b")" != "$marker" ]] && original="$b"
    done
    if (( DRY_RUN )); then
        say "would restore your own ~/$file${original:+ from ${original#"$HOME"/}}"
        return 0
    fi
    backup "$HOME/$file"
    if [[ -n "$original" ]]; then
        cp -p "$original" "$HOME/$file"
        say "restored your own ~/$file from ${original#"$HOME"/}"
    else
        say "removed the bundle's old ~/$file (there was no earlier one to restore)"
    fi
}
restore_original .bashrc       "# shell/bashrc — bash configuration, identical on every server."
restore_original .bash_profile "# shell/bash_profile — login bash."

# Two blocks. At the top, the environment alone: many ~/.bashrc files
# (Ubuntu's among them) return early for a non-interactive shell, and
# `ssh host cmd`, scp, rsync and `srun` still need $SCRATCH, PATH and the
# tokens. At the end, the rest — last, because the hand-over to zsh ends an
# interactive bash.
# A ~/.bashrc made here holds the site's defaults (on RHEL they define
# `module`) between the two blocks.
if [[ ! -e "$HOME/.bashrc" ]] && (( ! DRY_RUN )); then
    printf '%s\n' '[ -f /etc/bashrc ] && . /etc/bashrc' > "$HOME/.bashrc"
fi
ensure_block --top --name server-env .bashrc \
    "${SRV_SET}[ -r \"$SRV_REF/shell/env.sh\" ] && . \"$SRV_REF/shell/env.sh\""
ensure_block .bashrc \
    "${SRV_SET}[ -r \"$SRV_REF/shell/bashrc\" ] && . \"$SRV_REF/shell/bashrc\""

# A login bash reads the first of these that exists and nothing else, so
# that one has to read ~/.bashrc — most already do (Ubuntu's ~/.profile, a
# cluster's ~/.bash_profile). Creating a ~/.bash_profile where ~/.profile is
# the login file would hide ~/.profile, so a new one is made only when none
# of the three exists.
login_file=""
for f in .bash_profile .bash_login .profile; do
    if [[ -f "$HOME/$f" ]]; then login_file="$f"; break; fi
done
if [[ -n "$login_file" ]] && grep -v '^[[:space:]]*#' "$HOME/$login_file" | grep -q '\.bashrc'; then
    say "ok   $login_file (reads ~/.bashrc)"
else
    ensure_block "${login_file:-.bash_profile}" \
        '[ -n "${BASH_VERSION:-}" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"'
fi


# ---------------------------------------------------------------------------
step "Secrets"
# ---------------------------------------------------------------------------
# ~/.secrets.env holds every API token. It reaches a new machine one of three
# ways, tried in this order: it is already here; the bundle carries an
# encrypted copy and you know the passphrase; or you copy it across yourself.
if [[ -e "$HOME/.secrets.env" ]]; then
    run chmod 600 "$HOME/.secrets.env"
    say "ok   ~/.secrets.env"

elif [[ -r "$SRV_DIR/secrets/secrets.enc" && "$SECRETS_CHOICE" != no ]]; then
    say "this bundle carries encrypted credentials"
    grep -E '^# (locked on|holds)' "$SRV_DIR/secrets/secrets.enc" | sed 's/^# /   /' || true
    if (( DRY_RUN )); then
        say "would prompt for the passphrase and unlock it"
    elif [[ "$SECRETS_CHOICE" == yes ]] || [[ -n "${SRV_SECRETS_PASSPHRASE:-}" ]] \
         || ask "Unlock it now?" y; then
        "$SRV_DIR/secrets/secrets.sh" unlock || {
            warn "continuing without tokens — unlock later with: srvunlock"
        }
    else
        say "skipped — unlock later with: srvunlock"
    fi

else
    run cp "$SRV_DIR/secrets/secrets.env.example" "$HOME/.secrets.env"
    run chmod 600 "$HOME/.secrets.env"
    say "$( ((DRY_RUN)) && echo 'would create' || echo created ) ~/.secrets.env from the template — put the real tokens in it, or:"
    say "  scp <other-host>:~/.secrets.env ~/.secrets.env && chmod 600 ~/.secrets.env"
fi


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------
# Each installer is standalone and idempotent: it checks whether its tool is
# already here, installs it if not, and degrades to a warning when offline.
run_tool() {
    local name="$1"; shift
    local script="$SRV_DIR/tools/$name.sh"
    [[ -x "$script" ]] || { warn "no tools/$name.sh in this bundle"; return 0; }
    step "$name"
    "$script" "$@" || warn "tools/$name.sh did not finish cleanly — continuing"
}

if (( CONFIG_ONLY )); then
    step "Tools"
    say "skipped (--config-only)"
else
    # Lists come as a,b from a flag and as "a b" from server.json; a * in one
    # is a name, not a glob. --tools runs exactly its list, and the questions
    # below then only what a flag or server.json answered yes.
    set -f
    QUESTIONS=1
    if [[ -n "$TOOLS_REQUESTED" ]]; then
        QUESTIONS=0
        for t in ${TOOLS_REQUESTED//,/ }; do run_tool "$t"; done
    else
        # Core: what makes any server usable. Optional: what only some people
        # want everywhere, installed when named (--with, setup.with).
        for t in zsh tmux nvim cli; do run_tool "$t"; done
        with=" ${WITH_REQUESTED//,/ } " skipped=""
        optional=" rclone uv claude codex "
        for t in ${WITH_REQUESTED//,/ }; do
            if [[ "$optional" != *" $t "* ]]; then
                warn "--with: no optional tool '$t' (rclone, uv, claude, codex; the core always installs)"
            fi
        done
        for t in rclone uv claude codex; do
            if [[ "$with" == *" $t "* ]]; then run_tool "$t"; else skipped="$skipped $t"; fi
        done
        if [[ -n "$skipped" ]]; then
            step "Optional tools"
            say "not installed:$skipped — add them with --with=$(echo $skipped | tr ' ' ,) or setup.with in server.json"
        fi
    fi
    set +f

    # ---------------------------------------------------------------
    # conda — always a question, never a default
    # ---------------------------------------------------------------
    # It is several GB, and most machines already have it: on the
    # clusters it comes from a module (SRV_MODULES), elsewhere
    # there is often a system or Homebrew copy, and plenty of projects
    # use uv instead.
    step "conda"
    if (( ! QUESTIONS )) && [[ "$CONDA_CHOICE" != yes ]]; then
        say "skipped (--tools)"
    elif have conda; then
        say "ok   conda already available ($(conda --version 2>/dev/null || echo 'shell function'))"
        if [[ "$CONDA_CHOICE" != no ]]; then
            "$SRV_DIR/tools/conda.sh" condarc || warn "tools/conda.sh did not finish cleanly — continuing"
        fi
    elif [[ "$CONDA_CHOICE" == no ]]; then
        say "skipped (--no-conda)"
    elif [[ "$CONDA_CHOICE" == yes ]]; then
        "$SRV_DIR/tools/conda.sh" install || true
    else
        say "conda is not installed here."
        (( HAS_MODULES )) && say "this machine has environment modules — 'module load anaconda3' may be all you need"
        if ask "Download and install conda (Miniforge, ~500 MB) now?" n; then
            "$SRV_DIR/tools/conda.sh" install || true
            CONDA_CHOICE=yes
        else
            say "skipped — run '$SRV_DIR/tools/conda.sh' later if you change your mind"
            CONDA_CHOICE=no
        fi
    fi

    # ---------------------------------------------------------------
    # Google Drive — a question, like conda
    # ---------------------------------------------------------------
    # The remote needs a Google consent in a browser (or a token pasted
    # from a laptop, on a cluster), so it is never set up unasked. A
    # remote restored from the encrypted bundle is already there, and
    # then there is nothing to ask.
    step "Google Drive (rclone)"
    if (( ! QUESTIONS )) && [[ "$GDRIVE_CHOICE" != yes ]]; then
        say "skipped (--tools)"
    elif "$SRV_DIR/tools/rclone.sh" status; then
        say "ok   gdrive: remote is configured"
    elif [[ "$GDRIVE_CHOICE" == no ]]; then
        say "skipped (--no-gdrive)"
    elif [[ "$GDRIVE_CHOICE" == yes ]] || ask "Configure the gdrive rclone remote (Google Drive) now?" n; then
        "$SRV_DIR/tools/rclone.sh" gdrive || warn "tools/rclone.sh did not finish cleanly — continuing"
    else
        say "skipped — run '$SRV_DIR/tools/rclone.sh gdrive' later"
    fi

    # ---------------------------------------------------------------
    # GitHub — a question, like conda
    # ---------------------------------------------------------------
    # Identity, sign-in and a per-machine SSH key. Signing in opens a
    # browser or needs a one-time code typed somewhere, so it is never
    # done unasked; a machine already signed in has nothing to answer.
    step "GitHub"
    # --no-github touches nothing, not even the status probe: `gh auth
    # status` reads the macOS Keychain.
    if [[ "$GITHUB_CHOICE" == no ]]; then
        say "skipped (--no-github)"
    elif (( ! QUESTIONS )) && [[ "$GITHUB_CHOICE" != yes ]]; then
        say "skipped (--tools)"
    elif "$SRV_DIR/tools/github.sh" --status --quiet; then
        say "ok   git identity and GitHub access are configured"
    elif [[ "$GITHUB_CHOICE" == yes ]] || ask "Set up git identity and GitHub access (sign-in, SSH key) now?" y; then
        "$SRV_DIR/tools/github.sh" || warn "tools/github.sh did not finish cleanly — continuing"
    else
        say "skipped — run '$SRV_DIR/tools/github.sh' later"
    fi
fi


# ---------------------------------------------------------------------------
step "Pruning what this machine will not use"
# ---------------------------------------------------------------------------
# The bundle ships every cluster profile and every helper because it has to
# work anywhere. Once it knows where it landed, the rest is dead weight and
# only makes the directory harder to read. Nothing here is unrecoverable: the
# full bundle is one `install/make-bundle.sh` away on any other machine.
PRUNED=()

drop() {
    local target="$SRV_DIR/$1" why="$2"
    [[ -e "$target" ]] || return 0
    if (( DRY_RUN )); then
        say "would drop $1 ($why)"
    else
        rm -rf "$target"
        say "drop $1 ($why)"
    fi
    PRUNED+=("$1")
}

# Pruning is a first-install action, not something to repeat on every run.
# Two rules keep it from doing damage later:
#
#   Already done here. srvsync re-runs this script, and there is nothing left
#   to prune the second time — but re-running would also delete any profile a
#   `git pull` had just brought back.
#
#   This bundle has a git remote. Then it is the shared copy that every other
#   machine pulls from, and the other clusters' profiles have to survive. A
#   local prune commit would also diverge from the remote and break the next
#   `git pull --ff-only`.
#
# --prune overrides both.
SRV_STATE="$SRV_DIR/.srv-state"
FIRST_RUN=1; [[ -f "$SRV_STATE" ]] && FIRST_RUN=0
# A repository of its own: git's answer, not a .git directory (a worktree or a
# submodule has a .git file), and only when its top is this bundle (a zip
# unpacked inside some other repository is not one).
IS_REPO=0 HAS_REMOTE=0
if have git && [[ "$(git -C "$SRV_DIR" rev-parse --show-toplevel 2>/dev/null)" -ef "$SRV_DIR" ]]; then
    IS_REPO=1
    git -C "$SRV_DIR" remote 2>/dev/null | grep -q . && HAS_REMOTE=1
fi

if (( ! PRUNE )); then
    say "skipped (--keep-all)"
elif (( ! PRUNE_FORCED )) && (( ! FIRST_RUN )); then
    say "skipped — already pruned on this machine (force with --prune)"
elif (( ! PRUNE_FORCED )) && (( HAS_REMOTE )); then
    say "skipped — this bundle has a git remote, so it stays complete for the"
    say "other machines that pull from it (force with --prune)"
else
    # Host profiles for the other machines. generic.sh stays as the fallback
    # lib/detect.sh uses if this profile is ever missing, and the site's
    # fallback profile (hosts/$SRV_SITE.sh) stays with its site.
    for profile in "$SRV_DIR"/hosts/*.sh; do
        base="$(basename "$profile" .sh)"
        case "$base" in
            generic|"$SRV_HOST"|"${SRV_SITE:-generic}") continue ;;
            *.local) continue ;;      # yours and git-ignored: never removed
        esac
        drop "hosts/$base.sh" "not this machine"
    done

    # SLURM, on a machine with no scheduler.
    if (( ! HAS_SLURM )); then
        drop shell/slurm.zsh "no SLURM here"
    fi

    # conda templates, where conda was declined and is not installed.
    if [[ "$CONDA_CHOICE" == no ]] && ! have conda; then
        drop config/conda "conda declined"
    fi

    (( ${#PRUNED[@]} )) || say "nothing to prune — every file in this bundle applies here"
fi

# The zip this machine was set up from. Keeping it means the next person to
# look in $HOME finds a stale copy of a bundle that has since been pruned.
# `unzip -q server.zip` leaves it next to the bundle, which is usually $HOME
# but not always; both are the same file when it is.
#
# First install only: make-bundle.sh writes ~/server.zip too, and a later
# srvsync on the machine that builds the bundle must not delete what it has
# just built. And only once the bundle is at ~/server: configured in place
# with --here, a zip beside it may be the source it was unpacked from — or
# the copy a website serves.
if (( FIRST_RUN )) && [[ "$SRV_DIR" == "$DEST" ]]; then
    seen_zip=""
    for zip in "$HOME/server.zip" "$(dirname "$SRV_DIR")/server.zip"; do
        [[ -f "$zip" ]] || continue
        zip="$(cd "$(dirname "$zip")" && pwd)/server.zip"
        [[ "$zip" == "$seen_zip" ]] && continue
        seen_zip="$zip"
        if (( DRY_RUN )); then
            say "would remove $zip"
        else
            rm -f "$zip"; say "removed $zip"
        fi
    done
fi


# Remember that setup has completed here, so the prune rules above can tell a
# first install from a later srvsync.
if (( ! DRY_RUN )); then
    { printf 'first_setup=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'host=%s\n' "$SRV_HOST"
      printf 'pruned=%s\n' "$( (( PRUNE )) && echo yes || echo no )"
    } > "$SRV_STATE" 2>/dev/null || true
fi


# ---------------------------------------------------------------------------
step "Version control"
# ---------------------------------------------------------------------------
# The pre-push hook is the git-side counterpart to make-bundle.sh's check: it
# is the other route by which a weak-marked credential blob could reach the
# internet, and the easier one to take by accident.
install_hook() {
    local src="$SRV_DIR/config/git/hooks/pre-push" dst
    [[ -f "$src" ]] && (( IS_REPO )) || return 0
    dst="$(git -C "$SRV_DIR" rev-parse --git-path hooks)/pre-push"
    [[ "$dst" = /* ]] || dst="$SRV_DIR/$dst"
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        say "ok   pre-push hook"
    elif (( DRY_RUN )); then
        say "would install the pre-push hook"
    else
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst" && chmod +x "$dst"
        say "installed the pre-push hook (blocks pushing a weak credential blob)"
    fi
}

# A local repo, so the pruning above and every later edit is recoverable even
# on a machine that never gets a remote. A clone with a remote is left alone:
# whatever is uncommitted there is someone's work in progress, and a local
# commit would also break the next `git pull --ff-only` (srvsync).
# srv_commit <message> : commit everything here. A machine with no git
# identity yet (tools/github.sh skipped or declined) commits as "server setup".
srv_commit() {
    local -a who=()
    git -C "$SRV_DIR" config user.email >/dev/null 2>&1 ||
        who=(-c "user.name=server setup" -c "user.email=setup@$(hostname -s)")
    git -C "$SRV_DIR" add -A &&
        git ${who[@]+"${who[@]}"} -C "$SRV_DIR" commit -q -m "$1"
}

DIRTY=0
(( IS_REPO )) && [[ -n "$(git -C "$SRV_DIR" status --porcelain)" ]] && DIRTY=1
if ! have git; then
    say "git is not installed — skipping"
elif (( IS_REPO && HAS_REMOTE )); then
    if (( DIRTY )); then
        say "uncommitted changes in $SRV_DIR left as they are (it has a remote)"
    else
        say "ok   clean"
    fi
elif (( DRY_RUN )); then
    say "would commit any changes in $SRV_DIR"
elif (( IS_REPO )); then
    if (( ! DIRTY )); then
        say "ok   clean"
    elif srv_commit "setup on $(hostname -s): profile $SRV_HOST"; then
        say "committed this machine's changes"
    else
        warn "could not commit the changes in $SRV_DIR — left uncommitted"
    fi
else
    if git -C "$SRV_DIR" init -q && IS_REPO=1 &&
       srv_commit "Import bundle on $(hostname -s) (profile: $SRV_HOST)"; then
        say "initialised a repo — add a remote to sync with your other machines:"
        say "  git -C ~/server remote add origin <url> && git -C ~/server push -u origin main"
    else
        warn "could not record the bundle in a local git repo — continuing"
    fi
fi
install_hook


# ---------------------------------------------------------------------------
step "Done"
# ---------------------------------------------------------------------------
if (( DRY_RUN )); then
    say "dry run — nothing was changed"
else
    say "bundle  : $SRV_DIR"
    say "profile : $SRV_HOST${SRV_SITE:+ (site: $SRV_SITE)} on $SRV_OS"
    [[ -d "$SRV_BACKUP_DIR" ]] && say "replaced files backed up in $SRV_BACKUP_DIR"
    printf '\n   Start a new shell and check what resolved here:\n'
    printf '     exec zsh && srvinfo\n\n'
fi
