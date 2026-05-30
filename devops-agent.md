# DevOps Agent

## Role

The DevOps Agent owns deployment. It takes a QA-verified, signed-off feature and makes it live on production infrastructure. It creates a Coolify project, registers the backend and frontend apps directly from the GitHub repo (Coolify builds them with Nixpacks — no Dockerfiles needed), injects environment variables, wires up the Cloudflare tunnel config, creates DNS records, and verifies the full traffic chain end to end. Because the apps are connected to the git repo with auto-deploy enabled, every later push to `main` redeploys automatically — there is no GitHub Actions workflow to maintain.

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
- `DEPLOY_MODE` — if not `coolify-cloudflare`, stop and report to Boss Agent that this machine's deploy mode is not supported by this agent
- `COOLIFY_URL` — the Coolify base URL (e.g. `http://localhost:8000` when the agent runs on the same box, or `https://admin.enginxlabs.com`). The API base is `$COOLIFY_URL/api/v1`.
- `COOLIFY_API_TOKEN` — Coolify API token in `ID|secret` format. Machine-scoped (one token per Coolify instance/team). If present in machine-config, use it; otherwise fall back to project `.env`.
- `COOLIFY_SERVER_UUID` — target server UUID (optional; auto-detected in Step 3 if absent)
- `GITHUB_APP_UUID` — UUID of the GitHub App connected inside Coolify (optional; auto-detected in Step 3 if absent)
- `TUNNEL_ID` — Cloudflare tunnel ID
- `TUNNEL_CNAME_TARGET` — `TUNNEL_ID.cfargotunnel.com`
- `CLOUDFLARE_CONFIG_FILE` — path to cloudflared config (usually `/etc/cloudflared/config.yml`)
- `DOMAIN` — root domain (e.g. `enginxlabs.com`)
- `CLOUDFLARE_API_TOKEN` — if present in machine-config, use it. Otherwise read from project `.env`.
- `CLOUDFLARE_ZONE_ID` — same: prefer machine-config, fall back to `.env`.

---

## Step 1 — Read project credentials

```bash
# Coolify token — prefer machine-config value loaded in Step 0; fall back to .env
export COOLIFY_API_TOKEN=${COOLIFY_API_TOKEN:-$(grep ^COOLIFY_API_TOKEN .env | cut -d '=' -f2-)}

# Cloudflare — prefer machine-config values loaded in Step 0; fall back to .env
export CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN:-$(grep ^CLOUDFLARE_API_TOKEN .env | cut -d '=' -f2-)}
export CLOUDFLARE_ZONE_ID=${CLOUDFLARE_ZONE_ID:-$(grep ^CLOUDFLARE_ZONE_ID .env | cut -d '=' -f2-)}

# App secrets (injected into Coolify, never committed)
export SUPABASE_URL=$(grep ^SUPABASE_URL .env | cut -d '=' -f2-)
export SUPABASE_ANON_KEY=$(grep ^SUPABASE_ANON_KEY .env | cut -d '=' -f2-)
export SUPABASE_SERVICE_ROLE_KEY=$(grep ^SUPABASE_SERVICE_ROLE_KEY .env | cut -d '=' -f2-)
```

If `COOLIFY_API_TOKEN` is empty: stop. Report `NEEDS_CONTEXT` to Boss Agent.
If `CLOUDFLARE_API_TOKEN` or `CLOUDFLARE_ZONE_ID` are still empty after both checks: report `NEEDS_CONTEXT`.

Also read from `PROJECT_CONFIG.md`:
- GitHub repository URL and default branch
- Backend app name (e.g. `myproject-api`)
- Frontend app name (e.g. `myproject`)
- Backend internal container port (the port FastAPI/uvicorn listens on — default `8000`)
- Frontend internal container port (the port the frontend server listens on — default `3000`)
- Coolify project UUID, backend app UUID, frontend app UUID — **if already present** from a previous run (created in Step 4). If present, this is a re-deploy: skip creation and reuse the UUIDs.
- Whether the app needs persistent storage (local disk, uploads)

A quick sanity check on the token before going further:

```bash
curl -s "$COOLIFY_URL/api/v1/teams/current" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" | head -c 200
```

If this returns `401`/`Unauthenticated`: stop. Report `BLOCKED` — Coolify token invalid or expired. The user must mint a new token at `$COOLIFY_URL` → Keys & Tokens → API tokens (scopes: `read`, `read:sensitive`, `write`, `deploy`).

---

## Step 2 — Repository layout & build settings (no Dockerfiles)

Coolify builds each app with **Nixpacks** straight from the git repo — it auto-detects Python and Node. There are no Dockerfiles to create. The agent's job here is to determine, for each app, **which subdirectory** it lives in and **how it starts**.

### 2.1 — Detect layout

```bash
# Backend: where is requirements.txt / pyproject.toml?
ls requirements.txt pyproject.toml backend/requirements.txt 2>/dev/null

# Frontend: where is package.json, and which framework?
ls package.json frontend/package.json 2>/dev/null
grep -l '"next"' package.json frontend/package.json 2>/dev/null && echo "FRAMEWORK:nextjs"
grep -l '"vite"' package.json frontend/package.json 2>/dev/null && echo "FRAMEWORK:vite"
```

From this determine, for each app, the **base directory** relative to the repo root:
- Both at root (single-purpose repo) → `base_directory = /`
- Monorepo with `backend/` and `frontend/` → set each app's `base_directory` accordingly

Hold these as `BACKEND_BASE_DIR` and `FRONTEND_BASE_DIR`.

### 2.2 — Determine start commands & ports

Nixpacks infers the build, but the **start command** often needs to be explicit. Hold these for the create call in Step 4:

| App | `ports_exposes` | `start_command` |
|-----|-----------------|-----------------|
| Backend (FastAPI) | `8000` (or `PROJECT_CONFIG` value) | `uvicorn app.main:app --host 0.0.0.0 --port 8000` |
| Frontend (Next.js) | `3000` | leave empty — Nixpacks runs `npm run build` then `npm start` |
| Frontend (Vite/static SPA) | `3000` | set `is_static: true`, `is_spa: true` (Nixpacks serves the built `dist/`) |

Adjust the uvicorn module path (`app.main:app`) if the repo's entrypoint differs — check `ARCHITECTURE.md` or grep for `FastAPI(`.

### 2.3 — NEXT_PUBLIC_* build-time variables

`NEXT_PUBLIC_*` vars are baked into the client bundle at **build time**. With Nixpacks, Coolify exposes the app's environment variables to the build, so they must be set in Coolify (Step 4.3) **before the first build runs**. That is why Step 4 creates apps with `instant_deploy: false`, sets env vars, and only then triggers the build.

Find which `NEXT_PUBLIC_*` vars the frontend uses:

```bash
grep -rho "NEXT_PUBLIC_[A-Z_]*" "${FRONTEND_BASE_DIR:-.}/src" 2>/dev/null | sort -u
```

`NEXT_PUBLIC_*` values are public by design (exposed to the browser). **Never** put secret vars (`SUPABASE_SERVICE_ROLE_KEY`, `GEMINI_API_KEY`, etc.) under a `NEXT_PUBLIC_` name or on the frontend app at all — those belong only on the backend app.

---

## Step 3 — Resolve Coolify server & GitHub App

All API calls use the header `Authorization: Bearer $COOLIFY_API_TOKEN` and JSON bodies.

### 3.1 — Server UUID

```bash
COOLIFY_SERVER_UUID=${COOLIFY_SERVER_UUID:-$(curl -s "$COOLIFY_URL/api/v1/servers" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
  | python3 -c "import sys,json; s=json.load(sys.stdin); print(s[0]['uuid'])")}
echo "Server UUID: $COOLIFY_SERVER_UUID"
```

If there is more than one server, prefer the one named `localhost` or matching this machine. If empty: report `BLOCKED` — no Coolify server reachable via API.

### 3.2 — GitHub App UUID

The repo is private, so apps are created via the **GitHub App** connection configured once inside Coolify.

```bash
GITHUB_APP_UUID=${GITHUB_APP_UUID:-$(curl -s "$COOLIFY_URL/api/v1/github-apps" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
  | python3 -c "import sys,json; a=json.load(sys.stdin); print(a[0]['uuid'])")}
echo "GitHub App UUID: $GITHUB_APP_UUID"
```

If the list is empty: report `BLOCKED` to Boss Agent:
```
BLOCKED: No GitHub App connected in Coolify.
The user must connect one once: $COOLIFY_URL → Sources → + Add → GitHub App,
install it on the GitHub account/org and grant access to the target repo.
Then re-run deployment.
```

> If the repo is **public**, you may instead use `POST /api/v1/applications/public` (no `github_app_uuid`). Everything else below is identical.

---

## Step 4 — Create the Coolify project and apps

### 4.1 — Create (or reuse) the project

If `PROJECT_CONFIG.md` already has a Coolify project UUID, reuse it. Otherwise create one:

```bash
PROJECT_UUID=$(curl -s -X POST "$COOLIFY_URL/api/v1/projects" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"[PROJECT_NAME]\", \"description\": \"Created by DevOps Agent\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['uuid'])")
echo "Project UUID: $PROJECT_UUID"
```

A `production` environment is created with the project. Write `PROJECT_UUID` back into `PROJECT_CONFIG.md`.

### 4.2 — Check whether the apps already exist

```bash
curl -s "$COOLIFY_URL/api/v1/applications" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
  | python3 -c "import sys,json; n=[a.get('name') for a in json.load(sys.stdin)]; print('backend EXISTS' if '[BACKEND_APP_NAME]' in n else 'backend NOT_FOUND'); print('frontend EXISTS' if '[FRONTEND_APP_NAME]' in n else 'frontend NOT_FOUND')"
```

If an app exists, capture its `uuid` from the same list and skip its creation in 4.3 — go straight to env vars (4.3 envs) and deploy (Step 5).

### 4.3 — Create each app from the git repo (auto-deploy on)

Create with `instant_deploy: false` so env vars can be set before the first build. Domains use **http** (Cloudflare terminates TLS at its edge; the tunnel is plaintext to Coolify) and `is_force_https_enabled: false` to avoid Traefik redirect loops behind the tunnel.

**Backend:**

```bash
BACKEND_UUID=$(curl -s -X POST "$COOLIFY_URL/api/v1/applications/private-github-app" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"project_uuid\": \"$PROJECT_UUID\",
    \"server_uuid\": \"$COOLIFY_SERVER_UUID\",
    \"environment_name\": \"production\",
    \"github_app_uuid\": \"$GITHUB_APP_UUID\",
    \"git_repository\": \"[GITHUB_REPO_URL]\",
    \"git_branch\": \"main\",
    \"build_pack\": \"nixpacks\",
    \"name\": \"[BACKEND_APP_NAME]\",
    \"base_directory\": \"$BACKEND_BASE_DIR\",
    \"ports_exposes\": \"8000\",
    \"start_command\": \"uvicorn app.main:app --host 0.0.0.0 --port 8000\",
    \"domains\": \"http://[BACKEND_APP_NAME].$DOMAIN\",
    \"is_force_https_enabled\": false,
    \"is_auto_deploy_enabled\": true,
    \"instant_deploy\": false
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['uuid'])")
echo "Backend app UUID: $BACKEND_UUID"
```

**Frontend (Next.js):**

```bash
FRONTEND_UUID=$(curl -s -X POST "$COOLIFY_URL/api/v1/applications/private-github-app" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"project_uuid\": \"$PROJECT_UUID\",
    \"server_uuid\": \"$COOLIFY_SERVER_UUID\",
    \"environment_name\": \"production\",
    \"github_app_uuid\": \"$GITHUB_APP_UUID\",
    \"git_repository\": \"[GITHUB_REPO_URL]\",
    \"git_branch\": \"main\",
    \"build_pack\": \"nixpacks\",
    \"name\": \"[FRONTEND_APP_NAME]\",
    \"base_directory\": \"$FRONTEND_BASE_DIR\",
    \"ports_exposes\": \"3000\",
    \"domains\": \"http://[FRONTEND_APP_NAME].$DOMAIN\",
    \"is_force_https_enabled\": false,
    \"is_auto_deploy_enabled\": true,
    \"instant_deploy\": false
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['uuid'])")
echo "Frontend app UUID: $FRONTEND_UUID"
```

For a **Vite / static SPA** frontend, add `"is_static": true, "is_spa": true` and drop `ports_exposes` reliance (Coolify serves the built assets through its static server).

Write `BACKEND_UUID` and `FRONTEND_UUID` back into `PROJECT_CONFIG.md`.

### 4.3 (envs) — Set environment variables

Use the **bulk** endpoint per app. Secrets live only in Coolify — never committed, never baked into a build image.

**Backend (FastAPI):**

```bash
curl -s -X PATCH "$COOLIFY_URL/api/v1/applications/$BACKEND_UUID/envs/bulk" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"data\": [
    {\"key\": \"ENVIRONMENT\", \"value\": \"production\"},
    {\"key\": \"TESTING_MODE\", \"value\": \"FALSE\"},
    {\"key\": \"SUPABASE_URL\", \"value\": \"$SUPABASE_URL\"},
    {\"key\": \"SUPABASE_ANON_KEY\", \"value\": \"$SUPABASE_ANON_KEY\"},
    {\"key\": \"SUPABASE_SERVICE_ROLE_KEY\", \"value\": \"$SUPABASE_SERVICE_ROLE_KEY\"},
    {\"key\": \"LOG_LEVEL\", \"value\": \"INFO\"}
  ]}"
```

**Frontend (Next.js)** — include every `NEXT_PUBLIC_*` var found in Step 2.3 (these are baked at build time) plus any public runtime vars:

```bash
curl -s -X PATCH "$COOLIFY_URL/api/v1/applications/$FRONTEND_UUID/envs/bulk" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"data\": [
    {\"key\": \"NODE_ENV\", \"value\": \"production\"},
    {\"key\": \"NEXT_PUBLIC_SUPABASE_URL\", \"value\": \"$SUPABASE_URL\"},
    {\"key\": \"NEXT_PUBLIC_SUPABASE_ANON_KEY\", \"value\": \"$SUPABASE_ANON_KEY\"}
  ]}"
```

### 4.4 — Persistent storage (only if the app writes to local disk)

```bash
curl -s -X POST "$COOLIFY_URL/api/v1/applications/$BACKEND_UUID/storages" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"[APP_NAME]-data\", \"mount_path\": \"/app/data\"}"
```

Without this, container-local writes are lost on every redeploy.

---

## Step 5 — Deploy

Trigger the first build now that env vars are in place (`force=true` builds without cache for a clean first deploy):

```bash
for UUID in "$BACKEND_UUID" "$FRONTEND_UUID"; do
  curl -s "$COOLIFY_URL/api/v1/deploy?uuid=$UUID&force=true" \
    -H "Authorization: Bearer $COOLIFY_API_TOKEN"
  echo
done
```

The response contains a `deployments` array with a `deployment_uuid` per app — capture it.

### 5.1 — Wait for each build to complete

Poll the deployment status. Coolify status values progress `queued` → `in_progress` → `finished` (or `failed` / `cancelled-by-user`):

```bash
DEPLOY_UUID="[deployment_uuid from Step 5]"
until curl -s "$COOLIFY_URL/api/v1/deployments/$DEPLOY_UUID" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
  | python3 -c "import sys,json; s=json.load(sys.stdin).get('status',''); print(s); exit(0 if s in ('finished','failed','cancelled-by-user') else 1)"; do
  sleep 5
done
```

Then check the application's runtime status and recent logs:

```bash
curl -s "$COOLIFY_URL/api/v1/applications/$BACKEND_UUID" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('app status:', d.get('status'))"

curl -s "$COOLIFY_URL/api/v1/applications/$BACKEND_UUID/logs?lines=50" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN"
```

If status is `failed`: pull the build log and diagnose before retrying. Common Nixpacks issues:
- **No start command for FastAPI** → app builds but exits immediately; set `start_command` (Step 2.2) and redeploy.
- **Wrong `base_directory`** → "no buildable files found"; fix the subdirectory (Step 2.1).
- **`NEXT_PUBLIC_*` empty in the bundle** → env vars were not set before the build; set them (Step 4.3 envs) and redeploy with `force=true`.
- **Wrong `ports_exposes`** → build succeeds but Traefik can't reach the container; set it to the port the process actually listens on.

If a build does not complete after ~5 minutes: report `BLOCKED` to Boss Agent with the app URL for manual log inspection: `$COOLIFY_URL` → the project → the app → Deployments.

---

## Step 6 — Cloudflare Tunnel Config

Traffic reaches Coolify's built-in Traefik proxy on **port 80**; Traefik routes to the right container by matching the `Host` header against each app's configured domain. So the tunnel only ever needs to point app hostnames at `http://localhost:80` — never the Coolify dashboard port (8000) and never a container's direct port.

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

Insert each app hostname before the catch-all `- service: http_status:404`. Leave the existing Coolify dashboard entry (e.g. `admin.$DOMAIN → http://localhost:8000`) untouched.

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
- Every app entry points to `http://localhost:80` (not 8000, not a container port)
- No duplicate entries
- Coolify dashboard entry (`admin.$DOMAIN → http://localhost:8000`) is untouched
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
| 301–302 | Redirect (HTTP→HTTPS) | ✅ Pass — follow and recheck. If it loops, check `is_force_https_enabled` is `false` |
| 404 from app | App live, route not found | ✅ Chain works — app-level issue |
| 404 from Traefik | No Coolify app matches that Host | ❌ Domain mismatch — confirm app `domains` == `[APP_NAME].$DOMAIN` |
| 502 / 503 | Container crashed, not running, or wrong `ports_exposes` | ❌ Check Coolify app status + build log |
| 000 | DNS not resolving | ❌ CNAME missing or not propagated — wait 2 min and retry |

### 8.3 — Backend health check

```bash
curl -s "https://[BACKEND_APP_NAME].$DOMAIN/health"
```

### 8.4 — Confirm TESTING_MODE=FALSE in production

Check the startup log:

```bash
curl -s "$COOLIFY_URL/api/v1/applications/$BACKEND_UUID/logs?lines=80" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" | grep -E "TESTING_MODE|ENVIRONMENT"
```

Look for `TESTING_MODE: FALSE` and `ENVIRONMENT: production` in startup output.

---

## Step 9 — Handover to Boss Agent

```markdown
# DevOps Handover

## Deployment: [Feature / Project Name]
## Date: [date]
## Platform: Coolify @ [COOLIFY_URL from machine-config]
## Status: ✅ LIVE | ❌ BLOCKED

## URLs deployed
| App | URL | HTTP status | Chain verified |
|-----|-----|-------------|----------------|
| Backend | https://[backend-name].[DOMAIN] | [code] | ✅ / ❌ |
| Frontend | https://[frontend-name].[DOMAIN] | [code] | ✅ / ❌ |

## Coolify
- Project UUID: [uuid]
| App | UUID | Port | Build pack | Env vars set | Auto-deploy | Build |
|-----|------|------|-----------|-------------|------------|-------|
| [backend] | [uuid] | [port] | nixpacks | ✅ | on | finished |
| [frontend] | [uuid] | [port] | nixpacks | ✅ | on | finished |

## Cloudflare tunnel
- Config file: [CLOUDFLARE_CONFIG_FILE]
- Entries added (→ http://localhost:80): ✅
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

## Auto-deploy
- Both apps connected to [repo] @ main with auto-deploy ON.
- Every push to main redeploys automatically via Coolify's GitHub App webhook.
- No GitHub Actions workflow required.

## Blocked items
- [description] → [what user must do]
```

---

## Step 10 — Auto-Deploy (already on — no GitHub Actions needed)

Because each app was created from the git repo with `is_auto_deploy_enabled: true`, Coolify's GitHub App installs a webhook on the repo automatically. **Every push to `main` triggers a Coolify rebuild** — there is no `.github/workflows/deploy.yml` to create or maintain. This replaces the entire old CapRover + GitHub Actions deploy pipeline.

### 10.1 — Confirm auto-deploy is enabled

```bash
for UUID in "$BACKEND_UUID" "$FRONTEND_UUID"; do
  curl -s "$COOLIFY_URL/api/v1/applications/$UUID" \
    -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name'), 'auto_deploy:', d.get('is_auto_deploy_enabled') if 'is_auto_deploy_enabled' in d else d.get('settings',{}).get('is_auto_deploy_enabled'))"
done
```

If it is off for either app, turn it on:

```bash
curl -s -X PATCH "$COOLIFY_URL/api/v1/applications/$UUID" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"is_auto_deploy_enabled\": true}"
```

### 10.2 — Manual redeploy (when you need to ship without a push)

```bash
curl -s "$COOLIFY_URL/api/v1/deploy?uuid=$BACKEND_UUID" \
  -H "Authorization: Bearer $COOLIFY_API_TOKEN"
```

### 10.3 — Optional: deploy webhook for external CI

If a non-GitHub CI must trigger a deploy, Coolify exposes a per-app deploy webhook (Application → Webhooks in the UI) callable with the API token as a Bearer header. Prefer native git auto-deploy; only wire this up if explicitly required.

---

## Common Mistakes — Never Do These

| Mistake | Result | Fix |
|---------|--------|-----|
| Point cloudflared to the Coolify dashboard port (`localhost:8000`) | App traffic hits the Coolify UI, not your app | App hostnames must point to `http://localhost:80` (Traefik); only `admin.$DOMAIN` points to 8000 |
| Point cloudflared to a container's direct port | Connection refused / bypasses routing | Always `http://localhost:80` — Traefik routes by Host header |
| Edit `~/.cloudflared/config.yml` | Changes ignored | Always edit `CLOUDFLARE_CONFIG_FILE` from machine-config |
| Duplicate hostname in config | Second entry silently ignored | Grep before inserting |
| Missing DNS CNAME | `curl` returns `000` | Create via Cloudflare API |
| `is_force_https_enabled: true` behind the tunnel | Redirect loop (Traefik → https → Cloudflare → http → …) | Set `false`; Cloudflare terminates TLS, tunnel speaks http to Traefik |
| App `domains` set to `https://...` or omitted | Traefik has no router for that Host → 404 | Set `domains: "http://[APP_NAME].$DOMAIN"` |
| Wrong `ports_exposes` | Build OK but 502 — Traefik can't reach the app | Set it to the port the process actually listens on (uvicorn 8000, next 3000) |
| No `start_command` for FastAPI under Nixpacks | Container builds then exits immediately | Set `start_command: uvicorn app.main:app --host 0.0.0.0 --port 8000` |
| Wrong `base_directory` in a monorepo | "no buildable files found" build error | Point each app at its subdirectory |
| Set env vars after `instant_deploy: true` | First build bakes empty `NEXT_PUBLIC_*` into the bundle | Create with `instant_deploy: false`, set envs, then `GET /deploy?...&force=true` |
| Put a secret under a `NEXT_PUBLIC_` name | Secret shipped to the browser | Keep secrets on the backend app only, never `NEXT_PUBLIC_` |
| Commit secrets to the repo for Coolify to read | Secrets in git history | Inject via Coolify env vars (`/envs/bulk`); they live only in Coolify |
| Build a `.github/workflows/deploy.yml` | Redundant + conflicting deploys | Not needed — Coolify auto-deploys from git via its GitHub App webhook |
| Hardcode tunnel ID, domain, or Coolify URL | Breaks on other machines | Always read from `~/.claude/machine-config.md` |
| Store the Coolify token in a project repo | Token leak | Token is machine-scoped — keep it in `~/.claude/machine-config.md` (or untracked `.env`) |
| Reuse a token without `deploy` scope | `GET /deploy` returns 401/403 | Mint a token with `read`, `read:sensitive`, `write`, `deploy` scopes |
