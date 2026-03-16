'use strict';

/**
 * ⚠️  SRG VULNERABLE APP — Dynatrace Site Reliability Guardian Demo
 *
 * This application deliberately contains security vulnerabilities to demonstrate
 * how Dynatrace Application Security + SRG blocks unsafe deployments.
 *
 * Vulnerable packages loaded at runtime (detected by Dynatrace AppSec):
 *  - node-serialize@0.0.4   → CVE-2017-5941  (RCE, CVSS 9.8 CRITICAL)
 *  - ejs@3.1.6              → CVE-2022-29078 (RCE, CVSS 9.8 CRITICAL)
 *  - lodash@4.17.15         → CVE-2020-8203  (Prototype Pollution, CVSS 7.4)
 *  - axios@0.21.1           → CVE-2021-3749  (ReDoS, CVSS 7.5)
 *  - jsonwebtoken@8.5.1     → CVE-2022-23529 (Buffer Overflow, CVSS 6.4)
 *
 * DO NOT RUN IN PRODUCTION.
 */

const express    = require('express');
const mysql      = require('mysql2');
const lodash     = require('lodash');
const serialize  = require('node-serialize');
const jwt        = require('jsonwebtoken');
const path       = require('path');
const fs         = require('fs');
const { exec }   = require('child_process');
const axios      = require('axios');

const app  = express();
const PORT = process.env.PORT || 3000;

// ─── Middleware ───────────────────────────────────────────────────────────────
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

// ─── ⚠️ VULNERABILITY #1: Hardcoded Credentials ──────────────────────────────
const JWT_SECRET     = 'hardcoded-super-secret-key-12345';
const ADMIN_PASSWORD = 'admin123!';

// ─── Database Pool ────────────────────────────────────────────────────────────
const db = mysql.createPool({
  host:             process.env.DB_HOST     || 'mysql',
  user:             process.env.DB_USER     || 'root',
  password:         process.env.DB_PASSWORD || 'rootpassword',
  database:         process.env.DB_NAME     || 'vulndb',
  waitForConnections: true,
  connectionLimit:  10,
});

// ─── Home Page ────────────────────────────────────────────────────────────────
app.get('/', (_req, res) => {
  res.render('index');
});

// ─── ⚠️ VULNERABILITY #2: SQL Injection ──────────────────────────────────────
// PoC → username: ' OR '1'='1' --    password: anything
app.get('/login', (req, res) => {
  const { username, password } = req.query;
  if (!username || !password) {
    return res.render('login', { error: null, user: null, token: null });
  }

  // ❌ INSECURE: user input concatenated directly into SQL query
  const query = `SELECT * FROM users WHERE username='${username}' AND password='${password}'`;

  db.query(query, (err, results) => {
    if (err) {
      return res.render('login', { error: `DB Error: ${err.message}`, user: null, token: null });
    }
    if (results.length > 0) {
      const token = jwt.sign({ id: results[0].id, username }, JWT_SECRET, { expiresIn: '1h' });
      return res.render('login', { error: null, user: results[0], token });
    }
    return res.render('login', { error: 'Invalid credentials', user: null, token: null });
  });
});

app.post('/login', (req, res) => {
  const { username, password } = req.body;

  // ❌ INSECURE: SQL Injection via POST body
  const query = `SELECT * FROM users WHERE username='${username}' AND password='${password}'`;

  db.query(query, (err, results) => {
    if (err) {
      return res.render('login', { error: `DB Error: ${err.message}`, user: null, token: null });
    }
    if (results.length > 0) {
      const token = jwt.sign({ id: results[0].id, username }, JWT_SECRET, { expiresIn: '1h' });
      return res.render('login', { error: null, user: results[0], token });
    }
    return res.render('login', { error: 'Invalid credentials', user: null, token: null });
  });
});

// ─── ⚠️ VULNERABILITY #3: Reflected XSS ─────────────────────────────────────
// PoC → /search?q=<script>alert(document.cookie)</script>
app.get('/search', (req, res) => {
  const { q } = req.query;
  // ❌ INSECURE: raw (unescaped) output in EJS template via <%-
  res.render('search', { query: q || '' });
});

// ─── ⚠️ VULNERABILITY #4: Command Injection ──────────────────────────────────
// PoC → /ping?host=localhost; cat /etc/passwd
app.get('/ping', (req, res) => {
  const { host } = req.query;
  if (!host) return res.status(400).json({ error: 'host parameter required' });

  // ❌ INSECURE: user input injected directly into shell command
  exec(`ping -c 3 ${host}`, { timeout: 10000 }, (err, stdout, stderr) => {
    res.json({ command: `ping -c 3 ${host}`, output: stdout || stderr || err?.message });
  });
});

// ─── ⚠️ VULNERABILITY #5: Insecure Deserialization — CVE-2017-5941 ───────────
// Package: node-serialize@0.0.4  |  CVSS: 9.8 CRITICAL
// PoC payload: {"rce":"_$$ND_FUNC$$_function(){require('child_process').exec('id')}()"}
app.post('/api/profile', (req, res) => {
  const data = req.body.profile;
  if (!data) return res.status(400).json({ error: 'profile data required' });

  try {
    // ❌ INSECURE: node-serialize.unserialize() allows arbitrary code execution
    const profile = serialize.unserialize(data);
    res.json({ success: true, profile });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ─── ⚠️ VULNERABILITY #6: SSRF — CVE-2021-3749 (axios@0.21.1) ───────────────
// PoC → /api/fetch?url=http://169.254.169.254/latest/meta-data/
app.get('/api/fetch', async (req, res) => {
  const { url } = req.query;
  if (!url) return res.status(400).json({ error: 'url parameter required' });

  try {
    // ❌ INSECURE: no URL validation — allows access to internal services / cloud metadata
    const response = await axios.get(url);
    res.json({ content: response.data });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ─── ⚠️ VULNERABILITY #7: Path Traversal ─────────────────────────────────────
// PoC → /api/file?name=../../etc/passwd
app.get('/api/file', (req, res) => {
  const { name } = req.query;
  if (!name) return res.status(400).json({ error: 'name parameter required' });

  // ❌ INSECURE: no path sanitization; allows reading any file on the server
  const filePath = path.join(__dirname, 'data', name);

  try {
    const content = fs.readFileSync(filePath, 'utf-8');
    res.send(content);
  } catch (_e) {
    res.status(404).json({ error: 'File not found' });
  }
});

// ─── ⚠️ VULNERABILITY #8: Prototype Pollution — CVE-2020-8203 ────────────────
// Package: lodash@4.17.15  |  CVSS: 7.4 HIGH
// PoC body: {"__proto__": {"polluted": true}}
app.post('/api/merge', (req, res) => {
  const target = {};

  // ❌ INSECURE: lodash.merge with controlled user input allows prototype pollution
  lodash.merge(target, req.body);

  res.json({
    merged:            target,
    prototypePolluted: ({}).polluted === true,
  });
});

// ─── ⚠️ VULNERABILITY #9: JWT Algorithm Confusion — CVE-2022-23529 ───────────
// Package: jsonwebtoken@8.5.1  |  CVSS: 6.4
// PoC: send a token signed with "none" algorithm
app.get('/api/admin', (req, res) => {
  const token = req.headers.authorization?.replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'Token required' });

  try {
    // ❌ INSECURE: allows the "none" algorithm — unsigned tokens are accepted
    const decoded = jwt.verify(token, JWT_SECRET, { algorithms: ['HS256', 'none'] });
    res.json({ admin: true, user: decoded });
  } catch (e) {
    res.status(403).json({ error: 'Invalid token' });
  }
});

// ─── Vulnerability Reference ─────────────────────────────────────────────────
app.get('/vulnerabilities', (_req, res) => {
  res.json({
    total: 10,
    note: 'Dynatrace Application Security detects CVE-based vulnerabilities at runtime',
    vulnerabilities: [
      { id: 1,  severity: 'HIGH',     cve: null,            name: 'Hardcoded Credentials', endpoint: 'n/a' },
      { id: 2,  severity: 'CRITICAL', cve: null,            name: 'SQL Injection',          endpoint: 'GET /login?username=...&password=...' },
      { id: 3,  severity: 'HIGH',     cve: null,            name: 'Reflected XSS',          endpoint: 'GET /search?q=...' },
      { id: 4,  severity: 'CRITICAL', cve: null,            name: 'Command Injection',      endpoint: 'GET /ping?host=...' },
      { id: 5,  severity: 'CRITICAL', cve: 'CVE-2017-5941', name: 'Insecure Deserialization (node-serialize@0.0.4)', cvss: 9.8, endpoint: 'POST /api/profile' },
      { id: 6,  severity: 'HIGH',     cve: 'CVE-2021-3749', name: 'SSRF (axios@0.21.1)',   cvss: 7.5, endpoint: 'GET /api/fetch?url=...' },
      { id: 7,  severity: 'HIGH',     cve: null,            name: 'Path Traversal',         endpoint: 'GET /api/file?name=...' },
      { id: 8,  severity: 'HIGH',     cve: 'CVE-2020-8203', name: 'Prototype Pollution (lodash@4.17.15)', cvss: 7.4, endpoint: 'POST /api/merge' },
      { id: 9,  severity: 'HIGH',     cve: 'CVE-2022-23529', name: 'JWT Algorithm Confusion (jsonwebtoken@8.5.1)', cvss: 6.4, endpoint: 'GET /api/admin' },
      { id: 10, severity: 'CRITICAL', cve: 'CVE-2022-29078', name: 'Template Injection (ejs@3.1.6)', cvss: 9.8, endpoint: 'runtime' },
    ],
  });
});

// ─── Health Check ─────────────────────────────────────────────────────────────
app.get('/health', (_req, res) => {
  res.json({
    status:    'ok',
    app:       'srg-vulnerable-app',
    version:   process.env.APP_VERSION || '1.0.0',
    timestamp: new Date().toISOString(),
  });
});

// ─── Start ────────────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  console.log(`🚀 srg-vulnerable-app running on http://0.0.0.0:${PORT}`);
  console.log(`⚠️  Contains INTENTIONAL vulnerabilities — demo use only!`);
  console.log(`📋 /vulnerabilities  → full CVE list`);
  console.log(`❤️  /health          → health check`);
});

module.exports = app;
