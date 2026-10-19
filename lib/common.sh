# lib/common.sh — helpers shared by setup.sh, secrets.sh and everything in tools/.
#
# Sourced, never executed. Defines the output helpers, the copy/backup logic
# and the guards that let setup.sh and every tools/*.sh script be re-run
# safely.

# Set by setup.sh from its flags; defaults let a tools/*.sh script be run
# on its own (`./tools/claude.sh`) without setup.sh around it.
: "${SRV_DIR:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"
: "${SRV_DRY_RUN:=0}"
: "${SRV_BACKUP_DIR:="$HOME/.server-backup/$(date +%Y%m%d-%H%M%S)"}"

# Where this bundle installs its tools. A shell that has not sourced
# shell/env.sh — the first run on a fresh machine, a cron job — does not have
# them on PATH, and every `have` check below would then install them again.
for _srv_bin in "$HOME/software/nvim-linux64/bin" "$HOME/.local/bin"; do
    case ":$PATH:" in
        *":$_srv_bin:"*) ;;
        *) if [ -d "$_srv_bin" ]; then PATH="$_srv_bin:$PATH"; fi ;;
    esac
done
unset _srv_bin
export PATH


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
step() { printf '\n== %s\n' "$*"; }
say()  { printf '   %s\n' "$*"; }
warn() { printf '   ! %s\n' "$*" >&2; }

# run <cmd...> : execute, or just describe it under --dry-run
run() {
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would: $*"
    else
        "$@"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# updating : true under `setup.sh --update`, when a present tool is refreshed
# to its latest release instead of being left alone.
updating() { [ "${SRV_UPDATE:-0}" = 1 ]; }

# git_refresh <dir> <label> : fast-forward a clone made by clone_if_missing
git_refresh() {
    [ -d "$1/.git" ] || return 0
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would update $2"
    elif git -C "$1" pull -q --ff-only >/dev/null 2>&1; then
        say "updated $2"
    else
        warn "could not update $2 (offline, or local changes) — left as is"
    fi
}


# ---------------------------------------------------------------------------
# Backing up
# ---------------------------------------------------------------------------
# Nothing in this repo ever deletes a file the user put there: whatever is in
# the way is moved under ~/.server-backup/<timestamp>/ first.
# backup_path <path relative to $HOME> : where a backup of it goes this run.
# Never an existing file: one run can back the same file up twice (a
# migration, then a block), and the first copy may be the only original.
backup_path() {
    local target="$SRV_BACKUP_DIR/$1" n=1
    while [ -e "$target" ] || [ -L "$target" ]; do
        target="$SRV_BACKUP_DIR/$1.$n"; n=$((n + 1))
    done
    printf '%s\n' "$target"
}

backup() {
    local dst="$1" rel="${1#"$HOME"/}" target
    [ -e "$dst" ] || [ -L "$dst" ] || return 0
    target="$(backup_path "$rel")"
    run mkdir -p "$(dirname "$target")"
    run mv "$dst" "$target"
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would back up $rel"
    else
        say "back $rel -> ~/${target#"$HOME"/}"
    fi
}


# ---------------------------------------------------------------------------
# Deploying
# ---------------------------------------------------------------------------
# Files are COPIED out of the bundle into $HOME, never symlinked. That keeps
# $HOME self-contained: nothing breaks if this directory is moved, renamed or
# deleted, and a config still works inside a container or on a node that does
# not mount the same filesystem.
#
# The bundle is the source of truth, so a copy that has drifted is backed up
# and replaced. Push local edits the other way with `srvpull` before syncing.

# deploy <path relative to this bundle> <path relative to $HOME>
deploy() {
    local src="$SRV_DIR/$1" dst="$HOME/$2"

    if [ ! -e "$src" ]; then
        say "skip $2 (no $1 in this bundle)"
        return 0
    fi
    # Already identical: leave it alone rather than churn a backup on every run.
    if [ ! -L "$dst" ] && [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        say "ok   $2"; return 0
    fi

    backup "$dst"
    run mkdir -p "$(dirname "$dst")"
    run cp "$src" "$dst"
    if [ "$SRV_DRY_RUN" = 1 ]; then say "would copy $2"; else say "copy $2"; fi
}

# ensure_block [--top] [--name <name>] <path relative to $HOME> <lines> [<lines for a new file>]
#
# For files that are the user's (~/.bashrc, ~/.zshrc, ~/.gitconfig): the
# bundle's lines go in one marked block, at the end (or with --top, at the
# start), and every other line of the file is left as it is. A block that is
# current and in place is left alone; one that is out of date, or has had
# lines added on its far side (a conda init block, say), is rewritten in
# place. Only a complete block — its begin marker followed by its end marker
# — is ever replaced: a lone marker is one of the user's lines. The file is
# copied into the backup directory first, never moved. --name keeps two
# blocks in one file apart. Deleting a block, markers included, opts out.
srv_block_begin() { printf '# >>> %s (added by ~/server/setup.sh; delete this block to opt out) >>>' "$1"; }
srv_block_end()   { printf '# <<< %s <<<' "$1"; }
SRV_BLOCK_BEGIN="$(srv_block_begin server)"
SRV_BLOCK_END="$(srv_block_end server)"
ensure_block() {
    local at=end name=server
    while [ $# -gt 0 ]; do
        case "$1" in
            --top)  at=top; shift ;;
            --name) name="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    local dst="$HOME/$1" body="$2" header="${3:-}" begin end want state target
    begin="$(srv_block_begin "$name")"; end="$(srv_block_end "$name")"
    want="$begin
$body
$end"
    # The block goes to awk through the environment: BSD awk refuses a -v
    # value with a newline in it. Line endings are compared without a CR.
    if [ -f "$dst" ]; then
        state="$(SRV_WANT="$want" awk -v b="$begin" -v e="$end" -v at="$at" '
            { sub(/\r$/, ""); line[++n] = $0 }
            END {
                for (i = 1; i <= n; i++) {
                    if (line[i] != b) continue
                    for (j = i + 1; j <= n && line[j] != b && line[j] != e; j++) ;
                    if (j <= n && line[j] == e) { blocks++; first = i; last = j; i = j }
                }
                if (blocks != 1) { print "stale"; exit }
                text = line[first]
                for (k = first + 1; k <= last; k++) text = text "\n" line[k]
                if (text != ENVIRON["SRV_WANT"]) { print "stale"; exit }
                if (at == "top") { print (first == 1) ? "current" : "stale"; exit }
                for (k = last + 1; k <= n; k++) if (line[k] ~ /[^[:space:]]/) { print "stale"; exit }
                print "current"
            }' "$dst")"
        if [ "$state" = current ]; then
            say "ok   $1"
            return 0
        fi
    fi
    if [ "$SRV_DRY_RUN" = 1 ]; then
        say "would add the $name block to ~/$1"
        return 0
    fi
    if [ -f "$dst" ]; then
        target="$(backup_path "$1")"
        if ! { mkdir -p "$(dirname "$target")" && cp -p "$dst" "$target"; }; then
            warn "could not back up ~/$1 — left it unchanged"
            return 0
        fi
        # The user's lines without complete blocks of this name, trimmed of
        # blank lines on the block's side; then the block on that side.
        # Written through the existing file, so its mode and any symlink to it
        # stay as they were.
        if ! SRV_WANT="$want" awk -v b="$begin" -v e="$end" -v at="$at" '
            { sub(/\r$/, ""); line[++n] = $0 }
            END {
                for (i = 1; i <= n; i++) {
                    if (line[i] != b) continue
                    for (j = i + 1; j <= n && line[j] != b && line[j] != e; j++) ;
                    if (j <= n && line[j] == e) { for (k = i; k <= j; k++) drop[k] = 1; i = j }
                }
                for (i = 1; i <= n; i++) if (!drop[i]) keep[++m] = line[i]
                s = 1; t = m
                if (at == "top") { while (s <= t && keep[s] !~ /[^[:space:]]/) s++ }
                else             { while (t >= s && keep[t] !~ /[^[:space:]]/) t-- }
                if (at == "top") { print ENVIRON["SRV_WANT"]; if (s <= t) print "" }
                for (i = s; i <= t; i++) print keep[i]
                if (at != "top") { if (s <= t) print ""; print ENVIRON["SRV_WANT"] }
            }' "$dst" > "$dst.srv-tmp" || ! { cat "$dst.srv-tmp" > "$dst"; } 2>/dev/null; then
            rm -f "$dst.srv-tmp"
            warn "could not write ~/$1 — it is unchanged; the copy is in ${target#"$HOME"/}"
            return 0
        fi
        rm -f "$dst.srv-tmp"
        say "block $1 (your own lines kept; the file as it was is in ${target#"$HOME"/})"
    else
        if ! { mkdir -p "$(dirname "$dst")" &&
               { if [ -n "$header" ]; then printf '%s\n\n' "$header"; fi; printf '%s\n' "$want"; } > "$dst"; }; then
            warn "could not create ~/$1"
            return 0
        fi
        say "new  $1"
    fi
}

# copy_once <path relative to this bundle> <path relative to $HOME>
#
# For files the tool itself rewrites — ~/.claude/settings.json gains entries
# when a plugin is enabled, ~/.codex/config.toml gains per-project trust. Those
# edits are machine-local and must not be clobbered on every sync, so these are
# seeded once and then left alone.
copy_once() {
    local src="$SRV_DIR/$1" dst="$HOME/$2"

    if [ ! -e "$src" ]; then
        say "skip $2 (no $1 in this bundle)"
        return 0
    fi
    if [ -e "$dst" ]; then
        say "keep $2 (already here — the bundle's version is $1)"
        return 0
    fi

    run mkdir -p "$(dirname "$dst")"
    run cp -R "$src" "$dst"
    if [ "$SRV_DRY_RUN" = 1 ]; then say "would seed $2"; else say "seed $2"; fi
}


# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------
# clone_if_missing <url> <dest> : shallow clone, tolerant of no network
clone_if_missing() {
    local url="$1" dest="$2" name top
    name="$(basename "$dest")"

    # A directory tree with no files in it (a failed clone's leftover parents,
    # or a `mkdir -p` scaffold) is in the way of the clone but might still be
    # the user's. It is moved to the backup dir like any other displaced file
    # — never deleted — and the move goes through `run`, so --dry-run only
    # describes it.
    if [ -d "$dest" ] && [ ! -d "$dest/.git" ] &&
       [ -z "$(find "$dest" -mindepth 1 ! -type d 2>/dev/null | head -n 1)" ]; then
        say "move $name aside (empty directory tree, not a clone)"
        backup "$dest"
        if [ "$SRV_DRY_RUN" = 1 ]; then
            say "would clone $url -> $dest"
            return 0
        fi
    fi

    if [ -d "$dest/.git" ]; then
        say "ok   $name"
        return 0
    elif [ -e "$dest" ]; then
        say "keep $name (exists but is not a git clone — left alone)"
        return 0
    elif [ "$SRV_DRY_RUN" = 1 ]; then
        say "would clone $url -> $dest"
        return 0
    fi

    # Remember the topmost directory the clone will have to create, so a
    # failure can remove exactly what it made and nothing that was there.
    top="$dest"
    while [ ! -e "$(dirname "$top")" ]; do top="$(dirname "$top")"; done

    if git clone --depth 1 "$url" "$dest" >/dev/null 2>&1; then
        say "clone $name"
    else
        # Everything under $top is the clone's; rmdir only ever removes empty
        # directories, and one call per directory (not `+`) so each parent is
        # already empty by the time -depth reaches it.
        [ -e "$top" ] && find "$top" -depth -type d -exec rmdir {} \; 2>/dev/null
        warn "could not clone $url (no network?) — rerun setup.sh when online"
        return 1
    fi
}

# install_script <label> <url> <interpreter...> : fetch a vendor install
# script and pipe it into <interpreter...> (bash, sh, `env X=1 sh`, ...).
# Output goes to a private temp log; on failure the last lines are shown.
# Safe under `set -euo pipefail`: nothing here can abort the caller, so the
# configuration steps that follow an install still run.
install_script() {
    local label="$1" url="$2" log rc=0
    shift 2
    log="$(mktemp "${TMPDIR:-/tmp}/srv-install.XXXXXX" 2>/dev/null)" || {
        warn "cannot create a temp file under ${TMPDIR:-/tmp}"; return 1; }
    if fetch "$url" | "$@" >"$log" 2>&1; then
        rc=0
    else
        rc=1
        warn "$label install failed:"
        if [ -s "$log" ]; then
            { tail -n 5 "$log" | sed 's/^/     /' >&2; } || true
        fi
    fi
    rm -f "$log"
    return $rc
}

# fetch <url> : write the URL's body to stdout, curl or wget, whichever exists
fetch() {
    if have curl; then
        curl -fsSL "$1"
    elif have wget; then
        wget -qO- "$1"
    else
        warn "neither curl nor wget is installed — cannot download $1"
        return 1
    fi
}

# online : cheap reachability check, so installers can skip instead of hanging
online() {
    if have curl; then
        curl -fsS --max-time 5 -o /dev/null https://github.com 2>/dev/null
    elif have wget; then
        wget -q --timeout=5 --spider https://github.com 2>/dev/null
    else
        return 1
    fi
}
