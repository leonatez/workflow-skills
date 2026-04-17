# workflow-skills

A multi-agent app development workflow for [Claude Code](https://claude.ai/code). Four specialized agents work together under a single orchestrator to take a feature from idea to verified, production-ready code.

---

## Agents

| File | Agent | Role |
|------|-------|------|
| [`boss-agent.md`](boss-agent.md) | **Boss Agent** | Only agent that talks to the user. CEO/Head of PM mindset. Challenges scope, orchestrates all other agents, owns every approval gate, routes bugs, signs off features. |
| [`frontend-pm.md`](frontend-pm.md) | **Frontend PM** | Owns everything the user sees. Produces user stories, wireframes, high-fidelity HTML mockups, and test cases — in that order, with approval gates. |
| [`backend-pm.md`](backend-pm.md) | **Backend PM** | Owns the API, data models, auth, and infrastructure. FastAPI + Supabase stack. Produces architecture doc, OpenAPI spec, structured logging, and power-admin test account. |
| [`qa-agent.md`](qa-agent.md) | **QA Agent** | Owns verification. Backend HTTP tests first, then headed Playwright browser tests the user can watch. Writes live diary, routes bugs to right PM, iterates until everything passes. |
| [`devops-agent.md`](devops-agent.md) | **DevOps Agent** | Owns deployment. Creates Dockerfiles, deploys to CapRover, wires Cloudflare tunnel config, creates DNS records, verifies end-to-end traffic chain. |

---

## How it works

```
You
 └── Boss Agent  (only one that talks to you)
      ├── Phase 0: Collects prerequisites (Supabase keys, ports, Playwright setup, etc.)
      ├── Phase 1: Challenges feature scope before any work starts
      ├── Phase 2: Delegates to Frontend PM + Backend PM in parallel
      │    ├── Frontend PM → user stories → wireframes → mockups → test cases
      │    └── Backend PM → architecture → openapi.yaml → scaffold → implement
      │         [API contract sync gate between both PMs]
      ├── Phase 3: Activates QA Agent
      │    ├── QA Phase 1: Backend HTTP tests (httpx, X-Request-ID proof, log verification)
      │    └── QA Phase 2: Frontend headed browser tests (Playwright MCP, you watch live)
      │         [Bug routing: Frontend PM or Backend PM, max 3 fix rounds]
      ├── Phase 4: Feature sign-off (health score ≥ 80, TESTING_MODE reset to FALSE)
      └── Phase 5: Activates DevOps Agent
           ├── Create Dockerfiles (if not exist)
           ├── Deploy backend + frontend to CapRover
           ├── Add hostnames to /etc/cloudflared/config.yml + restart cloudflared
           ├── Create Cloudflare DNS CNAME records via API
           └── Verify full traffic chain: Browser → Cloudflare → tunnel → nginx → container
```

---

## Fixed stack

Every project built with this workflow uses:

| Layer | Technology |
|-------|-----------|
| API | FastAPI |
| Database + Auth | Supabase |
| Frontend | Any (workflow is framework-agnostic) |
| Browser testing | Playwright MCP (`--headless false`) |
| API testing | `httpx` (Python) |
| Design system | `DESIGN.md` (via gstack `/design-consultation`) |
| Visual QA | gstack `/qa-only` (final sanity pass) |
| Deployment | CapRover at `captain.crawlingrobo.com` |
| Tunnel | Cloudflare Tunnel (`20a4ef64-b536-4021-ac2f-67eb9b17040a`) |
| Domain | `crawlingrobo.com` |

---

## Key design decisions

**Boss Agent is the only user-facing agent.** All other agents communicate through it. You never talk to Frontend PM or Backend PM directly.

**Approval gates are sequential and explicit.** User stories → wireframes → mockups each require your approval before the next stage starts. Nothing advances automatically.

**API contract is locked before implementation.** `openapi.yaml` is synced between Frontend PM and Backend PM before a single endpoint is coded. Schema drift is the leading cause of integration bugs.

**QA tests backend before touching the browser.** HTTP tests confirm the API works in isolation. Only after all backend tests pass does the browser session open.

**Headed browser — you watch live.** Playwright MCP runs with `--headless false`. You see every click. You can interrupt with ESC.

**X-Request-ID traces every flow.** Every HTTP request gets a unique ID attached in FastAPI middleware, returned in response headers, and written to `logs/app.log`. QA Agent confirms each ID appears in logs — closing the proof loop from browser action to internal data flow.

**TESTING_MODE gates the power-admin account.** A power-admin account exists for testing but is rejected at login unless `TESTING_MODE=TRUE` in `.env`. Startup guard in FastAPI prevents `TESTING_MODE=TRUE` from running in `ENVIRONMENT=production`.

---

## Prerequisites (collected by Boss Agent on first run)

- Supabase project URL + anon key + service role key
- Local API port and frontend port
- GitHub repo URL
- Playwright MCP configured: `claude mcp add playwright -- npx @playwright/mcp@latest --headless false`
- Power-admin email preference (default: `admin@[project].test`)
- CapRover app names (backend + frontend) and internal container ports
- CapRover password
- Cloudflare API token + Zone ID for `crawlingrobo.com`

---

## Artifacts produced per feature

| Artifact | Produced by | Purpose |
|----------|-------------|---------|
| `PROJECT_CONFIG.md` | Boss Agent | Project-wide prerequisites and config |
| `FEATURE_BRIEF.md` | Boss Agent | Approved scope, MVP definition, failure modes |
| `USER_STORIES.md` | Frontend PM | User stories, journeys, acceptance criteria |
| `wireframes/*.html` | Frontend PM | Annotated HTML wireframes per screen |
| `mockups/*.html` | Frontend PM | High-fidelity HTML mockups per screen |
| `TEST_CASES.md` | Frontend PM | Annotated acceptance test cases |
| `DESIGN.md` | Frontend PM | Design system source of truth |
| `ARCHITECTURE.md` | Backend PM | Data models, auth flow, data flow per story |
| `openapi.yaml` | Backend PM | Authoritative API contract |
| `TEST_CREDENTIALS.md` | Backend PM | Power-admin credentials (gitignored) |
| `BACKEND_TEST_REPORT.md` | QA Agent | HTTP test proof with X-Request-ID per flow |
| `QA_DIARY.md` | QA Agent | Live test diary with pass/fail per test case |
| `QA_HANDOVER.md` | QA Agent | Final summary, health score, blocked items |
| `Dockerfile` | DevOps Agent | Backend container definition |
| `Dockerfile.frontend` | DevOps Agent | Frontend container definition |
| `captain-definition` | DevOps Agent | CapRover build config (backend) |
| `DEVOPS_HANDOVER.md` | DevOps Agent | Deployment summary, live URLs, DNS records created |

---

## Installation

Clone the repo and run the installer on each machine:

```bash
git clone https://github.com/leonatez/workflow-skills.git
cd workflow-skills
./install.sh
```

The installer:
- Copies all 5 agent files to `~/.claude/skills/[agent-name]/SKILL.md` (machine-level, applies to all projects)
- Creates `~/.claude/machine-config.md` from the template if it doesn't exist yet (never overwrites)
- Is safe to re-run

After installing, open `~/.claude/machine-config.md` and fill in the values for that machine:

```
DEPLOY_MODE=caprover-cloudflare
CAPROVER_URL=https://captain.yourdomain.com
TUNNEL_ID=your-tunnel-id
TUNNEL_CNAME_TARGET=your-tunnel-id.cfargotunnel.com
CLOUDFLARE_CONFIG_FILE=/etc/cloudflared/config.yml
DOMAIN=yourdomain.com
```

Sensitive values (CapRover password, Cloudflare API token) are **not** stored in machine-config — they go in each project's `.env` file.

---

## Related

- [`leonatez/claude-drawio-skills`](https://github.com/leonatez/claude-drawio-skills) — Convert diagram images to draw.io files and edit existing draw.io files
