# Zabbix + Grafana atrás de OPNsense

Documentação completa: [wiki.edencore.com.br/Seguranca/Monitoramento/NOC/zabbix-grafana-opnsense](https://wiki.edencore.com.br/Seguranca/Monitoramento/NOC/zabbix-grafana-opnsense/)

Stack de referência para monitoramento (Zabbix 7.0 + Grafana 11.6) containerizada, sem nenhum serviço com IP público direto. Todo tráfego externo passa por um firewall OPNsense antes de alcançar os containers.

## Pré-requisitos

- VPS/VM com Docker e Docker Compose
- OPNsense (ou equivalente) na frente, fazendo NAT de destino para a VM
- nftables como firewall do host
- Domínio próprio, DNS gerenciado pela Cloudflare (usado para emissão de certificado via DNS-01)
- Token de API da Cloudflare com escopo `Zone:DNS:Edit`

## Deploy

```bash
git clone https://github.com/edencoreoficial/edencore-zabbix-grafana-opnsense.git /opt/edencore-zabbix-grafana-opnsense
cd /opt/edencore-zabbix-grafana-opnsense

cp .env.example .env
nano .env   # define as senhas

cp certbot/cloudflare.ini.example certbot/cloudflare.ini
chmod 600 certbot/cloudflare.ini
nano certbot/cloudflare.ini   # cola o token da Cloudflare

# ajusta os domínios em nginx/conf.d/*.conf e em scripts/issue-cert.sh
# para os seus domínios reais (por padrão usam mon.exemplo.com.br / painel.exemplo.com.br)

cp scripts/nftables.conf /etc/nftables.conf
# ajusta o IP em scripts/nftables.conf e scripts/update-mgmt-set.sh
# para o IP/hostname real de gestão
systemctl enable --now nftables.service

./scripts/issue-cert.sh

docker compose up -d postgres-server
docker compose logs -f postgres-server   # aguarda "database system is ready to accept connections"

docker compose up -d

cp scripts/update-mgmt-set.sh scripts/apply-docker-user-rules.sh /usr/local/sbin/
chmod +x /usr/local/sbin/update-mgmt-set.sh /usr/local/sbin/apply-docker-user-rules.sh

cp systemd/*.service systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now nft-mgmt-set.timer
systemctl start nft-mgmt-set.service
systemctl enable --now certbot-renew.timer
```

## Validação

```bash
docker compose ps
nft list chain ip filter DOCKER-USER
curl -m3 https://mon.exemplo.com.br
```

De uma origem fora da allowlist, a porta 443 deve recusar ou dar timeout. Portas 10051/tcp e 162/udp ficam abertas para qualquer origem, é o requisito de comunicação com hosts cliente (agente Zabbix ativo e SNMP trap).

## Arquitetura, em resumo

- **`backend`**: rede Docker `internal: true`, sem rota de saída à internet. Postgres, Zabbix server/web, agentes.
- **`frontend`**: única rede com saída à internet. nginx-proxy, Grafana, zabbix-web.
- **`dmz`**: IPs estáticos, egress restrito por nftables. Zabbix server e SNMP traps, os dois componentes que recebem dado externo não confiável.

Containers que precisam publicar porta não podem estar exclusivamente em rede `internal: true`. Docker não gera a regra de DNAT nesse caso, por isso `zabbix-server` e `zabbix-snmptraps` estão em rede dupla.

MIT. Use e adapte os domínios e IPs para o seu ambiente.
