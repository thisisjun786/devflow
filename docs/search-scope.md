# Job search defaults and agent coverage

Every dv job receives `RIPGREP_CONFIG_PATH` unless the caller already set it
(including an empty value). The generated file supplies `--max-filesize=20M`,
`--max-columns=4000`, and the configured exclusion globs. These are defaults,
not a filesystem boundary: command-line options can override them, and tools
can use another search engine or `--no-config`.

The following audit used installed executable code and bundled JavaScript,
without starting model sessions. Fake-agent tests separately verify environment
delivery for all six launchers, an existing tmux server, exec, and the legacy
App Server shell configuration. They do **not** simulate proprietary search
implementations. Versions and implementations can change.

| Agent | Observed implementation | Does the built-in search honor the config? |
| --- | --- | --- |
| grok 1.0.67 | The main grep implementation contains `RIPGREP_CONFIG_PATH is set; grep runs rg without an offer`, bypassing accelerated search when a config is set. Cursor-compatible grep/glob implementations in the same executable contain `--no-config`. | Main grep explicitly recognizes the config; coverage is conditional on the selected tool path. Compatibility paths require the scope instructions. |
| codex 0.163.0 | Shell-command searches can invoke ordinary `rg`. The executable also contains an internal `--no-config --files --no-ignore` scan; this is not evidence that every search is a configurable rg subprocess. | Ordinary shell `rg` inherits the defaults under the normal environment policy. No blanket guarantee for internal searches; scope instructions still apply. |
| claude 2.1.304 | The bundled `qae()` selector chooses embedded rg with `args:["--no-config"]`. A system-rg branch uses `args:[]`. | No for the default embedded path; conditional for system rg. Scope instructions are required. |
| omp | The bundled grep tool describes its local search as native and uses `@oh-my-pi/pi-natives`; no `RIPGREP_CONFIG_PATH` handling was found in the JavaScript bundle. | No rg CLI config contract for native grep. Scope instructions are required. |
| cursor 2026.10.22-27dcf5f | `LocalGrepExecutor` appends `--no-config`; the file walker also passes it. | No for built-in grep/file walking. Scope instructions are required. |
| agy | The executable contains `search_ripgrep.go`, an embedded rg, and `falling back to in-process search`. Bundled rg supports config files, but this does not establish the caller's argv/environment. | Not verified for built-in search; treat as requiring scope instructions. Ordinary shell `rg` receives the environment. |

Codex environment inheritance/filtering is documented in the
[official configuration reference](https://developers.openai.com/codex/config-reference/#shell_environment_policy).
An explicit agent-level environment filter or a search command's options may
still override job defaults. dv does not change agent installations or user
configuration to force compliance.

All workers must search only their worktree and paths named in their brief,
use Git or `gh` to trace history, and narrow the search after a MemoryMax OOM.
The job supervisor retains its existing memory limit and retry budget. Kernel
OOM evidence records the largest anonymous RSS among attributed killed victims,
not a sampled peak for every process; missing journal access yields null fields.
