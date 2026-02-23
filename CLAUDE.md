# cld

An OpenClaw-style personal assistant in Zig. iMessage + Claude Code CLI, extensible to other adapters and providers.

## Constraints

- **Cannot run `claude` CLI from within this session.** Running `claude` inside Claude Code fails with nested session error. If you need to test claude CLI behavior, print the exact command for the user to copy-paste and run, then ask them to return the output.
- **Cannot run `imsg watch`** in tests — it blocks and reads from the live Messages database.
- When testing CLI-wrapping code, always ask the user to run commands manually.

## Architecture

See ~/notes/projects/zig-assistant-architecture.md for full plan.

- **Adapter** (message I/O): wraps `imsg` CLI (imsg watch/send)
- **Provider** (LLM backends): wraps `claude` CLI headless (--session-id for multi-session)
- **Memory**: hierarchical file-based (tiny.md + full.md per day)

## Code Principles

Follow the Zig zen principles when approaching how to write code, solve problems, and build:

- Communicate intent precisely.
- Edge cases matter.
- Favor reading code over writing code.
- Only one obvious way to do things.
- Runtime crashes are better than bugs.
- Compile errors are better than runtime crashes.
- Incremental improvements.
- Avoid local maximums.
- Reduce the amount one must remember.
- Focus on code rather than style.
- Resource allocation may fail; resource deallocation must succeed.
- Memory is a resource.
- Together we serve the users.

## Debugging Brew Service

When debugging issues with `brew services`, always check `cld --version` to verify the installed binary matches the expected commit.

- `cld --version` — shows version + git hash (e.g. `cld 0.1.0-e60c3ef`)
- `tail /opt/homebrew/var/log/cld.err.log` — service error log
- Build with hash: `zig build -Dgit-hash="$(git rev-parse --short HEAD)"`
- FDA must be granted to the Cellar binary after each `brew upgrade`

## Zig Version

Using Zig 0.15.2. Key API differences from older versions:
- `build.zig`: use `b.createModule()` with `root_source_file`, pass as `.root_module`
- `std.Thread.sleep()` not `std.time.sleep()`
