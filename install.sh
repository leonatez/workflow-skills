#!/usr/bin/env bash
# workflow-skills installer
# Installs all 5 agents as Claude Code machine-level skills
# and sets up ~/.claude/machine-config.md if not already present.
# Safe to re-run — never overwrites existing machine-config.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"
MACHINE_CONFIG="$HOME/.claude/machine-config.md"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC}  $1"; }
warn() { echo -e "${YELLOW}!${NC}  $1"; }

echo ""
echo "workflow-skills installer"
echo "========================="
echo ""

# --- Install agents as machine-level skills ---

declare -A AGENTS=(
  ["boss-agent"]="boss-agent.md"
  ["frontend-pm"]="frontend-pm.md"
  ["backend-pm"]="backend-pm.md"
  ["qa-agent"]="qa-agent.md"
  ["devops-agent"]="devops-agent.md"
)

for skill_name in boss-agent frontend-pm backend-pm qa-agent devops-agent; do
  src="$SCRIPT_DIR/${AGENTS[$skill_name]}"
  dest_dir="$SKILLS_DIR/$skill_name"
  dest="$dest_dir/SKILL.md"

  if [[ ! -f "$src" ]]; then
    warn "Source not found, skipping: $src"
    continue
  fi

  mkdir -p "$dest_dir"
  cp "$src" "$dest"
  ok "Installed skill: $skill_name → $dest"
done

echo ""

# --- Set up machine-config.md (never overwrites) ---

if [[ -f "$MACHINE_CONFIG" ]]; then
  warn "machine-config.md already exists — not overwritten: $MACHINE_CONFIG"
else
  mkdir -p "$(dirname "$MACHINE_CONFIG")"
  cp "$SCRIPT_DIR/machine-config.template.md" "$MACHINE_CONFIG"
  ok "Created machine config: $MACHINE_CONFIG"
  echo ""
  echo "  Next step: edit $MACHINE_CONFIG"
  echo "  Fill in your CAPROVER_URL, TUNNEL_ID, TUNNEL_CNAME_TARGET,"
  echo "  CLOUDFLARE_CONFIG_FILE, and DOMAIN for this machine."
fi

echo ""
echo "Done. All 5 agents are now available as machine-level skills."
echo "Activate any agent in Claude Code with: /boss-agent, /frontend-pm, etc."
echo ""
