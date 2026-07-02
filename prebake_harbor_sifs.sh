#!/bin/bash
# prebake_harbor_sifs.sh -- bake Harbor's in-container runtime deps into cached
# SIFs so trials on Hopper don't depend on apt egress or the 64 MiB
# --writable-tmpfs overlay at bootstrap time.
#
# Why: harbor's singularity bootstrap installs, PER TRIAL, into the RAM-backed
# overlay: python3 + python3-venv (ubuntu:24.04 images ship neither), a venv at
# /opt/harbor-server with uvicorn+fastapi, plus tmux/asciinema. The agent
# installers additionally apt-get curl/procps/ripgrep. On Hopper this dies with
# "[harbor] FATAL: cannot install /usr/bin/python3" (blocked port-80 apt egress
# and/or sessiondir max size = 64 MiB). Every install below is guarded by an
# existence check in harbor's bootstrap/agents, so baking them in makes the
# bootstrap a no-op.
#
# Harbor cache contract (verified in harbor 0.15.0 + 0.16.1 source):
#   cache file = <image with '/' and ':' -> '_'>.sif ; if the file exists it is
#   used verbatim (no digest check), guarded by flock on <file>.lock.
#   We take the same lock and replace the file atomically -- safe to run while
#   jobs are queued (not while a trial is mid-conversion of the same image).
#
# Usage (run where egress works -- login node or an egress-enabled compute node):
#   bash prebake_harbor_sifs.sh alexgshaw/adaptive-rejection-sampler:20251031
#   bash prebake_harbor_sifs.sh --all-cached          # rebake every SIF in cache
#   bash prebake_harbor_sifs.sh --from-tasks ~/.cache/harbor/tasks   # parse task.tomls
#   FORCE=1 bash prebake_harbor_sifs.sh ...           # rebake even if checks pass
#
# Images are pulled first if not yet cached (so you can pre-warm the whole
# cache from an egress-enabled node before any SLURM job runs).

set -uo pipefail

SCRATCH_DIR="${SCRATCH_DIR:-/scratch/czhai}"
SIF_CACHE_DIR="${SIF_CACHE_DIR:-$SCRATCH_DIR/.harbor_sif_cache}"
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$SCRATCH_DIR/.apptainer_cache}"
export SINGULARITY_CACHEDIR="$APPTAINER_CACHEDIR"
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-$SCRATCH_DIR/tmp}"
BAKE_TMP="${BAKE_TMP:-$SCRATCH_DIR/tmp/sif_bake}"   # sandboxes live on DISK, not tmpfs
FORCE="${FORCE:-0}"

# What to bake. CORE must install cleanly; tmux/asciinema are best-effort
# (libutempter0, a tmux dep, ships a root:utmp setgid file -- chown to the
# unmapped gid fails in the single-uid userns and aborts dpkg, so those get
# a dpkg-deb -x fallback that extracts without ownership or scripts).
APT_CORE="python3 python3-venv python3-pip curl procps ripgrep ca-certificates"
APT_OPT="tmux asciinema"

mkdir -p "$SIF_CACHE_DIR" "$APPTAINER_TMPDIR" "$BAKE_TMP"
# GMU scratch dirs are setgid group 'scratch'; that group is UNMAPPED in the
# single-uid userns (appears as overflow gid 65534) and apptainer's build
# copy step fails trying to Lchown files to it. Stop the inheritance here and
# normalize again right before the rebuild (belt and suspenders).
chmod g-s "$BAKE_TMP" "$APPTAINER_TMPDIR" 2>/dev/null || true
chgrp "$(id -g)" "$BAKE_TMP" 2>/dev/null || true

# Site modules export APPTAINER_BINDPATH (e.g. /groups on Hopper). Env-var
# binds are NOT covered by --no-mount bind-paths, and --writable sandboxes
# can't auto-create their mount points (no overlay). The bake needs no host
# binds at all -- clear them. (CACHEDIR/TMPDIR are not binds; they stay.)
unset APPTAINER_BINDPATH SINGULARITY_BINDPATH APPTAINER_BIND SINGULARITY_BIND 2>/dev/null || true

command -v singularity >/dev/null 2>&1 || {
    echo "ERROR: singularity not on PATH (module load hosts/hopper apptainer/1.4.1)"; exit 1; }

# --- collect target images ------------------------------------------------------
declare -a IMAGES=()
mode="${1:-}"
case "$mode" in
    --all-cached)
        # Rebake whatever harbor has already converted. Filename -> image is
        # ambiguous ('_' was both '/' and ':'), but for baking we don't need
        # the image name -- we operate on the .sif directly.
        for sif in "$SIF_CACHE_DIR"/*.sif; do
            [ -e "$sif" ] && IMAGES+=("sif:$sif")
        done
        ;;
    --from-tasks)
        task_dir="${2:?--from-tasks needs a directory of harbor task dirs}"
        while IFS= read -r img; do
            IMAGES+=("$img")
        done < <(grep -rh '^docker_image' "$task_dir" --include=task.toml 2>/dev/null \
                 | sed 's/.*=\s*"\(.*\)"/\1/' | sort -u)
        ;;
    "")
        echo "usage: $0 <image[:tag] ...> | --all-cached | --from-tasks <dir>"; exit 1
        ;;
    *)
        IMAGES=("$@")
        ;;
esac
[ "${#IMAGES[@]}" -gt 0 ] || { echo "no images to bake"; exit 1; }
echo "baking ${#IMAGES[@]} image(s) into $SIF_CACHE_DIR"

# --- helpers ---------------------------------------------------------------------
sif_path_for() {  # image -> cache path (harbor's safe_name scheme)
    local img="$1"
    case "$img" in *:*) ;; *) img="$img:latest";; esac
    echo "$SIF_CACHE_DIR/$(echo "$img" | tr '/:' '__').sif"
}

is_baked() {  # sif -> 0 if all runtime deps present
    singularity exec --no-mount bind-paths --containall "$1" bash -c '
        command -v python3 >/dev/null 2>&1 &&
        [ -x /opt/harbor-server/bin/python3 ] &&
        /opt/harbor-server/bin/python3 -c "import uvicorn, fastapi" 2>/dev/null &&
        command -v curl >/dev/null 2>&1' >/dev/null 2>&1
    # NOTE: tmux deliberately NOT required here -- it is best-effort (userns
    # chown issues) and harbor warns-and-continues without it.
}

bake_one() {  # <sif path> [image name for pull]
    local sif="$1" img="${2:-}" name rc=0
    name="$(basename "$sif")"

    if [ ! -f "$sif" ]; then
        [ -n "$img" ] || { echo "[$name] missing and no image name to pull"; return 1; }
        echo "[$name] pulling docker://$img ..."
        singularity pull "$sif" "docker://$img" || { echo "[$name] pull FAILED"; return 1; }
    fi

    if [ "$FORCE" != "1" ] && is_baked "$sif"; then
        echo "[$name] already baked -- skip"; return 0
    fi

    local work="$BAKE_TMP/$name.$$"
    local sandbox="$work/sandbox"
    mkdir -p "$work"
    trap 'rm -rf "$work"' RETURN

    echo "[$name] unpacking to disk sandbox (no tmpfs limits here)..."
    singularity build --sandbox "$sandbox" "$sif" >/dev/null \
        || { echo "[$name] sandbox build FAILED"; return 1; }

    echo "[$name] installing runtime deps..."
    # --writable on a DISK sandbox: apt unpacks to scratch, not the 64MiB tmpfs.
    # --no-mount bind-paths: site apptainer.conf binds (/groups, /projects, ...)
    # can't be auto-created in --writable sandbox mode (no overlay) and aren't
    # needed for the bake. Matches harbor's own default (home,tmp,bind-paths).
    singularity exec --no-mount bind-paths --writable --fakeroot --containall "$sandbox" bash -c '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        if command -v apt-get >/dev/null 2>&1; then
            # Hopper has no /etc/subuid ranges -> single-uid root-mapped userns.
            # apt privilege-drop to _apt (setegid 65534 / seteuid 42) hits
            # unmapped uids and its http method dies. Disable the sandbox for
            # THIS bake and persist the conf so every runtime apt (harbor
            # bootstrap, agent installers, task commands) works too.
            mkdir -p /etc/apt/apt.conf.d
            echo '\''APT::Sandbox::User "root";'\'' > /etc/apt/apt.conf.d/99harbor-userns
            # Debian/Ubuntu default mirrors are plain HTTP :80; flip to HTTPS
            # in case compute-node egress only allows 443 (deb.debian.org and
            # archive.ubuntu.com both serve HTTPS).
            sed -i "s|http://|https://|g" /etc/apt/sources.list 2>/dev/null || true
            sed -i "s|http://|https://|g" /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
            apt-get -o Acquire::Retries=3 update
            apt-get install -y --no-install-recommends '"$APT_CORE"'
            # Best-effort extras. Normal install first; on failure (userns
            # chown to unmapped uids/gids aborts dpkg for packages shipping
            # non-root-owned files, e.g. libutempter0), fall back to raw
            # dpkg-deb -x extraction: no maintainer scripts, no chown, files
            # land owned by mapped-root. tmux does not need utempter setgid
            # inside a container, and harbor treats missing tmux as a warning.
            if ! apt-get install -y --no-install-recommends '"$APT_OPT"'; then
                echo "[bake] optional pkgs via apt failed; extracting with dpkg-deb -x" >&2
                # Scrub the half-installed packages from dpkg state FIRST, so
                # future runtime apt on this image does not trip over them.
                # (--remove also deletes any files they placed; we re-extract
                # below, so ordering matters: scrub, then extract.)
                dpkg --remove --force-remove-reinstreq --force-depends \
                    '"$APT_OPT"' libutempter0 libevent-core-2.1-7 2>/dev/null || true
                dpkg --configure -a 2>/dev/null || true
                dpkg --audit && echo "[bake] dpkg state clean" >&2 \
                    || echo "[bake] WARNING: dpkg --audit still unhappy" >&2
                extract_dir=$(mktemp -d)
                ( cd "$extract_dir" \
                  && apt-get download '"$APT_OPT"' libutempter0 libevent-core-2.1-7 2>/dev/null \
                  && for d in *.deb; do
                         # --no-same-owner: skip the chown that dies on unmapped
                         # ids (e.g. libutempter0 ships a root:utmp setgid file)
                         dpkg-deb --fsys-tarfile "$d" | tar -x --no-same-owner -C / || true
                     done ) || true
                rm -rf "$extract_dir"
                # tmux -V exercises the dynamic linker too (libutempter.so.0,
                # libevent) -- a mere command -v can lie about runnability.
                tmux -V >/dev/null 2>&1 && echo "[bake] tmux extracted OK ($(tmux -V))" >&2 \
                    || echo "[bake] WARNING: tmux unavailable (harbor warns + continues)" >&2
            fi
            rm -rf /var/lib/apt/lists/*        # keep image small; bootstrap apt-update failing is || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y python3 python3-pip tmux curl procps-ng ripgrep || dnf install -y python3 curl
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache python3 py3-pip tmux curl procps ripgrep bash
        else
            echo "NO PACKAGE MANAGER -- this image belongs in EXCLUDE_TASKS" >&2
            command -v python3 >/dev/null 2>&1 || exit 42
        fi
        # /usr/bin/python3 must exist by that literal path (bootstrap checks it)
        command -v python3 >/dev/null 2>&1 || exit 42
        [ -x /usr/bin/python3 ] || ln -sf "$(command -v python3)" /usr/bin/python3
        # Pre-create the harbor server venv exactly where bootstrap expects it
        /usr/bin/python3 -m venv /opt/harbor-server
        /opt/harbor-server/bin/python3 -m pip install --quiet --upgrade pip
        /opt/harbor-server/bin/python3 -m pip install --quiet uvicorn fastapi
        /opt/harbor-server/bin/python3 -c "import uvicorn, fastapi"
        # asciinema via pip if the distro package was unavailable
        command -v asciinema >/dev/null 2>&1 \
            || /opt/harbor-server/bin/python3 -m pip install --quiet asciinema || true
    ' || rc=$?
    if [ "$rc" -eq 42 ]; then
        echo "[$name] UNBAKEABLE (no python3, no package manager) -> EXCLUDE_TASKS"; return 2
    elif [ "$rc" -ne 0 ]; then
        echo "[$name] dep install FAILED (rc=$rc) -- read the apptainer/apt output above"; return 1
    fi

    echo "[$name] normalizing ownership for rebuild..."
    # All sandbox files are uid czhai on disk (created as mapped-root), but
    # setgid scratch dirs gave many of them group 'scratch' -- unmapped in the
    # userns -> gid 65534 -> apptainer build FATALs on Lchown. As the file
    # owner we may chgrp to our own primary group; also clear setgid dir bits
    # so nothing re-inherits during the build's copy.
    chgrp -Rh "$(id -g)" "$sandbox" 2>/dev/null || true
    find "$sandbox" -type d -perm -2000 -exec chmod g-s {} + 2>/dev/null || true

    echo "[$name] rebuilding SIF (bundled mksquashfs, --fakeroot)..."
    singularity build --fakeroot "$work/new.sif" "$sandbox" >/dev/null \
        || { echo "[$name] SIF rebuild FAILED"; return 1; }

    # Replace under harbor's own lock so a concurrently starting trial never
    # sees a half-written file (harbor flocks <sif>.lock around conversion).
    (
        exec 9>"$sif.lock"
        flock 9
        mv -f "$work/new.sif" "$sif"
    )
    is_baked "$sif" && echo "[$name] baked OK" || { echo "[$name] verify FAILED"; return 1; }
}

# --- main loop -------------------------------------------------------------------
fail=0; unbakeable=0
for entry in "${IMAGES[@]}"; do
    if [[ "$entry" == sif:* ]]; then
        bake_one "${entry#sif:}" || { [ $? -eq 2 ] && unbakeable=$((unbakeable+1)) || fail=$((fail+1)); }
    else
        bake_one "$(sif_path_for "$entry")" "$entry" || { [ $? -eq 2 ] && unbakeable=$((unbakeable+1)) || fail=$((fail+1)); }
    fi
done

echo
echo "done: $((${#IMAGES[@]} - fail - unbakeable)) baked, $unbakeable unbakeable (add to EXCLUDE_TASKS), $fail failed"
[ "$fail" -eq 0 ] || exit 1