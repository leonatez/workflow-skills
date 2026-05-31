# Machine Config

This file lives at `~/.claude/machine-config.md` on each machine.
It contains infrastructure values that are specific to this machine — not the project.
The DevOps Agent reads this file at the start of every deployment.

Do NOT commit this file to any project repo.
The source template lives in: https://github.com/leonatez/workflow-skills

---

## Deployment capability

<!-- Set to one of: coolify-cloudflare | none -->
DEPLOY_MODE=coolify-cloudflare

---

## Coolify

<!-- Base URL of the Coolify instance. Use localhost when the agent runs on the same box. -->
COOLIFY_URL=http://localhost:8000

<!-- Coolify API token in ID|secret format. -->
<!-- Mint at: Coolify dashboard → Keys & Tokens → API tokens -->
<!-- Scopes required: read, read:sensitive, write, deploy -->
<!-- This token is machine/team-scoped (not project-specific). It lives here because -->
<!-- this file is local-only and never committed. (Agent also falls back to .env.) -->
COOLIFY_API_TOKEN=

<!-- Target server UUID. Leave blank to auto-detect the first/only server. -->
<!-- Find via: GET /api/v1/servers -->
COOLIFY_SERVER_UUID=

<!-- UUID of the GitHub App connected inside Coolify (Sources → GitHub App). -->
<!-- Leave blank to auto-detect the first connected app. Find via: GET /api/v1/github-apps -->
GITHUB_APP_UUID=

---

## GitHub

<!-- Personal Access Token for GitHub API calls (repo scope). Machine-scoped. -->
<!-- Used for pushing commits, reading/creating repos, managing repo secrets, etc. -->
<!-- This file is local-only and never committed. -->
GITHUB_PAT=

---

## Cloudflare Tunnel

<!-- Your tunnel ID (find it in: cloudflared tunnel list) -->
TUNNEL_ID=a27daddb-e6e9-49b8-8925-06a80210415f

<!-- The CNAME target for DNS records — always TUNNEL_ID.cfargotunnel.com -->
TUNNEL_CNAME_TARGET=a27daddb-e6e9-49b8-8925-06a80210415f.cfargotunnel.com

<!-- Full path to the cloudflared config file used by the systemd service -->
CLOUDFLARE_CONFIG_FILE=/etc/cloudflared/config.yml

<!-- Your root domain -->
DOMAIN=enginxlabs.com

<!-- Cloudflare Zone ID (Cloudflare dashboard → domain → overview → right sidebar) -->
<!-- Stored per-project in .env as CLOUDFLARE_ZONE_ID -->
<!-- Do not store it here — use .env -->

<!-- Cloudflare API token -->
<!-- Stored per-project in .env as CLOUDFLARE_API_TOKEN -->
<!-- Do not store it here — use .env -->

---

## Notes

<!-- Add any machine-specific notes here -->
<!-- e.g. "MiniPC running Ubuntu 22.04, Coolify v4.x, cloudflared v2024.x" -->
NOTES=This PC. Coolify at http://localhost:8000, dashboard via tunnel at admin.enginxlabs.com. Cloudflare tunnel active. App traffic routes through Coolify's Traefik proxy on :80.
