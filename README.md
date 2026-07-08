# go-claude-setup

Portable **Go + Claude Code** development environment. Clone on any machine, run one
script, and get an agent that writes idiomatic Go, checks itself on every edit, and
looks up the latest library docs instead of guessing from stale training data.

It bundles four layers that solve four different failure modes:

| Layer | What it gives Claude | Fixes |
|-------|----------------------|-------|
| **Skills** (`golang-*` from [samber/cc-skills-golang](https://github.com/samber/cc-skills-golang)) | Knowledge of idiomatic Go — style, errors, concurrency, testing, security, patterns | "AI slop" / non-idiomatic code |
| **gopls LSP plugin** ([anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/gopls-lsp)) | Real-time types, definitions, references | Wrong symbols / invented APIs |
| **PostToolUse hook** (`hooks/go-hooks.sh`) | Auto format → compile-gate → vet/lint/gosec/modernize on every edit | Syntax errors slipping through |
| **Context7 MCP** | Live, versioned library documentation | "AI is out of date, can't use new libs" |

## Install

```bash
git clone https://github.com/<you>/go-claude-setup.git
cd go-claude-setup
./install.sh
```

Then open a new shell and restart Claude Code. That's it.

To provide the Context7 API key non-interactively:

```bash
CONTEXT7_API_KEY=ctx7sk-xxxx ./install.sh
```

(Get a key at <https://context7.com/dashboard>. The key is **never** stored in this repo.)

## What `install.sh` does

1. Verifies Go and adds `$(go env GOPATH)/bin` to your PATH (bash/zsh/fish).
2. `go install`s the dev tools: `gopls`, `golangci-lint`, `govulncheck`, `gosec`,
   `goimports`, `staticcheck`, `modernize`.
3. Installs the `golang-*` skills listed in [`skills/golang-skills.txt`](skills/golang-skills.txt) globally.
4. Enables the `gopls-lsp` plugin via `/plugin install gopls-lsp@claude-plugins-official` from [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) (merged into `~/.claude/settings.json`).
5. Copies [`hooks/go-hooks.sh`](hooks/go-hooks.sh) to `~/.claude/hooks/` and wires the
   `PostToolUse` hook.
6. Registers the Context7 MCP server (`claude mcp add`, user scope).
7. Exports `ENABLE_LSP_TOOL=1`.

Everything is **idempotent** — re-running only fills in what's missing. JSON configs are
merged, never clobbered.

## The edit hook

`hooks/go-hooks.sh` runs after every `Edit`/`Write`/`MultiEdit`. For `*.go` files:

1. **format** — `goimports`/`gofmt -w`
2. **compile gate** — `go build`; on failure it reports and stops (analysers can't read
   broken code)
3. **analysers in parallel** — `go vet`, `golangci-lint`, `gosec`, `modernize`

For `go.mod`: `govulncheck`, `go mod tidy -diff`, `go mod verify`. It is non-blocking —
findings are fed back to Claude as context so it can fix them immediately.

## Customising the skill set

Edit [`skills/golang-skills.txt`](skills/golang-skills.txt) — one skill per line, `#`
comments ignored. Add e.g. `golang-spf13-cobra` (CLI), `golang-uber-fx` (DI), or
`golang-stretchr-testify`. Full catalogue: <https://github.com/samber/cc-skills-golang/tree/main/skills>.

## Files

```
install.sh                 one-shot installer (idempotent)
commands/setup.md          /setup slash command (re-run inside Claude Code)
hooks/go-hooks.sh          PostToolUse dispatcher
config/settings.hook.json  hook + plugin snippet merged into settings.json
skills/golang-skills.txt   list of skills to install
rules/context7.md          "always use Context7 for library docs" rule
```
