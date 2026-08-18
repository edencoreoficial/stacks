#!/bin/bash
set -euo pipefail

TABLE="ip filter"
CHAIN="DOCKER-USER"

for i in $(seq 1 30); do
    nft list chain $TABLE $CHAIN >/dev/null 2>&1 && break
    sleep 1
done

nft flush chain $TABLE $CHAIN 2>/dev/null || true

nft add rule $TABLE $CHAIN ip saddr 172.30.0.10 ct state established,related accept
nft add rule $TABLE $CHAIN ip saddr 172.30.0.10 udp dport 53 accept
nft add rule $TABLE $CHAIN ip saddr 172.30.0.10 tcp dport 53 accept
nft add rule $TABLE $CHAIN ip saddr 172.30.0.10 tcp dport 443 accept
nft add rule $TABLE $CHAIN ip saddr 172.30.0.10 drop

nft add rule $TABLE $CHAIN ip saddr 172.30.0.11 ct state established,related accept
nft add rule $TABLE $CHAIN ip saddr 172.30.0.11 drop

nft add rule $TABLE $CHAIN meta l4proto tcp th dport { 443, 80 } ip saddr @mgmt_v4_docker accept
nft add rule $TABLE $CHAIN meta l4proto tcp th dport { 443, 80 } log prefix "\"NFT-DROP-WEB4: \"" drop
nft add rule $TABLE $CHAIN meta l4proto tcp th dport 10051 accept
nft add rule $TABLE $CHAIN meta l4proto udp th dport 162 accept
nft add rule $TABLE $CHAIN accept
