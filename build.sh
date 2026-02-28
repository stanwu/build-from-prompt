#!/usr/bin/env bash
# build.sh — Universal Markdown Prompt Runner
#
# Usage:
#   ./build.sh --prompt <prompt.md>
#   ./build.sh --prompt <prompt.md> --agent gemini
#   ./build.sh --prompt <prompt.md> --agent codex
#   ./build.sh --prompt <prompt.md> --context <context.md>
#   ./build.sh --prompt <prompt.md> --output-dir /path/to/dir
#   ./build.sh --prompt <prompt.md> --max-chars 8000
#   ./build.sh --dry-run --prompt <prompt.md>
#
# Options:
#   --prompt     <file>  Path to the .md prompt file (required)
#   --agent      <name>  AI agent: claude (default), gemini, codex
#   --context    <file>  Optional .md file prepended before the prompt
#   --output-dir <dir>   Working directory where agent executes (default: $PWD)
#   --max-chars  <N>     Split prompt into chunks if it exceeds N chars (0 = off)
#   --dry-run            Print assembled prompt without calling the agent
#   --no-sentinel        Always run even if sentinel exists
#   --skip-security-check  Skip prompt security scan (credentials, injection)
#   -h|--help            Show this help message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE=""
CONTEXT_FILE=""
OUTPUT_DIR="$PWD"
AGENT="claude"
DRY_RUN=""
NO_SENTINEL=""
MAX_CHARS=0
SKIP_SECURITY=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prompt)      PROMPT_FILE="$2";  shift 2 ;;
        --context)     CONTEXT_FILE="$2"; shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";   shift 2 ;;
        --no-sentinel)         NO_SENTINEL=1;    shift   ;;
        --skip-security-check) SKIP_SECURITY=1;  shift   ;;
        --max-chars)
            [[ "$2" =~ ^[0-9]+$ ]] || { echo "Invalid --max-chars value: $2" >&2; exit 1; }
            MAX_CHARS="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1;         shift   ;;
        --agent)
            case "$2" in
                claude|gemini|codex) AGENT="$2" ;;
                *) echo "Unknown agent: $2. Choose: claude, gemini, codex" >&2; exit 1 ;;
            esac
            shift 2 ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[build]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn] ${NC} $*"; }
info() { echo -e "${CYAN}[info] ${NC} $*"; }
fail() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ── Validate inputs ───────────────────────────────────────────────────────────
[[ -z "$PROMPT_FILE" ]] && fail "--prompt <file.md> is required."

resolve_file() {
    local f="$1" label="$2"
    if [[ -f "$f" ]]; then
        echo "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
    elif [[ -f "$SCRIPT_DIR/$f" ]]; then
        echo "$SCRIPT_DIR/$f"
    else
        fail "$label not found: $f"
    fi
}

PROMPT_FILE="$(resolve_file "$PROMPT_FILE" "Prompt file")"
[[ -n "$CONTEXT_FILE" ]] && CONTEXT_FILE="$(resolve_file "$CONTEXT_FILE" "Context file")"

# ── Dependency check ──────────────────────────────────────────────────────────
[[ -z "$DRY_RUN" ]] && \
    command -v "$AGENT" >/dev/null 2>&1 || \
    { [[ -z "$DRY_RUN" ]] && fail "$AGENT CLI not found in PATH."; }

# ── Sentinel setup ────────────────────────────────────────────────────────────
BUILT_DIR="$OUTPUT_DIR/.built"
PROMPT_BASENAME="$(basename "$PROMPT_FILE" .md)"
SENTINEL="$BUILT_DIR/$PROMPT_BASENAME"

mkdir -p "$OUTPUT_DIR" "$BUILT_DIR"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
info "Prompt file  : $PROMPT_FILE"
[[ -n "$CONTEXT_FILE"  ]] && info "Context file : $CONTEXT_FILE"
info "Output dir   : $OUTPUT_DIR"
info "Agent        : ${BOLD}$AGENT${NC}"
[[ $MAX_CHARS -gt 0   ]] && info "Max chars    : $MAX_CHARS (auto-chunk enabled)"
[[ -n "$DRY_RUN"      ]] && warn "Dry-run mode  : nothing will be executed"
[[ -n "$NO_SENTINEL"  ]] && warn "No-sentinel   : sentinel check disabled"
echo ""

# ── Sentinel check ────────────────────────────────────────────────────────────
if [[ -z "$NO_SENTINEL" && -f "$SENTINEL" ]]; then
    warn "Already ran: $PROMPT_BASENAME (sentinel: $SENTINEL)"
    warn "Use --no-sentinel to force re-run, or: rm $SENTINEL"
    exit 0
fi

# ── Agent runner ──────────────────────────────────────────────────────────────
run_agent() {
    local prompt="$1"
    case "$AGENT" in
        claude) claude --dangerously-skip-permissions -p "$prompt" ;;
        gemini) gemini --yolo -p "$prompt" ;;
        codex)  echo "$prompt" | codex exec --dangerously-bypass-approvals-and-sandbox - ;;
    esac
}

# ── Assemble final prompt ─────────────────────────────────────────────────────
assemble_prompt() {
    local out=""
    if [[ -n "$CONTEXT_FILE" ]]; then
        out+="$(cat "$CONTEXT_FILE")"
        out+=$'\n\n---\n\n'
    fi
    out+="$(cat "$PROMPT_FILE")"
    out+=$'\n\n---\n\n'
    out+="Implement ALL deliverables listed above. "
    out+="Create every required file in the current working directory. "
    out+="Do not ask clarifying questions — implement everything now."
    printf '%s' "$out"
}

# ── Prompt chunker ────────────────────────────────────────────────────────────
# Splits $1 (raw text) into numbered chunk files under $2 (tmpdir),
# respecting a max of $3 chars per chunk.  Prefers splitting at Markdown
# section headers, falls back to blank lines, then forces a split when the
# chunk is already at or beyond the limit.  Prints the number of chunks.
chunk_prompt() {
    local text="$1" tmpdir="$2" max="$3"
    printf '%s' "$text" | awk -v max="$max" -v dir="$tmpdir" '
    BEGIN { chunk=1; size=0; out=dir "/chunk_1.txt" }
    {
        len = length($0) + 1
        is_boundary = ($0 ~ /^#{1,6} / || $0 == "")
        if (size > 0 && size + len > max && (is_boundary || size >= max)) {
            close(out); chunk++; out=dir "/chunk_" chunk ".txt"; size=0
        }
        print > out
        size += len
    }
    END { close(out); cnt=dir "/count.txt"; print chunk > cnt; close(cnt) }
    '
    cat "$tmpdir/count.txt"
}

# ── Chunked / single-shot runner ──────────────────────────────────────────────
# Reads raw prompt-file content, splits into chunks when MAX_CHARS > 0 and the
# content exceeds the limit, assembles each chunk with context + label +
# instructions, and runs the agent on each in sequence.
run_with_chunks() {
    local prompt_content="$1"
    local char_count=${#prompt_content}

    # ── No splitting needed ──────────────────────────────────────────────────
    if [[ $MAX_CHARS -le 0 || $char_count -le $MAX_CHARS ]]; then
        run_agent "$(assemble_prompt)"
        return
    fi

    # ── Split into chunks ────────────────────────────────────────────────────
    local tmpdir
    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local total
    total="$(chunk_prompt "$prompt_content" "$tmpdir" "$MAX_CHARS")"

    warn "Prompt is $char_count chars — splitting into $total chunks (max $MAX_CHARS chars each)"
    echo ""

    local i
    for ((i=1; i<=total; i++)); do
        local chunk_text assembled=""
        chunk_text="$(cat "$tmpdir/chunk_$i.txt")"

        # Prepend context file to every chunk so each run has full background
        if [[ -n "$CONTEXT_FILE" ]]; then
            assembled+="$(cat "$CONTEXT_FILE")"
            assembled+=$'\n\n---\n\n'
        fi

        assembled+="[Part $i of $total — $(basename "$PROMPT_FILE")]"
        assembled+=$'\n\n'
        assembled+="$chunk_text"
        assembled+=$'\n\n---\n\n'
        assembled+="Implement ALL deliverables listed in this section (part $i of $total). "
        assembled+="Create every required file in the current working directory. "
        assembled+="Do not ask clarifying questions — implement everything now."

        echo -e "${CYAN}━━━ Running $AGENT — part $i of $total ━━━${NC}"
        run_agent "$assembled"
        log "Part $i of $total complete."
        echo ""
    done
}

# ── Security scanner ──────────────────────────────────────────────────────────
# Scans $1 (text content) for security issues; labels findings with $2 (name).
# Prints each finding.  Returns the number of BLOCKING issues found.
#
# BLOCK — credential/secret leakage: aborts the run.
# WARN  — prompt-injection patterns, dangerous shell idioms: advisory only.
check_security() {
    local content="$1" label="$2"
    local errors=0 warnings=0

    # Inner helper: grep $content with the supplied grep flags + pattern.
    # Signature: _sec_match LEVEL DESC [grep-flags] PATTERN
    # The PATTERN is always the last argument and is passed via -e to prevent
    # patterns starting with "-" (e.g. PEM headers) being read as grep flags.
    _sec_match() {
        local level="$1" desc="$2"; shift 2
        local args=("$@")
        local last=$(( ${#args[@]} - 1 ))
        local pattern="${args[$last]}"
        local flags=("${args[@]:0:$last}")
        if printf '%s' "$content" | grep -q "${flags[@]}" -e "$pattern" 2>/dev/null; then
            if [[ "$level" == BLOCK ]]; then
                echo -e "  ${RED}[BLOCK]${NC} $desc"
                errors=$((errors + 1))
            else
                echo -e "  ${YELLOW}[WARN] ${NC} $desc"
                warnings=$((warnings + 1))
            fi
        fi
    }

    # ── Credentials / secrets (BLOCK) ─────────────────────────────────────
    _sec_match BLOCK "PEM private key or certificate" \
        -E '-----BEGIN[[:space:]]+(RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----|-----BEGIN CERTIFICATE-----'
    _sec_match BLOCK "OpenAI API key (sk-…)" \
        -E 'sk-[A-Za-z0-9_-]{24,}'
    _sec_match BLOCK "Anthropic API key (sk-ant-…)" \
        -E 'sk-ant-[A-Za-z0-9-]{20,}'
    _sec_match BLOCK "GitHub personal access token (ghp_/ghs_/gho_)" \
        -E 'gh[pso]_[A-Za-z0-9]{36,}'
    _sec_match BLOCK "AWS access key ID (AKIA…)" \
        -E 'AKIA[A-Z0-9]{16}'
    _sec_match BLOCK "Generic Bearer token" \
        -E 'Bearer[[:space:]]+[A-Za-z0-9+/=._-]{32,}'
    _sec_match WARN  "Possible inline credential (password/secret/token/key=…)" \
        -iE '(password|passwd|secret|api_?key|auth_?token)[[:space:]]*[:=][[:space:]]*[^[:space:]]{8,}'

    # ── Prompt injection (WARN) ────────────────────────────────────────────
    _sec_match WARN "Prompt injection — instruction override" \
        -iE 'ignore .{0,30}instructions?'
    _sec_match WARN "Prompt injection — context/identity reset" \
        -iE '(forget everything|disregard all|you are now a[^a-z])'
    _sec_match WARN "Prompt injection — system prompt override" \
        -iE 'new (system prompt|system message|system instruction)'
    _sec_match WARN "Prompt injection — jailbreak framing" \
        -iE '(DAN mode|developer mode|jailbreak|pretend (you have no|there are no) (restrictions|limits))'

    # ── Dangerous shell patterns requested in prompt (WARN) ───────────────
    _sec_match WARN "Destructive rm -rf in prompt" \
        -E 'rm[[:space:]]+-rf[[:space:]]+'
    _sec_match WARN "Pipe-to-shell pattern (curl/wget | sh)" \
        -E '(curl|wget)[^|]*\|[[:space:]]*(ba)?sh'
    _sec_match WARN "Base64-encoded command execution" \
        -E '(base64[[:space:]]+-d|base64[[:space:]]+--decode)[^|]*\|[[:space:]]*(ba)?sh'

    # ── Summary ───────────────────────────────────────────────────────────
    if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} No issues found in $label"
    else
        [[ $warnings -gt 0 ]] && \
            echo -e "  ${YELLOW}→${NC} $warnings warning(s) in $label — review before proceeding"
        [[ $errors -gt 0 ]] && \
            echo -e "  ${RED}→${NC} $errors blocking issue(s) in $label"
    fi

    return $errors
}

# ── Execute ───────────────────────────────────────────────────────────────────
PROMPT_CONTENT="$(cat "$PROMPT_FILE")"
CHAR_COUNT=${#PROMPT_CONTENT}

# ── Security scan ─────────────────────────────────────────────────────────────
if [[ -z "$SKIP_SECURITY" ]]; then
    echo -e "${CYAN}[security]${NC} Scanning for credentials, injection, and dangerous patterns..."
    sec_errors=0

    check_security "$PROMPT_CONTENT" "$(basename "$PROMPT_FILE")" || sec_errors=$?

    if [[ -n "$CONTEXT_FILE" ]]; then
        check_security "$(cat "$CONTEXT_FILE")" "$(basename "$CONTEXT_FILE")" || \
            sec_errors=$((sec_errors + $?))
    fi

    if [[ $sec_errors -gt 0 ]]; then
        echo ""
        fail "$sec_errors blocking issue(s) found. Fix them or pass --skip-security-check to override."
    fi
    echo ""
fi

if [[ -n "$DRY_RUN" ]]; then
    ASSEMBLED="$(assemble_prompt)"
    echo -e "${CYAN}━━━ Assembled prompt (dry-run, ${CHAR_COUNT} chars) ━━━${NC}"
    echo ""
    printf '%s\n' "$ASSEMBLED"
    echo ""
    echo -e "${CYAN}━━━ End of prompt ━━━${NC}"
    if [[ $MAX_CHARS -gt 0 && $CHAR_COUNT -gt $MAX_CHARS ]]; then
        warn "Prompt exceeds $MAX_CHARS chars — would split into chunks"
    fi
    log "Would run: $AGENT -p <prompt above>"
else
    echo -e "${CYAN}━━━ Running $AGENT on: $(basename "$PROMPT_FILE") ━━━${NC}"
    (cd "$OUTPUT_DIR" && run_with_chunks "$PROMPT_CONTENT")
    touch "$SENTINEL"
    echo ""
    log "Done. Sentinel written: $SENTINEL"
fi
