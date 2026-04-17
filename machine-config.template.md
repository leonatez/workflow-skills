# Machine Config

This file lives at `~/.claude/machine-config.md` on each machine.
It contains infrastructure values that are specific to this machine — not the project.
The DevOps Agent reads this file at the start of every deployment.

Do NOT commit this file to any project repo.
The source template lives in: https://github.com/leonatez/workflow-skills

---

## Deployment capability

<!-- Set to one of: caprover-cloudflare | none -->
DEPLOY_MODE=caprover-cloudflare

---

## CapRover

<!-- The URL of your CapRover dashboard -->
CAPROVER_URL=https://captain.crawlingrobo.com

<!-- CapRover password is stored in each project's .env as CAPROVER_PASSWORD -->
<!-- Do not store it here — it is project-sensitive -->

---

## Cloudflare Tunnel

<!-- Your tunnel ID (find it in: cloudflared tunnel list) -->
TUNNEL_ID=20a4ef64-b536-4021-ac2f-67eb9b17040a

<!-- The CNAME target for DNS records — always TUNNEL_ID.cfargotunnel.com -->
TUNNEL_CNAME_TARGET=20a4ef64-b536-4021-ac2f-67eb9b17040a.cfargotunnel.com

<!-- Full path to the cloudflared config file used by the systemd service -->
CLOUDFLARE_CONFIG_FILE=/etc/cloudflared/config.yml

<!-- Your root domain -->
DOMAIN=crawlingrobo.com

<!-- Cloudflare Zone ID (Cloudflare dashboard → domain → overview → right sidebar) -->
<!-- Stored per-project in .env as CLOUDFLARE_ZONE_ID -->
<!-- Do not store it here — use .env -->

<!-- Cloudflare API token -->
<!-- Stored per-project in .env as CLOUDFLARE_API_TOKEN -->
<!-- Do not store it here — use .env -->

---

## Notes

<!-- Add any machine-specific notes here -->
<!-- e.g. "MiniPC running Ubuntu 22.04, CapRover v1.x, cloudflared v2024.x" -->
NOTES=MiniPC (Mac mini). CapRover at captain.crawlingrobo.com. Cloudflare tunnel active.
