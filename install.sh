#!/usr/bin/env bash
# install.sh — one-shot setup of a Go + Claude Code development environment.
#
# Clone this repo on any machine and run ./install.sh. It installs:
#   1. Go toolchain checks + ~/go/bin on PATH
#   2. Go dev tools     : gopls, golangci-lint, govulncheck, gosec, goimports,
#                         staticcheck, modernize
#   3. Claude skills    : the golang-* skills from samber/cc-skills-golang (global)
#   4. go-lsp plugin    : zircote/go-lsp (real-time LSP inside Claude Code)
#   5. PostToolUse hook : go-hooks.sh — auto format/build/vet/lint/gosec on every edit
#   6. Context7 MCP     : live library docs (needs a Context7 API key)
#   7. ENABLE_LSP_TOOL=1 exported in your shell rc
#
# Idempotent: safe to re-run. Nothing here is destructive; JSON configs are
# merged, not overwritten.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_JSON="$HOME/.claude.json"
SETTINGS="$CLAUDE_DIR/settings.json"

# ---------- pretty logging ----------
c_reset=$'\033[0m'; c_blue=$'\033[34m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'
step() { printf '\n%s==>%s %s\n' "$c_blue" "$c_reset" "$1"; }
ok()   { printf '  %s✓%s %s\n' "$c_green" "$c_reset" "$1"; }
warn() { printf '  %s!%s %s\n' "$c_yellow" "$c_reset" "$1"; }
die()  { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- 0. preflight ----------
step "Preflight — checking prerequisites"
have go   || die "Go tidak ditemukan. Install dari https://go.dev/dl lalu jalankan ulang."
have git  || die "git tidak ditemukan."
have node || warn "node/npx tidak ditemukan — langkah skill akan dilewati (install Node.js untuk skill)."
ok "Go $(go version | awk '{print $3}')"
GOBIN="$(go env GOPATH)/bin"

# ---------- 1. PATH ----------
step "PATH — memastikan $GOBIN ada di PATH"
export PATH="$PATH:$GOBIN"
add_path_line() {
  local rc="$1" line="$2"
  [ -f "$rc" ] || return 0
  grep -qF "$line" "$rc" 2>/dev/null || { printf '\n%s\n' "$line" >>"$rc"; ok "PATH ditambahkan ke $rc"; }
}
add_path_line "$HOME/.bashrc" 'export PATH="$PATH:$(go env GOPATH)/bin"'
add_path_line "$HOME/.zshrc"  'export PATH="$PATH:$(go env GOPATH)/bin"'
if [ -f "$HOME/.config/fish/config.fish" ]; then
  grep -qF 'go env GOPATH' "$HOME/.config/fish/config.fish" 2>/dev/null || {
    printf '\nfish_add_path (go env GOPATH)/bin\n' >>"$HOME/.config/fish/config.fish"
    ok "PATH ditambahkan ke fish config"
  }
fi

# ---------- 2. Go dev tools ----------
step "Go tools — install/update (gopls, linters, security, modernize)"
install_tool() {  # install_tool <bin-name> <go-install-path>
  if have "$1"; then ok "$1 sudah ada"; else
    printf '  … go install %s\n' "$2"
    go install "$2" && ok "$1 terpasang" || warn "gagal install $1"
  fi
}
install_tool gopls          golang.org/x/tools/gopls@latest
install_tool golangci-lint  github.com/golangci/golangci-lint/cmd/golangci-lint@latest
install_tool govulncheck    golang.org/x/vuln/cmd/govulncheck@latest
install_tool gosec          github.com/securego/gosec/v2/cmd/gosec@latest
install_tool goimports      golang.org/x/tools/cmd/goimports@latest
install_tool staticcheck    honnef.co/go/tools/cmd/staticcheck@latest
install_tool modernize      golang.org/x/tools/gopls/internal/analysis/modernize/cmd/modernize@latest

# ---------- 3. Claude golang skills ----------
step "Skills — install golang-* dari samber/cc-skills-golang (global)"
if have npx; then
  while IFS= read -r skill; do
    skill="${skill%%#*}"; skill="$(printf '%s' "$skill" | tr -d '[:space:]')"
    [ -z "$skill" ] && continue
    if [ -d "$CLAUDE_DIR/skills/$skill" ]; then
      ok "$skill sudah ada"
    else
      printf '  … %s\n' "$skill"
      npx -y skills add "samber/cc-skills-golang@$skill" -g -y >/dev/null 2>&1 \
        && ok "$skill terpasang" || warn "gagal: $skill"
    fi
  done < "$REPO_DIR/skills/golang-skills.txt"
else
  warn "npx tidak ada — lewati skills. Install Node.js lalu jalankan ulang."
fi

# ---------- 4 & 5. hook script + settings.json merge (plugin, hook) ----------
step "Hook — pasang go-hooks.sh + wire ke settings.json"
mkdir -p "$CLAUDE_DIR/hooks"
cp "$REPO_DIR/hooks/go-hooks.sh" "$CLAUDE_DIR/hooks/go-hooks.sh"
chmod +x "$CLAUDE_DIR/hooks/go-hooks.sh"
ok "go-hooks.sh disalin ke $CLAUDE_DIR/hooks/"

# Merge config/settings.hook.json (with CLAUDE_HOOKS_DIR substituted) into settings.json
python3 - "$SETTINGS" "$REPO_DIR/config/settings.hook.json" "$CLAUDE_DIR/hooks" <<'PY'
import json, os, sys
settings_path, template_path, hooks_dir = sys.argv[1], sys.argv[2], sys.argv[3]
tmpl = json.load(open(template_path))
# substitute the hooks dir placeholder
def sub(o):
    if isinstance(o, str): return o.replace("CLAUDE_HOOKS_DIR", hooks_dir)
    if isinstance(o, list): return [sub(x) for x in o]
    if isinstance(o, dict): return {k: sub(v) for k, v in o.items()}
    return o
tmpl = sub(tmpl)
s = {}
if os.path.exists(settings_path):
    try: s = json.load(open(settings_path))
    except Exception: s = {}
# --- hooks.PostToolUse: add our matcher only if not already present ---
hooks = s.setdefault("hooks", {})
ptu = hooks.setdefault("PostToolUse", [])
our_cmd = tmpl["hooks"]["PostToolUse"][0]["hooks"][0]["command"]
def has_cmd(arr, cmd):
    for entry in arr:
        for h in entry.get("hooks", []):
            if h.get("command") == cmd: return True
    return False
if not has_cmd(ptu, our_cmd):
    ptu.extend(tmpl["hooks"]["PostToolUse"])
    print("  hook PostToolUse ditambahkan")
else:
    print("  hook PostToolUse sudah ada")
# --- enabledPlugins + extraKnownMarketplaces (go-lsp) ---
s.setdefault("enabledPlugins", {}).update(tmpl["enabledPlugins"])
s.setdefault("extraKnownMarketplaces", {}).update(tmpl["extraKnownMarketplaces"])
json.dump(s, open(settings_path, "w"), indent=2)
open(settings_path, "a").write("\n")
PY
ok "settings.json diperbarui (hook + go-lsp plugin)"

# ---------- 6. context7 rule ----------
step "Rules — pasang aturan penggunaan Context7"
mkdir -p "$CLAUDE_DIR/rules"
cp "$REPO_DIR/rules/context7.md" "$CLAUDE_DIR/rules/context7.md"
ok "rules/context7.md disalin"

# ---------- 7. Context7 MCP server ----------
step "MCP — daftarkan Context7 (docs library terbaru)"
CTX7_URL="https://mcp.context7.com/mcp"
if python3 -c "import json,sys; d=json.load(open('$CLAUDE_JSON')); sys.exit(0 if 'context7' in d.get('mcpServers',{}) else 1)" 2>/dev/null; then
  ok "Context7 sudah terdaftar — dilewati"
else
  KEY="${CONTEXT7_API_KEY:-}"
  if [ -z "$KEY" ] && [ -t 0 ]; then
    printf '  Masukkan Context7 API key (ambil di https://context7.com/dashboard, kosongkan untuk skip): '
    read -r KEY
  fi
  if [ -z "$KEY" ]; then
    warn "Tanpa API key — Context7 dilewati. Nanti jalankan:"
    printf '      claude mcp add --transport http --scope user context7 %s --header "CONTEXT7_API_KEY: <KEY>"\n' "$CTX7_URL"
  elif have claude; then
    claude mcp add --transport http --scope user context7 "$CTX7_URL" --header "CONTEXT7_API_KEY: $KEY" \
      && ok "Context7 MCP terdaftar (scope user)" || warn "gagal daftar Context7 via CLI"
  else
    warn "claude CLI tidak ada — Context7 dilewati."
  fi
fi

# ---------- 8. ENABLE_LSP_TOOL ----------
step "LSP — aktifkan tool LSP di Claude Code (ENABLE_LSP_TOOL=1)"
add_env_line() {  # add_env_line <rc> <line> <needle>
  local rc="$1" line="$2" needle="$3"
  [ -f "$rc" ] || return 0
  grep -qF "$needle" "$rc" 2>/dev/null || { printf '\n%s\n' "$line" >>"$rc"; ok "ENABLE_LSP_TOOL diset di $rc"; }
}
add_env_line "$HOME/.bashrc" 'export ENABLE_LSP_TOOL=1' 'ENABLE_LSP_TOOL'
add_env_line "$HOME/.zshrc"  'export ENABLE_LSP_TOOL=1' 'ENABLE_LSP_TOOL'
add_env_line "$HOME/.config/fish/config.fish" 'set -gx ENABLE_LSP_TOOL 1' 'ENABLE_LSP_TOOL'

# ---------- done ----------
printf '\n%s✓ Selesai!%s\n' "$c_green" "$c_reset"
cat <<EOF

Langkah terakhir:
  • Buka shell baru (atau: source ~/.bashrc / ~/.zshrc) agar PATH & ENABLE_LSP_TOOL aktif.
  • Restart Claude Code agar plugin go-lsp, hook, dan Context7 MCP kebaca.
  • Verifikasi: claude mcp list   (harus ada 'context7')
                gopls version && golangci-lint --version
EOF
