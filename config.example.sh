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
: "${DV_CLAUDE_BIN:=claude}"
: "${DV_DEVIN_BIN:=$HOME/.local/bin/devin}"
: "${DV_CODEX_MODEL:=gpt-6-astra}"
: "${DV_CODEX_EFFORT:=xhigh}"
: "${DV_CODEX_DISABLE_HOOKS:=1}" # 0 keeps installed hooks enabled
: "${DV_CODEX_DISABLE_CRW:=1}" # 0 keeps installed crw plugin enabled
: "${DV_CLAUDE_MODEL:=opus}"
: "${DV_CLAUDE_EFFORT:=xhigh}"
: "${DV_DEVIN_MODEL:=fusion-gpt-6-astra-xhigh-sidekick-swe-2-high}"
: "${DV_AGENT:=codex}"
: "${DV_MODE:=goal}"
: "${DV_AGENT_CMD_codex:=}" # complete shell command, no extra CLI flags
: "${DV_AGENT_CMD_claude:=}"
: "${DV_AGENT_CMD_devin:=}"
: "${DV_TMUX_SOCKET:=}" # empty uses the normal tmux server
: "${DV_START_WAIT:=30}" # seconds to wait for Codex prompt / Devin trust menu
: "${DV_READY_PATTERN:=›|❯|dv-ready>}" # Codex TUI input marker
: "${DV_SEND_DELAY:=0.3}" # let bracketed paste settle before Enter
: "${DV_LAND_MODE:=ff}" # ff or merge (local repositories)
: "${DV_TEST_CMD:=}" # required for local land; .devflow may supply it
: "${DV_REVIEW_WAIT:=300}" # maximum seconds after checks for bot reviews
: "${DV_REVIEW_BOTS:=devin,codex}" # comma-separated required author regexes (all must review this head)
: "${DV_POLL_INTERVAL:=10}" # PR review interval
: "${DV_WORKER_CMD:=}" # shell command; receives prompt file path; default Hermes below
: "${DV_HERMES_BIN:=hermes}"
: "${DV_WATCH_INTERVAL:=3}" # local queue read interval, seconds
: "${DV_MAX_WORKERS:=4}" # 1..4
: "${DV_RECONCILE_INTERVAL:=1800}" # remote status safety net, seconds
: "${DV_HOSTS=lina-os hx go2 gos}" # whitespace-separated SSH aliases
# DV_CONFIG: config file override (default ~/.config/devflow/config.sh).
# DV_TEST_TMP: test temporary root (default TMPDIR or /tmp); no live agents/network.
