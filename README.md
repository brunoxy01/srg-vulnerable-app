# SRG Vulnerable App

> **⚠️ Aplicação intencionalmente vulnerável — apenas para demonstração.**

App Node.js com vulnerabilidades propositais que demonstra o **Dynatrace Site Reliability Guardian (SRG)** como **security gate no CI/CD** — bloqueando deploys quando o Application Security detecta CVEs em runtime.

---

## Arquitetura

```mermaid
flowchart LR
    B["build<br/><i>image → GHCR</i>"] --> SG["security-gate<br/><i>OneAgent + App + SRG</i>"]
    SG -- "CVEs detectados<br/>em runtime" --> DT["Dynatrace<br/><i>AppSec + Guardian</i>"]
    DT -- "PASS ✅ / FAIL ❌" --> SG

    style B fill:#2ea44f,color:#fff
    style SG fill:#d73a49,color:#fff
    style DT fill:#6f2da8,color:#fff
```

Pipeline roda 100% em `ubuntu-latest` (VM efêmera). O OneAgent instrumenta o Node.js no host, detecta os CVEs dos pacotes npm e o Guardian decide se o deploy passa ou não.

---

## Vulnerabilidades incluídas

### Pacotes npm com CVEs (detectados pelo OneAgent)

| Pacote | Versão | CVE | Severidade |
|--------|--------|-----|------------|
| `node-serialize` | 0.0.4 | CVE-2017-5941 | **CRITICAL** (9.8) — RCE via desserialização |
| `ejs` | 3.1.6 | CVE-2022-29078 | **CRITICAL** (9.8) — Template Injection |
| `lodash` | 4.17.15 | CVE-2020-8203 | **HIGH** (7.4) — Prototype Pollution |
| `axios` | 0.21.1 | CVE-2021-3749 | **HIGH** (7.5) — ReDoS / SSRF |
| `jsonwebtoken` | 8.5.1 | CVE-2022-23529 | **MEDIUM** (6.4) — Buffer Overflow |

### Vulnerabilidades no código

| Tipo | Endpoint |
|------|----------|
| SQL Injection | `POST /login` |
| Reflected XSS | `GET /search?q=` |
| Command Injection | `GET /ping?host=` |
| SSRF | `GET /api/fetch?url=` |
| Path Traversal | `GET /api/file?name=` |
| Prototype Pollution | `POST /api/merge` |
| Insecure Deserialization | `POST /api/profile` |

---

## Estrutura do projeto

```
├── app/
│   ├── server.js            # App vulnerável (Express)
│   ├── package.json         # Dependências com CVEs
│   ├── views/               # Templates EJS
│   └── data/sample.txt      # Alvo para Path Traversal
├── dynatrace/
│   ├── guardian.json         # Definição do Guardian
│   └── workflow.json         # Template do Workflow
├── scripts/
│   ├── setup_dynatrace.sh   # Cria Guardian + Workflow (executar 1x)
│   ├── trigger_validation.sh # Dispara o Workflow
│   └── check_validation.sh  # Poll do resultado
├── .github/workflows/
│   └── deploy.yml           # Pipeline CI/CD
├── docker-compose.yml       # Stack local (app + mysql)
├── Dockerfile               # Build da imagem
├── init.sql                 # Seed do banco MySQL
└── README.md
```

---

## Setup

### 1. Rodar localmente

```bash
git clone https://github.com/brunoxy01/srg-vulnerable-app.git
cd srg-vulnerable-app
cp .env.example .env
docker compose up -d
```

Acesse http://localhost:3000

### 2. Configurar Dynatrace

Crie um **OAuth2 Client** em [Account Management](https://myaccount.dynatrace.com/iam/oauth-clients) com os scopes:

```
automation:workflows:read, write, run
srg:guardians:read, write
security:findings:read
```

Execute o setup (cria Guardian + Workflow):

```bash
./scripts/setup_dynatrace.sh
```

### 3. Configurar GitHub Secrets

| Secret | Descrição |
|--------|-----------|
| `DOCKER_USERNAME` | Username GitHub |
| `DOCKER_PASSWORD` | PAT com `write:packages` |
| `DT_API_TOKEN` | Token com escopo `InstallerDownload` |
| `DT_CLIENT_ID` | OAuth2 Client ID |
| `DT_CLIENT_SECRET` | OAuth2 Client Secret |
| `DT_WORKFLOW_ID` | ID do Workflow (saída do setup) |

### 4. Push e ver o bloqueio

```bash
git push origin main
# Actions: build ✅ → security-gate ❌ BLOCKED
```

---

## Como corrigir (desbloquear)

Atualize os pacotes em `app/package.json`:

```json
"ejs":            "3.1.10",
"lodash":         "4.17.21",
"axios":          "1.7.9",
"jsonwebtoken":   "9.0.2"
```

Remova `node-serialize` e substitua por `JSON.parse`/`JSON.stringify`.

```bash
git commit -am "fix: upgrade vulnerable dependencies"
git push origin main
# Actions: build ✅ → security-gate ✅ PASSED
```
