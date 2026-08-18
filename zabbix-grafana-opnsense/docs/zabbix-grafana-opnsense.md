# Zabbix + Grafana atrás de OPNsense

## Visão geral

Ambiente de monitoramento corporativo com Zabbix 7.0 e Grafana 11.6, containerizado via Docker, hospedado numa VPS Cloud sem IP público direto — todo o tráfego externo passa por um firewall OPNsense que faz NAT de destino e filtragem de origem antes de qualquer pacote alcançar os serviços.

A doutrina de mudança segue o princípio **infra altera, SOC valida**: nenhuma alteração de firewall ou infraestrutura entra em produção sem validação cruzada. Toda regra de segurança carrega rastreabilidade MITRE ATT&CK.

### Topologia

```
Internet
   │
   ▼
[OPNsense — FW-EXEMPLO]
   WAN: 203.0.113.50/24, gw 203.0.113.1
   LAN: 10.20.0.254/24
   │
   ▼ (NAT de destino)
[VM Cloud — MON-EXEMPLO]
   IP privado: 10.20.0.1/24
   Docker: Zabbix, Grafana, Postgres, nginx-proxy
```

Domínios de exemplo: `mon.exemplo.com.br` (Zabbix), `painel.exemplo.com.br` (Grafana). Origem de gestão liberada: `198.51.100.10` (IP fixo do escritório) e o hostname dinâmico do concentrador VPN.

---

## 1. OPNsense — Firewall de borda

### 1.1 Destination NAT (Port Forward)

O OPNsense recebe todo o tráfego na WAN e traduz para o IP privado da VM. Regras cadastradas em **Firewall → NAT → Destination NAT**:

| Protocolo | Origem | Porta destino | Redirect Target | Porta alvo | Descrição |
|---|---|---|---|---|---|
| TCP | `Access_DDNS` (alias) | 443 | 10.20.0.1 | 443 | Web (Zabbix + Grafana via nginx) |
| TCP | `Access_DDNS` | 22222 | 10.20.0.1 | 22 | SSH (porta não padrão na WAN) |
| TCP | any | Zabbix_Agent_Server (alias) | 10.20.0.1 | 10050:10051 | Zabbix Agent ativo |
| UDP | any | Zabbix_SNMP_Trap (alias) | 10.20.0.1 | 162 | SNMP Trap |

O alias `Access_DDNS` resolve o hostname de DDNS do escritório dinamicamente — necessário porque o IP público do escritório muda periodicamente.

Os itens de Agent e SNMP Trap ficam liberados para **qualquer origem** de propósito: hosts de cliente monitorados via agente ativo estão espalhados por várias redes diferentes, não dá para restringir por IP fixo. A superfície de exposição desses dois protocolos é aceitável — não expõem painel administrativo, só recebem métrica.

### 1.2 Firewall Rules — WAN

Toda regra Destination NAT gera automaticamente uma regra de filtro correspondente (`Automatically generated rules`), que efetivamente processa o tráfego. Confirmar sempre com `pfctl -sr` no shell, não confiar só na interface — regras podem existir no XML de configuração e não estar de fato carregadas no kernel se houver erro de sintaxe silencioso (ver seção de Troubleshooting).

Regra adicional de acesso administrativo ao próprio firewall, separada das regras de NAT:

| Interface | Protocolo | Origem | Destino | Porta | Ação |
|---|---|---|---|---|---|
| WAN | TCP | `Access_DDNS` | This Firewall | porta de gestão não padrão | Pass |

**Nunca** usar a porta administrativa padrão (443/80) exposta na WAN — sempre porta alta, não documentada publicamente, e restrita ao alias de origem.

---

## 2. VM — Stack Docker

### 2.1 docker-compose.yml (estrutura)

```yaml
services:
  postgres-server:
    image: postgres:16-alpine
    container_name: zbx-postgres
    networks: [backend]
    restart: unless-stopped

  zabbix-server:
    image: zabbix/zabbix-server-pgsql:alpine-7.0-latest
    container_name: zbx-server
    ports:
      - "10051:10051"
    networks:
      backend:
      dmz:
        ipv4_address: 172.30.0.10
    restart: unless-stopped

  zabbix-snmptraps:
    image: zabbix/zabbix-snmptraps:alpine-7.0-latest
    container_name: zbx-snmptraps
    ports:
      - "162:162/udp"
    networks:
      dmz:
        ipv4_address: 172.30.0.11
    restart: unless-stopped

  zabbix-web:
    image: zabbix/zabbix-web-nginx-pgsql:alpine-7.0-latest
    container_name: zbx-web
    networks: [backend, frontend]
    restart: unless-stopped

  zabbix-agent-self:
    image: zabbix/zabbix-agent2:alpine-7.0-latest
    container_name: zbx-agent-self
    volumes:
      - /:/hostfs:ro
    networks: [backend]
    restart: unless-stopped

  zabbix-agent-docker:
    image: zabbix/zabbix-agent2:alpine-7.0-latest
    container_name: zbx-agent-docker
    environment:
      ZBX_PLUGINS: "docker"
    group_add:
      - "${DOCKER_GID}"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [backend]
    restart: unless-stopped

  grafana:
    image: grafana/grafana:11.6.0
    container_name: noc-grafana
    environment:
      GF_INSTALL_PLUGINS: alexanderzobnin-zabbix-app
    networks: [frontend, backend]
    restart: unless-stopped

  nginx-proxy:
    image: nginx:1.27-alpine
    container_name: nginx-proxy
    ports:
      - "443:443"
    networks: [frontend]
    restart: unless-stopped

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true
  dmz:
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.0.0/28
```

### 2.2 Segmentação de rede

Três redes Docker isoladas por função:

- **`backend`** (`internal: true`): Postgres, Zabbix server/web, agentes. Sem rota de saída à internet — isolamento real do banco de dados.
- **`frontend`**: nginx-proxy, Grafana, zabbix-web. Único segmento com saída à internet, porque precisa buscar plugins/atualizações.
- **`dmz`** (`172.30.0.0/28`, IPs estáticos): zabbix-server e zabbix-snmptraps, com egress restrito por regra de firewall dedicada (ver seção 3.3) — são os únicos componentes que recebem dado não confiável de origem externa.

**Achado de arquitetura relevante:** containers conectados **exclusivamente** a uma rede `internal: true` não recebem publicação de porta funcional no Docker — a regra de DNAT nunca é criada. Por isso `zabbix-server` e `zabbix-snmptraps`, que precisam publicar porta (10051 e 162), estão em rede dupla (`backend` + `dmz`), não só `backend`.

### 2.3 Egress restrito por IP estático (dmz)

Como a rede `dmz` não é `internal`, ela ganha rota de saída à internet — mas só o `zabbix-server` precisa disso de fato (webhook de alerta via Telegram, porta 443 apenas). O `zabbix-snmptraps` não precisa de nenhuma saída — só recebe trap e grava em volume compartilhado.

Regra aplicada via `nftables`, na chain `DOCKER-USER` (não na table `inet filter` própria — é onde o Docker injeta regras de NAT/forward via compatibilidade `iptables-nft`):

```bash
nft add rule ip filter DOCKER-USER ip saddr 172.30.0.10 ct state established,related accept
nft add rule ip filter DOCKER-USER ip saddr 172.30.0.10 udp dport 53 accept
nft add rule ip filter DOCKER-USER ip saddr 172.30.0.10 tcp dport 53 accept
nft add rule ip filter DOCKER-USER ip saddr 172.30.0.10 tcp dport 443 accept
nft add rule ip filter DOCKER-USER ip saddr 172.30.0.10 udp dport 161 accept
nft add rule ip filter DOCKER-USER ip saddr 172.30.0.10 drop

nft add rule ip filter DOCKER-USER ip saddr 172.30.0.11 ct state established,related accept
nft add rule ip filter DOCKER-USER ip saddr 172.30.0.11 drop
```

Porta 53 (DNS) liberada porque a resolução de nome de containers em rede bridge personalizada sai com o IP real do container como origem — diferente do pressuposto inicial de que o resolver embutido do Docker sempre mascara a origem.

### Registro MITRE ATT&CK — Egress restrito

| Controle | Técnica | Descrição |
|---|---|---|
| `zabbix-server` limitado a TCP 443 + DNS de saída | T1041 (Exfiltration Over C2 Channel) | Reduz canal de exfiltração em caso de comprometimento, mantendo só o necessário para alerta funcionar |
| `zabbix-snmptraps` sem saída nenhuma | T1041 | Container que só recebe dado externo não confiável, sem capacidade de "ligar pra casa" |

---

## 3. Firewall de host (nftables)

### 3.1 Estrutura idempotente

Nunca usar `flush ruleset` num script recarregado por timer — isso apaga **todas** as tables do kernel, inclusive as que o Docker gerencia via `iptables-nft` (NAT, DOCKER-USER), derrubando toda a stack de containers publicados. Usar o padrão de deletar e recriar só a própria table:

```nft
#!/usr/sbin/nft -f

table inet filter {
}
delete table inet filter

table inet filter {
    set mgmt_v4 {
        type ipv4_addr
        flags interval
        elements = { 198.51.100.10 }
    }

    chain input {
        type filter hook input priority 0; policy drop;

        ct state established,related accept
        iif lo accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        tcp dport 22 ip saddr @mgmt_v4 accept
        tcp dport 22 log prefix "NFT-DROP-SSH: " drop
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
    }
}
```

### 3.2 Allowlist dinâmica (DOCKER-USER)

Script executado via timer systemd a cada 5 minutos, resolve o hostname DDNS de gestão e popula um set nftables:

```bash
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
```

Regras aplicadas na `DOCKER-USER` (script separado, chamado em sequência pelo mesmo timer):

```bash
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
nft add rule $TABLE $CHAIN meta l4proto tcp th dport { 443, 80 } log prefix "NFT-DROP-WEB4: " drop
nft add rule $TABLE $CHAIN meta l4proto tcp th dport 10051 accept
nft add rule $TABLE $CHAIN meta l4proto udp th dport 162 accept
nft add rule $TABLE $CHAIN accept
```

**Nota de sintaxe:** usar `nft add rule` (acrescenta ao final), nunca `nft insert rule` (insere no início) quando o script depende de ordem sequencial de execução — `insert` inverte a ordem lógica das regras a cada chamada.

### 3.3 Systemd — unidades de automação

```ini
# nft-mgmt-set.service
[Unit]
Description=Popula set nftables mgmt_v4_docker e aplica regras em DOCKER-USER
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update-mgmt-set.sh
ExecStartPost=/usr/local/sbin/apply-docker-user-rules.sh
```

```ini
# nft-mgmt-set.timer
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

`After=docker.service` é obrigatório — sem isso, no primeiro boot da máquina o script roda antes do Docker existir, falha silenciosamente, e a stack fica sem allowlist até o próximo ciclo do timer.

---

## 4. Certificado TLS

Emissão via **DNS-01** (Let's Encrypt + Cloudflare API), nunca HTTP-01 — a porta 80 fica permanentemente fechada para a internet, sem exceção, então o desafio HTTP nunca completaria.

```bash
docker run --rm \
  -v "$(pwd)/certbot/conf:/etc/letsencrypt" \
  -v "$(pwd)/certbot/cloudflare.ini:/cloudflare.ini:ro" \
  certbot/dns-cloudflare certonly \
  --dns-cloudflare --dns-cloudflare-credentials /cloudflare.ini \
  --dns-cloudflare-propagation-seconds 30 \
  -d mon.exemplo.com.br -d painel.exemplo.com.br \
  --email contato@exemplo.com.br --agree-tos --non-interactive
```

Certificado com múltiplos domínios (SAN) é salvo num único diretório, nomeado pelo primeiro `-d` da lista — os dois vhosts nginx apontam para o mesmo caminho de certificado, isso é esperado, não é erro de configuração.

Renovação automatizada via timer mensal, chamando o mesmo comando com `renew` e recarregando o nginx depois.

### Pré-requisito frequentemente esquecido: DNS do Docker

Se o daemon Docker herdar resolver de loopback do host (`127.0.0.53`, típico com `systemd-resolved`), containers não resolvem DNS externo — a emissão de certificado falha com erro de conexão à API do Let's Encrypt. Corrigir fixando resolver explícito:

```json
// /etc/docker/daemon.json
{
  "dns": ["1.1.1.1", "8.8.8.8"]
}
```

---

## 5. Zabbix — configuração de monitoramento

### 5.1 Self-monitoring

Host padrão "Zabbix server" vem pré-configurado esperando agente em `127.0.0.1:10050` — nunca funciona em ambiente Docker, porque loopback do container zabbix-server é isolado. Corrigir a interface do host para apontar ao container do agente dedicado (`zbx-agent-self:10050`, resolução via DNS interno do Docker).

### 5.2 Monitoramento de host (disco/memória)

O container `zbx-agent-self` monta `/` do host em `/hostfs:ro` — sem isso, item de filesystem mede só a camada interna isolada do container, número sem relação com a partição real.

| Item | Key | Unidade |
|---|---|---|
| Espaço livre em disco | `vfs.fs.size[/hostfs,pfree]` | % |
| Memória disponível | `vm.memory.size[pavailable]` | % |

Memória não precisa de montagem extra — sem `mem_limit` definido no container, o agente já enxerga o total real de RAM do host via kernel compartilhado.

### 5.3 Descoberta automática de containers Docker

Container dedicado com plugin nativo do agent2:

```yaml
zabbix-agent-docker:
  environment:
    ZBX_PLUGINS: "docker"
  group_add:
    - "${DOCKER_GID}"
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro
```

Template **Docker by Zabbix agent 2**, LLD descobre todos os containers do host automaticamente — CPU, memória, status. Não requer cadastro manual por container.

**Registro MITRE ATT&CK:** socket montado somente leitura mitiga escrita/controle do daemon (T1611, Escape to Host), mas não elimina leitura de metadados sensíveis de outros containers via inspect. Risco residual aceito, validado por SOC antes de produção.

### 5.4 Usuário dedicado para integração (Grafana)

Nunca reutilizar credencial de Admin em integrações externas. Criar Role + User Group + Usuário dedicados:

**User Role** (`Grafana Integration`):
- User type: `User`
- Access to API: habilitado, allow list explícita com métodos de leitura apenas (`host.get`, `item.get`, `history.get`, `trigger.get`, `problem.get`, `event.get`, `usermacro.get`)
- Access to actions: tudo desmarcado — nenhuma ação de escrita, gestão de token, ou execução de script

**User Group**:
- Frontend access: `Disabled` — esse usuário nunca faz login por senha, só usa API Token
- Host permissions: só os grupos que o Grafana realmente consulta, nível `Read`

**API Token**: gerado com validade definida (não "nunca expira"), colado no datasource do Grafana.

---

## 6. Grafana — integração com Zabbix

Plugin `alexanderzobnin-zabbix-app` exige versão mínima específica do Grafana — checar compatibilidade antes de fixar a tag da imagem, incompatibilidade de versão gera erro de renderização no editor do datasource sem mensagem clara.

Datasource:
- URL: `http://zabbix-web:8080/api_jsonrpc.php` (HTTP interno, nome do container — nunca HTTPS aqui, não existe TLS nessa camada interna)
- Auth type: API Token
- Token: gerado pelo usuário dedicado da seção 5.4

---

## 7. Alertas — Telegram

Media type Webhook nativo do Zabbix 7.0. Campos obrigatórios: `api_token` (do bot, gerado via BotFather), `api_parse_mode` (`HTML`).

**Trigger action** com condição `Trigger severity >= Warning` (usar `>=`, nunca `equals` — isso restringiria a um único nível de severidade).

### Checklist de configuração do canal Telegram

1. Bot criado via `@BotFather`, token copiado
2. Se o destino for **grupo** (não chat individual), o `chat_id` tem formato negativo com prefixo `-100` para supergrupos — obtido via `getUpdates` da API do bot
3. Bot precisa ser promovido a **administrador** do grupo se a permissão padrão de envio de mensagem estiver restrita a admins
4. Teste manual pelo botão da interface do Zabbix **sempre falha** por natureza (macros `{EVENT.*}` não são resolvidas fora de um evento real) — validar via evento genuíno (força mudança de estado de um trigger de teste, ou usa evento real de disponibilidade)

### Verificação de expiração de certificado

Script cron diário, calcula dias restantes via `openssl` e envia como trapper item:

```bash
#!/bin/bash
set -euo pipefail

DOMAIN="mon.exemplo.com.br"
CERT_PATH="/opt/stack/certbot/conf/live/mon.exemplo.com.br/fullchain.pem"

EXPIRY_EPOCH=$(date -d "$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)" +%s)
DAYS_LEFT=$(( (EXPIRY_EPOCH - $(date +%s)) / 86400 ))

zabbix_sender -z 127.0.0.1 -s "Zabbix Server" -k cert.days.remaining -o "$DAYS_LEFT"
```

Item cadastrado como `Zabbix trapper` no host correspondente, trigger disparando abaixo de 15 dias, severidade `High`.

---

## 8. Endurecimento do sistema operacional

### Swap

VMs com múltiplos containers (8+) e RAM limitada precisam de rede de segurança contra OOM killer, mesmo sem uso constante esperado:

```bash
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

---

## 9. Troubleshooting — incidentes conhecidos e causa raiz

### 9.1 nginx-proxy em crash loop após reinício do Docker

**Causa Raiz:** `systemctl restart docker` reprograma as tables `iptables-nft` do zero (NAT, DOCKER-USER), mas containers já em execução não são recriados — mantêm configuração de rede antiga em memória, e a regra DNAT que os expunha ao host nunca é reemitida para eles especificamente.

**Ação Corretiva:** após qualquer restart do daemon Docker, forçar recriação dos containers publicados:
```bash
docker compose up -d --force-recreate
```
E reaplicar a allowlist do host:
```bash
systemctl start nft-mgmt-set.service
```

**Prevenção:** documentar esse passo como parte obrigatória de qualquer manutenção que envolva reiniciar o Docker.

### 9.2 Erro de certificado mesmo com arquivo existente

**Causa Raiz:** comandos `docker compose` executados a partir de diretório diferente daquele onde a stack foi originalmente implantada usam caminhos relativos de volume diferentes — o container acessa um volume vazio/inexistente com o mesmo nome, não o volume real com o certificado.

**Prevenção:** sempre `cd` para o diretório canônico da stack antes de qualquer comando `docker compose`. Nunca manter cópias duplicadas do projeto em diretórios diferentes do mesmo host.

### 9.3 Regra de firewall carregada na interface mas ausente do kernel

**Causa Raiz:** regras de NAT dual-stack (`IPv4+IPv6`) apontando para alvo que só existe numa família de endereço falham na compilação do `pf.conf` — a falha de uma única regra pode derrubar o carregamento do arquivo inteiro, sem mensagem de erro visível na interface web.

**Diagnóstico:** sempre validar carregamento direto no shell, nunca confiar apenas na interface:
```bash
pfctl -f /tmp/rules.debug
echo $status
```
Qualquer erro de compilação aparece na saída desse comando.

**Prevenção:** ao criar regra de NAT/filtro com múltiplas famílias de endereço, confirmar que o alvo (target/redirect) é compatível com ambas, ou separar em regras de versão única.

### 9.4 SYN chega na VM mas conexão nunca estabelece

**Sintoma:** `tcpdump` na interface da VM mostra o pacote SYN chegando corretamente, com retransmissões, mas a aplicação nunca responde — mesmo com o serviço confirmado saudável via teste local.

**Causa Raiz observada:** table `ip filter` (onde reside a chain `DOCKER-USER`) removida do kernel por reinício do daemon Docker sem reaplicação subsequente da allowlist — o caminho de encaminhamento (`forward`) para os containers publicados fica sem chain funcional, descartando pacotes silenciosamente antes de alcançar a aplicação.

**Diagnóstico:**
```bash
nft list chain ip filter DOCKER-USER
```
Erro `No such file or directory` confirma a table inteira ausente, não só a regra específica.

**Ação Corretiva:**
```bash
systemctl restart docker
sleep 5
/usr/local/sbin/update-mgmt-set.sh
/usr/local/sbin/apply-docker-user-rules.sh
```

---

## 10. Checklist de sign-off

- [ ] Containers todos `Up`, sem restart loop
- [ ] Certificado válido, emitido para ambos os domínios
- [ ] `nft list chain ip filter DOCKER-USER` mostra as regras completas, na ordem correta
- [ ] Teste de origem autorizada: acesso funcional
- [ ] Teste de origem não autorizada: timeout/recusa confirmado
- [ ] Timer de allowlist dinâmica validado após ciclo completo (5 min)
- [ ] Portas de agente/SNMP acessíveis de fora (teste com cliente real)
- [ ] Alerta de tentativa bloqueada em portas administrativas configurado e testado
- [ ] Alerta de expiração de certificado configurado e testado
- [ ] Alerta de disco/memória do host configurado
- [ ] Canal de notificação (Telegram) validado via evento real, não teste manual da interface
- [ ] Rastreabilidade MITRE ATT&CK revisada para cada controle de rede

---

## 11. Inventário de credenciais (referência — sem valores)

| Credencial | Escopo | Rotação recomendada |
|---|---|---|
| Senha admin Postgres | Acesso total ao banco | Anual ou por incidente |
| Senha admin Grafana | Acesso total ao painel | Anual ou por incidente |
| Senha admin Zabbix | Acesso total ao Zabbix | Anual ou por incidente |
| Token API Zabbix (integração Grafana) | Somente leitura, grupos específicos | Conforme validade definida no token |
| Token bot Telegram | Envio de mensagem no canal de alerta | Se vazamento suspeito |
| Token API Cloudflare (DNS) | Edição de DNS da zona | Anual ou por incidente |

Nenhuma dessas credenciais deve estar em texto plano em repositório de código — usar arquivo `.env` fora de controle de versão, ou cofre de segredos dedicado.
