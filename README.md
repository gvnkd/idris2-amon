# amon — Ansible Monitor TUI

A terminal UI for running and monitoring long-running shell tasks (e.g. Ansible playbooks) in parallel. Built with [Idris 2](https://www.idris-lang.org/), `idris2-tui`, and `idris2-async`.

## Features

- **Real-time task output** — merged stdout/stderr streaming from each task into a scrollable log pane
- **Concurrent execution** — configurable worker pool (`maxWorkers`, default: 2); excess tasks queue and start as slots free up
- **Visual status badges** — Queued, Running, Success, Failed, Timed Out, Cancelled
- **Task cancellation** — select a running job and press `x` to send SIGTERM
- **ANSI color passthrough** — color codes from tasks are rendered in the TUI
- **Per-task logging** — optional `logFile` writes `[START]` / `[END]` footers alongside raw output
- **Per-task environment variables** — `envVars` in `tasks.json` sets environment for a single task
- **Timeout support** — tasks are wrapped with `timeout` and killed after the configured number of seconds
- **Deterministic job ordering** — batches and jobs are sorted alphabetically
- **Keyboard-driven log viewer** — `j`/`k` vertical scroll, `h`/`l` horizontal scroll, `PgUp`/`PgDn` page
- **EINTR-resilient event loop** — local patches make the async `epoll` loop handle signals instead of crashing

## Build and Run

Requires [Nix](https://nixos.org/) with flakes enabled.

```sh
direnv allow
idris2 --build amon.ipkg
./build/exec/amon                    # default: loads tasks.json
./build/exec/amon custom.json        # load custom task definition
./build/exec/amon --help             # show usage
```

## CLI Options

```
amon: Ansible Monitor TUI
Usage: amon [[TASKS_JSON]]

Options:

<pos> <TASKS_JSON>    Path to tasks.json definition
```

- `TASKS_JSON` — optional path to the task definition file (default: `tasks.json`)
- `--help` / `-h` — print usage help and exit

## Flake Outputs

### Default executable

```sh
nix build .#default
./result/bin/amon tasks.json
```

Produces a wrapped executable with all transitive Idris FFI shared libraries linked/symlinked under the output.

### OCI Container

```sh
nix build .#container
docker load -i result
```

Produces a layered OCI image (`amon.tar.gz`) with `tini` as PID 1 and the amon executable as entrypoint. The image includes `ansible`, `coreutils`, and `bash`.

```sh
# Run with a TTY (required for TUI)
docker run -it -v $(pwd)/tasks.json:/data/tasks.json amon /data/tasks.json
```

### Debian package

```sh
nix build .#amonDeb
sudo dpkg -i result/amon_1.0.0_amd64.deb
amon tasks.json
```

Produces a self-contained `.deb` that works on Debian 12+ without Nix installed. It bundles:

- the Chez Scheme runtime (`/usr/lib/amon/scheme`)
- the compiled amon program object (`/usr/lib/amon/amon.so`)
- Chez heap/boot files
- the bundled Nix glibc and dynamic linker
- all transitive Idris FFI shared objects

The wrapper at `/usr/bin/amon` starts the bundled Chez runtime with no `LD_LIBRARY_PATH` leakage, so child processes use the host system glibc.

### Bundle (self-contained executable)

```sh
nix bundle .#default --bundler .
```

Produces a portable bundled executable (`amon-arx`).

## Task Configuration

Tasks are defined in `tasks.json` using a nested batch structure:

```json
{
  "config": {
    "batchName": "Test Suite",
    "maxWorkers": 3,
    "leftWidth": 20
  },
  "Test Suite": {
    "Quick Task": {
      "path": "ls",
      "args": ["--color=always", "-la"],
      "timeout": 5,
      "logFile": "logs/quick.log",
      "envVars": { "FOO": "bar" }
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
- `<batch>.<task>.envVars` — optional object of environment variables to set for this task

## Task Logging

When `logFile` is set:

- Log begins with `[START] YYYY-MM-DD HH:MM:SS`
- Task stdout/stderr is written to the file as it is produced
- Log ends with `[END] YYYY-MM-DD HH:MM:SS STATUS` (SUCCESS, FAILED, TIMEDOUT, or CANCELLED)

Log paths are resolved relative to the directory containing `tasks.json`. Missing log directories are reported at startup.

## Testing with zrun

`zrun` launches the amon TUI inside a headless [Zellij](https://zellij.dev/) session for automated testing:

```sh
./zrun                        # Start amon in headless session
./zrun --screen               # Dump TUI screen to stdout
./zrun --send-keys Down Down  # Send keys to the pane
./zrun --subscribe            # Stream viewport updates as NDJSON
./zrun --test                 # Run tasks and report pass/fail summary
./zrun --stop                 # Kill the session
```

## Source Layout

```
src/Monitor/
  Main.idr            # TUI entry point, worker pool config, CLI parsing
  Types.idr           # JobDisplayStatus, JobUpdate, JobMonitorState
  View.idr            # TUI rendering, status badges, colorized output
  Handler.idr         # Key handling (x = cancel), job state updates
  Process.idr         # ANSI stripping/truncation, log helpers, legacy spawn path
  ProcessStream.idr   # Async process I/O with pipe2(O_CLOEXEC)
  Source.idr          # Worker pool dispatcher
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

`amon_spawn_child` performs fork/exec inside the C helper (avoiding fork-safety issues in the Chez runtime) and unsets `LD_LIBRARY_PATH` in the child so spawned tasks use the host system's dynamic linker.

## Keyboard Controls

| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate job list |
| `j` / `k` | Scroll log viewer down / up |
| `h` / `l` | Scroll log viewer horizontally |
| `PgUp` / `PgDn` | Page log viewer up / down |
| `x` | Cancel selected running job |
| `q` / `Esc` | Quit |

## Known Limitations

- **Cancellation kills only the direct child PID.** Grandchildren spawned by `sh -c` (for example `timeout` or `ansible-playbook` subprocesses) are not terminated automatically.
- **No headless / non-TUI mode.** amon always opens a terminal UI; there is no `--batch` or `--json` flag for CI-only use.
- **Task order depends on `tasks.json` and alphabetical sorting.** Jobs within each batch are sorted alphabetically; batches appear in the order they are defined in the JSON object.
