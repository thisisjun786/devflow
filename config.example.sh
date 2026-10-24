#!/usr/bin/env bash
# ~/.config/devflow/config.sh. Shell code: use only trusted configuration.
# ${VAR:=default} keeps environment overrides, including test agent commands.
if { [ -d /scratch ] && [ -w /scratch ] && [ -x /scratch ]; } ||
   { [ -d /scratch/dv-wt ] && [ -w /scratch/dv-wt ] && [ -x /scratch/dv-wt ]; }; then
  : "${DV_WORK:=/scratch/dv-wt}"
else
  : "${DV_WORK:=$HOME/dv/wt}"
fi
: "${DV_STATE:=$HOME/.local/state/devflow}"
: "${DV_TMP:=$HOME/.cache/dv/tmp}" # host-local disk scratch for dv and its agents
: "${DV_TMP_QUOTA_KB:=12582912}" # fallback per-user /tmp quota estimate (12 GiB); 0 = unknown
: "${DV_HOME:=$HOME/.local/state/devflow-mac}"
: "${DV_HOST:=$(hostname -s)}"
: "${DV_JOB_MEMORY_MAX:=6G}" # Linux scope aggregate memory; fallback per-process virtual memory
: "${DV_JOB_TASKS_MAX:=1500}" # Linux scope processes AND threads
: "${DV_JOB_MEMORY_SWAP_MAX:=0}" # Linux scope swap; never changes host settings
: "${DV_JOB_NPROC_MAX:=1000}" # extra user processes, capped at 70% of host/hard limit
: "${DV_JOB_LAUNCHD_MAX:=200}" # owned macOS launchd registrations per job
: "${DV_JOB_LAUNCHD_PATTERN:=com.lina.*}" # shell glob; ownership also requires worktree or DV_ISSUE
: "${DV_RG_MAX_FILESIZE:=20M}" # job rg defaults; an existing RIPGREP_CONFIG_PATH wins
: "${DV_RG_MAX_COLUMNS:=4000}"
# Newline-separated rg globs; set empty to disable these exclusions.
: "${DV_RG_EXCLUDE_GLOBS=!**/.codex/**
!**/.hermes/**
!**/.claude/**
!**/.grok/**
!**/.local/state/**
!**/.cache/**
!**/node_modules/**
!**/.git/objects/**}"
: "${DV_AUTO_UPDATE:=1}" # clean main checkout: dv checks every 5 min; watcher on landed/safety pass
: "${DV_KICK_HOST:=lina-os}" # host running dv-watch (lina-mac before 10-19)
: "${DV_KICK:=}" # shell command; receives kind issue message host head as arguments
: "${DV_CODEX_BIN:=codex}" # ~/node/bin/codex or ~/.opencodex/bin/codex
: "${DV_CODEX_MODE:=auto}" # new auto/appserver jobs use isolated exec; goal/tui keeps terminals
: "${DV_APPSERVER_SOCKET:=}" # empty uses Codex's existing default control socket
: "${DV_APPSERVER_TIMEOUT:=10}" # bounded JSON-RPC response wait, seconds
: "${DV_APPSERVER_POLL:=5}" # job client state refresh, seconds
: "${DV_STALL_AFTER:=300}" # App Server / exec / idle / stalled / blocked queue cursor, positive seconds
: "${DV_RECOVER_MAX:=3}" # App Server: maximum automatic recoveries per job
: "${DV_CAPACITY_BACKOFF:=120}" # first provider capacity wait; then 2.5x, 7.5x (repeated)
: "${DV_CAPACITY_MAX_WAIT:=21600}" # provider capacity wait deadline in seconds (6 h)
: "${DV_CODEX_ENV_FILE=$HOME/.opencodex/codex-auth-env.sh}" # trusted host-local shell file; empty disables
: "${DV_TRUSTED_REPOS=}" # newline-separated absolute repo roots; exact matches, no globs
: "${DV_BID_REJECT_REPOS=}" # space-separated owner/name this host never bids on (e.g. keep a Mac free for app work)
: "${DV_CLAUDE_BIN:=claude}"
: "${DV_DEVIN_BIN:=$HOME/.local/bin/devin}"
: "${DV_OMP_BIN:=omp}"
: "${DV_DSH_BIN:=$HOME/.local/dsh/node_modules/.bin/dsh}"
: "${DV_DSH_HOME:=$HOME/.dsh-dv}" # exported as DSH_HOME only to dsh
: "${DV_DSH_PROFILE:=headless}"
: "${DV_DSH_VERSION:=0.2.1-rc.3}"
: "${DV_DSH_KEY_FILE:=$HOME/.omp/agent/.env}" # parsed, never sourced
: "${DV_DSH_KEY_VAR:=INFERHUB_API_KEY}"
: "${DV_DSH_FALLBACK:=omp}"
: "${DV_DSH_JAIL:=auto}" # auto, on (required on Linux), off
: "${DV_DSH_JAIL_BIND=}" # newline-separated absolute directories bound read-write
: "${DV_DSH_SESSIONS:=$DV_DSH_HOME/sessions}"
: "${DV_AGY_BIN:=agy}"
: "${DV_GROK_BIN:=grok}"
: "${DV_CURSOR_BIN:=cursor-agent}"
: "${DV_CODEX_MODEL:=gpt-6-astra}"
: "${DV_CODEX_EFFORT:=xhigh}"
: "${DV_CODEX_DISABLE_HOOKS:=1}" # tmux only; herdr always keeps its state hooks enabled
: "${DV_CODEX_DISABLE_CRW:=1}" # 0 keeps installed crw plugin enabled
: "${DV_CLAUDE_MODEL:=opus}"
: "${DV_CLAUDE_EFFORT:=xhigh}"
: "${DV_DEVIN_MODEL:=fusion-gpt-6-astra-xhigh-sidekick-swe-2-high}"
: "${DV_OMP_MODEL:=inferhub/deepseek-v4.1-flash}" # provider/model; custom providers live in ~/.omp/agent/models.yml
: "${DV_OMP_COMPACT_TOKENS:=200000}" # host sync: positive fixed compaction threshold; host check reports drift
: "${DV_OMP_RESTART_GAP:=180}" # minimum seconds between text-tool session restarts per job
: "${DV_OMP_RESTART_SETTLE:=2}" # seconds after /new before sending the state summary
: "${DV_AGY_MODEL:=gemini-4-argon}" # Argon at medium effort; the TUI ignores gemini-4-argon-medium
: "${DV_GROK_MODEL:=}" # empty = grok's own default
: "${DV_CURSOR_MODEL:=}" # empty = cursor-agent's own default
: "${DV_ROUTE_WRITING=agy}" # dv submit without --agent: brief line "Route: writing"; empty keeps DV_AGENT
: "${DV_ROUTE_SMALL=dsh}" # DeepSeek worker; omp is the readiness/recovery fallback
: "${DV_AGENT:=codex}"
: "${DV_AGENT_QUESTIONS:=sion}" # herdr: question tools on; off (always under tmux): disable Codex/Claude question tools
: "${DV_CODEX_SESSIONS:=${CODEX_HOME:-$HOME/.codex}/sessions}" # question transcripts, read only
: "${DV_CLAUDE_SESSIONS:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}" # question transcripts, read only
: "${DV_OMP_SESSIONS:=$HOME/.omp/agent/sessions}" # transcripts shown by dv status and revival, read only
: "${DV_AGY_SESSIONS:=$HOME/.gemini/antigravity-cli/conversations}"
: "${DV_GROK_SESSIONS:=$HOME/.grok/sessions}"
: "${DV_CURSOR_SESSIONS:=$HOME/.cursor/projects}"
: "${DV_MODE:=}" # optional legacy override; --mode takes precedence
: "${DV_AGENT_CMD_codex:=}" # complete shell command, no extra CLI flags
: "${DV_AGENT_CMD_claude:=}"
: "${DV_AGENT_CMD_devin:=}"
: "${DV_AGENT_CMD_omp:=}"
: "${DV_AGENT_CMD_agy:=}"
: "${DV_AGENT_CMD_grok:=}"
: "${DV_AGENT_CMD_cursor:=}"
: "${DV_TMUX_SOCKET:=}" # empty uses the normal tmux server
: "${DV_HERDR:=1}" # native herdr backend when installed; 0 uses tmux
: "${DV_START_WAIT:=30}" # seconds to wait for Codex prompt / Devin, agy, grok trust menu
: "${DV_BLOCKED_GRACE:=20}" # seconds a herdr pane must stay blocked before a question event
: "${DV_READY_PATTERN:=›|❯|dv-ready>}" # Codex TUI input marker
: "${DV_SEND_DELAY:=0.3}" # let bracketed paste settle before Enter
: "${DV_LAND_MODE:=ff}" # ff or merge (local repositories)
: "${DV_LAND_METHOD:=}" # GitHub: empty = auto; squash, merge or rebase
: "${DV_TEST_CMD:=}" # required for local land; .devflow may supply it
: "${DV_REVIEW_WAIT:=300}" # maximum seconds after checks for bot reviews
: "${DV_LAND_CHECK:=}" # optional executable run before a GitHub merge: <owner/repo> <pr> <head>; non-zero refuses land
: "${DV_REVIEW_BOTS:=codex}" # Codex review author regex
: "${DV_REVIEW_ROUNDS:=4}" # maximum reviewed heads before unresolved P0/P1 block
: "${DV_POLL_INTERVAL:=10}" # PR review interval
: "${DV_CHECKS_INTERVAL:=60}" # gh pr checks --watch refresh; GraphQL budget is shared by every worker on the account
: "${DV_POLISH:=1}" # 0 disables optional PR prose polishing
: "${DV_POLISH_CMD:=}" # shell command; receives the prompt as its last argument
: "${DV_POLISH_TIMEOUT:=180}" # seconds; default command uses local agy or ssh lina-os
: "${DV_WORKER_CMD:=}" # shell command; receives prompt file path; default Hermes below
: "${DV_HERMES_BIN:=hermes}"
: "${DV_WATCH_INTERVAL:=3}" # local queue read interval, seconds
: "${DV_STATUS_TIMEOUT:=60}" # seconds for each host's status pass plus follow-up recovery/PR RPCs
: "${DV_WORKER_RETRY:=15}" # seconds before retrying a failed queue worker
: "${DV_MAX_WORKERS:=4}" # 1..8 ordinary/fallback workers; QA uses host DV_MAX_JOBS slots
: "${DV_RECONCILE_INTERVAL:=1800}" # status safety net seconds; capped at min(DV_STALL_AFTER, 60)
: "${DV_METRICS_INTERVAL:=60}" # file/event activity sampling by dv-watch, seconds
: "${DV_PULL_HOSTS=}" # watcher only: remote dev hosts whose kick queue it follows (dv-kick-pull)
: "${DV_PULL_RETRY:=15}" # seconds between restarts of an ended pull stream
: "${DV_HOSTS=lina-os hx-linux amd-linux go2-linux}" # SSH aliases for status/bidding; add gos-linux explicitly as the last fallback
: "${DV_MANAGER_HOST:=lina-os}" # submit/queue manager, independent of the local kick host
: "${DV_MANAGER_AGENT:=hermes}" # persistent per-repository Hermes session
: "${DV_MANAGER_MAX_WAIT:=1800}" # busy seconds before other issues use plain one-shot workers
: "${DV_MANAGER_ROTATE_CHECK=}" # optional hook <session_id>; exit 10 starts the next manager turn in a fresh session
: "${DV_AUTOFILL_REPOS=}" # manager: space-separated owner/repo allowlist; empty disables
# DV_AUTOFILL_BRIEF_owner_repo=/path/brief.md (lowercase; / . - become _).
# Default template: enabled repo's .devflow/brief.md on its default branch.
: "${DV_MAX_JOBS:=}" # optional upper bound on the measured host cap
: "${DV_TARGET_LOAD:=1.2}" # p75 load5/cores threshold and live overload guard
: "${DV_HOST_CAPACITY_WINDOW:=86400}" # recent sample window; recompute once per hour
: "${DV_MIN_MEMORY_MB:=512}" # available memory reserved per effective slot; 0 disables
: "${DV_HEAVY_SLOTS:=}" # host-wide heavy commands; empty = max(1, floor(logical cores / 8))
: "${DV_MIN_DISK_GB:=15}" # work/cache free GiB; reject either below this, penalize below 2x
: "${DV_CACHE_TRIM_DAYS:=2}" # trim Go build files not accessed for this many days
: "${DV_DISK_INTERVAL:=1800}" # dv-watch disk safety pass, seconds
: "${DV_REPO_ROOT:=$HOME/code}" # existing clones, or clone destination after an award
: "${DV_BID_TIMEOUT:=10}" # seconds per read-only SSH bid/auth probe
: "${DV_AWARD_TIMEOUT:=90}" # seconds to confirm agent startup
: "${DV_AGENT_READY_codex:=}" # optional read-only auth probe command (exit 0 = ready)
: "${DV_AGENT_READY_claude:=}"
: "${DV_AGENT_READY_devin:=}"
: "${DV_AGENT_READY_omp:=}" # default: DV_OMP_MODEL's provider and key are configured
: "${DV_AGENT_READY_dsh:=}" # optional read-only readiness override
: "${DV_AGENT_READY_agy:=}" # default for agy, grok, cursor: "<bin> models" succeeds
: "${DV_AGENT_READY_grok:=}"
: "${DV_AGENT_READY_cursor:=}"
# DV_CONFIG: config file override (default ~/.config/devflow/config.sh).
# DV_TEST_TMP: test temporary root (default TMPDIR or /tmp); no live agents/network.
: "${DV_QA:=0}" # 1: poll enabled manager repositories for base merges; literal .devflow overrides
: "${DV_QA_AGENT:=codex}" # codex exec or claude (fresh session)
: "${DV_QA_AGENT_CMD:=}" # optional command receiving the QA prompt path
: "${DV_QA_COALESCE:=600}" # quiet seconds before bidding one QA for accumulated merges
: "${DV_QA_SCAN_MIN:=60}" # minimum seconds between event scans; new base push/merge events wake once immediately
: "${DV_QA_BASE:=}" # QA base; empty uses the registered repository's remote default
: "${DV_MANAGER_LAST=1}" # 1: the manager host (lina-os) bids only after work hosts; 0: it competes on score like the others
