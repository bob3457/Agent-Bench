#!/bin/bash
# patch_harbor_hopper.sh (v2 RECONSTRUCTION, 2026-07-09) -- patch the installed
# harbor package for Hopper's rootless single-uid Apptainer environment.
#
# The original script was lost; this version was rebuilt against harbor 0.16.1
# source (verified paths/strings below). Semantics may differ in detail from
# the original five-class patcher -- several v1-era classes (dpkg chown,
# Lchown on setgid dirs, sandbox-unpack issues) are superseded by the v2
# def-file prebaker + apptainer 1.5.2 and are handled at BAKE time now, not
# here. What still needs patching at RUN time in 0.16.1:
#
#   P1  singularity.py: strip inherited site bind env (APPTAINER_BINDPATH et
#       al., exported by the hosts/hopper module chain) before `singularity
#       exec` -- site binds like /groups fail under --containall/--fakeroot.
#   P2  bootstrap.sh: write APT::Sandbox::User "root" before any apt call --
#       apt's privilege drop to _apt fails in the single-uid userns
#       ("couldn't drop privileges"). Prebaked images already carry this conf
#       (prebaker writes 99harbor-userns); this covers non-prebaked images.
#   P3  agents/installed/codex.py + claude_code.py: prefer an ALREADY-BAKED
#       node/npm over the curl|bash nvm bootstrap. The nvm path needs live
#       egress to raw.githubusercontent.com + nodejs.org, which compute nodes
#       don't reliably have; with node baked into the SIF the install becomes
#       a local no-network no-op (or is skipped entirely when the agent
#       binary itself is baked).
#
# IDEMPOTENT: safe to rerun. MUST RERUN after every harbor reinstall/upgrade
# (pip reinstalls revert everything, including `conda env update` runs that
# reinstall pinned pip deps).
#
# Usage (with the bench env active, or CONDA_ENV set):
#   bash patch_harbor_hopper.sh          # apply
#   bash patch_harbor_hopper.sh --check  # report patch status, change nothing

set -euo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

CONDA_ROOT="${CONDA_ROOT:-/projects/kzhou6/czhai/miniconda3}"
CONDA_ENV="${CONDA_ENV:-$CONDA_ROOT/envs/bench}"
PY="${PY:-$CONDA_ENV/bin/python}"

[ -x "$PY" ] || { echo "ERROR: python not found at $PY (set CONDA_ENV=)"; exit 1; }

HARBOR_DIR="$("$PY" - <<'EOF'
import harbor, pathlib, sys
print(pathlib.Path(harbor.__file__).parent)
EOF
)" || { echo "ERROR: harbor not importable from $PY"; exit 1; }

HARBOR_VERSION="$("$PY" -c 'import importlib.metadata as m; print(m.version("harbor"))' 2>/dev/null || echo '?')"
echo "harbor $HARBOR_VERSION at $HARBOR_DIR"
[ "$HARBOR_VERSION" = "0.16.1" ] || echo "WARNING: patches verified against 0.16.1; review before trusting on $HARBOR_VERSION"

export HARBOR_DIR CHECK_ONLY
"$PY" - <<'PYEOF'
import os, re, sys
from pathlib import Path

HARBOR = Path(os.environ["HARBOR_DIR"])
CHECK = os.environ["CHECK_ONLY"] == "1"
changed, already, failed = [], [], []


def patch(path: Path, marker: str, transform, desc: str):
    """Apply transform(text) -> new_text unless marker already present."""
    if not path.exists():
        failed.append(f"{desc}: {path} MISSING")
        return
    text = path.read_text()
    if marker in text:
        already.append(desc)
        return
    if CHECK:
        failed.append(f"{desc}: NOT applied")
        return
    new = transform(text)
    if new is None:
        failed.append(f"{desc}: anchor not found in {path.name} -- harbor code changed?")
        return
    path.write_text(new)
    changed.append(desc)


# --- P1: unset site bind env before singularity exec -------------------------
# Anchor: the subprocess exec of the container start command in singularity.py.
# We inject env scrubbing right before create_subprocess_exec by giving it an
# explicit env with the site bind vars removed.
sing = HARBOR / "environments/singularity/singularity.py"

P1_MARK = "# HOPPER-PATCH P1"

def p1(text):
    anchor = "self._server_process = await asyncio.create_subprocess_exec(\n                *cmd,\n                stdout=asyncio.subprocess.PIPE,\n                stderr=asyncio.subprocess.STDOUT,\n            )"
    if anchor not in text:
        return None
    repl = (
        "_env = dict(os.environ)  # HOPPER-PATCH P1: site module exports\n"
        "            for _k in (\"APPTAINER_BINDPATH\", \"SINGULARITY_BINDPATH\",\n"
        "                       \"APPTAINER_BIND\", \"SINGULARITY_BIND\"):\n"
        "                _env.pop(_k, None)  # /groups etc. fail under --containall\n"
        "            self._server_process = await asyncio.create_subprocess_exec(\n"
        "                *cmd,\n"
        "                stdout=asyncio.subprocess.PIPE,\n"
        "                stderr=asyncio.subprocess.STDOUT,\n"
        "                env=_env,\n"
        "            )"
    )
    text = text.replace(anchor, repl, 1)
    if not re.search(r"^import os$", text, re.M) and "import os\n" not in text:
        text = text.replace("import asyncio", "import asyncio\nimport os", 1)
    return text

patch(sing, P1_MARK, p1, "P1 singularity.py: scrub site bind env")

# --- P2: apt rootless sandbox conf in bootstrap.sh ----------------------------
boot = HARBOR / "environments/singularity/bootstrap.sh"

P2_MARK = "# HOPPER-PATCH P2"

def p2(text):
    anchor = 'export DEBIAN_FRONTEND=noninteractive\n'
    if anchor not in text:
        return None
    inject = (
        anchor +
        "\n# HOPPER-PATCH P2: apt's privilege drop to _apt fails in the\n"
        "# single-uid root-mapped userns; keep the sandbox as root.\n"
        "if command -v apt-get >/dev/null 2>&1; then\n"
        "  mkdir -p /etc/apt/apt.conf.d 2>/dev/null || true\n"
        "  echo 'APT::Sandbox::User \"root\";' > /etc/apt/apt.conf.d/99harbor-userns 2>/dev/null || true\n"
        "fi\n"
    )
    return text.replace(anchor, inject, 1)

patch(boot, P2_MARK, p2, "P2 bootstrap.sh: apt sandbox = root")

# --- P3: prefer baked binaries over network installs --------------------------
# codex.py (glibc branch): nvm curl|bash -> node 22 -> npm i -g codex. Prepend
# a "command -v npm" short-circuit so images with node baked in (prebaker)
# never touch the network.
NVM_HEAD = '"  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh | bash &&"'
P3_HEAD = '"  command -v npm &>/dev/null ||"  # HOPPER-PATCH P3: baked node wins\n                " {  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh | bash &&"'

P3_MARK = "HOPPER-PATCH P3"

def p3(text):
    if NVM_HEAD not in text:
        return None
    # close the { ... } group where the nvm branch's npm -v ends
    tail = '"  nvm install 22 && nvm alias default 22 && npm -v &&"'
    if tail not in text:
        return None
    text = text.replace(NVM_HEAD, P3_HEAD, 1)
    text = text.replace(tail, '"  nvm install 22 && nvm alias default 22 && npm -v; } &&"', 1)
    return text

patch(HARBOR / "agents/installed/codex.py", P3_MARK, p3,
      "P3 codex.py: skip nvm when npm is baked")

# claude_code.py (glibc branch): downloads.claude.ai bootstrap.sh installer.
# Prefer baked npm (npm i -g runs local-registry-only... still network for the
# package itself, but skips the installer entirely when the binary is baked --
# and harbor's own version check already short-circuits install() then).
# Here: if npm exists in the image, install via npm instead of the curl
# bootstrap (single fetch from registry.npmjs.org, which login-node prebakes
# make unnecessary anyway).
CC_CURL = '"  curl -fsSL https://downloads.claude.ai/claude-code-releases/bootstrap.sh | bash -s --{version_flag};"'

def p3_cc(text):
    # source uses an f-string; match on the stable prefix
    anchor = 'curl -fsSL https://downloads.claude.ai/claude-code-releases/bootstrap.sh | bash -s --'
    if anchor not in text:
        return None
    text = text.replace(
        anchor,
        'command -v npm &>/dev/null && npm install -g @anthropic-ai/claude-code || '
        + anchor,
        1,
    )
    # marker lives at top of file (anchor line is inside an f-string, so the
    # marker can't ride along inline without changing the runtime command)
    return "# HOPPER-PATCH P3: prefer baked npm over curl bootstrap\n" + text

patch(HARBOR / "agents/installed/claude_code.py", P3_MARK, p3_cc,
      "P3 claude_code.py: prefer npm over curl bootstrap")

# --- report -------------------------------------------------------------------
for d in changed:
    print(f"  PATCHED : {d}")
for d in already:
    print(f"  already : {d}")
for d in failed:
    print(f"  !! {d}")

if failed and not CHECK:
    sys.exit(1)
sys.exit(0 if not (CHECK and failed) else 1)
PYEOF
rc=$?

if [ "$CHECK_ONLY" = "1" ]; then
  [ "$rc" -eq 0 ] && echo "all patches present" || echo "patches missing (run without --check to apply)"
else
  [ "$rc" -eq 0 ] && echo "done -- rerun this script after any harbor reinstall/upgrade" \
                  || echo "SOME PATCHES FAILED -- harbor source may have changed; inspect above"
fi
exit "$rc"