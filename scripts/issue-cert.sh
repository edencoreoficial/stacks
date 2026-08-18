#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

docker run --rm \
  -v "${BASE_DIR}/certbot/conf:/etc/letsencrypt" \
  -v "${BASE_DIR}/certbot/cloudflare.ini:/cloudflare.ini:ro" \
  certbot/dns-cloudflare certonly \
  --dns-cloudflare --dns-cloudflare-credentials /cloudflare.ini \
  --dns-cloudflare-propagation-seconds 30 \
  -d mon.exemplo.com.br -d painel.exemplo.com.br \
  --email contato@exemplo.com.br --agree-tos --non-interactive
