# EdenCore Stacks

Coleção de stacks de infraestrutura prontas para deploy: monitoramento, automação, serviços internos. Cada stack vive na própria subpasta, é autocontida e pode ser clonada isoladamente.

Documentação técnica de cada stack fica na [wiki](https://wiki.edencore.com.br/), com link direto a partir do README de cada uma.

## Stacks disponíveis

| Stack | Descrição |
|---|---|
| [zabbix-grafana-opnsense](./zabbix-grafana-opnsense/) | Zabbix 7.0 + Grafana 11.6 containerizados, atrás de firewall OPNsense, sem serviço com IP público direto |

## Convenções

Cada stack segue a mesma estrutura interna:

- `docker-compose.yml` na raiz da subpasta
- `.env.example` com as variáveis necessárias, nunca valores reais
- `README.md` próprio, com pré-requisitos e passo a passo de deploy

Nenhuma stack publicada aqui contém domínio, IP ou credencial real. Sempre placeholder ou variável de ambiente, para que qualquer pessoa possa clonar e adaptar ao próprio ambiente sem risco de vazamento de dado.
