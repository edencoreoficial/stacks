#!/bin/bash
set -euo pipefail

DOMAIN="mon.exemplo.com.br"
CERT_PATH="/opt/edencore-zabbix-grafana-opnsense/certbot/conf/live/mon.exemplo.com.br/fullchain.pem"
ZABBIX_SERVER="127.0.0.1"
ZABBIX_HOST="Zabbix server"
ITEM_KEY="cert.days.remaining"

EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
NOW_EPOCH=$(date +%s)
DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

zabbix_sender -z "$ZABBIX_SERVER" -s "$ZABBIX_HOST" -k "$ITEM_KEY" -o "$DAYS_LEFT"
