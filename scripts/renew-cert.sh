#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

docker run --rm \
  -v "${BASE_DIR}/certbot/conf:/etc/letsencrypt" \
  -v "${BASE_DIR}/certbot/cloudflare.ini:/cloudflare.ini:ro" \
  certbot/dns-cloudflare renew \
  --dns-cloudflare --dns-cloudflare-credentials /cloudflare.ini

docker exec nginx-proxy nginx -s reload
