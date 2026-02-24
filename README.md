<img src="icon.png" width="62" align="left" />
<h1 style="border: none;">cld</h1>

Command line daemon. A fast, persistent assistant.

You don't need a TypeScript app with a dependency graph deeper than the Mariana Trench to connect your messaging app to a coding agent. Just processes, persistent memory, pipes, and poll. Written in Zig.

> *Reduce the amount one must remember.* — Zig Zen

Single static binary. ~500KB.

## Install

```
brew tap jeffhodsdon/tap
brew install cld
brew services start cld
```

Grant Full Disk Access to the installed binary in System Settings > Privacy & Security.

## Architecture

```
Adapter  ──>  Provider  ──>  LLM
    │                         │
    │        Memory           │
    │     (markdown files)    │
    <────────────────────────<
```

- **Adapter**: message transport (iMessage via `imsg` CLI)
- **Provider**: LLM backend (Claude via `claude` CLI, headless multi-session)
- **Memory**: file-based context — identity, personality, long-term notes, daily logs and summaries

## Adapters

| Adapter  | Transport       | Dependency |
|----------|-----------------|------------|
| iMessage | `imsg` CLI      | [imsg](https://github.com/brettferdosi/imsg) |

## Providers

| Provider | Backend         | Dependency |
|----------|-----------------|------------|
| Claude   | `claude` CLI    | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) |

## Configure

`~/.config/cld/config.json`

```json
{
  "adapters": {
    "imessage": {
      "allowed_senders": ["+15555555555"]
    }
  }
}
```

Empty `allowed_senders` permits all senders.

## Status

```
cld status
```

Verifies binaries, auth, database access, config, and memory directory.

## Memory

Files in `~/.local/share/cld/memory/`:

```
IDENTITY.md           # who the assistant is
SOUL.md               # personality and tone
USER.md               # facts about the user
MEMORY.md             # long-term notes
YYYY-MM-DD.tiny.md    # daily summary
YYYY-MM-DD.full.md    # full conversation log
```

All optional. Changes picked up automatically via stat checks.

## Project Status

Early development. Core loop works — messages come in, get routed to Claude, responses go back out, memory accumulates. Running it daily as a personal assistant over iMessage.

What's solid:
- Event-driven process pool with poll-based I/O
- iMessage adapter (watch + send)
- Claude provider with session reuse and queuing
- File-based memory with stat-checked hot reload

What's next:
- More adapters (Signal, Telegram, etc.)
- More providers (local models, OpenAI, etc.)
- Memory compaction (daily tiny.md generation)
- Skills (checked-in, reviewed prompts the assistant can invoke)
- Tool use and agent capabilities
