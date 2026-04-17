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

---

## Step 1 — Read project credentials from .env

```bash
export CAPROVER_PASSWORD=$(grep ^CAPROVER_PASSWORD .env | cut -d '=' -f2-)
export CLOUDFLARE_API_TOKEN=$(grep ^CLOUDFLARE_API_TOKEN .env | cut -d '=' -f2-)
export CLOUDFLARE_ZONE_ID=$(grep ^CLOUDFLARE_ZONE_ID .env | cut -d '=' -f2-)
```

If any variable is empty: stop. Report `NEEDS_CONTEXT` to Boss Agent — list exactly which `.env` variables are missing.

Also read from `PROJECT_CONFIG.md`:
- Backend CapRover app name
- Frontend CapRover app name
- Backend internal container port
- Frontend internal container port

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
```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
EXPOSE [FRONTEND_INTERNAL_PORT]
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

## Step 4 — Create apps in CapRover

For each app (backend, frontend):

### 4.1 — Check if app exists

```bash
curl -s "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  | python3 -c "import sys,json; names=[a['appName'] for a in json.load(sys.stdin)['data']['appDefinitions']]; print('EXISTS' if '[APP_NAME]' in names else 'NOT_FOUND')"
```

### 4.2 — Create if not found

```bash
curl -s -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/register" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"appName\": \"[APP_NAME]\", \"hasPersistentData\": false}"
```

### 4.3 — Set HTTP port

```bash
curl -s -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/update" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"appName\": \"[APP_NAME]\",
    \"containerHttpPort\": [INTERNAL_PORT],
    \"notExposeAsWebApp\": false,
    \"forceSsl\": false
  }"
```

### 4.4 — Set production environment variables (backend only)

Read Supabase values from the project's `.env`:

```bash
SUPABASE_URL=$(grep ^SUPABASE_URL .env | cut -d '=' -f2-)
SUPABASE_ANON_KEY=$(grep ^SUPABASE_ANON_KEY .env | cut -d '=' -f2-)
SUPABASE_SERVICE_ROLE_KEY=$(grep ^SUPABASE_SERVICE_ROLE_KEY .env | cut -d '=' -f2-)

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

### Option A — caprover CLI (preferred)

```bash
caprover --version 2>/dev/null || npm install -g caprover

# Backend
caprover deploy \
  --host "$CAPROVER_URL" \
  --appToken "$CAPROVER_TOKEN" \
  --appName "[BACKEND_APP_NAME]" \
  --branch main

# Frontend
caprover deploy \
  --host "$CAPROVER_URL" \
  --appToken "$CAPROVER_TOKEN" \
  --appName "[FRONTEND_APP_NAME]" \
  --branch main
```

### Option B — Tarball upload (fallback)

```bash
tar -czf /tmp/deploy.tar.gz \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='__pycache__' \
  --exclude='.env' \
  --exclude='logs' \
  .

curl -s -X POST "$CAPROVER_URL/api/v2/user/apps/webhooks/triggerbuild" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  -F "sourceFile=@/tmp/deploy.tar.gz" \
  -F "appName=[APP_NAME]"
```

### 5.1 — Wait for build

```bash
for i in $(seq 1 30); do
  STATUS=$(curl -s "$CAPROVER_URL/api/v2/user/apps/appData/[APP_NAME]" \
    -H "x-captain-auth: $CAPROVER_TOKEN" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data'].get('isAppBuilding', True))")
  echo "Building: $STATUS"
  [ "$STATUS" = "False" ] && echo "BUILD COMPLETE" && break
  sleep 10
done
```

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
sudo grep "[BACKEND_APP_NAME].$DOMAIN" "$CLOUDFLARE_CONFIG_FILE" && echo "EXISTS" || echo "MISSING"
sudo grep "[FRONTEND_APP_NAME].$DOMAIN" "$CLOUDFLARE_CONFIG_FILE" && echo "EXISTS" || echo "MISSING"
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
        f'{entry}\n  - service: http_status:404'
    )
    print(f"ADDED: {hostname}")

with open(config_file, 'w') as f:
    f.write(content)

print("Done.")
EOF
```

### 6.4 — Verify config

```bash
sudo cat "$CLOUDFLARE_CONFIG_FILE"
```

Confirm:
- Both new hostname entries appear before `- service: http_status:404`
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

Use `TUNNEL_CNAME_TARGET` and `CLOUDFLARE_ZONE_ID` (from `.env`).

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
| App | Port | Env vars set | Build |
|-----|------|-------------|-------|
| [backend] | [port] | ✅ | DEPLOYED |
| [frontend] | [port] | N/A | DEPLOYED |

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

## Common Mistakes — Never Do These

| Mistake | Result | Fix |
|---------|--------|-----|
| Point cloudflared to app port (e.g. `localhost:8000`) | Connection refused | Always use `localhost:80` |
| Edit `~/.cloudflared/config.yml` | Changes ignored | Always edit `CLOUDFLARE_CONFIG_FILE` from machine-config |
| Duplicate hostname in config | Second entry silently ignored | Grep before inserting |
| Missing DNS CNAME | `curl` returns `000` | Create via Cloudflare API |
| Deploy without setting `containerHttpPort` | nginx can't route | Always call update API first |
| Bake `.env` secrets into Docker image | Secrets in image layers | Set env vars in CapRover app config |
| Forget to restart cloudflared after config edit | New hostname not active | Always `sudo systemctl restart cloudflared` |
| Hardcode tunnel ID or domain | Breaks on other machines | Always read from `~/.claude/machine-config.md` |
