#!/bin/bash
set -euo pipefail

STATIC_IP="198.51.100.10"
VPN_DOMAIN="vpn.exemplo.com.br"
TABLE="ip filter"
SET="mgmt_v4_docker"

nft add table $TABLE 2>/dev/null || true
nft add set $TABLE $SET '{ type ipv4_addr; }' 2>/dev/null || true

nft flush set $TABLE $SET
nft add element $TABLE $SET "{ $STATIC_IP }"

for ip in $(dig +short A "$VPN_DOMAIN"); do
    nft add element $TABLE $SET "{ $ip }"
done
