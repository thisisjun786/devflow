# devflow

시온이 Linear 이슈를 잡고, 코딩 에이전트 하나가 worktree 하나에서 개발하는 작은 bash 도구입니다. 개발·자기 시험 → 리뷰 한 번 → P0·P1 수정 한 번 → CI/시험 통과 후 병합. 완료는 SSH 이벤트로 알립니다.

## 설치

```bash
./install.sh --host            # hx / go2 / gos 등 개발 호스트
./install.sh --host --watch    # 감시 호스트(lina-os): 스킬 링크와 systemd user 유닛 생성
# 출력된 systemctl --user enable --now 명령은 직접 실행
./install.sh --mac --watch     # (옛 구성) Mac LaunchAgent; 출력된 launchctl 명령 직접 실행
```

감시 호스트는 Hermes의 sion 프로필로 작업자를 띄우므로 Hermes가 도는 호스트(10-19부터 lina-os)여야 합니다. 리눅스 감시는 로그아웃 뒤에도 돌도록 `loginctl enable-linger $USER`가 켜져 있어야 합니다(설치가 상태를 알려 줍니다). 모든 dv 호스트의 `DV_KICK_HOST`는 감시 호스트로 둡니다(기본 lina-os). 감시 호스트 자신은 ssh 없이 로컬 큐에 씁니다. git, gh, tmux, jq가 필요합니다. 설치는 `~/.local/bin`에 링크하고 기존 `~/.config/devflow/config.sh`를 보존합니다. 저장소는 링크 대상이므로 이동하지 마세요. `~/.local/bin`을 로컬과 SSH 비대화형 PATH에 추가하고 `gh auth login`은 사람이 준비합니다.

[config.example.sh](config.example.sh)에 모든 기본값이 있습니다. Codex 경로는 호스트에 따라 `~/node/bin/codex` 또는 `~/.opencodex/bin/codex`로 설정하세요. 기본 모델은 gpt-6-astra/xhigh이고, hooks와 crw 플러그인을 해당 실행에서만 끕니다. `DV_CODEX_DISABLE_HOOKS=0`, `DV_CODEX_DISABLE_CRW=0`으로 바꿀 수 있습니다. Claude는 opus/xhigh, Devin은 fusion-gpt-6-astra-xhigh-sidekick-swe-2-high입니다.

## 개발 호스트 도구 맞추기

새 Linux 호스트에서는 다음 순서로 준비합니다. `sync`는 x86_64/aarch64 Linux를 지원하고, 셸 코드는 macOS 기본 bash 3.2에서도 읽을 수 있습니다.

```bash
./install.sh --host
~/.local/bin/dv host sync
~/.local/bin/dv host check
# 로그인·토큰은 운영자가 준비한 뒤 선택적으로 실제 요청 한 번 확인
~/.local/bin/dv host check --probe-codex --json
# 준비가 끝나면 관리자 config.sh의 DV_HOSTS, 감시 호스트의 DV_PULL_HOSTS에 추가
```

[`hosts/tools.tsv`](hosts/tools.tsv)의 열은 이름, 버전, 설치 방식, 적용 호스트(`all` 또는 `DV_HOST` 값)입니다. `system`은 배포판 버전을 허용하고 `bundled`는 고정된 Node 배포본의 npm을 뜻합니다. `agy`는 lina-os에서만 조회합니다. Go는 `~/.local/go/go`(GOROOT), GOPATH는 `~/.local/go`, Node와 npm global은 `~/node`, 나머지 설치 대상은 `~/.local/bin`입니다. Codex와 Devin은 조회만 합니다. apt 도구도 설치하지 않고 없으면 운영자가 실행할 `sudo apt-get install ...`을 출력합니다.

`check`는 각 도구의 `ok` / `missing` / `wrong-version`, 실제 버전과 실행 경로, gh·codex·claude·devin 로그인 상태를 보여 줍니다. `--json`은 `tools[].login/ssh`, `auth`, `codex` 객체로 같은 결과를 냅니다. 기본 조회는 상태·설정 파일을 만들거나 바꾸지 않으며 drift가 있어도 종료 코드 0입니다. 조회 자체 실패나 요청한 probe 실패는 1입니다. 오래된 체크아웃을 가리킬 수 있는 gitleaks 심볼릭 링크는 버전이 같아도 `wrong-version`과 `reason=symlink`로 표시합니다.

PATH 검사는 상속된 개발 세션 PATH를 제외하고 계정 셸(`SHELL`, 필요하면 `DV_HOST_SHELL`로 지정)의 로그인 `-lc`와 SSH 비대화형 `-c` 시작을 **로컬에서** 재현합니다. 후자는 `SSH_CLIENT`를 설정하여 bash의 SSH 시작 파일 처리도 포함합니다. 실제 SSH 접속이나 sshd/PAM의 환경 정책까지 검증하는 것은 아닙니다. 셸의 실행 파일 경로를 검사하며 alias/function은 대상이 아닙니다. `sync`는 `~/.profile`과 `~/.zshenv`의 `# BEGIN devflow PATH` / `# END devflow PATH` 블록만 관리하며 중복된 자체 블록을 하나로 합칩니다. 그 밖의 사용자 줄·예전 수동 PATH 블록은 유지합니다. zsh는 비대화형에서도 `.zshenv`를 읽습니다. bash의 `.bashrc` 또는 `.bash_profile`이 `.profile`을 읽지 않으면 해당 모드의 drift는 남으며, `check`가 보여 줍니다. 이 파일들을 자동 편집하지는 않습니다.

`sync`는 설치 경로의 버전도 직접 확인하므로 PATH만 틀린 도구를 다시 받지 않습니다. 실패한 다운로드와 버전 불일치는 기존 도구를 교체하지 않습니다. 교체하는 기존 설치·링크는 같은 위치의 `.dv-backup.*`에 남기고 링크 대상에는 쓰지 않습니다. Node 업그레이드 시 이전 global 패키지도 백업에 남습니다. 새 Node에는 목록의 global 패키지(Claude Code·pnpm)를 설치하며, 그 밖의 패키지는 운영자가 옮깁니다. 셸 파일이 심볼릭 링크이거나 표시 블록이 깨졌으면 변경 전에 거절합니다. 성공 후 다시 실행하면 다운로드·npm 설치·PATH 파일 변경이 없습니다. 설치 잠금은 `~/.local/state/devflow-host/sync.lock`이며 강제 종료로 남으면 실행 중인 sync가 없는지 확인한 뒤 운영자가 제거합니다.

`codex` 항목은 PATH상의 도구 검사와 별도로 **실제 `DV_CODEX_BIN`**의 두 모드 실행 경로를 보여 줍니다. `~/.opencodex` 디렉터리, OpenCodex 토큰 환경 변수 또는 Codex 설정의 OpenCodex 표기가 있으면 프록시 호스트로 판단하고 `~/.opencodex/bin/codex`로 연결되지 않는 실행기를 `wrong-launcher`로 표시합니다. 설정은 바꾸지 않으므로 운영자가 `DV_CODEX_BIN="$HOME/.opencodex/bin/codex"`를 지정해야 합니다. 로그인 성공만으로 공급자 준비를 보장하지 않습니다.

`--probe-codex`는 SSH 모드에서 선택된 실행기로 기존 공급자에 `OK` 응답을 요청합니다. 기본 조회에는 이 요청이 없습니다. 임시 작업 폴더·읽기 전용 sandbox·승인 거절·ephemeral 실행을 사용하고 hooks와 shell tool을 끕니다. 프록시 자동 시작도 요청하지 않습니다. 최대 60초 후 실패로 보고하며 공급자 출력·토큰은 결과에 담지 않습니다. **실제 모델 요청이므로 사용량이 발생하며 비용 0을 보장하지 않습니다.** `sync`는 로그인, 토큰, SSH 키, 네트워크 설정을 다루지 않습니다.

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

herdr가 PATH 또는 `~/.local/bin/herdr`에 있으면 `dv start`가 포커스를 바꾸지 않고 `dv-<ISSUE>` workspace에서 에이전트를 직접 실행합니다(Codex hooks 유지). send·status·clean/land는 기록된 backend를 따르며 herdr 로그는 done/clean 시 화면을 저장합니다. 미설치 또는 `DV_HERDR=0`이면 tmux를 사용하고, 기존 backend 없는 이슈도 tmux로 처리합니다. herdr 시작 오류는 상태를 보존하고 실패를 알립니다.

herdr 0.9.1에서 `alive`는 pane 존재 여부를 뜻합니다. 사용자 지정 명령처럼 에이전트가 감지되지 않아도 `alive=true`, `agent_status=unknown`일 수 있으며, 이때 `dv send`는 `agent_not_found`를 반환합니다.

`DV_AGENT_QUESTIONS=sion`이 기본값이며 Codex의 `request_user_input*`와 Claude의 `AskUserQuestion` 도구를 켜 둡니다. `DV_AGENT_QUESTIONS=off`이면 두 에이전트의 질문 도구를 끄는 기존 동작을 사용합니다. tmux·herdr와 Codex goal·exec에 모두 적용하며, `DV_AGENT_CMD_*`로 전체 명령을 지정한 경우에는 CLI 인자를 추가하지 않으므로 질문 도구 설정도 해당 명령에서 정합니다.

에이전트는 브리프 안의 작거나 되돌릴 수 있는 선택을 직접 결정하고 보고서의 "결정"에 이유를 남깁니다. 설계 방향·범위·사용자에게 보이는 동작·데이터 형식처럼 결과를 바꾸는 선택만 시온에게 물으며, 선택지 2–3개와 추천안을 제시합니다. Codex의 `request_user_input_async`는 질문을 열어 둔 채 작업을 계속할 수 있으므로, 답에 의존하지 않는 작업은 진행합니다.

herdr에서는 에이전트와 함께 실행되는 작은 감시자가 `agent wait`로 상태 전환을 기다립니다. `blocked`가 `DV_BLOCKED_GRACE`초(기본 20) 지속되면 `question` 이벤트를 한 번 보내고, 차단이 풀린 뒤 다음 에피소드를 기다립니다. `dv status --json`의 `question_pending`은 알림을 보낸 에피소드가 열려 있는 동안 true입니다. 시온은 준의 맥락(기억·이전 결정·이슈)을 바탕으로 답하고 이유를 이슈에 기록하며, 되돌릴 수 없는 행동·외부 효과·비용·권한에 관한 질문만 준에게 올립니다. tmux에는 이 감시자가 없으며, herdr가 `working`을 유지하는 비동기 질문도 이 감시자의 이벤트를 발생시키지 않습니다.

질문 본문은 herdr의 `agent_session.value`와 일치하는 세션 기록을 먼저 읽습니다. Codex는 `~/.codex/sessions/**/rollout-*.jsonl`의 마지막 `request_user_input` 계열 function call의 `arguments`, Claude는 `~/.claude/projects/**/<세션 ID>.jsonl`의 마지막 `AskUserQuestion` tool use의 `input`을 사용합니다. 세션 ID를 기록 안에서도 확인하고, 질문·선택지의 JSON을 최대 2,000자로 전달합니다(긴 JSON은 중간에 잘릴 수 있습니다). 기록·질문을 찾지 못하거나 읽을 수 없으면 기존처럼 마지막 화면 8줄을 정리해 최대 1,000자로 보냅니다. 기록 경로는 `DV_CODEX_SESSIONS`·`DV_CLAUDE_SESSIONS`로 지정할 수 있으며, 기본값은 `CODEX_HOME`·`CLAUDE_CONFIG_DIR`도 따릅니다. 기록과 사용자 설정은 읽기만 합니다.

| 명령 | 기능 |
|---|---|
| `dv submit REPO ISSUE SLUG --brief FILE [--agent AGENT] [--base BRANCH] [--mode MODE]` | 관리자에게 제출, 호스트는 입찰로 결정 |
| `dv bid --json [--repo REPO] [--agent AGENT]` | 수용량·부하·메모리·clone·로그인 조회, 상태 변경 없음 |
| `dv queue [ISSUE] [--json]` / `dv cancel ISSUE` | 관리자 배정 상태 조회 / 미배정 제출 취소 |
| `dv start REPO ISSUE SLUG [--agent codex\|claude\|devin] [--brief FILE] [--base BRANCH] [--mode goal\|exec]` | worktree·브랜치·상태·herdr/tmux 생성 |
| `dv done ISSUE [--note TEXT]` | head·변경 파일 수·보고서 경로·완료 이벤트 |
| `dv pr ISSUE` | force 없이 push, PR 생성/기존 PR 갱신, 대기 시작 |
| `dv polish ISSUE` | PR 본문 퇴고·코드/URL 보존 검증 후 본문만 갱신 |
| `dv pr-wait ISSUE` | 체크 watch 후 봇 리뷰 또는 대기 시간 종료, pr-ready 이벤트 |
| `dv review ISSUE` | 로컬 리뷰 출력과 횟수 저장 |
| `dv land ISSUE` | PR squash / 로컬 시험 후 병합, worktree 정리 |
| `dv status [ISSUE] [--json]` | 상태, 에이전트, 호스트, 경과, backend·생존·에이전트 상태, 마지막 로그 |
| `dv send ISSUE 'text'` | herdr agent prompt(차단 시 대기 후 한 번 재시도) / tmux 붙여넣기 후 Enter |
| `dv clean ISSUE` | 깨끗한 worktree·herdr/tmux 정리; 병합된 로컬 브랜치만 삭제 |
| `dv kick KIND ISSUE [msg]` | 완료 알림 전송, 실패 로그 보관 |
| `dv-kick KIND ISSUE [msg [host [head]]]` | 감시 호스트 로컬 큐와 로그에 이벤트 추가 |
| `dv-watch` | 로컬 큐 소비, 최대 4개 시온 작업자, 느린 상태 점검 |

상태는 `$DV_STATE/ISSUE/`의 `meta`(JSON), `brief.md`, `log`, `report.md`, `done.json`, 리뷰·PR 결과입니다. done은 PR 대기 상태를 덮어쓰지 않습니다. ready는 **확인할 자료가 준비됨**을 뜻하며 CI 성공을 보장하지 않습니다. land는 빈 체크·skipped·pending·실패·head 불일치를 모두 거절합니다. 원격 브랜치를 지우지 않으며 squash 후 로컬 브랜치도 조상이 아니면 보존합니다.

## 기기 자동 배정

시온은 lina-os에서 `dv submit ~/code/my-app APP-42 fix-save --brief /path/brief.md`를 실행합니다. `DV_MANAGER_HOST` 기본값은 lina-os이며, 다른 호스트의 submit은 기존 SSH 연결로 관리자에게 브리프 내용을 전송합니다. 개발 호스트에 관리자 방향 SSH 키가 없어도 관리자에서 제출하면 됩니다. `DV_HOSTS`에는 배정 가능한 SSH 별칭을 적고, 모든 호스트에 같은 버전의 dv를 둡니다. 원격 저장소가 있는 로컬 경로는 origin URL로 전달합니다. 각 호스트는 `$DV_REPO_ROOT`(기본 `~/code`)의 같은 이름 clone을 확인하고, 없으면 낙찰 후 clone합니다. 이름이 같은 다른 origin은 덮어쓰지 않습니다. 원격 없는 경로는 해당 경로가 있는 호스트만 입찰합니다.

`dv-watch`가 submitted 이벤트를 받으면 각 호스트에 `dv bid --json --repo REPO --agent AGENT`를 실행합니다. 입찰은 읽기 전용이며 빈 자리, load5/논리 코어 수, 사용 가능 메모리(MiB), 기존 clone, 에이전트 로그인 여부를 반환합니다. `DV_MAX_JOBS`는 호스트별 설정이고 기본값은 `max(1, floor(코어 수 / 8))`입니다. 실행 중인 기존 dv 작업도 자리를 차지하며 done 또는 종료된 작업은 제외합니다. 만석, 로그인 불가, 사용할 수 없는 저장소·터미널, `DV_MIN_MEMORY_MB`(기본 512) 미만이면 거절합니다. 로그인 확인은 Codex `login status`, Claude/Devin `auth status`를 사용하며, 다른 CLI는 `DV_AGENT_READY_codex/claude/devin`에 읽기 전용 명령을 지정할 수 있습니다. `DV_AGENT_CMD_*`로 지정한 사용자 실행기는 준비된 것으로 간주합니다.

점수는 `100 × 빈 자리/수용량 − 20 × load5/코어 + min(64, 남은 메모리/1024) + clone 보너스 20`입니다. 조회·배정은 작업 호스트 → 관리자와 lina-os → gos 순으로 진행하며, 점수가 높아도 뒤 그룹이 앞 그룹을 추월하지 않습니다. 같은 그룹에서는 높은 점수가 먼저이고, 기본 관리자(lina-os)에서 동점 순서는 **hx-linux → amd-linux → go2-linux → lina-os → gos-linux**입니다(준 10-20 결정). 조회는 각 그룹 안에서 `DV_HOSTS`에 적힌 순서를 따릅니다. hx·amd·go2·gos 별칭에도 같은 우선순위를 적용합니다. gos는 명시적으로 `DV_HOSTS`에 넣을 때만 쓰는 최후 후보입니다. 낙찰 호스트는 잠금 안에서 수용량을 다시 확인하고 `dv start`를 실행합니다. 직접 실행하는 `dv start`는 수동 경로이므로 자동 배정 중에는 `submit`을 사용하세요.

관리자 상태는 `$DV_HOME/submissions/ISSUE/task.json`이고 `dv queue`로 봅니다. A2A 상태 `submitted/working/input-required/completed/failed/canceled`를 사용하며, 개별 입찰은 `submitted/rejected`입니다. 기존 개발·PR 상태(`dv status`의 running/pr/ready 등)는 그대로 유지합니다. `bids.json`에는 점수·거절 이유, `dispatch.log`에는 시작 결과가 남습니다. 모두 거절하면 submitted로 남고, 기존 done/failed/landed 이벤트가 올 때만 재입찰합니다. 별도 입찰 폴링이나 데몬은 없습니다. `dv cancel`은 아직 배정되지 않은 제출만 취소합니다.

응답 없는 입찰, 낙찰 재검사의 거절, 확인된 시작 실패는 같은 회차의 다음 후보로 넘어갑니다. 새 submitted/done/failed/landed 이벤트에서 시작하는 회차에는 이전 실패 호스트도 다시 입찰합니다. 재시도 가능한 시작 실패의 상태·로그·영수증은 `$DV_STATE/.awards/ISSUE/failed.*/`에 보관하고 새 브랜치를 사용합니다. 낙찰 응답을 잃었으면 같은 요청 토큰의 호스트 영수증을 조회해 중복 시작을 막습니다. 실행 여부가 불명확하거나 실패한 worktree가 dirty이면 input-required로 유지하고 이후 호스트 이벤트로 결과를 확정합니다. 이전 회차의 실패 이벤트는 새로 실행 중인 작업을 실패 처리하지 않습니다. `DV_BID_TIMEOUT`(10초), `DV_AWARD_TIMEOUT`(90초)으로 조회와 시작 확인 시간을 정합니다. `.admission-lock`은 소유 PID가 죽은 경우에만 회수합니다. 소유자 기록이 없는 잠금과 SIGKILL로 남은 `.schedule-lock`은 프로세스 종료 확인 뒤 수동 정리가 필요합니다.

`dv pr`은 PR을 처음 만든 직후 `dv polish`를 백그라운드로 시작합니다. CI·봇 리뷰와 나란히 돌며 병합을 기다리게 하지 않습니다. 기본 명령은 로컬 `agy --model gemini-4-argon-high -p "<프롬프트>"`이며, `agy`가 없으면 `ssh lina-os`에서 같은 명령을 실행합니다. `DV_POLISH=0`으로 끄거나 `DV_POLISH_CMD`에 퇴고 명령을 지정할 수 있습니다. 명령에는 프롬프트가 마지막 인자로 전달되고, 표준 출력은 본문으로 사용됩니다(예: `DV_POLISH_CMD='my-polisher --model editor'`).

퇴고는 군더더기·AI 말투·설명용 줄표만 정리하도록 요청합니다. 코드 블록·인라인 코드·URL의 내용과 출현 횟수를 보존했는지 검사한 뒤 `gh api --method PATCH repos/OWNER/REPO/pulls/NUMBER -F body=@파일`로 본문만 바꿉니다. 대상은 `pr.json`의 URL에서 구하며, 적용 직전에 읽은 GitHub 본문이 원문과 다르거나 읽기에 실패하면 적용하지 않고 로그에 남깁니다. 최초 원문은 `pr-body.orig.md`, 적용한 본문은 `pr-body.md`, 실행 결과는 `polish.log`에 남습니다. 빈 출력·검증 실패·명령 오류·시간 초과(기본 180초, `DV_POLISH_TIMEOUT`)에는 원문을 유지하고 종료 코드 0으로 끝납니다. 사실·숫자·일반 문장과 모든 Markdown 변형의 의미 보존까지 자동으로 증명하는 검사는 아닙니다.

감시 호스트의 `$DV_HOME/kick.q`와 `events.log`는 JSON Lines입니다. 이벤트 ID(host/issue/kind/head)로 중복을 무시하며, 작업자 로그·프롬프트는 `workers/`에 남습니다. 3초 간격은 로컬 파일 읽기이며 원격 안전망은 30분 간격 `ssh HOST dv status --json`입니다(감시 호스트 자신은 ssh 없이). 원격 개발 호스트는 감시 호스트의 dv-watch가 `DV_PULL_HOSTS`에 적힌 호스트마다 `dv-kick-pull <host>`를 띄워, 그 호스트의 `kick.q`를 ssh 한 줄기로 `tail -f` 해 받아 옵니다(끊기면 dv-watch가 다시 띄움, 별도 데몬 없음). 개발 호스트에서 감시 호스트로 가는 ssh 키가 필요 없고, 폴링 없이 쓰는 즉시 도착하며, 줄 위치와 파일 inode를 이 쪽 큐에 쓴 뒤에만 저장해, 전달 실패·재접속·큐 교체 때도 빠짐없이 이어 받습니다. 원격 쪽은 그 호스트의 devflow 설정(DV_HOME)을 읽습니다. 그 호스트의 `DV_KICK_HOST`는 자기 자신(로컬 큐)으로 둡니다. `$DV_HOME/stop`을 만들면 새 작업을 멈추고 실행 중인 작업자를 기다립니다. 재시작할 때 stop 파일을 지우세요. 비정상 종료의 잠금은 PID와 실제 프로세스를 확인한 뒤 사람이 지웁니다.

Codex goal은 tmux에서 TUI 입력 마커를 기다린 후 `/goal`을 붙여넣고 Enter를 보냅니다. herdr에서는 Codex 감지를 기다린 뒤 `agent prompt`로 제출하고, 준비되지 않았거나 차단됐으면 시작 제한 시간 안에서 재시도합니다. hook 신뢰 창이 보이면 자동 승인이나 입력 없이 `codex hook trust required` failed 이벤트를 보내고 주입을 중단합니다. 제출 성공 후에도 `DV_START_WAIT`초 안에 herdr의 `working` 또는 화면의 `Pursuing goal`을 확인합니다. 같은 `/goal`이 입력 칸에 남아 있으면 1초 뒤 Enter를 한 번만 더 보내고, 시작이 확인되지 않으면 `codex goal did not start` failed 이벤트를 보냅니다. 실패한 시작은 `dv status`에서 `start-failed`로 표시하며, 터미널은 사람이 확인할 수 있게 남깁니다. 신뢰 문제를 해결한 뒤 `dv send`로 다시 지시할 수 있습니다. 폴더 신뢰는 해당 실행의 CLI 설정으로 worktree와 원본 저장소 루트에 모두 적용하며 사용자 설정 파일은 수정하지 않습니다.

exec는 한 번 실행 후 성공할 때 래퍼가 done을 호출합니다. goal은 Codex/Claude/Devin과 사용자 지정 실행기 모두 `dv done` 없이 종료되면 종료 코드가 0이어도 기존 failed 이벤트로 알립니다. 이미 done을 기록했다면 실패 이벤트를 보내지 않습니다. 시작에 성공했던 에이전트의 재시작은 자동화하지 않습니다. `DV_AGENT_CMD_codex/claude/devin`은 전체 명령을 덮어쓰며 추가 CLI 플래그·TUI 입력을 넣지 않습니다. 해당 명령은 `DV_ISSUE`, `DV_STATE`, 작업 디렉터리를 받습니다.

## 시험

```bash
tests/run.sh
shellcheck -x bin/* lib/*.sh install.sh config.example.sh tests/run.sh tests/fixtures/*
```

실제 에이전트·GitHub·SSH·Hermes를 시험에서 부르지 않습니다. 임시 bare 원격과 실제 tmux를 쓰며 tmux가 없을 때만 해당 시험을 skip합니다. `DV_TEST_TMP=/scratch/...`로 임시 위치를 지정할 수 있습니다. 큐·worker 기록은 운영자가 보관 주기를 정하고, worktree는 `dv clean`으로 정리하세요.

실제 herdr 연결 시험은 `DV_HERDR=1 tests/herdr-live.sh`로 별도 실행합니다. herdr가 없으면 skip하고, 있으면 임시 저장소와 `echo SMOKE-OK; sleep 15`만 실행하여 start·status·clean을 확인합니다. 사용자 설정은 읽거나 바꾸지 않습니다. 이 스크립트의 정적 검사는 `shellcheck tests/herdr-live.sh`로 실행합니다.
