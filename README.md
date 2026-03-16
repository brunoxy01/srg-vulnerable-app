# SRG Vulnerable App — Dynatrace Security Gate Demo

> **⚠️ FOR DEMO PURPOSES ONLY. Do not deploy to production.**

A deliberately vulnerable Node.js application used to demonstrate how
[Dynatrace Site Reliability Guardian (SRG)](https://docs.dynatrace.com/docs/deliver/site-reliability-guardian)
automatically **blocks CI/CD deployments** when Dynatrace Application Security detects
critical or high-severity vulnerabilities at runtime.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          GitHub Actions CI/CD                            │
│                                                                          │
│  push/PR ──► build ──► deploy ──► 🔴 SRG Security Gate ──► (blocked!)  │
│                         │                      │                         │
│             (docker     │          trigger + poll SRG validation        │
│              compose)   │          fail pipeline if vulns found         │
└─────────────────────────┼──────────────────────────────────────────────-┘
                          ▼
            ┌─────────────────────────┐
            │  Server / Docker Host   │
            │  (OneAgent installed)   │
            │  ┌─────────────────┐   │
            │  │ vulnerable-app  │   │  ◄── OneAgent scans Node.js process
            │  │  (Node.js)      │   │       and detects CVEs at runtime
            │  └─────────────────┘   │
            │  ┌─────────────────┐   │
            │  │     MySQL       │   │
            │  └─────────────────┘   │
            └─────────────────────────┘
                          │
                          ▼
            ┌─────────────────────────────────┐
            │   Dynatrace                     │
            │   fov31014.apps.dynatrace.com   │
            │                                 │
            │  Application Security           │
            │    → detects CVE-2017-5941      │
            │    → detects CVE-2022-29078     │
            │    → detects CVE-2020-8203 …    │
            │                                 │
            │  Site Reliability Guardian      │
            │    Objective: 0 critical vulns  │
            │    Result:    ❌ FAIL → block!  │
            └─────────────────────────────────┘
```

---

## Vulnerabilities Included

| # | Vulnerability | Package | CVE | CVSS |
|---|--------------|---------|-----|------|
| 1 | Hardcoded Credentials | (code) | — | — |
| 2 | SQL Injection | (code) | — | CRITICAL |
| 3 | Reflected XSS | (code) | — | HIGH |
| 4 | Command Injection | (code) | — | CRITICAL |
| 5 | Insecure Deserialization / **RCE** | `node-serialize@0.0.4` | **CVE-2017-5941** | **9.8** |
| 6 | SSRF | `axios@0.21.1` | **CVE-2021-3749** | 7.5 |
| 7 | Path Traversal | (code) | — | HIGH |
| 8 | Prototype Pollution | `lodash@4.17.15` | **CVE-2020-8203** | 7.4 |
| 9 | JWT Algorithm Confusion | `jsonwebtoken@8.5.1` | **CVE-2022-23529** | 6.4 |
| 10 | Template Injection / **RCE** | `ejs@3.1.6` | **CVE-2022-29078** | **9.8** |

Dynatrace Application Security detects **CVEs 5, 6, 8, 9, 10** (the library-based ones)
at runtime the moment the Node.js process starts. The SRG Guardian objective
"No Critical Vulnerabilities" immediately fails on `node-serialize` and `ejs`.

---

## Prerequisites

| Tool | Version |
|------|---------|
| Docker + Docker Compose | v2+ |
| Git | any |
| Dynatrace account | [fov31014.apps.dynatrace.com](https://fov31014.apps.dynatrace.com) |
| Dynatrace OneAgent | installed on your Docker host |
| GitHub account | for CI/CD |

---

## Step 1 — Clone & Run Locally

```bash
git clone https://github.com/brunoxy01/srg-vulnerable-app.git
cd srg-vulnerable-app

cp .env.example .env        # edit if you want custom passwords

docker compose up -d        # starts vulnerable-app + mysql
```

Open <http://localhost:3000> to see the demo.

```bash
# Health check
curl http://localhost:3000/health

# Full vulnerability list (JSON)
curl http://localhost:3000/vulnerabilities
```

---

## Step 2 — Install Dynatrace OneAgent on the Docker Host

OneAgent must run on the **host** machine (not inside the container).
It automatically discovers Docker containers and scans Node.js processes for CVEs.

1. Open: <https://fov31014.apps.dynatrace.com/ui/hub/ext/dynatrace.linux.oneagent>
2. Follow the Linux installer instructions (copy & run the `wget` command).
3. Verify the agent is running:
   ```bash
   systemctl status dynatrace-oneagent
   ```
4. In the Dynatrace UI, go to **Infrastructure → Hosts** and confirm your host appears.
5. After starting `docker compose up`, go to **Application Security → Vulnerabilities** —
   within 2–5 minutes the CVEs from `node-serialize`, `ejs`, `lodash`, and `axios`
   will appear automatically.

---

## Step 3 — Criar o OAuth2 Client no Dynatrace

No **novo Dynatrace Platform** (SaaS Gen 3), os OAuth clients ficam no **Account Management** — fora da tenant, no portal de conta.

1. Acesse o **Account Management**:
   <https://myaccount.dynatrace.com/iam/oauth-clients>
   *(login com a mesma conta da sua tenant)*

2. Clique em **Create client**.

3. Preencha:
   - **Name:** `srg-security-gate`
   - **Account:** selecione sua conta

4. Ative os **scopes** (permissões):
   - `automation:workflows:read`
   - `automation:workflows:write`
   - `automation:workflows:run`
   - `srg:guardians:read`
   - `srg:guardians:write`
   - `security:findings:read`
   - `openpipeline:events:ingest`

5. Clique em **Save**. O Dynatrace exibe o **Client ID** e **Client Secret** uma única vez — copie os dois imediatamente.

   > O Client ID começa com `dt0s02.` e o Secret tem o formato `dt0s02.XXXX.XXXX`.

6. Adicione ao seu `.env`:
   ```
   DT_CLIENT_ID=dt0s02.XXXXXXXXX
   DT_CLIENT_SECRET=dt0s02.XXXXXXXXX.XXXXXXXX
   ```

> **Alternativa:** em algumas tenants você encontra os OAuth clients em **Settings → Connections → OAuth clients** dentro da própria tenant. Se não aparecer, use o Account Management acima.

---

## Step 4 — Create the SRG Guardian & Automation Workflow

Run the setup script **once**. It creates the Guardian and Workflow in your Dynatrace
tenant and prints the IDs needed as GitHub secrets.

```bash
chmod +x scripts/setup_dynatrace.sh
./scripts/setup_dynatrace.sh
```

Expected output:
```
✅ Authenticated
✅ Guardian created — ID: abc123...
✅ Workflow created — ID: def456...

Add these secrets to your GitHub repository:
  DT_CLIENT_ID     = dt0s02.XXXXXXX
  DT_CLIENT_SECRET = <your secret>
  DT_TENANT_URL    = https://fov31014.apps.dynatrace.com
  DT_WORKFLOW_ID   = def456...
  DT_GUARDIAN_ID   = abc123...
```

Verify in the UI:

- **Guardian**: <https://fov31014.apps.dynatrace.com/ui/apps/dynatrace.site.reliability.guardian>
- **Workflow**: <https://fov31014.apps.dynatrace.com/ui/apps/dynatrace.automations>

### What the Guardian checks

| Objective | DQL | Pass condition |
|-----------|-----|----------------|
| No Critical Vulnerabilities | `fetch security_problems \| filter status == "OPEN" and riskLevel == "CRITICAL" \| count` | count ≤ 0 |
| High Vulnerabilities < 3 | `fetch security_problems \| filter status == "OPEN" and riskLevel == "HIGH" \| count` | count ≤ 2 (warn at 1) |

---

## Step 5 — Configurar os GitHub Actions Secrets

O pipeline roda **100% no cloud do GitHub** (`ubuntu-latest`) — sem servidor fixo, sem self-hosted runner, sem SSH.

### Como funciona

```
[ubuntu-latest — VM Linux efêmera do GitHub]              [Dynatrace]

job: build              job: security-gate
────────────       ──────────────────────────────────────────────────
build image    →   ① instala OneAgent na VM do runner
push GHCR          ② docker compose up (sobe app vulnerável)
                   ③ aguarda AppSec detectar CVEs (~8 min)
                   ④ dispara SRG Workflow
                   ⑤ polling do resultado → exit 1 = BLOQUEADO
                   ⑥ docker compose down  (VM é descartada)
```

O runner `ubuntu-latest` é uma VM Linux completa. O OneAgent é instalado nela durante o pipeline, monitora o processo Node.js em tempo real e o Application Security detecta os CVEs dos pacotes vulneráveis. Quando o job termina, a VM é descartada pelo GitHub automaticamente.

### Secrets necessários (apenas 6 — sem SSH, sem servidor fixo)

GitHub → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Como obter |
|--------|------------|
| `DOCKER_USERNAME` | Seu username do GitHub: `brunoxy01` |
| `DOCKER_PASSWORD` | GitHub → Settings → Developer settings → **Personal access tokens** → escopo `write:packages` |
| `DT_API_TOKEN` | Dynatrace → **Access tokens** → Generate new token → escopo `InstallerDownload` *(ver abaixo)* |
| `DT_CLIENT_ID` | Account Management → OAuth clients (Step 3) |
| `DT_CLIENT_SECRET` | Account Management → OAuth clients (Step 3) |
| `DT_WORKFLOW_ID` | Saída do `./scripts/setup_dynatrace.sh` (Step 4) |

### Como criar o DT_API_TOKEN (token para baixar o OneAgent)

Esse token é diferente do OAuth2 — é um token clássico da tenant usado para fazer download do instalador do OneAgent.

1. Acesse: <https://fov31014.apps.dynatrace.com/ui/apps/dynatrace.classic.tokens>
2. Clique em **Generate new token**
3. Nome: `oneagent-installer`
4. Escopo: ✅ `InstallerDownload`
5. Clique em **Generate token** e copie o valor (começa com `dt0c01.`)

---

## Step 6 — Push to GitHub and Watch the Pipeline Fail

```bash
git add .
git commit -m "feat: add vulnerable app for SRG demo"
git push origin main
```

Go to the **Actions** tab in GitHub. The pipeline runs three jobs:

```
build ✅  →  deploy ✅  →  security-gate ❌  BLOCKED
```

The `security-gate` job output:
```
❌  SRG VALIDATION FAILED — DEPLOYMENT BLOCKED
⛔  Dynatrace Application Security detected vulnerabilities!
  Objectives:  0 passed  |  1 failed  |  0 warnings

  Review vulnerabilities:
    https://fov31014.apps.dynatrace.com/ui/apps/dynatrace.classic.security.overview
```

---

## Step 7 — Fix the Vulnerabilities (Make the Gate Pass)

Create a fix branch that upgrades the vulnerable packages:

```bash
git checkout -b fix/upgrade-vulnerable-packages
```

Edit `app/package.json` — replace the vulnerable versions:

```json
"ejs":            "3.1.6"   →  "3.1.10"
"lodash":         "4.17.15" →  "4.17.21"
"axios":          "0.21.1"  →  "1.7.9"
"node-serialize": "0.0.4"   →  remove (replace with JSON.parse/stringify)
"jsonwebtoken":   "8.5.1"   →  "9.0.2"
```

```bash
git add app/package.json
git commit -m "fix: upgrade vulnerable dependencies"
git push origin fix/upgrade-vulnerable-packages
```

Open a PR → merge to `main` → the pipeline now passes:

```
build ✅  →  deploy ✅  →  security-gate ✅  PASSED
```

---

## File Structure

```
srg-vulnerable-app/
├── app/
│   ├── server.js            # Node.js app with intentional vulnerabilities
│   ├── package.json         # Deps with known CVEs (node-serialize, ejs, lodash …)
│   ├── views/
│   │   ├── index.ejs        # Home page with vulnerability demo links
│   │   ├── login.ejs        # SQL injection demo
│   │   └── search.ejs       # Reflected XSS demo
│   └── data/
│       └── sample.txt       # Path traversal demo target
├── init.sql                 # MySQL seed data
├── Dockerfile               # node:18-alpine (OneAgent runs on host, not inside)
├── docker-compose.yml       # vulnerable-app + mysql
├── .env.example             # Environment variable template
├── .gitignore
├── .github/
│   └── workflows/
│       └── deploy.yml       # Build → Deploy → SRG Security Gate
├── dynatrace/
│   ├── guardian.json        # SRG Guardian definition (security objectives)
│   └── workflow.json        # Dynatrace Automation Workflow template
├── scripts/
│   ├── setup_dynatrace.sh   # Creates Guardian + Workflow via API (run once)
│   ├── trigger_validation.sh # Triggers SRG workflow execution
│   └── check_validation.sh  # Polls result — exits 1 if vulnerabilities found
└── README.md
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `❌ Authentication failed` | Verify `DT_CLIENT_ID` / `DT_CLIENT_SECRET` in `.env`. Check the OAuth scopes listed in Step 3. |
| Vulnerabilities not appearing in Dynatrace | Ensure OneAgent is installed **on the Docker host** and the app is running (`docker compose ps`). Wait 2–5 minutes. |
| `❌ Could not extract validation_status` | The workflow may not have a `run_validation` task. Re-run `setup_dynatrace.sh`. |
| Guardian always passes even with vulns | Application Security may be disabled. Enable at: Settings → Application Security → Vulnerability Analytics. |
| `invalid_scope` error on token request | Recreate the OAuth client and add all scopes listed in Step 3. |

---

## References

- [Dynatrace Site Reliability Guardian](https://docs.dynatrace.com/docs/deliver/site-reliability-guardian)
- [Dynatrace Application Security](https://docs.dynatrace.com/docs/protect/application-security)
- [Dynatrace Automation Workflows](https://docs.dynatrace.com/docs/deliver/dynatrace-workflows)
- [CVE-2017-5941 — node-serialize RCE](https://nvd.nist.gov/vuln/detail/CVE-2017-5941)
- [CVE-2022-29078 — ejs Template Injection](https://nvd.nist.gov/vuln/detail/CVE-2022-29078)
- [CVE-2020-8203 — lodash Prototype Pollution](https://nvd.nist.gov/vuln/detail/CVE-2020-8203)
