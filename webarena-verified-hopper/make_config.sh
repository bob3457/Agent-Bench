#!/usr/bin/env bash
# make_config.sh - emit a webarena-verified config.json wired to the running
# Hopper sites (shopping + shopping_admin only).
#
# Usage:
#   ./make_config.sh > config.hopper.json
#   WA_HOST=hop123 ./make_config.sh > config.hopper.json

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

cat <<EOF
{
  "environments": {
    "__SHOPPING__": {
      "urls": ["http://${WA_HOST}:${SHOPPING_HTTP_PORT}"],
      "active_url_idx": 0,
      "use_header_login": true,
      "credentials": { "username": "emma.lopez@gmail.com", "password": "Password.123" }
    },
    "__SHOPPING_ADMIN__": {
      "urls": ["http://${WA_HOST}:${SHOPPING_ADMIN_HTTP_PORT}/admin"],
      "active_url_idx": 0,
      "use_header_login": true,
      "credentials": { "username": "admin", "password": "admin1234" }
    }
  }
}
EOF
