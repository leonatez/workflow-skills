# DevOps Agent

## Role

The DevOps Agent owns deployment. It takes a QA-verified, signed-off feature and makes it live on production infrastructure. It creates Dockerfiles if they don't exist, deploys both frontend and backend apps to CapRover, wires up the Cloudflare tunnel config, creates DNS records, and verifies the full traffic chain end to end.

**The DevOps Agent never interacts directly with the user.** All communication goes through the Boss Agent.

---

## Step 0 — Read machine config

**Before doing anything else**, read `~/.claude/machine-config.md`:

```bash
cat ~/.claude/machine-config.md
```

If the file does not exist: stop immediately. Report to Boss Agent:
```
BLOCKED: ~/.claude/machine-config.md not found on this machine.
The user must run the workflow-skills install script first:
  bash /path/to/workflow-skills/install.sh
Then fill in ~/.claude/machine-config.md with this machine's infrastructure values.
```

Extract and hold these values for use throughout this skill:
- `DEPLOY_MODE` — if not `caprover-cloudflare`, stop and report to Boss Agent that this machine's deploy mode is not supported by this agent
- `CAPROVER_URL` — the CapRover dashboard URL
- `TUNNEL_ID` — Cloudflare tunnel ID
- `TUNNEL_CNAME_TARGET` — `TUNNEL_ID.cfargotunnel.com`
- `CLOUDFLARE_CONFIG_FILE` — path to cloudflared config (usually `/etc/cloudflared/config.yml`)
- `DOMAIN` — root domain (e.g. `crawlingrobo.com`)
- `CLOUDFLARE_API_TOKEN` — if present in machine-config, use it. Otherwise read from project `.env`.
- `CLOUDFLARE_ZONE_ID` — same: prefer machine-config, fall back to `.env`.
- `GITHUB_PAT` — if present in machine-config, use it for GitHub API calls (adding secrets, pushing workflow files).

---

## Step 1 — Read project credentials

```bash
export CAPROVER_PASSWORD=$(grep ^CAPROVER_PASSWORD .env | cut -d '=' -f2-)

# Cloudflare — prefer machine-config values loaded in Step 0; fall back to .env
export CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN:-$(grep ^CLOUDFLARE_API_TOKEN .env | cut -d '=' -f2-)}
export CLOUDFLARE_ZONE_ID=${CLOUDFLARE_ZONE_ID:-$(grep ^CLOUDFLARE_ZONE_ID .env | cut -d '=' -f2-)}
```

If `CAPROVER_PASSWORD` is empty: stop. Report `NEEDS_CONTEXT` to Boss Agent.
If `CLOUDFLARE_API_TOKEN` or `CLOUDFLARE_ZONE_ID` are still empty after both checks: report `NEEDS_CONTEXT`.

Also read from `PROJECT_CONFIG.md`:
- Backend CapRover app name
- Frontend CapRover app name
- Backend internal container port
- Frontend internal container port
- Whether the app needs persistent storage (e.g. local disk, uploads)

---

## Step 2 — Dockerfiles

### 2.1 — Check for existing Dockerfiles

```bash
ls Dockerfile Dockerfile.frontend captain-definition 2>/dev/null
```

If all exist: skip to Step 3.

### 2.2 — Backend Dockerfile (FastAPI)

If `Dockerfile` does not exist, create it:

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE [BACKEND_INTERNAL_PORT]

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "[BACKEND_INTERNAL_PORT]"]
```

**Never bake secrets into the image.** All env vars (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `TESTING_MODE`, etc.) are injected via CapRover app config at deploy time.

### 2.3 — Frontend Dockerfile

Detect framework first:

```bash
[ -f "package.json" ] && grep -q '"next"' package.json && echo "FRAMEWORK:nextjs"
[ -f "package.json" ] && grep -q '"vite"' package.json && echo "FRAMEWORK:vite"
[ -f "package.json" ] && grep -q '"react-scripts"' package.json && echo "FRAMEWORK:cra"
```

**Next.js:**

Before creating the Dockerfile, check `next.config.mjs` (or `next.config.js`) for `output: 'standalone'`. If it is missing, add it:

```js
const nextConfig = {
  output: 'standalone',
  // ... rest of config
};
```

This is required — the Dockerfile copies from `.next/standalone` and will fail silently without it.

Also check if the repo has a `public/` directory:

```bash
ls public/ 2>/dev/null || echo "NO_PUBLIC_DIR"
```

If `public/` does not exist, the `COPY --from=builder /app/public ./public` step will fail at build time. The Dockerfile below handles this by creating it before the build.

Check `package.json` for `NEXT_PUBLIC_*` variables used in the codebase:

```bash
grep -r "NEXT_PUBLIC_" src/ --include="*.ts" --include="*.tsx" -l 2>/dev/null
```

If any `NEXT_PUBLIC_*` vars exist, they are baked into the client bundle at **build time**. CapRover does NOT support Docker build args via its API — they are silently ignored. Instead, create a `.env.production` file in the repo root. Next.js reads it automatically at build time. `NEXT_PUBLIC_*` values are safe to commit — they are exposed to the browser by design.

```bash
# Create .env.production with all NEXT_PUBLIC_ vars
cat > .env.production <<EOF
NEXT_PUBLIC_SUPABASE_URL=https://xxx.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key
EOF
```

Do NOT put secret vars (`SUPABASE_SERVICE_ROLE_KEY`, `GEMINI_API_KEY`, etc.) in `.env.production` — those go in CapRover env vars only.

```dockerfile
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci

FROM node:20-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# .env.production in the repo provides NEXT_PUBLIC_ vars at build time
ENV NEXT_TELEMETRY_DISABLED=1

# Create public/ if not present in repo (COPY will fail if it doesn't exist)
RUN mkdir -p /app/public && npm run build

FROM node:20-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

# If the app uses local disk storage (e.g. data/), create and own the directory
# RUN mkdir -p /app/data && chown -R nextjs:nodejs /app/data

USER nextjs

EXPOSE [FRONTEND_INTERNAL_PORT]
ENV PORT=[FRONTEND_INTERNAL_PORT]
ENV HOSTNAME="0.0.0.0"

CMD ["node", "server.js"]
```

**Vite / static SPA:**
```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE [FRONTEND_INTERNAL_PORT]
CMD ["nginx", "-g", "daemon off;"]
```

With `nginx.conf`:
```nginx
server {
    listen [FRONTEND_INTERNAL_PORT];
    root /usr/share/nginx/html;
    index index.html;
    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

### 2.4 — captain-definition files

**Backend (`captain-definition`):**
```json
{
  "schemaVersion": 2,
  "dockerfilePath": "./Dockerfile"
}
```

**Frontend (`captain-definition.frontend`):**
```json
{
  "schemaVersion": 2,
  "dockerfilePath": "./Dockerfile.frontend"
}
```

---

## Step 3 — Authenticate with CapRover API

```bash
CAPROVER_TOKEN=$(curl -s -X POST "$CAPROVER_URL/api/v2/login" \
  -H "Content-Type: application/json" \
  -d "{\"password\": \"$CAPROVER_PASSWORD\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['token'])")

echo "CapRover token: ${CAPROVER_TOKEN:0:20}..."
```

If the token is empty: stop. Report `BLOCKED` — CapRover authentication failed. Check `CAPROVER_PASSWORD` in `.env` and confirm `CAPROVER_URL` in `~/.claude/machine-config.md` is correct.

---

## Step 4 — Create and configure apps in CapRover

For each app (backend, frontend):

### 4.1 — Check if app exists

```bash
curl -s "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  | python3 -c "import sys,json; names=[a['appName'] for a in json.load(sys.stdin)['data']['appDefinitions']]; print('EXISTS' if '[APP_NAME]' in names else 'NOT_FOUND')"
```

### 4.2 — Create if not found

Set `hasPersistentData` to `true` if the app writes to local disk (uploads, project files, etc.).

```bash
curl -s -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/register" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"appName\": \"[APP_NAME]\", \"hasPersistentData\": false}"
```

### 4.3 — Set HTTP port, env vars, build args, and volumes

Do this in a single update call per app. For Next.js apps with `NEXT_PUBLIC_*` variables, include `buildArgs` so they are passed to `docker build --build-arg`.

```bash
curl -s -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/update" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"appName\": \"[APP_NAME]\",
    \"instanceCount\": 1,
    \"containerHttpPort\": [INTERNAL_PORT],
    \"notExposeAsWebApp\": false,
    \"forceSsl\": false,
    \"hasPersistentData\": false,
    \"envVars\": [
      {\"key\": \"NODE_ENV\", \"value\": \"production\"},
      {\"key\": \"NEXT_PUBLIC_SUPABASE_URL\", \"value\": \"$SUPABASE_URL\"},
      {\"key\": \"NEXT_PUBLIC_SUPABASE_ANON_KEY\", \"value\": \"$SUPABASE_ANON_KEY\"},
      {\"key\": \"SUPABASE_SERVICE_ROLE_KEY\", \"value\": \"$SUPABASE_SERVICE_ROLE_KEY\"},
      {\"key\": \"GEMINI_API_KEY\", \"value\": \"$GEMINI_API_KEY\"}
    ],
    \"buildArgs\": []
  }"
```

If the app uses local disk storage, also include `volumes`:

```json
"volumes": [
  {
    "containerPath": "/app/data",
    "volumeName": "[APP_NAME]-data"
  }
]
```

### 4.4 — Backend-specific env vars (FastAPI)

```bash
curl -s -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/update" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"appName\": \"[BACKEND_APP_NAME]\",
    \"envVars\": [
      {\"key\": \"ENVIRONMENT\", \"value\": \"production\"},
      {\"key\": \"TESTING_MODE\", \"value\": \"FALSE\"},
      {\"key\": \"SUPABASE_URL\", \"value\": \"$SUPABASE_URL\"},
      {\"key\": \"SUPABASE_ANON_KEY\", \"value\": \"$SUPABASE_ANON_KEY\"},
      {\"key\": \"SUPABASE_SERVICE_ROLE_KEY\", \"value\": \"$SUPABASE_SERVICE_ROLE_KEY\"},
      {\"key\": \"LOG_LEVEL\", \"value\": \"INFO\"}
    ]
  }"
```

---

## Step 5 — Deploy to CapRover

### Option A — Tarball upload (preferred — works without interactive login)

```bash
tar -czf /tmp/deploy.tar.gz \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='__pycache__' \
  --exclude='.env' \
  --exclude='data' \
  --exclude='.next' \
  --exclude='logs' \
  .

curl -s -X POST "$CAPROVER_URL/api/v2/user/apps/appData/[APP_NAME]" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  -F "sourceFile=@/tmp/deploy.tar.gz"
```

**Note:** The app name goes in the URL path, not as a form field. The correct endpoint is `/api/v2/user/apps/appData/[APP_NAME]`.

### Option B — caprover CLI (requires interactive login session)

```bash
caprover --version 2>/dev/null || npm install -g caprover

caprover deploy \
  --host "$CAPROVER_URL" \
  --appToken "$CAPROVER_TOKEN" \
  --appName "[APP_NAME]" \
  --branch main
```

### 5.1 — Wait for build to complete

```bash
until [ "$(curl -s "$CAPROVER_URL/api/v2/user/apps/appData/[APP_NAME]" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['isAppBuilding'])")" = "False" ]; do
  sleep 5
done

curl -s "$CAPROVER_URL/api/v2/user/apps/appData/[APP_NAME]" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Failed:', d['data']['isBuildFailed']); [print(l, end='') for l in d['data']['logs']['lines'][-30:]]"
```

If `isBuildFailed` is `True`: read the full log output and diagnose before retrying. Common Next.js failures:
- `COPY failed: stat app/public: file does not exist` → repo has no `public/` dir; add `mkdir -p /app/public` before `npm run build` in the builder stage
- `output: 'standalone'` missing → add it to `next.config.mjs` and redeploy

If build does not complete after 5 minutes: report `BLOCKED` to Boss Agent with the CapRover app URL for manual log inspection: `$CAPROVER_URL/apps/details/[APP_NAME]`.

---

## Step 6 — Cloudflare Tunnel Config

Use `CLOUDFLARE_CONFIG_FILE` from `~/.claude/machine-config.md` (not hardcoded).

### 6.1 — Read current config

```bash
sudo cat "$CLOUDFLARE_CONFIG_FILE"
```

### 6.2 — Check for existing entries

```bash
sudo grep "[APP_NAME].$DOMAIN" "$CLOUDFLARE_CONFIG_FILE" && echo "EXISTS" || echo "MISSING"
```

### 6.3 — Add missing entries

Always use `http://localhost:80` — never the app's direct container port.
CapRover's nginx routes by Host header internally to the correct container.

```bash
sudo python3 - <<EOF
config_file = "$CLOUDFLARE_CONFIG_FILE"
domain = "$DOMAIN"
apps = [
    "[BACKEND_APP_NAME]",
    "[FRONTEND_APP_NAME]",
]

with open(config_file, 'r') as f:
    content = f.read()

for app in apps:
    hostname = f"{app}.{domain}"
    if hostname in content:
        print(f"SKIP (already exists): {hostname}")
        continue
    entry = f"  - hostname: {hostname}\n    service: http://localhost:80"
    content = content.replace(
        '  - service: http_status:404',
        f'{entry}\n\n  - service: http_status:404'
    )
    print(f"ADDED: {hostname}")

with open(config_file, 'w') as f:
    f.write(content)

print("Done.")
EOF
```

**Note:** The DevOps Agent cannot write to `/etc/cloudflared/config.yml` directly — it requires sudo. If sudo is not available non-interactively, report to Boss Agent with the exact command for the user to run:

```
BLOCKED (tunnel config): sudo access required to edit /etc/cloudflared/config.yml.
Ask the user to run:

sudo python3 - <<'EOF'
[paste the python script above with values substituted]
EOF

sudo systemctl restart cloudflared
```

### 6.4 — Verify config

```bash
sudo cat "$CLOUDFLARE_CONFIG_FILE"
```

Confirm:
- New hostname entries appear before `- service: http_status:404`
- No duplicate entries
- CapRover dashboard entry (`captain.$DOMAIN`) is untouched
- Catch-all is still last

### 6.5 — Restart cloudflared

```bash
sudo systemctl restart cloudflared
sleep 3
sudo systemctl status cloudflared | grep -E "Active|running|failed"
```

If status shows `failed`:
```bash
sudo journalctl -u cloudflared -n 50
```
Report full output to Boss Agent as `BLOCKED`.

---

## Step 7 — Cloudflare DNS Records

Use `TUNNEL_CNAME_TARGET` from machine-config and `CLOUDFLARE_ZONE_ID` + `CLOUDFLARE_API_TOKEN` (from machine-config or `.env`).

### 7.1 — Check if record exists

```bash
curl -s "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=CNAME&name=[APP_NAME].$DOMAIN" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print('EXISTS' if r['result'] else 'MISSING')"
```

### 7.2 — Create CNAME (if missing)

```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"CNAME\",
    \"name\": \"[APP_NAME]\",
    \"content\": \"$TUNNEL_CNAME_TARGET\",
    \"proxied\": true,
    \"ttl\": 1,
    \"comment\": \"[PROJECT_NAME] - created by DevOps Agent\"
  }" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print('CREATED' if r['success'] else f'ERROR: {r[\"errors\"]}')"
```

Do this for both backend and frontend app names.

---

## Step 8 — End-to-End Verification

### 8.1 — Wait for DNS propagation

```bash
echo "Waiting 60s for DNS propagation..."
sleep 60
```

### 8.2 — Test traffic chain

```bash
for url in "https://[BACKEND_APP_NAME].$DOMAIN" "https://[FRONTEND_APP_NAME].$DOMAIN"; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$url")
  echo "$url → HTTP $CODE"
done
```

**Interpret results:**

| Code | Meaning | Action |
|------|---------|--------|
| 200–299 | Working | ✅ Pass |
| 301–302 | Redirect (HTTP→HTTPS) | ✅ Pass — follow and recheck |
| 404 from app | App live, route not found | ✅ Chain works — app-level issue |
| 404 from nginx HTML | CapRover has no app matching hostname | ❌ App name mismatch — check CapRover |
| 502 / 503 | Container crashed or not running | ❌ Check CapRover build log |
| 000 | DNS not resolving | ❌ CNAME missing or not propagated — wait 2 min and retry |

### 8.3 — Backend health check

```bash
curl -s "https://[BACKEND_APP_NAME].$DOMAIN/health"
```

### 8.4 — Confirm TESTING_MODE=FALSE in production

Check the startup log in CapRover at: `$CAPROVER_URL/apps/details/[BACKEND_APP_NAME]`

Look for: `"TESTING_MODE: FALSE"` and `"ENVIRONMENT: production"` in startup output.

---

## Step 9 — Handover to Boss Agent

```markdown
# DevOps Handover

## Deployment: [Feature / Project Name]
## Date: [date]
## Machine: [CAPROVER_URL from machine-config]
## Status: ✅ LIVE | ❌ BLOCKED

## URLs deployed
| App | URL | HTTP status | Chain verified |
|-----|-----|-------------|----------------|
| Backend | https://[backend-name].[DOMAIN] | [code] | ✅ / ❌ |
| Frontend | https://[frontend-name].[DOMAIN] | [code] | ✅ / ❌ |

## CapRover
| App | Port | Env vars set | Build args set | Build |
|-----|------|-------------|---------------|-------|
| [backend] | [port] | ✅ | N/A | DEPLOYED |
| [frontend] | [port] | ✅ | ✅ | DEPLOYED |

## Cloudflare tunnel
- Config file: [CLOUDFLARE_CONFIG_FILE]
- Entries added: ✅
- cloudflared restarted: ✅
- cloudflared status: active (running)

## DNS records
| Hostname | CNAME target | Proxied | Status |
|----------|-------------|---------|--------|
| [backend].[DOMAIN] | [TUNNEL_CNAME_TARGET] | ✅ | created |
| [frontend].[DOMAIN] | [TUNNEL_CNAME_TARGET] | ✅ | created |

## Verification
- Backend health: [response]
- TESTING_MODE in production: FALSE ✅
- ENVIRONMENT: production ✅

## Blocked items
- [description] → [what user must do]
```

---

## Step 10 — GitHub Actions Auto-Deploy (run once per project)

Sets up push-to-deploy: every push to `main` triggers a CapRover rebuild automatically.

**Do not use `caprover/deploy-to-caprover` — that action does not exist on GitHub and will cause an immediate "Set up job" failure. Use direct CapRover API calls instead (see 10.4).**

### 10.1 — Prerequisites

From machine-config: `GITHUB_PAT`, `CAPROVER_URL`, `CAPROVER_PASSWORD`
From project: GitHub repo URL (e.g. `https://github.com/leonatez/myapp`)

```bash
GITHUB_OWNER="leonatez"
GITHUB_REPO="myapp"
```

### 10.2 — Add GitHub Actions secrets

Three secrets are required: `CAPROVER_SERVER`, `CAPROVER_APP_NAME`, `CAPROVER_PASSWORD`.

```bash
npm install libsodium-wrappers --prefix /tmp/nacl --silent

PUBKEY_RESPONSE=$(curl -s \
  -H "Authorization: Bearer $GITHUB_PAT" \
  "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/actions/secrets/public-key")
KEY_ID=$(echo $PUBKEY_RESPONSE | python3 -c "import sys,json; print(json.load(sys.stdin)['key_id'])")
PUB_KEY=$(echo $PUBKEY_RESPONSE | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")

node -e "
const sodium = require('/tmp/nacl/node_modules/libsodium-wrappers');
const https = require('https');
const KEY_ID = '$KEY_ID';
const PUB_KEY = '$PUB_KEY';
const GH_TOKEN = '$GITHUB_PAT';
const OWNER = '$GITHUB_OWNER';
const REPO = '$GITHUB_REPO';

const secrets = {
  CAPROVER_SERVER: '$CAPROVER_URL',
  CAPROVER_APP_NAME: '$APP_NAME',
  CAPROVER_PASSWORD: '$CAPROVER_PASSWORD',
};

async function encryptSecret(pubKey, value) {
  await sodium.ready;
  const binKey = sodium.from_base64(pubKey, sodium.base64_variants.ORIGINAL);
  const encrypted = sodium.crypto_box_seal(sodium.from_string(value), binKey);
  return sodium.to_base64(encrypted, sodium.base64_variants.ORIGINAL);
}

async function putSecret(name, value) {
  const encrypted = await encryptSecret(PUB_KEY, value);
  const body = JSON.stringify({ encrypted_value: encrypted, key_id: KEY_ID });
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: 'api.github.com',
      path: '/repos/' + OWNER + '/' + REPO + '/actions/secrets/' + name,
      method: 'PUT',
      headers: {
        'Authorization': 'Bearer ' + GH_TOKEN,
        'Content-Type': 'application/json',
        'User-Agent': 'devops-agent',
        'Content-Length': Buffer.byteLength(body)
      }
    }, res => { let d=''; res.on('data',c=>d+=c); res.on('end',()=>resolve({name,status:res.statusCode})); });
    req.on('error', reject); req.write(body); req.end();
  });
}

(async () => {
  for (const [name, value] of Object.entries(secrets)) {
    const r = await putSecret(name, value);
    console.log(r.status === 201 || r.status === 204 ? 'OK' : 'FAIL', r.name, r.status);
  }
})();
"
```

All three must show `OK`. If any shows `FAIL`: check the PAT has `repo` + `secrets` scopes.

### 10.3 — Create the workflow file

Create `.github/workflows/deploy.yml`. **All python3 calls must be single-line** — multiline python3 inside a `run: |` block breaks YAML parsing and causes the run to fail with zero jobs and no error message.

Always validate YAML before committing:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yml').read()); print('YAML valid')"
```

The workflow (copy exactly — do not modify the python3 lines to multiline):

```yaml
name: Deploy to CapRover

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Create tarball
        run: |
          tar -czf /tmp/deploy.tar.gz \
            --exclude='.git' \
            --exclude='node_modules' \
            --exclude='data' \
            --exclude='.next' \
            --exclude='logs' \
            .

      - name: Login and deploy
        run: |
          TOKEN=$(curl -s -X POST "${{ secrets.CAPROVER_SERVER }}/api/v2/login" \
            -H "Content-Type: application/json" \
            -d "{\"password\": \"${{ secrets.CAPROVER_PASSWORD }}\"}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['token'])")

          if [ -z "$TOKEN" ]; then
            echo "Failed to get CapRover token"
            exit 1
          fi

          RESULT=$(curl -s -X POST \
            "${{ secrets.CAPROVER_SERVER }}/api/v2/user/apps/appData/${{ secrets.CAPROVER_APP_NAME }}" \
            -H "x-captain-auth: $TOKEN" \
            -F "sourceFile=@/tmp/deploy.tar.gz")
          echo "Upload result: $RESULT"
          echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0) if d.get('status')==100 else exit(1)"

          for i in $(seq 1 36); do
            BUILDING=$(curl -s \
              "${{ secrets.CAPROVER_SERVER }}/api/v2/user/apps/appData/${{ secrets.CAPROVER_APP_NAME }}" \
              -H "x-captain-auth: $TOKEN" \
              | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['isAppBuilding'])")
            echo "[$i] Building: $BUILDING"
            [ "$BUILDING" = "False" ] && break
            sleep 10
          done

          FAILED=$(curl -s \
            "${{ secrets.CAPROVER_SERVER }}/api/v2/user/apps/appData/${{ secrets.CAPROVER_APP_NAME }}" \
            -H "x-captain-auth: $TOKEN" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['isBuildFailed'])")

          if [ "$FAILED" = "True" ]; then
            echo "Build failed!"
            exit 1
          fi
          echo "Deploy successful!"
```

### 10.4 — Commit and push

```bash
cd /path/to/project
git config user.email "hailinh.leo@gmail.com"
git config user.name "leonatez"
git remote set-url origin "https://$GITHUB_PAT@github.com/$GITHUB_OWNER/$GITHUB_REPO.git"
git pull --rebase origin main
git add .github/workflows/deploy.yml
git commit -m "Add GitHub Actions auto-deploy to CapRover"
git push origin main
```

### 10.5 — Verify

```bash
# Wait ~20s for GitHub to register the run, then check
sleep 20
curl -s -H "Authorization: Bearer $GITHUB_PAT" \
  "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/actions/runs?per_page=1" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['workflow_runs'][0]; print(r['name'], r['status'], r['conclusion'])"
```

If conclusion is `failure` with zero jobs: YAML parse error — re-validate the workflow file.
If conclusion is `failure` with jobs: check logs via `GET /repos/$OWNER/$REPO/actions/jobs/$JOB_ID/logs`.

Report to Boss Agent once conclusion is `success`.

---

## Common Mistakes — Never Do These

| Mistake | Result | Fix |
|---------|--------|-----|
| Point cloudflared to app port (e.g. `localhost:8000`) | Connection refused | Always use `localhost:80` |
| Edit `~/.cloudflared/config.yml` | Changes ignored | Always edit `CLOUDFLARE_CONFIG_FILE` from machine-config |
| Duplicate hostname in config | Second entry silently ignored | Grep before inserting |
| Missing DNS CNAME | `curl` returns `000` | Create via Cloudflare API |
| Deploy without setting `containerHttpPort` | nginx can't route | Always call update API before deploy |
| Bake `.env` secrets into Docker image | Secrets in image layers | Set env vars in CapRover app config |
| Forget to restart cloudflared after config edit | New hostname not active | Always `sudo systemctl restart cloudflared` |
| Hardcode tunnel ID or domain | Breaks on other machines | Always read from `~/.claude/machine-config.md` |
| Use wrong tarball upload endpoint | 404 from CapRover API | Correct endpoint: `POST /api/v2/user/apps/appData/[APP_NAME]` (app name in URL, not form field) |
| Missing `output: 'standalone'` in next.config.mjs | Standalone Dockerfile fails silently | Always add it before building a Next.js Docker image |
| No `public/` dir in repo with Next.js standalone | `COPY failed: stat app/public` build error | Add `mkdir -p /app/public` before `npm run build` in builder stage |
| NEXT_PUBLIC_ vars only set as CapRover runtime env vars | Client bundle uses empty strings | CapRover buildArgs are silently ignored — use `.env.production` in the repo instead |
| `hasPersistentData: false` for app with local disk writes | Data lost on every deploy/restart | Set `hasPersistentData: true` and configure a named volume |
| Using `caprover/deploy-to-caprover` GitHub Action | "Set up job" failure — action not found | That action doesn't exist; use direct CapRover API calls (see Step 10) |
| Multiline python3 inside `run:` block (unindented) | Workflow fails with zero jobs, no error shown | Keep all python3 calls single-line in workflow files; validate YAML before committing |
| Forgetting `CAPROVER_PASSWORD` secret in GitHub repo | Login step gets empty token, upload returns 401 | Add `CAPROVER_PASSWORD` as a GitHub secret alongside `CAPROVER_SERVER` and `CAPROVER_APP_NAME` |
