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

## Step 3 — Create the Dynatrace OAuth2 Client

The scripts need an OAuth2 client to authenticate with the Dynatrace APIs.

1. Open: <https://fov31014.apps.dynatrace.com/ui/apps/dynatrace.classic.settings/settings/oauth-client-management>
2. Click **Create client**.
3. Name: `srg-security-gate`
4. Enable these **scopes**:
   - `automation:workflows:read`
   - `automation:workflows:write`
   - `automation:workflows:run`
   - `srg:guardians:read`
   - `srg:guardians:write`
   - `security:findings:read`
   - `openpipeline:events:ingest`
5. Save and copy the **Client ID** and **Client Secret**.
6. Add them to your `.env` file:
   ```
   DT_CLIENT_ID=dt0s02.XXXXXXXXX
   DT_CLIENT_SECRET=dt0s02.XXXXXXXXX.XXXXXXXX
   ```

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

## Step 5 — Configure GitHub Actions Secrets

Go to your GitHub repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Description |
|--------|-------------|
| `DOCKER_USERNAME` | Your GitHub username (`brunoxy01`) |
| `DOCKER_PASSWORD` | GitHub PAT with `write:packages` scope |
| `DEPLOY_HOST` | SSH IP/hostname of your server |
| `DEPLOY_USER` | SSH username on that server |
| `DEPLOY_SSH_KEY` | Full PEM content of your SSH private key |
| `DT_CLIENT_ID` | From Step 3 |
| `DT_CLIENT_SECRET` | From Step 3 |
| `DT_WORKFLOW_ID` | From Step 4 output |

> **No remote server yet?** You can test the SRG scripts locally without SSH:
> ```bash
> export DT_CLIENT_ID=...
> export DT_CLIENT_SECRET=...
> export DT_WORKFLOW_ID=...
> export DT_TENANT_URL=https://fov31014.apps.dynatrace.com
>
> ./scripts/trigger_validation.sh
> ./scripts/check_validation.sh
> ```

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
