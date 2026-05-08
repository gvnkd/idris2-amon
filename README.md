# amon — Ansible Monitor TUI

Idris 2 TUI application that monitors long-running tasks (e.g., ansible playbooks) with a real-time terminal interface. Built with `idris2-tui` and `idris2-async`.

## Features

- **Real-time task output** — live streaming of stdout/stderr from each task
- **Concurrent execution** — configurable worker pool (default: 2 parallel jobs); excess tasks queue and start as slots free up
- **Emoji status badges** — ⏳ Queued, ⏵ Running, ✔ Success, ✘ Failed, ⏱ Timed Out, ⛔ Cancelled
- **Task cancellation** — select a running job and press `x` to send SIGTERM
- **Colored output** — ANSI color codes from tasks pass through to the TUI
- **Task logging** — optional per-task log files with timestamps and status footers
- **Per-task environment variables** — pass `envVars` in `tasks.json` to set environment for individual tasks
- **Timeout support** — tasks auto-terminate after a configurable timeout (uses GNU `timeout`)

## Build and Run

Requires [nix](https://nixos.org/) with flakes enabled:

```sh
direnv allow
idris2 --build amon.ipkg
./build/exec/amon          # default 2 workers
./build/exec/amon 4        # 4 parallel workers
```

## Task Configuration

Tasks are defined in `tasks.json` using a nested batch structure:

```json
{
  "config": {
    "batchName": "Test Suite",
    "maxWorkers": 3
  },
  "Test Suite": {
    "Quick Task": {
      "path": "ls",
      "args": ["--color=always", "-la"],
      "timeout": 5,
      "logFile": "logs/quick.log",
      "blockingIO": false
    }
  }
}
```

Fields:
- `config.batchName` — display label in the TUI title bar
- `config.maxWorkers` — number of parallel workers (default: 2)
- `config.leftWidth` — optional left column width override
- `<batch>.<task>.path` — command to execute
- `<batch>.<task>.args` — arguments passed to the command
- `<batch>.<task>.timeout` — max seconds before kill (0 = no timeout)
- `<batch>.<task>.logFile` — optional path to write full output log
- `<batch>.<task>.blockingIO` — use blocking I/O mode (for tasks that buffer stdout)
- `<batch>.<task>.envVars` — optional object of environment variables to set for this task

## Task Logging

When `logFile` is set, all task output is streamed to that file:

- Log begins with `[START] YYYY-MM-DD HH:MM:SS`
- Raw output is written through `tee` (ANSI escape sequences preserved)
- Log ends with `[END] YYYY-MM-DD HH:MM:SS STATUS` (SUCCESS, FAILED, or CANCELLED)

## Testing with zrun

`zrun` launches the amon TUI inside a headless [Zellij](https://zellij.dev/) session for automated testing:

```sh
./zrun                        # Start amon in headless session
./zrun --screen               # Dump TUI screen to stdout
./zrun --send-keys Down Down  # Send keys to the pane
./zrun --subscribe            # Stream viewport updates as NDJSON
./zrun --stop                 # Kill the session
```

## Source Layout

```
src/Monitor/
  Main.idr            # TUI entry point, worker pool config
  Types.idr           # JobDisplayStatus, JobUpdate, JobMonitorState
  View.idr            # TUI rendering, emoji badges, colorized output
  Handler.idr         # Key handling (x = cancel), job state updates
  Process.idr         # ANSI stripping and truncation utilities
  ProcessStream.idr   # Async process I/O with pipe2(O_CLOEXEC)
  Source.idr          # Event source (JobStarted, JobFinished, etc.)
  Provider.idr        # tasks.json parsing and job entry creation
  Mock.idr            # Mock data for testing
src/Protocol.idr      # Shared types: ProcessTask, TaskState, Ticket
support/
  amon-idris.c        # C FFI: spawn_child, cstr_write, cstr_timestamp
  Makefile            # Builds support/amon-idris.so
```

## C FFI Helpers

The C support library is built automatically via `amon.ipkg`'s `prebuild` hook:

```sh
make -C support
```

This produces `support/amon-idris`, which is copied to `build/exec/amon_app/amon-idris.so` during the `postbuild` phase.

## Keyboard Controls

| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate job list |
| `j` / `k` | Scroll log viewer down / up |
| `h` / `l` | Scroll log viewer horizontally |
| `x` | Cancel selected running job |
| `q` / `Esc` | Quit |
