#!/usr/bin/env bash
# Claude Code PostToolUse dispatcher for Go — written from scratch.
#
# The zircote/go-lsp plugin DOCUMENTS these hooks but ships an empty hooks.json,
# so this script implements them. Wired in settings.json on the
# Edit|Write|MultiEdit matcher; it gates by filename.
#
# Algorithm (the point of this version):
#   *.go:
#     STAGE 1  format      goimports/gofmt -w      (WRITES the file -> must run
#                                                    first and alone; the readers
#                                                    below would otherwise race it)
#     STAGE 2  compile gate go build -o /dev/null . (if it fails, report and STOP:
#                                                    vet/lint/gosec/modernize can't
#                                                    analyse non-compiling code and
#                                                    would just echo the same error)
#     STAGE 3  analysers    go vet | golangci-lint | gosec | modernize
#                           run in PARALLEL (all read-only, independent); output
#                           captured to temp files, assembled in a fixed order.
#   go.mod:  govulncheck | go mod tidy -diff | go mod verify  (parallel, read-only)
#
# Everything is bounded with `head`, every tool guarded with `command -v`
# (missing tools skipped), NON-BLOCKING: findings go back to Claude as a single
# additionalContext, exit is always 0.
set -u

input=$(cat)
f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)
[ -n "$f" ] && [ -f "$f" ] || exit 0

dir=$(dirname "$f")
tmpd=$(mktemp -d "${TMPDIR:-/tmp}/gohooks.XXXXXX") || exit 0
trap 'rm -rf "$tmpd"' EXIT

ctx=""
add() {  # add <label> <body>; appends only if body is non-empty
  [ -z "$2" ] && return 0
  [ -n "$ctx" ] && ctx="$ctx"$'\n\n'
  ctx="${ctx}[$1] $f"$'\n'"$2"
}
slurp() { [ -f "$1" ] && cat "$1"; }  # safe read of a (maybe absent) temp file

# Locate the module root (walk up for go.mod).
modroot="$dir"
while [ "$modroot" != "/" ] && [ "$modroot" != "." ]; do
  [ -f "$modroot/go.mod" ] && break
  modroot=$(dirname "$modroot")
done
has_mod=0; [ -f "$modroot/go.mod" ] && has_mod=1

case "$(basename "$f")" in
  go.mod)
    [ "$has_mod" = 1 ] || exit 0
    command -v govulncheck >/dev/null 2>&1 && ( cd "$modroot" && govulncheck ./... 2>&1 )            >"$tmpd/vuln"   &
    command -v go          >/dev/null 2>&1 && ( cd "$modroot" && go mod tidy -diff 2>&1 | grep -v '^go: warning:' | head -15 ) >"$tmpd/tidy"   &
    command -v go          >/dev/null 2>&1 && ( cd "$modroot" && go mod verify 2>&1 )                >"$tmpd/verify" &
    wait
    if [ -f "$tmpd/vuln" ] && grep -q 'Vulnerability #' "$tmpd/vuln"; then
      add govulncheck "$(grep -E 'Vulnerability #|Your code|More info' "$tmpd/vuln" | head -20)"
    fi
    add "go mod tidy -diff" "$(slurp "$tmpd/tidy")"
    add "go mod verify"     "$(slurp "$tmpd/verify" | grep -v '^all modules verified$' | head -10)"
    ;;

  *.go)
    # STAGE 1 — format (WRITE; serial, must finish before any reader).
    if   command -v goimports >/dev/null 2>&1; then goimports -w "$f" 2>/dev/null
    elif command -v gofmt     >/dev/null 2>&1; then gofmt     -w "$f" 2>/dev/null; fi

    # TODO/FIXME — read-only, no compile needed.
    add "TODO/FIXME" "$(grep -nE '\b(TODO|FIXME)\b' "$f" 2>/dev/null | head -15)"

    if [ "$has_mod" = 1 ] && command -v go >/dev/null 2>&1; then
      # STAGE 2 — compile gate.
      build_out=$(cd "$dir" && go build -o /dev/null . 2>&1 | head -20)
      if [ -n "$build_out" ]; then
        add "go build" "$build_out"            # broken build -> report & skip analysers
      else
        # STAGE 3 — independent analysers in parallel (build cache is concurrency-safe).
        ( cd "$dir" && go vet . 2>&1 | head -25 ) >"$tmpd/vet" &
        command -v golangci-lint >/dev/null 2>&1 && ( cd "$dir" && golangci-lint run --disable=govet 2>&1 | grep -E '\.go:[0-9]' | head -25 ) >"$tmpd/lint"      &
        command -v gosec         >/dev/null 2>&1 && ( cd "$dir" && gosec -color=false . 2>/dev/null      | grep -E 'Severity:'  | head -20 ) >"$tmpd/gosec"     &
        command -v modernize     >/dev/null 2>&1 && ( cd "$dir" && modernize . 2>&1                      | grep -E '\.go:[0-9]' | head -25 ) >"$tmpd/modernize" &
        wait
        add "go vet"        "$(slurp "$tmpd/vet")"
        add "golangci-lint" "$(slurp "$tmpd/lint")"
        add "gosec"         "$(slurp "$tmpd/gosec")"
        add "modernize"     "$(slurp "$tmpd/modernize")"
      fi
    fi
    ;;

  *) exit 0 ;;
esac

[ -n "$ctx" ] && jq -n --arg ctx "$ctx" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}'
exit 0
