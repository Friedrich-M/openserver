# lib/detect.sh — which machine this is, and its profile.
#
# Sets SRV_OS (linux | macos) and SRV_HOST (a profile's name), then sources
# that profile, which sets every other SRV_* value — SRV_SITE among them.
# Profiles live in hosts/ (shipped) and hosts/local/ (your own, git-ignored;
# read first, so one of yours wins over a shipped one of the same name).
# Nothing in this file names a machine: a profile claims its own in header
# lines that are read before anything is sourced,
#
#   # hosts: login* *.cluster.example.edu   shell patterns on the hostname
#   # domain: *.example.edu                 a site's fallback, after every hosts: line
#   # os: macos                             the last resort, by operating system
#
# checked in that order, first match wins. So adding a machine is one new
# file and nothing else. Preset SRV_HOST to force a profile; a preset name
# with no profile falls back to generic.sh, and srvinfo says so.
#
# POSIX sh: sourced by bash and by zsh, interactive and not.

: "${SRV_DIR:="$HOME/server"}"

# Every profile builds its paths from $USER, which login shells set but
# cloud-init, Docker RUN and CI runners do not. Under `set -u` a bare $USER
# would abort there.
USER="${USER:-$(id -un)}"
export USER

if [ -z "${SRV_OS:-}" ]; then
    case "$(uname -s 2>/dev/null)" in
        Darwin) SRV_OS=macos ;;
        *)      SRV_OS=linux ;;
    esac
fi

# _srv_match <name> "<patterns>" : does any shell pattern match the name?
# The pattern is spliced into the case by eval — the one form both shells
# treat as a pattern (zsh would otherwise match a variable literally, and
# its GLOB_SUBST option globs the loop list too).
_srv_match() {
    local IFS=' ' pattern globbing=1
    # Split the list without expanding `login*` against the files in the
    # current folder: globbing off for the loop, as it was afterwards.
    case $- in *f*) globbing=0 ;; esac
    set -f
    for pattern in $2; do
        if eval 'case "$1" in '"$pattern"') true ;; *) false ;; esac'; then
            [ "$globbing" = 1 ] && set +f
            return 0
        fi
    done
    [ "$globbing" = 1 ] && set +f
    return 1
}

# _srv_detect : set SRV_HOST from the profiles' headers, or fail.
_srv_detect() {
    # null_glob: an empty hosts/local/ must not stop zsh before the grep.
    [ -n "${ZSH_VERSION:-}" ] && setopt local_options sh_word_split null_glob
    local name key line file value nl='
'
    # Both forms are tried: `hostname -f` is the reliable one on a cluster,
    # but it is slow to fail on a laptop that is off the network, so the
    # short name is the fallback rather than the other way round.
    name=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)

    for key in hosts domain os; do
        local IFS="$nl"
        # One grep for every profile, yours first; -H so a lone file still
        # gets its name.
        for line in $(grep -H "^# $key: " "$SRV_DIR"/hosts/local/*.sh "$SRV_DIR"/hosts/*.sh 2>/dev/null); do
            file=${line%%:*}
            value=${line#*"# $key: "}
            # A <name>.local.sh copied from a profile keeps its header, but it
            # is an override, never a profile of its own.
            case "$file" in *.local.sh) continue ;; esac
            if [ "$key" = os ]; then
                [ "$value" = "$SRV_OS" ] || continue
            else
                _srv_match "$name" "$value" || continue
            fi
            file=${file##*/}
            SRV_HOST=${file%.sh}
            return 0
        done
    done
    return 1
}

if [ -z "${SRV_HOST:-}" ]; then
    _srv_detect || SRV_HOST=generic
fi

SRV_PROFILE="$SRV_DIR/hosts/local/$SRV_HOST.sh"
[ -r "$SRV_PROFILE" ] || SRV_PROFILE="$SRV_DIR/hosts/$SRV_HOST.sh"
[ -r "$SRV_PROFILE" ] || SRV_PROFILE="$SRV_DIR/hosts/generic.sh"

# The profile is declarative and sets only SRV_* values; these are the
# defaults a profile may leave out.
SRV_SITE=""
SRV_CONDA_TREE=""
. "$SRV_PROFILE"
# hosts/<name>.local.sh: the same SRV_* values, yours rather than the
# machine's (a lab account, a group fileset); git-ignored, so a public copy
# of this repository carries none of them.
[ -r "${SRV_PROFILE%.sh}.local.sh" ] && . "${SRV_PROFILE%.sh}.local.sh"

unset -f _srv_match _srv_detect
export SRV_OS SRV_HOST SRV_SITE SRV_PROFILE
