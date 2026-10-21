#!/usr/bin/env bash
# ~/.config/devflow/config.sh. Shell code: use only trusted configuration.
# ${VAR:=default} keeps environment overrides, including test agent commands.
if [ -d /scratch ]; then : "${DV_WORK:=/scratch/dv-wt}"; else : "${DV_WORK:=$HOME/dv/wt}"; fi
: "${DV_STATE:=$HOME/.local/state/devflow}"
: "${DV_HOME:=$HOME/.local/state/devflow-mac}"
: "${DV_HOST:=$(hostname -s)}"
: "${DV_KICK_HOST:=lina-os}" # host running dv-watch (lina-mac before 10-19)
: "${DV_KICK:=}" # shell command; receives kind issue message host head as arguments
: "${DV_CODEX_BIN:=codex}" # ~/node/bin/codex or ~/.opencodex/bin/codex
: "${DV_CODEX_MODE:=auto}" # existing App Server, otherwise exec; appserver, exec, goal/tui
: "${DV_APPSERVER_SOCKET:=}" # empty uses Codex's existing default control socket
: "${DV_APPSERVER_TIMEOUT:=10}" # bounded JSON-RPC response wait, seconds
: "${DV_APPSERVER_POLL:=5}" # job client state refresh, seconds
: "${DV_STALL_AFTER:=300}" # shared App Server / exec / idle / stalled threshold, positive seconds
: "${DV_RECOVER_MAX:=3}" # App Server: maximum automatic recoveries per job
: "${DV_CAPACITY_BACKOFF:=120}" # App Server: seconds before capacity/rate-limit recovery
: "${DV_CODEX_ENV_FILE=$HOME/.opencodex/codex-auth-env.sh}" # trusted host-local shell file; empty disables
: "${DV_TRUSTED_REPOS=}" # newline-separated absolute repo roots; exact matches, no globs
: "${DV_CLAUDE_BIN:=claude}"
: "${DV_DEVIN_BIN:=$HOME/.local/bin/devin}"
: "${DV_CODEX_MODEL:=gpt-6-astra}"
: "${DV_CODEX_EFFORT:=xhigh}"
: "${DV_CODEX_DISABLE_HOOKS:=1}" # tmux only; herdr always keeps its state hooks enabled
: "${DV_CODEX_DISABLE_CRW:=1}" # 0 keeps installed crw plugin enabled
: "${DV_CLAUDE_MODEL:=opus}"
: "${DV_CLAUDE_EFFORT:=xhigh}"
: "${DV_DEVIN_MODEL:=fusion-gpt-6-astra-xhigh-sidekick-swe-2-high}"
: "${DV_AGENT:=codex}"
: "${DV_AGENT_QUESTIONS:=sion}" # herdr: question tools on; off (always under tmux): disable Codex/Claude question tools
: "${DV_CODEX_SESSIONS:=${CODEX_HOME:-$HOME/.codex}/sessions}" # question transcripts, read only
: "${DV_CLAUDE_SESSIONS:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}" # question transcripts, read only
: "${DV_MODE:=}" # optional legacy override; --mode takes precedence
: "${DV_AGENT_CMD_codex:=}" # complete shell command, no extra CLI flags
: "${DV_AGENT_CMD_claude:=}"
: "${DV_AGENT_CMD_devin:=}"
: "${DV_TMUX_SOCKET:=}" # empty uses the normal tmux server
: "${DV_HERDR:=1}" # native herdr backend when installed; 0 uses tmux
: "${DV_START_WAIT:=30}" # seconds to wait for Codex prompt / Devin trust menu
: "${DV_BLOCKED_GRACE:=20}" # seconds a herdr pane must stay blocked before a question event
: "${DV_READY_PATTERN:=›|❯|dv-ready>}" # Codex TUI input marker
: "${DV_SEND_DELAY:=0.3}" # let bracketed paste settle before Enter
: "${DV_LAND_MODE:=ff}" # ff or merge (local repositories)
: "${DV_LAND_METHOD:=}" # GitHub: empty = auto; squash, merge or rebase
: "${DV_TEST_CMD:=}" # required for local land; .devflow may supply it
: "${DV_REVIEW_WAIT:=300}" # maximum seconds after checks for bot reviews
: "${DV_REVIEW_BOTS:=devin,codex}" # comma-separated required author regexes (all must review this head)
: "${DV_POLL_INTERVAL:=10}" # PR review interval
: "${DV_POLISH:=1}" # 0 disables optional PR prose polishing
: "${DV_POLISH_CMD:=}" # shell command; receives the prompt as its last argument
: "${DV_POLISH_TIMEOUT:=180}" # seconds; default command uses local agy or ssh lina-os
: "${DV_WORKER_CMD:=}" # shell command; receives prompt file path; default Hermes below
: "${DV_HERMES_BIN:=hermes}"
: "${DV_WATCH_INTERVAL:=3}" # local queue read interval, seconds
: "${DV_WORKER_RETRY:=15}" # seconds before retrying a failed queue worker
: "${DV_MAX_WORKERS:=4}" # 1..4
: "${DV_RECONCILE_INTERVAL:=1800}" # status safety net seconds; capped at min(DV_STALL_AFTER, 60)
: "${DV_METRICS_INTERVAL:=60}" # file/event activity sampling by dv-watch, seconds
: "${DV_PULL_HOSTS=}" # watcher only: remote dev hosts whose kick queue it follows (dv-kick-pull)
: "${DV_PULL_RETRY:=15}" # seconds between restarts of an ended pull stream
: "${DV_HOSTS=lina-os hx-linux amd-linux go2-linux}" # SSH aliases for status/bidding; add gos-linux explicitly as the last fallback
: "${DV_MANAGER_HOST:=lina-os}" # submit/queue manager, independent of the local kick host
: "${DV_MANAGER_AGENT:=hermes}" # persistent per-repository Hermes session
: "${DV_MANAGER_MAX_WAIT:=120}" # busy seconds before other issues use plain workers
: "${DV_MAX_JOBS:=}" # host capacity; empty = max(1, floor(logical cores / 8))
: "${DV_MIN_MEMORY_MB:=512}" # reject bids below this available memory
: "${DV_MIN_DISK_GB:=15}" # work/cache free GiB; reject either below this, penalize below 2x
: "${DV_CACHE_TRIM_DAYS:=2}" # trim Go build files not accessed for this many days
: "${DV_DISK_INTERVAL:=1800}" # dv-watch disk safety pass, seconds
: "${DV_REPO_ROOT:=$HOME/code}" # existing clones, or clone destination after an award
: "${DV_BID_TIMEOUT:=10}" # seconds per read-only SSH bid/auth probe
: "${DV_AWARD_TIMEOUT:=90}" # seconds to confirm agent startup
: "${DV_AGENT_READY_codex:=}" # optional read-only auth probe command (exit 0 = ready)
: "${DV_AGENT_READY_claude:=}"
: "${DV_AGENT_READY_devin:=}"
# DV_CONFIG: config file override (default ~/.config/devflow/config.sh).
# DV_TEST_TMP: test temporary root (default TMPDIR or /tmp); no live agents/network.
: "${DV_QA:=0}" # 1: real-use QA after landed; .devflow on merged base may opt in/out
: "${DV_QA_AGENT:=codex}" # codex exec or claude (fresh session)
: "${DV_QA_AGENT_CMD:=}" # optional command receiving the QA prompt path
