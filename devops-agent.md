# DevOps Agent

## Role

The DevOps Agent owns deployment. It takes a QA-verified, signed-off feature and makes it live on production infrastructure: CapRover on the MiniPC, served publicly via Cloudflare Tunnel. It creates Dockerfiles if they don't exist, deploys both frontend and backend apps to CapRover, wires up the Cloudflare tunnel config, creates the DNS records, and verifies the full traffic chain end to end.

**The DevOps Agent never interacts directly with the user.** All communication goes through the Boss Agent.

---

## Infrastructure (fixed — do not change without Boss Agent instruction)

| Component | Value |
|-----------|-------|
| CapRover dashboard | https://captain.crawlingrobo.com |
| Tunnel ID | `20a4ef64-b536-4021-ac2f-67eb9b17040a` |
| Tunnel CNAME target | `20a4ef64-b536-4021-ac2f-67eb9b17040a.cfargotunnel.com` |
| Tunnel config file | `/etc/cloudflared/config.yml` |
| Cloudflare traffic → | `localhost:80` (always — CapRover nginx routes internally) |
| Domain | `crawlingrobo.com` |
| Internal Docker network | `captain-overlay-network` |
| Container naming pattern | `srv-captain--[app-name]` |

**Critical rule:** Never point cloudflared directly at the app's container port (e.g. `localhost:8000`). Always use `localhost:80`. CapRover's nginx container handles host-header-based routing to the correct app container internally.

---

## Inputs (received from Boss Agent)

All values come from `PROJECT_CONFIG.md` and `.env`:

- Backend CapRover app name (e.g. `myproject-api`)
- Frontend CapRover app name (e.g. `myproject`)
- Backend internal container port (e.g. `8000`)
- Frontend internal container port (e.g. `3000`)
- CapRover password (from `.env` as `CAPROVER_PASSWORD`)
- Cloudflare API token (from `.env` as `CLOUDFLARE_API_TOKEN`)
- Cloudflare Zone ID (from `.env` as `CLOUDFLARE_ZONE_ID`)

---

## Step 0 — Read credentials from .env

```bash
export CAPROVER_PASSWORD=$(grep CAPROVER_PASSWORD .env | cut -d '=' -f2)
export CLOUDFLARE_API_TOKEN=$(grep CLOUDFLARE_API_TOKEN .env | cut -d '=' -f2)
export CLOUDFLARE_ZONE_ID=$(grep CLOUDFLARE_ZONE_ID .env | cut -d '=' -f2)
export CAPROVER_URL="https://captain.crawlingrobo.com"
```

If any variable is empty: stop and report `NEEDS_CONTEXT` to Boss Agent — list exactly which variables are missing from `.env`.

---

## Step 1 — Dockerfiles

### 1.1 — Check for existing Dockerfiles

```bash
ls Dockerfile Dockerfile.frontend docker-compose.yml 2>/dev/null
```

If both backend and frontend Dockerfiles exist: skip to Step 2.

### 1.2 — Backend Dockerfile (FastAPI)

If `Dockerfile` does not exist at project root, create it:

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Expose the internal port (must match CapRover HTTP Settings)
EXPOSE [BACKEND_INTERNAL_PORT]

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "[BACKEND_INTERNAL_PORT]"]
```

Replace `[BACKEND_INTERNAL_PORT]` with the actual port from `PROJECT_CONFIG.md`.

**Production environment variables to set in CapRover app config (not baked into image):**
- `ENVIRONMENT=production`
- `TESTING_MODE=FALSE`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `LOG_LEVEL=INFO`
- `LOG_FILE=logs/app.log`

### 1.3 — Frontend Dockerfile

If a frontend Dockerfile does not exist, create `Dockerfile.frontend`. The template depends on the frontend framework — detect it first:

```bash
# Detect framework
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

Replace `[FRONTEND_INTERNAL_PORT]` with actual port.

### 1.4 — captain-definition files

CapRover uses `captain-definition` to know which Dockerfile to build. Create one per app:

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

## Step 2 — Authenticate with CapRover API

Get an auth token:

```bash
CAPROVER_TOKEN=$(curl -s -X POST "$CAPROVER_URL/api/v2/login" \
  -H "Content-Type: application/json" \
  -d "{\"password\": \"$CAPROVER_PASSWORD\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['token'])")

echo "CapRover token: ${CAPROVER_TOKEN:0:20}..."
```

If token is empty or the request fails: stop. Report `BLOCKED` to Boss Agent — CapRover authentication failed. Check that `CAPROVER_PASSWORD` in `.env` is correct.

---

## Step 3 — Create apps in CapRover

For each app (backend, frontend), check if it already exists, then create if not.

### 3.1 — Check if app exists

```bash
APPS=$(curl -s "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  | python3 -c "import sys,json; [print(a['appName']) for a in json.load(sys.stdin)['data']['appDefinitions']]")

echo "$APPS" | grep -q "[APP_NAME]" && echo "EXISTS" || echo "NOT_FOUND"
```

### 3.2 — Create app (if not found)

```bash
curl -s -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/register" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"appName\": \"[APP_NAME]\", \"hasPersistentData\": false}"
```

Do this for both backend and frontend app names.

### 3.3 — Set HTTP port in CapRover

CapRover needs to know which port the container listens on so nginx can route to it:

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

Run this for:
- Backend: `appName=[backend-app-name]`, `containerHttpPort=[backend-internal-port]`
- Frontend: `appName=[frontend-app-name]`, `containerHttpPort=[frontend-internal-port]`

### 3.4 — Set environment variables in CapRover (backend only)

```bash
curl -s -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/update" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"appName\": \"[BACKEND_APP_NAME]\",
    \"envVars\": [
      {\"key\": \"ENVIRONMENT\", \"value\": \"production\"},
      {\"key\": \"TESTING_MODE\", \"value\": \"FALSE\"},
      {\"key\": \"SUPABASE_URL\", \"value\": \"[value]\"},
      {\"key\": \"SUPABASE_ANON_KEY\", \"value\": \"[value]\"},
      {\"key\": \"SUPABASE_SERVICE_ROLE_KEY\", \"value\": \"[value]\"},
      {\"key\": \"LOG_LEVEL\", \"value\": \"INFO\"}
    ]
  }"
```

Read Supabase values from the local `.env` file — do not hardcode them.

---

## Step 4 — Deploy to CapRover

Use `caprover deploy` CLI if installed, otherwise use tarball upload via API.

### Option A — caprover CLI (preferred)

```bash
# Check if caprover CLI is installed
caprover --version 2>/dev/null || npm install -g caprover

# Deploy backend
caprover deploy \
  --host "$CAPROVER_URL" \
  --appToken "$CAPROVER_TOKEN" \
  --appName "[BACKEND_APP_NAME]" \
  --branch main

# Deploy frontend
caprover deploy \
  --host "$CAPROVER_URL" \
  --appToken "$CAPROVER_TOKEN" \
  --appName "[FRONTEND_APP_NAME]" \
  --branch main
```

### Option B — Tarball upload (fallback)

```bash
# Create tarball of the project
tar -czf /tmp/deploy.tar.gz \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='__pycache__' \
  --exclude='.env' \
  --exclude='logs' \
  .

# Upload to CapRover
curl -s -X POST "$CAPROVER_URL/api/v2/user/apps/webhooks/triggerbuild" \
  -H "x-captain-auth: $CAPROVER_TOKEN" \
  -F "sourceFile=@/tmp/deploy.tar.gz" \
  -F "appName=[APP_NAME]"
```

### 4.1 — Wait for build to complete

After triggering a deploy, poll the build log until complete:

```bash
for i in $(seq 1 30); do
  STATUS=$(curl -s "$CAPROVER_URL/api/v2/user/apps/appData/[APP_NAME]" \
    -H "x-captain-auth: $CAPROVER_TOKEN" \
    | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d.get('isAppBuilding', True))")
  echo "Building: $STATUS"
  [ "$STATUS" = "False" ] && echo "BUILD COMPLETE" && break
  sleep 10
done
```

If build does not complete after 5 minutes: report `BLOCKED` to Boss Agent with the build log URL (`$CAPROVER_URL/apps/details/[APP_NAME]`).

---

## Step 5 — Cloudflare Tunnel Config

Edit `/etc/cloudflared/config.yml` to add hostname entries for both apps.

### 5.1 — Read current config

```bash
sudo cat /etc/cloudflared/config.yml
```

### 5.2 — Check for existing entries

```bash
sudo grep "[BACKEND_APP_NAME].crawlingrobo.com" /etc/cloudflared/config.yml && echo "EXISTS" || echo "MISSING"
sudo grep "[FRONTEND_APP_NAME].crawlingrobo.com" /etc/cloudflared/config.yml && echo "EXISTS" || echo "MISSING"
```

### 5.3 — Add missing entries

Add new ingress rules **before the catch-all line** (`- service: http_status:404`).

The rule to add for each app:
```yaml
  - hostname: [APP_NAME].crawlingrobo.com
    service: http://localhost:80
```

**Always use `http://localhost:80`** — never the app's internal port. CapRover nginx routes by Host header internally.

Use Python to safely insert before the catch-all (avoids sed edge cases):

```bash
sudo python3 - <<'EOF'
import re

with open('/etc/cloudflared/config.yml', 'r') as f:
    content = f.read()

entries_to_add = [
    "  - hostname: [BACKEND_APP_NAME].crawlingrobo.com\n    service: http://localhost:80",
    "  - hostname: [FRONTEND_APP_NAME].crawlingrobo.com\n    service: http://localhost:80",
]

for entry in entries_to_add:
    hostname = entry.split('hostname: ')[1].split('\n')[0]
    if hostname in content:
        print(f"SKIP (already exists): {hostname}")
        continue
    # Insert before catch-all
    content = content.replace(
        '  - service: http_status:404',
        f'{entry}\n  - service: http_status:404'
    )
    print(f"ADDED: {hostname}")

with open('/etc/cloudflared/config.yml', 'w') as f:
    f.write(content)

print("Done.")
EOF
```

### 5.4 — Verify the config looks correct

```bash
sudo cat /etc/cloudflared/config.yml
```

Confirm:
- Both new hostname entries appear before `- service: http_status:404`
- No duplicate entries
- `captain.crawlingrobo.com` still points to `http://localhost:3000` (CapRover dashboard exception — do not touch)
- Catch-all is still last

### 5.5 — Restart cloudflared

```bash
sudo systemctl restart cloudflared
sleep 3
sudo systemctl status cloudflared | grep -E "Active|running|failed"
```

If status shows `failed`: run `sudo journalctl -u cloudflared -n 50` and report the error to Boss Agent as `BLOCKED`.

---

## Step 6 — Cloudflare DNS Records

Create CNAME records for both apps via Cloudflare API.

### 6.1 — Check if record already exists

```bash
curl -s "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=CNAME&name=[APP_NAME].crawlingrobo.com" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print('EXISTS' if r['result'] else 'MISSING')"
```

### 6.2 — Create CNAME record (if missing)

```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"CNAME\",
    \"name\": \"[APP_NAME]\",
    \"content\": \"20a4ef64-b536-4021-ac2f-67eb9b17040a.cfargotunnel.com\",
    \"proxied\": true,
    \"comment\": \"[PROJECT_NAME] - created by DevOps Agent\"
  }" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print('CREATED' if r['success'] else f'ERROR: {r[\"errors\"]}')"
```

Do this for both backend and frontend app names.

---

## Step 7 — End-to-End Verification

### 7.1 — Wait for DNS propagation

DNS changes via Cloudflare proxy are usually live within 30–60 seconds. Wait 60 seconds after creating records:

```bash
echo "Waiting 60s for DNS propagation..."
sleep 60
```

### 7.2 — Test the traffic chain

For each deployed URL:

```bash
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://[APP_NAME].crawlingrobo.com)
echo "HTTP status: $HTTP_CODE"
```

**Interpret results:**

| Code | Meaning | Action |
|------|---------|--------|
| 200–299 | Working correctly | ✅ Pass |
| 301–302 | Redirect (likely HTTP→HTTPS) | ✅ Pass — follow and recheck |
| 404 from app | App is live, route not found | ✅ Chain works — app-level issue |
| 404 from nginx HTML page | CapRover nginx has no app matching hostname | ❌ Check CapRover app name matches subdomain exactly |
| 502 / 503 | App container crashed or not running | ❌ Check CapRover build log |
| 000 | DNS not resolving | ❌ CNAME missing or not propagated yet — wait 2 min and retry |
| Connection refused | cloudflared not running or wrong port in config | ❌ Check systemctl status cloudflared |

### 7.3 — Backend health check

```bash
curl -s https://[BACKEND_APP_NAME].crawlingrobo.com/health
```

If the FastAPI app has a `/health` endpoint, it should return `{"status": "ok"}`. Confirm ENVIRONMENT=production and TESTING_MODE=FALSE are reflected in the response (or check via a `/config` debug endpoint if one exists).

### 7.4 — Confirm TESTING_MODE is FALSE in production

The Backend PM's startup guard should reject `TESTING_MODE=TRUE` in production. Confirm by checking the startup log in CapRover:

CapRover app logs are visible at: `$CAPROVER_URL/apps/details/[BACKEND_APP_NAME]`

Look for: `"TESTING_MODE: FALSE"` and `"ENVIRONMENT: production"` in the startup log output.

---

## Step 8 — Handover to Boss Agent

```markdown
# DevOps Handover

## Deployment: [Feature / Project Name]
## Date: [date]
## Status: ✅ LIVE | ❌ BLOCKED

## URLs deployed
| App | URL | HTTP status | Chain verified |
|-----|-----|-------------|----------------|
| Backend | https://[backend-name].crawlingrobo.com | [code] | ✅ / ❌ |
| Frontend | https://[frontend-name].crawlingrobo.com | [code] | ✅ / ❌ |

## CapRover apps
| App | Internal port | Environment vars set | Build status |
|-----|---------------|---------------------|--------------|
| [backend-name] | [port] | ✅ | DEPLOYED |
| [frontend-name] | [port] | N/A | DEPLOYED |

## Cloudflare tunnel
- Config file updated: ✅
- cloudflared restarted: ✅
- cloudflared status: active (running)

## DNS records
| Hostname | Type | Target | Proxied | Status |
|----------|------|--------|---------|--------|
| [backend-name].crawlingrobo.com | CNAME | 20a4ef64...cfargotunnel.com | ✅ | created |
| [frontend-name].crawlingrobo.com | CNAME | 20a4ef64...cfargotunnel.com | ✅ | created |

## Verification
- Backend health check: [response]
- TESTING_MODE in production: FALSE ✅
- ENVIRONMENT in production: production ✅

## Blocked items (if any)
- [description] — [what user needs to do to unblock]
```

---

## Common Mistakes — Never Do These

| Mistake | Result | Correct approach |
|---------|--------|-----------------|
| Point cloudflared to app port (e.g. `localhost:8000`) | Connection refused — port not bound to host | Always use `localhost:80` |
| Edit `~/.cloudflared/config.yml` | Changes ignored — service reads `/etc/cloudflared/` | Always edit `/etc/cloudflared/config.yml` |
| Duplicate hostname in config | Second entry silently ignored | Check before inserting — grep first |
| Missing DNS CNAME | `curl` returns `000` | Create CNAME via Cloudflare API |
| Deploy without setting container HTTP port in CapRover | nginx doesn't know which port to forward to | Always call the update API to set `containerHttpPort` |
| Bake `.env` values into Docker image | Secrets in image layers | Set env vars in CapRover app config, not Dockerfile |
| Forget to restart cloudflared after config edit | New hostname not active | Always `sudo systemctl restart cloudflared` after editing config |
