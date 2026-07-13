#!/usr/bin/env bash
# make_config.sh - emit a webarena-verified config.json wired to the running
# Hopper sites (all sites except wikipedia).
#
# URLs are resolved in priority order:
#   1. $WA_URLS_DIR/<site>.env fragments (written by webarena_sites.sbatch;
#      lets sites live on different compute nodes / hosting jobs)
#   2. wa_site_url() with the current $WA_HOST
#
# Usage:
#   ./make_config.sh > config.hopper.json
#   WA_HOST=hop123 ./make_config.sh > config.hopper.json

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

# Pull in per-site URL fragments (export SHOPPING=..., export REDDIT=..., ...)
if [ -d "$WA_URLS_DIR" ]; then
  for f in "$WA_URLS_DIR"/*.env; do
    [ -f "$f" ] || continue
    # shellcheck disable=SC1090
    source "$f"
  done
fi

SHOPPING_URL="${SHOPPING:-$(wa_site_url shopping)}"
SHOPPING_ADMIN_URL="${SHOPPING_ADMIN:-$(wa_site_url shopping_admin)}"
REDDIT_URL="${REDDIT:-$(wa_site_url reddit)}"
GITLAB_URL="${GITLAB:-$(wa_site_url gitlab)}"
MAP_URL="${MAP:-$(wa_site_url map)}"

cat <<EOF
{
  "environments": {
    "__SHOPPING__": {
      "urls": ["$SHOPPING_URL"],
      "active_url_idx": 0,
      "use_header_login": true,
      "credentials": { "username": "emma.lopez@gmail.com", "password": "Password.123" }
    },
    "__SHOPPING_ADMIN__": {
      "urls": ["$SHOPPING_ADMIN_URL"],
      "active_url_idx": 0,
      "use_header_login": true,
      "credentials": { "username": "admin", "password": "admin1234" }
    },
    "__REDDIT__": {
      "urls": ["$REDDIT_URL"],
      "active_url_idx": 0,
      "use_header_login": true,
      "credentials": { "username": "MarvelsGrantMan136", "password": "test1234" }
    },
    "__GITLAB__": {
      "urls": ["$GITLAB_URL"],
      "active_url_idx": 0,
      "use_header_login": false,
      "credentials": { "username": "byteblaze", "password": "hello1234" }
    },
    "__MAP__": {
      "urls": ["$MAP_URL"],
      "active_url_idx": 0,
      "use_header_login": false
    }
  }
}
EOF
