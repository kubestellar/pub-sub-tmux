# 🎸 Pluk

Pluk structured events from non-deterministic AI agent terminal output.

AI coding agents (Claude Code, GitHub Copilot CLI, Gemini CLI, Goose, etc.) produce rich but unstructured terminal output — spinners, tool calls, rate limit messages, login prompts, error states. This project captures that output via `tmux pipe-pane` and classifies it into a structured JSONL event stream that any system can subscribe to.

## Quick start

```bash
# One-liner install
curl -fsSL https://raw.githubusercontent.com/kubestellar/pluk/main/install-remote.sh | bash

# Or clone and install
git clone https://github.com/kubestellar/pluk.git
cd pluk && make install

# Attach publisher to an existing tmux session
tmux pipe-pane -t mysession -o "pluk-publish --session mysession --cli claude 2>/dev/null"

# Subscribe to events (in another terminal)
pluk-subscribe mysession

# Subscribe with filter
pluk-subscribe mysession --filter "rate_limit,state_change,error"

# Send a command back to the session
pluk-send --session mysession --text "read CLAUDE.md" --enter
```

## Event types

| Type | Meaning | Example trigger |
|------|---------|-----------------|
| `raw_output` | Every non-empty line of terminal output | Any text |
| `state_change` | Agent went idle or started working | `❯` prompt, spinner chars |
| `rate_limit` | Usage limit / quota exhausted | "out of extra usage" |
| `login_required` | Authentication needed | Login URL in output |
| `trust_dialog` | Folder trust prompt | "Do you trust the files" |
| `bypass_permissions` | Permission bypass prompt | "bypass permissions on" |
| `tool_call_started` | Agent invoked a tool | `● Read`, `● Bash` |
| `tool_call_completed` | Tool finished | `✓ Read (0.1s)` |
| `error` | Error in output | "Error:", "panic:" |
| `model_changed` | Model was switched | Model name in output |
| `session_ended` | CLI session ended | "Session ended" |
| `command_received` | Command sent via pluk-send | Bidirectional input |

## Event schema

```json
{
  "v": 1,
  "ts": "2026-06-04T12:34:56.000Z",
  "seq": 42,
  "pid": 12345,
  "session": "scanner",
  "pane": "0",
  "source": "pipe-pane",
  "type": "rate_limit",
  "data": {
    "cli": "claude",
    "message": "out of extra usage",
    "resets_at": "3am"
  }
}
```

## Supported CLIs

Pattern files in `config/patterns.d/` define the regex patterns for each CLI:

- **Claude Code** (`claude.patterns`) — spinners, tool calls, rate limits, trust dialogs, bypass permissions
- **GitHub Copilot CLI** (`copilot.patterns`) — environment loaded, idle prompt, rate limits
- **Gemini CLI** (`gemini.patterns`) — thinking indicators, quota errors
- **Goose CLI** (`goose.patterns`) — processing indicators, rate limits

Adding a new CLI is a single pattern file — no code changes needed.

## Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌──────────────┐
│  tmux session    │────▶│ pluk-publish  │────▶│ session.jsonl│
│  (any AI CLI)    │     │ (pipe-pane)  │     │ (append-only)│
└─────────────────┘     └──────────────┘     └──────┬───────┘
                                                     │
                              ┌───────────────┐      │ tail -f
                              │ pluk-subscribe │◀─────┘
                              │ (any number)  │
                              └───────────────┘
                                                     │
                              ┌───────────────┐      │
                              │ pluk-send      │─────▶│ command FIFO
                              │ (bidirectional)│      │
                              └───────────────┘      ▼
                                              tmux send-keys
```

- **No broker process** — log-based pub-sub using append-only JSONL files
- **Multiple subscribers** — any number of `tail -f` processes on the same file
- **Bidirectional** — named FIFO per session for sending commands back
- **Atomic writes** — JSON lines under PIPE_BUF (4096 bytes) are atomic on Linux

## Docker / Container install

```dockerfile
# Install pluk in a container image
RUN git clone --depth 1 https://github.com/kubestellar/pluk.git /tmp/pst && \
    bash /tmp/pluk/install.sh /usr/local && \
    rm -rf /tmp/pluk && \
    mkdir -p /var/run/pluk/logs /var/run/pluk/commands
```

The runtime directories under `/var/run/pluk/` must exist before `pluk-publish` runs. If your container uses a tmpfs `/var/run`, create them at startup:

```bash
mkdir -p /var/run/pluk/logs /var/run/pluk/commands
```

Attach to a tmux session in your entrypoint or agent manager:

```bash
tmux pipe-pane -t mysession -o "pluk-publish --session mysession --cli claude"
```

## Dependencies

- bash 4.4+, coreutils, tmux 3.2+
- perl (for ANSI escape stripping)
- Optional: `jq` (for subscriber filtering)

## Testing

```bash
make test
```

## License

Apache 2.0
