---
description: Install/refresh the Go + Claude Code dev environment (tools, skills, hook, LSP, Context7)
---

# Go dev environment setup

Run the bundled installer from this repository. It is idempotent — safe to run any time
to repair or update the environment.

```bash
./install.sh
```

To pass the Context7 API key without a prompt:

```bash
CONTEXT7_API_KEY=ctx7sk-xxxx ./install.sh
```

After it finishes:

1. Open a new shell (or `source` your shell rc) so `PATH` and `ENABLE_LSP_TOOL` apply.
2. Restart Claude Code so the `go-lsp` plugin, the PostToolUse hook, and the Context7 MCP
   server are picked up.
3. Verify:

   ```bash
   claude mcp list            # expect: context7
   gopls version
   golangci-lint --version
   ```

See `README.md` for the full breakdown of what gets installed and why.
