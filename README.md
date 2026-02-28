# prompt-make

[![CI](https://github.com/stanwu/prompt-make/actions/workflows/ci.yml/badge.svg)](https://github.com/stanwu/prompt-make/actions/workflows/ci.yml)

A universal shell script that turns a Markdown prompt file into a fully executed AI coding session. Point it at any `.md` file describing a task, and `build.sh` assembles the prompt, invokes your preferred AI agent, and runs it in any target directory — with a sentinel guard to prevent accidental re-runs.

## Features

- **Multi-agent support** — Claude (default), Gemini, and Codex
- **Sentinel guard** — tracks which prompts have already run; skips re-runs automatically
- **Context injection** — prepend a shared context file before any prompt
- **Auto-chunking** — split oversized prompts into sequential batches with `--max-chars`
- **Security scan** — detects credentials, prompt injection, and dangerous patterns before every run
- **Dry-run mode** — preview the fully assembled prompt without calling any agent
- **Output directory control** — run the agent in any working directory

## Requirements

- Bash 4+
- At least one AI agent CLI installed and authenticated:
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
  - [Gemini CLI](https://github.com/google-gemini/gemini-cli) (`gemini`)
  - [Codex CLI](https://github.com/openai/codex) (`codex`)

## Installation

```bash
git clone https://github.com/<your-username>/prompt-make.git
cd prompt-make
chmod +x build.sh
```

Optionally add it to your `PATH`:

```bash
ln -s "$PWD/build.sh" /usr/local/bin/prompt-make
```

### Git Hooks

A pre-commit hook is included in `hooks/pre-commit`. It scans every staged file for credentials and sensitive patterns before each commit, using the same rules as the `build.sh` security scan.

Install:

```bash
make install-hooks
```

Uninstall:

```bash
make uninstall-hooks
```

**Suppressing a specific line** — if a line is an intentional test fixture or example value, append `# nosec` as a comment:

```bash
printf 'key: sk-fakekeyfortest\n'  # nosec — test fixture
```

**Skipping the hook for one commit** (e.g. bulk historical import):

```bash
git commit --no-verify
```

## Usage

```
./build.sh --prompt <prompt.md> [options]
```

### Options

| Flag | Description |
|---|---|
| `--prompt <file>` | Path to the `.md` prompt file **(required)** |
| `--agent <name>` | AI agent to use: `claude` (default), `gemini`, `codex` |
| `--context <file>` | Optional `.md` file prepended before the prompt |
| `--output-dir <dir>` | Directory where the agent executes (default: `$PWD`) |
| `--max-chars <N>` | Split prompt into chunks when it exceeds `N` characters (`0` = disabled) |
| `--dry-run` | Print the assembled prompt without calling any agent |
| `--no-sentinel` | Force re-run even if the sentinel already exists |
| `--skip-security-check` | Skip the security scan (use only for trusted local prompts) |
| `-h`, `--help` | Show help message |

### Examples

Run a prompt with the default Claude agent:

```bash
./build.sh --prompt tasks/scaffold-api.md
```

Use Gemini instead:

```bash
./build.sh --prompt tasks/scaffold-api.md --agent gemini
```

Prepend a shared project context:

```bash
./build.sh --prompt tasks/add-tests.md --context context/project.md
```

Run in a specific output directory:

```bash
./build.sh --prompt tasks/scaffold-api.md --output-dir ~/projects/my-app
```

Preview the assembled prompt without running anything:

```bash
./build.sh --dry-run --prompt tasks/scaffold-api.md --context context/project.md
```

Force re-run after a previous successful run:

```bash
./build.sh --prompt tasks/scaffold-api.md --no-sentinel
```

Auto-split a large prompt into 8 000-character chunks:

```bash
./build.sh --prompt tasks/big-spec.md --max-chars 8000
```

Preview how a large prompt would be chunked without running anything:

```bash
./build.sh --dry-run --prompt tasks/big-spec.md --max-chars 8000
```

## How It Works

### Prompt Assembly

When you run `build.sh`, it assembles a final prompt in this order:

1. Contents of `--context` file (if provided)
2. A `---` separator
3. Contents of `--prompt` file
4. A `---` separator
5. A fixed instruction block telling the agent to implement everything immediately without asking clarifying questions

### Auto-chunking

When `--max-chars N` is set and the prompt file exceeds `N` characters, the script
splits the prompt file into multiple chunks and submits them to the agent one at a time.
Each chunk is assembled independently:

```
[context file content]     ← prepended to every chunk if --context is set
---
[Part X of N — filename.md]

[chunk content]
---
Implement ALL deliverables listed in this section (part X of N). ...
```

Chunks are split at natural Markdown boundaries — section headers (`#`, `##`, …) first,
blank lines second, and a hard split if the chunk is already at the size limit.
The sentinel is written only after all chunks have completed successfully.

### Security Scan

Before invoking any agent, `build.sh` scans the prompt file (and context file if provided)
for security issues. Each finding is labelled by severity:

| Severity | Colour | Behaviour |
|---|---|---|
| `[BLOCK]` | Red | Aborts the run immediately |
| `[WARN]` | Yellow | Printed as advisory; run continues |

**Blocking patterns — credential / secret leakage:**

| Pattern | Example trigger |
|---|---|
| PEM private key or certificate | `-----BEGIN RSA PRIVATE KEY-----` |
| OpenAI API key | `sk-…` / `sk-proj-…` |
| Anthropic API key | `sk-ant-…` |
| GitHub personal access token | `ghp_…` / `ghs_…` / `gho_…` |
| AWS access key ID | `AKIA…` |
| HTTP Bearer token | `Bearer <long-token>` |

**Warning patterns — prompt injection & dangerous operations:**

| Pattern | Example trigger |
|---|---|
| Possible inline credential | `password=hunter2`, `api_key: abc123xyz` |
| Instruction override | `ignore all previous instructions` |
| Context / identity reset | `forget everything`, `you are now a…` |
| System prompt override | `new system prompt:` |
| Jailbreak framing | `DAN mode`, `pretend you have no restrictions` |
| Destructive shell command | `rm -rf /` |
| Pipe-to-shell | `curl https://… \| bash` |
| Base64 decode pipe | `base64 -d payload \| sh` |

If a blocking issue is found the script exits with an error message and does **not** call the agent:

```
[security] Scanning for credentials, injection, and dangerous patterns...
  [BLOCK] OpenAI API key (sk-…)
  [WARN]  Prompt injection — instruction override
  → 1 blocking issue(s) in my-prompt.md
[error] 1 blocking issue(s) found. Fix them or pass --skip-security-check to override.
```

To bypass the scan for a prompt you know is safe:

```bash
./build.sh --prompt tasks/trusted.md --skip-security-check
```

### Sentinel Guard

After a successful run, a sentinel file is written to `.built/<prompt-name>` inside the output directory. On subsequent runs with the same prompt, the script detects the sentinel and exits early to prevent duplicate execution.

To reset and re-run:

```bash
# Remove a specific sentinel
rm .built/scaffold-api

# Or disable the check for one run
./build.sh --prompt tasks/scaffold-api.md --no-sentinel
```

### Agent Commands

Internally the script calls each agent as follows:

| Agent | Command |
|---|---|
| `claude` | `claude --dangerously-skip-permissions -p "<prompt>"` |
| `gemini` | `gemini --yolo -p "<prompt>"` |
| `codex` | `echo "<prompt>" \| codex exec --dangerously-bypass-approvals-and-sandbox -` |

> **Note:** All agents are invoked in full-auto mode (no interactive approval prompts). Only use this on prompts and in environments you trust.

## Prompt File Format

Prompt files are plain Markdown. Write them like a spec — describe deliverables, file structures, constraints, and acceptance criteria. The script appends implementation instructions automatically.

Example (`tasks/scaffold-api.md`):

```markdown
# Scaffold a REST API

Create a Node.js Express API with the following endpoints:

- `GET /health` — returns `{ status: "ok" }`
- `GET /users` — returns a hardcoded list of users
- `POST /users` — accepts `{ name, email }` and echoes it back

## Files required

- `src/index.js` — entry point
- `src/routes/users.js` — user routes
- `package.json` — with express as a dependency
```

## License

MIT — see [LICENSE](LICENSE) for details.
