# devflow

시온이 Linear 이슈를 잡고, 코딩 에이전트 하나가 worktree 하나에서 개발하는 작은 bash 도구입니다. 개발·자기 시험 → 리뷰 한 번 → P0·P1 수정 한 번 → CI/시험 통과 후 병합. 완료는 SSH 이벤트로 알립니다.

## 설치

```bash
./install.sh --host            # lina-os / hx / go2 / gos
./install.sh --mac --watch     # Mac: 스킬 링크와 LaunchAgent 파일 생성
# 출력된 launchctl bootstrap 명령은 직접 실행
```

git, gh, tmux, jq가 필요하며 Mac 작업자는 Hermes의 sion 프로필을 사용합니다. 설치는 `~/.local/bin`에 링크하고 기존 `~/.config/devflow/config.sh`를 보존합니다. 저장소는 링크 대상이므로 이동하지 마세요. `~/.local/bin`을 로컬과 SSH 비대화형 PATH에 추가하고 `gh auth login`은 사람이 준비합니다.

[config.example.sh](config.example.sh)에 모든 기본값이 있습니다. Codex 경로는 호스트에 따라 `~/node/bin/codex` 또는 `~/.opencodex/bin/codex`로 설정하세요. 기본 모델은 gpt-6-astra/xhigh이고, hooks와 crw 플러그인을 해당 실행에서만 끕니다. `DV_CODEX_DISABLE_HOOKS=0`, `DV_CODEX_DISABLE_CRW=0`으로 바꿀 수 있습니다. Claude는 opus/xhigh, Devin은 fusion-gpt-6-astra-xhigh-sidekick-swe-2-high입니다.

## 하루 흐름

```bash
dv start ~/code/my-app APP-42 fix-save --brief /path/brief.md
# 에이전트: 개발·시험·커밋 → dv pr APP-42 → dv done APP-42
dv status APP-42
dv send APP-42 'P1 저장 오류를 한 번 수정하고 관련 시험, 커밋, dv pr, dv done까지 해주세요.'
# 시온: 이벤트에서 보고서·diff·시험·리뷰를 확인
dv land APP-42                 # 현재 PR head의 체크가 전부 성공해야 함
```

원격이 없으면 로컬 기본 브랜치(main, master, 현재 브랜치 순)를 사용합니다. 원격이 있으면 fetch 후 원격 기본 브랜치에서 시작합니다. `--base`로 지정할 수 있습니다. 로컬 저장소는 `dv review APP-42` 한 번 후 `dv land`; `DV_TEST_CMD` 또는 저장소의 `.devflow`에 `DV_TEST_CMD='bash tests/run.sh'`가 필요합니다. `.devflow`는 신뢰하는 shell 설정이며, 후보 병합을 임시 worktree에서 시험한 뒤 base를 갱신합니다. 기본 ff, `DV_LAND_MODE=merge`는 merge 커밋입니다.

| 명령 | 기능 |
|---|---|
| `dv start REPO ISSUE SLUG [--agent codex\|claude\|devin] [--brief FILE] [--base BRANCH] [--mode goal\|exec]` | worktree·브랜치·상태·tmux 생성 |
| `dv done ISSUE [--note TEXT]` | head·변경 파일 수·보고서 경로·완료 이벤트 |
| `dv pr ISSUE` | force 없이 push, PR 생성/기존 PR 갱신, 대기 시작 |
| `dv pr-wait ISSUE` | 체크 watch 후 봇 리뷰 또는 대기 시간 종료, pr-ready 이벤트 |
| `dv review ISSUE` | 로컬 리뷰 출력과 횟수 저장 |
| `dv land ISSUE` | PR squash / 로컬 시험 후 병합, worktree 정리 |
| `dv status [ISSUE] [--json]` | 상태, 에이전트, 호스트, 경과, tmux, 마지막 로그 |
| `dv send ISSUE 'text'` | tmux에 붙여넣기 후 Enter |
| `dv clean ISSUE` | 깨끗한 worktree·tmux 정리; 병합된 로컬 브랜치만 삭제 |
| `dv kick KIND ISSUE [msg]` | 완료 알림 전송, 실패 로그 보관 |
| `dv-kick KIND ISSUE [msg [host [head]]]` | Mac 로컬 큐와 로그에 이벤트 추가 |
| `dv-watch` | 로컬 큐 소비, 최대 4개 시온 작업자, 느린 상태 점검 |

상태는 `$DV_STATE/ISSUE/`의 `meta`(JSON), `brief.md`, `log`, `report.md`, `done.json`, 리뷰·PR 결과입니다. done은 PR 대기 상태를 덮어쓰지 않습니다. ready는 **확인할 자료가 준비됨**을 뜻하며 CI 성공을 보장하지 않습니다. land는 빈 체크·skipped·pending·실패·head 불일치를 모두 거절합니다. 원격 브랜치를 지우지 않으며 squash 후 로컬 브랜치도 조상이 아니면 보존합니다.

Mac의 `$DV_HOME/kick.q`와 `events.log`는 JSON Lines입니다. 이벤트 ID(host/issue/kind/head)로 중복을 무시하며, 작업자 로그·프롬프트는 `workers/`에 남습니다. 3초 간격은 로컬 파일 읽기이며 원격 안전망은 30분 간격 `ssh HOST dv status --json`입니다. `$DV_HOME/stop`을 만들면 새 작업을 멈추고 실행 중인 작업자를 기다립니다. 재시작할 때 stop 파일을 지우세요. 비정상 종료의 잠금은 PID와 실제 프로세스를 확인한 뒤 사람이 지웁니다.

Codex goal은 TUI 입력 마커를 기다린 후 `/goal`을 붙여넣고 Enter를 보냅니다. TUI 버전이 달라 입력을 못 찾으면 failed 이벤트를 남기며 `dv send`로 보낼 수 있습니다. exec는 한 번 실행 후 성공할 때 래퍼가 done을 호출합니다. 종료된 에이전트 재시작은 자동화하지 않습니다. `DV_AGENT_CMD_codex/claude/devin`은 전체 명령을 덮어쓰며 추가 CLI 플래그·TUI 입력을 넣지 않습니다. 해당 명령은 `DV_ISSUE`, `DV_STATE`, 작업 디렉터리를 받습니다.

## 시험

```bash
tests/run.sh
shellcheck -x bin/* lib/*.sh install.sh config.example.sh tests/run.sh tests/fixtures/*
```

실제 에이전트·GitHub·SSH·Hermes를 시험에서 부르지 않습니다. 임시 bare 원격과 실제 tmux를 쓰며 tmux가 없을 때만 해당 시험을 skip합니다. `DV_TEST_TMP=/scratch/...`로 임시 위치를 지정할 수 있습니다. 큐·worker 기록은 운영자가 보관 주기를 정하고, worktree는 `dv clean`으로 정리하세요.
