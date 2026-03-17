# SRG Vulnerable App — Dynatrace Security Gate Demo

> **⚠️ APLICAÇÃO INTENCIONALMENTE VULNERÁVEL — apenas para demonstração. Não utilize em produção.**

## O que é este projeto?

Uma aplicação **Node.js propositalmente vulnerável** que demonstra como o
[Dynatrace Site Reliability Guardian (SRG)](https://docs.dynatrace.com/docs/deliver/site-reliability-guardian)
pode atuar como **security gate no CI/CD**, **bloqueando deployments automaticamente**
quando o [Dynatrace Application Security](https://docs.dynatrace.com/docs/protect/application-security)
detecta vulnerabilidades de alta severidade em runtime.

### Conceito

O pipeline faz *push* → *build* → *deploy temporário* → **SRG avalia** → bloqueia ou aprova.  
O OneAgent instrumenta o processo Node.js em tempo real, detecta os CVEs dos pacotes npm
e o Guardian decide se o deploy passa ou não — tudo **automatizado, sem intervenção humana**.

---

## Arquitetura

```
  GitHub Actions (ubuntu-latest)                      Dynatrace
 ┌──────────────────────────────────────┐     ┌──────────────────────────────┐
 │                                      │     │                              │
 │  ┌──────────┐    ┌────────────────┐  │     │  Application Security        │
 │  │ job:     │    │ job:           │  │     │   ↳ OneAgent detecta CVEs    │
 │  │ build    │───►│ security-gate  │──┼────►│     dos pacotes npm em       │
 │  │          │    │                │  │     │     runtime                  │
 │  │ build +  │    │ ① OneAgent     │  │     │                              │
 │  │ push     │    │ ② MySQL docker │  │     │  Site Reliability Guardian   │
 │  │ GHCR     │    │ ③ Node.js host │  │     │   ↳ Avalia security_events  │
 │  │          │    │ ④ Espera 5min  │  │     │     via DQL                 │
 │  │          │    │ ⑤ Trigger SRG  │  │     │   ↳ HIGH vulns > limite?    │
 │  │          │    │ ⑥ Poll result  │  │     │     → ❌ FAIL → exit 1      │
 │  └──────────┘    └────────────────┘  │     │     → ✅ PASS → exit 0      │
 │                                      │     │                              │
 └──────────────────────────────────────┘     └──────────────────────────────┘
           VM efêmera — descartada                   fov31014.apps
           após o pipeline terminar                  .dynatrace.com
```

**Pontos-chave:**
- **100% cloud** — roda em `ubuntu-latest` do GitHub, sem servidor fixo, sem self-hosted runner
- **Node.js no host** (não dentro de Docker) para que o OneAgent instrumente o processo e detecte os CVEs via Runtime Vulnerability Detection
- **MySQL em Docker** — dependência da app (SQL injection demo)
- **VM descartada** — quando o pipeline termina, o runner é destruído

---

## Vulnerabilidades incluídas

A aplicação inclui **vulnerabilidades no código** e **pacotes npm com CVEs conhecidos**:

### Pacotes npm vulneráveis (detectados pelo OneAgent)

| Pacote | Versão | CVE | Severidade | Descrição |
|--------|--------|-----|------------|-----------|
| `node-serialize` | 0.0.4 | CVE-2017-5941 | **CRITICAL** (9.8) | Insecure Deserialization → RCE |
| `ejs` | 3.1.6 | CVE-2022-29078 | **CRITICAL** (9.8) | Template Injection → RCE |
| `lodash` | 4.17.15 | CVE-2020-8203 | **HIGH** (7.4) | Prototype Pollution |
| `axios` | 0.21.1 | CVE-2021-3749 | **HIGH** (7.5) | ReDoS / SSRF |
| `jsonwebtoken` | 8.5.1 | CVE-2022-23529 | **MEDIUM** (6.4) | Algorithm confusion |

### Vulnerabilidades no código-fonte

| Tipo | Endpoint | Descrição |
|------|----------|-----------|
| SQL Injection | `POST /login` | Concatenação direta de input no SQL |
| Reflected XSS | `GET /search?q=` | Input refletido sem sanitização |
| Command Injection | `GET /ping?host=` | Execução de comando sem validação |
| SSRF | `GET /api/fetch?url=` | Fetch de URL arbitrária |
| Path Traversal | `GET /api/file?name=` | Acesso a arquivos fora do diretório |
| Prototype Pollution | `POST /api/merge` | Merge profundo sem proteção |
| Insecure Deserialization | `POST /api/profile` | `node-serialize.unserialize()` |
| Hardcoded Credentials | `server.js` | Credenciais no código |

---

## Como o SRG Security Gate funciona

```
 Pacotes npm vulneráveis          Dynatrace Application Security         SRG Guardian
 (node-serialize, ejs, ...)  →    OneAgent detecta em runtime      →     Avalia via DQL
                                  e reporta como Security Problems       e bloqueia pipeline
```

1. O **OneAgent** é instalado no runner e instrumenta o processo Node.js
2. O **Application Security** detecta os CVEs dos pacotes npm carregados em runtime
3. O **Automation Workflow** é disparado via API OAuth2
4. O **Site Reliability Guardian** executa uma query DQL que conta as vulnerabilidades HIGH abertas
5. Se o resultado exceder o limite configurado → **FAIL** → pipeline bloqueada (`exit 1`)

### Objetivo do Guardian

| Objetivo | Query DQL | Condição de falha |
|----------|-----------|-------------------|
| Vulnerabilidades HIGH detectadas | `fetch security.events \| filter vulnerability.risk.level == "HIGH" AND vulnerability.resolution.status == "OPEN" \| summarize count` | count > 1 |

> O Dynatrace usa o **Davis Security Score** (não o CVSS bruto) que considera reachability,
> disponibilidade de exploit e exposição do asset.

---

## Estrutura do projeto

```
srg-vulnerable-app/
├── app/
│   ├── server.js              # App Node.js com vulnerabilidades intencionais
│   ├── package.json           # Dependências com CVEs conhecidos
│   ├── views/
│   │   ├── index.ejs          # Página inicial com links para demos
│   │   ├── login.ejs          # Demo de SQL Injection
│   │   └── search.ejs         # Demo de Reflected XSS
│   └── data/
│       └── sample.txt         # Arquivo-alvo para Path Traversal
├── init.sql                   # Seed do banco MySQL
├── Dockerfile                 # node:18-alpine para build da imagem
├── docker-compose.yml         # Stack local (app + mysql)
├── .env.example               # Template de variáveis de ambiente
├── .github/
│   └── workflows/
│       └── deploy.yml         # Pipeline: Build → Deploy → SRG Gate
├── dynatrace/
│   ├── guardian.json          # Definição do Guardian (objetivos de segurança)
│   └── workflow.json          # Template do Automation Workflow
├── scripts/
│   ├── setup_dynatrace.sh     # Cria Guardian + Workflow via API (executar 1x)
│   ├── create_workflow.sh     # Cria apenas o Workflow via API
│   ├── trigger_validation.sh  # Dispara execução do Workflow
│   └── check_validation.sh   # Poll do resultado — exit 1 se vulnerável
└── README.md
```

---

## Pré-requisitos

| Ferramenta | Versão | Para quê |
|------------|--------|----------|
| Git | qualquer | Clonar o repositório |
| Docker + Docker Compose | v2+ | Rodar localmente |
| Conta GitHub | — | CI/CD pipeline |
| Conta Dynatrace SaaS | Gen 3 (Platform) | Application Security + SRG |

---

## Setup rápido

### 1. Clonar e rodar localmente

```bash
git clone https://github.com/brunoxy01/srg-vulnerable-app.git
cd srg-vulnerable-app
cp .env.example .env
docker compose up -d
```

Acesse http://localhost:3000 — a aplicação está rodando.

```bash
curl http://localhost:3000/health           # Health check
curl http://localhost:3000/vulnerabilities  # Lista de vulns (JSON)
```

### 2. Criar OAuth2 Client no Dynatrace

Acesse o **Account Management**: https://myaccount.dynatrace.com/iam/oauth-clients

Crie um client com os scopes:
- `automation:workflows:read`
- `automation:workflows:write`
- `automation:workflows:run`
- `srg:guardians:read`
- `srg:guardians:write`
- `security:findings:read`

> O Client ID começa com `dt0s02.` e o Secret tem o formato `dt0s02.XXXX.XXXX`.

### 3. Criar o Guardian e Workflow

```bash
chmod +x scripts/setup_dynatrace.sh
./scripts/setup_dynatrace.sh
```

Isso cria o Guardian e o Automation Workflow na tenant e imprime os IDs.

### 4. Configurar GitHub Secrets

GitHub → **Settings → Secrets and variables → Actions**:

| Secret | Descrição |
|--------|-----------|
| `DOCKER_USERNAME` | Username do GitHub (ex: `brunoxy01`) |
| `DOCKER_PASSWORD` | GitHub PAT com escopo `write:packages` |
| `DT_API_TOKEN` | Token clássico Dynatrace com escopo `InstallerDownload` |
| `DT_CLIENT_ID` | OAuth2 Client ID (`dt0s02.XXXX`) |
| `DT_CLIENT_SECRET` | OAuth2 Client Secret |
| `DT_WORKFLOW_ID` | ID do Workflow (saída do `setup_dynatrace.sh`) |

### 5. Push e ver o pipeline ser bloqueado

```bash
git push origin main
```

Na aba **Actions** do GitHub:

```
build ✅  →  security-gate ❌  BLOCKED
```

O SRG detecta as vulnerabilidades HIGH e bloqueia o deploy automaticamente.

---

## Como corrigir (desbloquear o pipeline)

Atualize os pacotes vulneráveis em `app/package.json`:

```json
"ejs":            "3.1.10"    // era 3.1.6
"lodash":         "4.17.21"   // era 4.17.15
"axios":          "1.7.9"     // era 0.21.1
"node-serialize": remover     // substituir por JSON.parse/stringify
"jsonwebtoken":   "9.0.2"     // era 8.5.1
```

```bash
git commit -am "fix: upgrade vulnerable dependencies"
git push origin main
```

O pipeline agora passa:

```
build ✅  →  security-gate ✅  PASSED
```

---

## Troubleshooting

| Sintoma | Solução |
|---------|---------|
| `Authentication failed` | Verifique `DT_CLIENT_ID` / `DT_CLIENT_SECRET`. Recrie o OAuth client com os scopes listados acima. |
| Vulnerabilidades não aparecem | O OneAgent precisa de até 5 minutos para detectar os CVEs. Verifique se a app está rodando e os endpoints foram acessados. |
| `Could not extract validation_status` | O Workflow pode não ter a task `run_validation`. Execute `setup_dynatrace.sh` novamente. |
| Guardian sempre passa | O Application Security pode estar desativado. Ative em: Settings → Application Security → Vulnerability Analytics. |
| `invalid_scope` no token | Recrie o OAuth client com todos os scopes listados na seção 2. |

---

## Tecnologias utilizadas

| Tecnologia | Uso |
|------------|-----|
| [Node.js](https://nodejs.org/) + [Express](https://expressjs.com/) | Aplicação web vulnerável |
| [MySQL 8](https://www.mysql.com/) | Banco de dados (SQL injection demo) |
| [Docker](https://www.docker.com/) | Containerização e build |
| [GitHub Actions](https://github.com/features/actions) | CI/CD pipeline |
| [Dynatrace OneAgent](https://docs.dynatrace.com/docs/setup-and-configuration/dynatrace-oneagent) | Instrumentação e monitoramento em runtime |
| [Dynatrace Application Security](https://docs.dynatrace.com/docs/protect/application-security) | Detecção de vulnerabilidades em runtime |
| [Dynatrace Site Reliability Guardian](https://docs.dynatrace.com/docs/deliver/site-reliability-guardian) | Security gate — avaliação automatizada |
| [Dynatrace Automation Workflows](https://docs.dynatrace.com/docs/deliver/dynatrace-workflows) | Orquestração da validação SRG |

---

## Referências e links úteis

### Documentação Dynatrace
- [Site Reliability Guardian — Overview](https://docs.dynatrace.com/docs/deliver/site-reliability-guardian)
- [Site Reliability Guardian — Create a guardian](https://docs.dynatrace.com/docs/deliver/site-reliability-guardian/how-to/create-guardian)
- [Application Security — Overview](https://docs.dynatrace.com/docs/protect/application-security)
- [Application Security — Vulnerability Analytics](https://docs.dynatrace.com/docs/protect/application-security/vulnerability-analytics)
- [Davis Security Score](https://docs.dynatrace.com/docs/protect/application-security/vulnerability-analytics/davis-security-score)
- [Automation Workflows](https://docs.dynatrace.com/docs/deliver/dynatrace-workflows)
- [OneAgent — Setup](https://docs.dynatrace.com/docs/setup-and-configuration/dynatrace-oneagent)
- [OAuth2 Client Credentials](https://docs.dynatrace.com/docs/manage/identity-access-management/access-tokens-and-oauth-clients/oauth-clients)

### Repositório
- **GitHub**: https://github.com/brunoxy01/srg-vulnerable-app
- **Container Registry**: `ghcr.io/brunoxy01/srg-vulnerable-app`

### CVEs utilizados neste demo
- [CVE-2017-5941](https://nvd.nist.gov/vuln/detail/CVE-2017-5941) — node-serialize Remote Code Execution
- [CVE-2022-29078](https://nvd.nist.gov/vuln/detail/CVE-2022-29078) — ejs Template Injection
- [CVE-2020-8203](https://nvd.nist.gov/vuln/detail/CVE-2020-8203) — lodash Prototype Pollution
- [CVE-2021-3749](https://nvd.nist.gov/vuln/detail/CVE-2021-3749) — axios ReDoS
- [CVE-2022-23529](https://nvd.nist.gov/vuln/detail/CVE-2022-23529) — jsonwebtoken Algorithm Confusion

---

## Licença

Este projeto é apenas para fins de demonstração e educação. Não possui licença para uso em produção.
