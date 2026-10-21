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

Claude 온보딩은 `check`의 텍스트 출력과 JSON의 `claude.onboarding`에 `hasCompletedOnboarding`, `skipDangerousModePermissionPrompt` 두 boolean으로 표시합니다. 파일이 없거나 읽을 수 없거나 올바른 JSON 객체가 아니면 해당 값은 false입니다. 이 검사도 설정을 변경하지 않습니다.

`sync`는 설치 경로의 버전도 직접 확인하므로 PATH만 틀린 도구를 다시 받지 않습니다. 다운로드는 배포자의 SHA-256 목록(herdr는 GitHub release asset digest)과 대조한 후 압축을 풀거나 실행합니다. 체크섬을 구하지 못하거나 일치하지 않으면 설치를 거절합니다. 실패한 다운로드와 버전 불일치는 기존 도구를 교체하지 않습니다. npm global 설치는 현재 Node prefix의 임시 복사본에서 수행하고, 버전 검증을 통과한 뒤 교체합니다. 실패한 npm 설치는 현재 Claude Code·pnpm을 보존합니다. 교체하는 기존 설치·링크는 같은 위치의 `.dv-backup.*`에 남기고 링크 대상에는 쓰지 않습니다. Node 업그레이드 시 이전 global 패키지도 백업에 남습니다. 새 Node에는 목록의 global 패키지(Claude Code·pnpm)를 설치하며, 그 밖의 패키지는 운영자가 옮깁니다. 셸 파일이 심볼릭 링크이거나 표시 블록이 깨졌으면 변경 전에 거절합니다. 성공 후 다시 실행하면 다운로드·npm 설치·PATH 파일 변경이 없습니다. 설치 잠금은 `~/.local/state/devflow-host/sync.lock`이며 강제 종료로 남으면 실행 중인 sync가 없는지 확인한 뒤 운영자가 제거합니다.

`npm bundled` 검사는 PATH의 npm이 고정된 `~/node` 배포본 내부에 있고 같은 배포본의 node가 실행되는지 확인합니다. 다른 npm이면 `reason=not-bundled`로 표시합니다. 로그인 검사는 `DV_CODEX_BIN`, `DV_CLAUDE_BIN`, `DV_DEVIN_BIN`에 지정한 실행 파일을 사용합니다. 시간 제한은 명령의 하위 프로세스도 종료하며, 별도 세션으로 이탈한 프로세스까지 추적하지는 않습니다.

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

GitHub의 `dv land`는 저장소의 허용 병합 방식을 한 번 조회하고 squash → merge commit → rebase 순으로 선택합니다. `DV_LAND_METHOD=squash|merge|rebase`를 환경변수 또는 작업 worktree의 `.devflow`에 지정하면 해당 방식을 사용합니다(비어 있지 않은 환경변수가 우선). 예: `DV_LAND_METHOD=merge dv land APP-42`. 잘못된 값, 저장소가 허용하지 않는 지정값, 허용 방식 없음, 조회 실패 시 병합하지 않고 worktree를 보존합니다. 현재 PR head 고정과 병합 후 MERGED 확인은 그대로 적용됩니다. 로컬 저장소는 기존 `DV_LAND_MODE`를 사용합니다.

herdr가 PATH 또는 `~/.local/bin/herdr`에 있으면 `dv start`가 포커스를 바꾸지 않고 `dv-<ISSUE>` workspace에서 에이전트를 직접 실행합니다(Codex hooks 유지). send·status·clean/land는 기록된 backend를 따르며 herdr 로그는 done/clean 시 화면을 저장합니다. 미설치 또는 `DV_HERDR=0`이면 tmux를 사용하고, 기존 backend 없는 이슈도 tmux로 처리합니다. herdr 시작 오류는 상태를 보존하고 실패를 알립니다.

herdr 0.9.1에서 `alive`는 pane 존재 여부를 뜻합니다. 사용자 지정 명령처럼 에이전트가 감지되지 않아도 `alive=true`, `agent_status=unknown`일 수 있습니다. `dv send`는 전달 실패 후 에이전트 종료가 확인되면 같은 worktree·브랜치·에이전트 종류·실행 모드로 한 번 자동 재시작합니다. 요청 문장을 첫 입력에 넣고 기존 brief·보고서 경로를 함께 전달합니다. 미커밋 변경과 PR, `review-fix.sent`는 보존하며 같은 수정 요청을 이어가므로 두 번째 리뷰 수정으로 세지 않습니다.

tmux는 사라진 세션이나 종료된 pane을 확인하고, herdr는 `agent_not_found`와 래퍼 종료를 함께 확인합니다. pane이 사라졌어도 살아 있는 래퍼는 재시작하지 않으며 통신 오류, 감지 지연에도 재시작하지 않습니다. 기존 herdr pane이 있으면 재사용하고 없으면 같은 작업 폴더에 새 workspace를 만듭니다. `$DV_STATE/ISSUE/revive/`에 최초 요청과 이전 실행·완료 기록을 보존하며 이슈당 자동 재시작은 한 번입니다. 새 에이전트의 시작·실행이 실패하거나 goal이 새 `dv done` 없이 끝나면 `blocked` 이벤트를 한 번 보냅니다. 강제 종료로 래퍼까지 사라져 종료 처리가 실행되지 않았다면 다음 `dv send`가 종료를 확인해 차단을 알립니다. 이전 버전의 herdr 이슈에서 래퍼 PID도 종료 기록도 없다면 자동으로 종료를 단정하지 않습니다.

Claude 기본 실행은 먼저 `~/.claude.json`의 `projects[worktree 경로].hasTrustDialogAccepted=true`를 기록합니다. `CLAUDE_CONFIG_DIR`가 비어 있지 않으면 Claude Code와 같이 `$CLAUDE_CONFIG_DIR/.claude.json`에 기록하고 `$CLAUDE_CONFIG_DIR/settings.json`에서 설정을 읽습니다. `CLAUDE_CONFIG_DIR`를 명시적으로 `~/.claude`로 지정해도 신뢰·온보딩 파일은 그 디렉터리 **안의** `.claude.json`입니다. `dv host check`도 같은 프로필을 읽으며, 선택한 프로필에 파일이 없거나 손상되어도 기본 프로필로 돌아가지 않습니다.

없는 프로필 디렉터리와 신뢰 파일은 만들고(새 파일 권한 600), 다른 키는 보존하며, 같은 디렉터리의 임시 파일을 rename하여 교체합니다. 기존 파일은 `cp -p`로 소유권·권한·ACL을 복사한 뒤 내용을 갱신하고 원래 mode를 복원합니다. Linux의 GNU cp와 macOS의 cp는 `-p`로 ACL도 보존합니다. 복사·권한 복원·쓰기 중 오류가 나면 원본을 교체하지 않습니다. 선택한 파일 옆의 `.claude.json.dv-lock`으로 dv의 동시 기록을 직렬화하며 약 10초 동안 잠금을 얻지 못하면 시작 실패로 끝납니다. 손상된 JSON과 심볼릭 링크는 보존하고 시작을 거절합니다. SIGKILL 등으로 잠금이 남으면 실행 중인 기록 작업이 없는지 확인한 뒤 운영자가 잠금 파일을 제거해야 합니다. 이 잠금을 사용하지 않는 Claude 자체나 다른 도구의 동시 설정 변경까지 직렬화하지는 않습니다.

선택한 프로필의 `.claude.json`에서 `hasCompletedOnboarding`, `settings.json`에서 `skipDangerousModePermissionPrompt`가 모두 true여야 Claude를 띄웁니다. 환경 변수가 없거나 비어 있으면 각각 `~/.claude.json`과 `~/.claude/settings.json`을 읽습니다. 남은 온보딩이 있으면 `start-failed` 상태와 실패 이벤트를 남기며 화면에 키를 보내지 않습니다. 같은 `CLAUDE_CONFIG_DIR` 환경에서 `claude --dangerously-skip-permissions`를 한 번 대화형으로 실행해 테마·보안 안내·바이패스 경고를 끝내고 `dv host check`로 확인하세요. dv는 온보딩 플래그를 대신 설정하지 않습니다. `DV_AGENT_CMD_claude`로 전체 명령을 지정하면 이 준비 절차도 해당 명령에서 관리합니다.

`DV_AGENT_QUESTIONS=sion`이 기본값이며 herdr에서 Codex의 `request_user_input*`와 Claude의 `AskUserQuestion` 도구를 켜 둡니다. `DV_AGENT_QUESTIONS=off`이면 두 에이전트의 질문 도구를 끕니다. 질문 감시자가 없는 tmux에서는 항상 이 off 인자를 전달합니다. Codex goal·exec에 모두 적용하며, `DV_AGENT_CMD_*`로 전체 명령을 지정한 경우에는 CLI 인자를 추가하지 않으므로 질문 도구 설정도 해당 명령에서 정합니다.

에이전트는 브리프 안의 작거나 되돌릴 수 있는 선택을 직접 결정하고 보고서의 "결정"에 이유를 남깁니다. 설계 방향·범위·사용자에게 보이는 동작·데이터 형식처럼 결과를 바꾸는 선택만 시온에게 물으며, 선택지 2–3개와 추천안을 제시합니다. Codex의 `request_user_input_async`는 질문을 열어 둔 채 작업을 계속할 수 있으므로, 답에 의존하지 않는 작업은 진행합니다.

herdr에서는 에이전트와 함께 실행되는 작은 감시자가 `agent wait`로 상태 전환을 기다리며, 약 1초마다 세션 기록의 미응답 질문도 확인합니다. `working` 상태의 비동기 질문도 호출마다 `question` 이벤트를 보냅니다. 전달 성공 뒤에만 전송 기록을 남기므로 실패한 호출은 다음 감시에서 재시도합니다. 겹친 호출도 각각 추적하며, 비동기 도구의 즉시 `accepted:true` 응답은 답변으로 보지 않습니다. 사용자 답변의 `questionItemId`가 그 호출의 모든 질문에 대응하면 닫습니다. 기록에 질문이 없으면 `blocked`가 `DV_BLOCKED_GRACE`초(기본 20) 지속될 때 화면으로 알립니다. 답변된 호출은 재사용하지 않습니다. `dv status --json`의 `question_pending`은 전달에 성공한 질문 중 하나라도 열려 있는 동안 true입니다. 감시자 오류는 pane 대신 이슈의 `question.log`에 기록합니다. 시온은 준의 맥락(기억·이전 결정·이슈)을 바탕으로 답하고 이유를 이슈에 기록하며, 되돌릴 수 없는 행동·외부 효과·비용·권한에 관한 질문만 준에게 올립니다.

질문 본문은 herdr의 `agent_session.value`와 일치하는 세션 기록을 먼저 읽습니다. Codex는 `~/.codex/sessions/**/rollout-*.jsonl`의 미응답 `request_user_input` 계열 function call의 `arguments`, Claude는 `~/.claude/projects/**/<세션 ID>.jsonl`의 미응답 `AskUserQuestion` tool use의 `input`을 사용합니다. 호출 ID에 대응하는 답변만 해당 호출을 닫습니다. 세션 ID를 기록 안에서도 확인하고, 질문·선택지의 JSON을 호출당 최대 2,000자로 전달합니다(긴 JSON은 중간에 잘릴 수 있습니다). 기록·질문을 찾지 못하거나 읽을 수 없으면 기존처럼 마지막 화면 8줄을 정리해 최대 1,000자로 보냅니다. 기록 경로는 `DV_CODEX_SESSIONS`·`DV_CLAUDE_SESSIONS`로 지정할 수 있으며, 기본값은 `CODEX_HOME`·`CLAUDE_CONFIG_DIR`도 따릅니다. 기록과 사용자 설정은 읽기만 합니다.

| 명령 | 기능 |
|---|---|
| `dv submit REPO ISSUE SLUG --brief FILE [--agent AGENT] [--base BRANCH] [--mode MODE]` | 관리자에게 제출, 호스트는 입찰로 결정 |
| `dv bid --json [--repo REPO] [--agent AGENT]` | 수용량·부하·메모리·clone·로그인 조회, 상태 변경 없음 |
| `dv queue [ISSUE] [--json]` / `dv cancel ISSUE` | 관리자 배정 상태 조회 / 미배정 제출 취소 |
| `dv start REPO ISSUE SLUG [--agent codex\|claude\|devin] [--brief FILE] [--base BRANCH] [--mode goal\|exec]` | worktree·브랜치·상태·herdr/tmux 생성 |
| `dv done ISSUE [--note TEXT]` | head·변경 파일 수·보고서 경로·완료 이벤트 |
| `dv pr ISSUE` | force 없이 push, PR 생성/기존 PR 갱신, 대기 시작. 상태 폴더에 `pr.md`(작업자가 쓴 공개용 본문)가 있으면 그대로 본문으로 쓰고, 없으면 브리프와 보고서로 만든다 |
| `dv polish ISSUE` | PR 본문 퇴고·코드/URL 보존 검증 후 본문만 갱신 |
| `dv pr-wait ISSUE` | CI 등록·종료 후 봇 리뷰 또는 리뷰 대기 시간 종료, pr-ready 이벤트 |
| `dv review ISSUE` | 로컬 리뷰 출력과 횟수 저장 |
| `dv land ISSUE` | PR 허용 방식 선택 / 로컬 시험 후 병합, worktree 정리 |
| `dv status [ISSUE] [--json]` | 상태, 에이전트, 호스트, 경과, backend·생존·에이전트 상태, 마지막 로그 |
| `dv send ISSUE 'text'` | 실행 중이면 입력 전달; 종료가 확인되면 같은 작업을 한 번 자동 재시작 |
| `dv clean ISSUE` | 깨끗한 worktree·herdr/tmux 정리; 병합된 로컬 브랜치만 삭제 |
| `dv kick KIND ISSUE [msg]` | 완료 알림 전송, 실패 로그 보관 |
| `dv-kick KIND ISSUE [msg [host [head]]]` | 감시 호스트 로컬 큐와 로그에 이벤트 추가 |
| `dv-watch` | 로컬 큐 소비, 최대 4개 시온 작업자, 느린 상태 점검 |
| `dv manager start REPO [--agent hermes]` | 저장소별 Hermes 초기 프롬프트 실행·세션 ID 저장, 재호출 시 재사용 |
| `dv manager status [REPO] [--json]` / `dv manager stop REPO` | 등록·세션·실행 상태 조회 / 관리자 라우팅 중지 |

상태는 `$DV_STATE/ISSUE/`의 `meta`(JSON), `brief.md`, `log`, `report.md`, `done.json`, 리뷰·PR 결과입니다. done은 PR 대기 상태를 덮어쓰지 않습니다. ready는 **확인할 자료가 준비됨**을 뜻하며 CI 성공을 보장하지 않습니다. land는 빈 체크·skipped·pending·실패·head 불일치를 모두 거절합니다. 원격 브랜치를 지우지 않으며 squash 후 로컬 브랜치도 조상이 아니면 보존합니다.

PR 체크가 아직 없거나 실행 중이면 `DV_POLL_INTERVAL` 간격으로 다시 확인합니다. 체크가 종료된 뒤 `DV_REVIEW_WAIT`의 봇 리뷰 제한 시간이 시작되므로, CI가 아예 없는 PR은 체크 등록을 계속 기다립니다. `dv pr`의 대기자는 Linux에서 `setsid`로 분리하며, `setsid`가 없는 환경에서는 Bash job control로 별도 프로세스 그룹을 만듭니다. `.pr-wait`의 PID 소유자가 죽었으면 다음 대기자가 잠금을 회수합니다. 30분 상태 안전망도 `pr` 상태의 호스트에서 대기자 생존을 확인하고 필요하면 다시 시작합니다.

감시자는 작업자가 성공 종료한 이벤트만 `seen`에 기록합니다. 실패한 이벤트는 `$DV_HOME/pending/`에 보존하고 `DV_WORKER_RETRY`초(기본 15) 후 다시 실행하며, 재시작 후에도 이어집니다. 실행 중인 중복 이벤트는 한 작업자로 묶습니다. 작업자가 외부 작업을 끝내고 성공 기록 전에 죽으면 다시 실행될 수 있으므로 작업은 재실행을 견딜 수 있어야 합니다. 상태 안전망은 `done`과, `done_at`이 있고 완료 head가 현재 head와 같은 `pr/ready`의 완료 이벤트를 복구합니다. `dv status --json`의 `done_head`는 기존 `done.json`에서 읽으며, 완료 기록을 읽을 수 없으면 `null`입니다. 이전 완료 시각은 보존하므로 수정본의 `dv pr`이 작업 중 슬롯 계산을 바꾸지 않습니다.

## 프로젝트 관리자

`DV_MANAGER_HOST`(기본 lina-os)에서 `dv manager start ~/code/devflow`를 실행합니다. `DV_MANAGER_AGENT` 기본값과 지원 에이전트는 `hermes`입니다. start는 로그인된 `DV_HERMES_BIN`의 sion 프로필로 초기 역할 프롬프트를 한 번 실행하고 stderr의 `session_id:`를 저장합니다. 이후 같은 저장소의 이벤트는 `hermes -p sion chat -Q --yolo -t terminal,connections -s devflow --resume ID --query-file FILE`로 같은 대화를 이어갑니다. 매 이벤트마다 프로세스는 종료되며 대화 세션만 유지합니다.

관리자는 GitHub와 dv의 현재 상태에서 의존 이슈가 닫힌 작업을 milestone 순으로 골라 brief와 `dv submit`을 준비하고 빈 호스트 자리를 채웁니다. `templates/manager-prompt.md`가 참조하는 `templates/worker-prompt.md`를 초기 입력에 원문 그대로 포함합니다. 이벤트별 입력은 기존 worker 프롬프트입니다. 개발 호스트 worker와 기존 리뷰·병합 규칙은 그대로 사용합니다.

등록과 세션 ID는 `$DV_HOME/managers/<저장소 키>/meta.json`, 대기 이벤트는 `pending/`, 실행 결과는 `events.log`와 각 실행의 `.out`/`.err`에 남습니다. 저장소는 submission 또는 이슈 meta에서 찾으며 GitHub HTTPS/SSH URL을 같은 식별자로 정규화합니다. 원격 이슈는 설정된 `DV_HOSTS`에서만 상태와 origin을 조회하고 저장소 이름만으로 매칭하지 않습니다. 같은 저장소는 디스크 큐와 실행 잠금으로 한 번에 하나씩 처리합니다. 서로 다른 저장소와 기존 worker는 `DV_MAX_WORKERS` 한도 안에서 병렬 실행됩니다.

재개가 실패하거나 세션 ID를 받지 못하면 실패를 기록하고 초기 역할과 해당 이벤트로 새 세션을 한 번 실행해 새 ID를 저장합니다. 새 실행까지 실패하면 이벤트를 `failed/`에 보관하며 자동으로 계속 재시도하지 않습니다. 재개 실패 전에 일부 동작이 실행됐을 수 있으므로 기존 worker의 head·중복·review-fix 확인 규칙이 계속 필요합니다. Hermes가 압축 후 새 ID를 반환하면 그 ID를 이어 사용합니다.

`stop`은 기록과 세션을 삭제하지 않고 다음 이벤트부터 기존 worker 경로를 사용합니다. 실행 중이면 busy로 거절하므로 현재 turn이 끝난 뒤 다시 실행하세요. 다시 start하면 현재 checkout 경로를 갱신하고 저장된 세션을 재사용합니다. watcher가 멈추면 대기 파일은 남고 다시 시작할 때 이어 처리합니다. 비정상 종료로 남은 run.lock/pid는 소유 프로세스와 하위 worker의 종료를 확인한 뒤 사람이 정리해야 합니다. 사용자 지정 `DV_WORKER_CMD`는 관리 이벤트에서 기존 첫 인자인 프롬프트 경로 뒤에 `--pass-session-id`, 필요한 경우 `--resume ID --no-restore-cwd`를 받고 stderr에 `session_id: ID`를 출력해야 합니다. 미관리 저장소의 명령 호출 방식은 바뀌지 않습니다.

## 기기 자동 배정

시온은 lina-os에서 `dv submit ~/code/my-app APP-42 fix-save --brief /path/brief.md`를 실행합니다. `DV_MANAGER_HOST` 기본값은 lina-os이며, 다른 호스트의 submit은 기존 SSH 연결로 관리자에게 브리프 내용을 전송합니다. 개발 호스트에 관리자 방향 SSH 키가 없어도 관리자에서 제출하면 됩니다. `DV_HOSTS`에는 배정 가능한 SSH 별칭을 적고, 모든 호스트에 같은 버전의 dv를 둡니다. 원격 저장소가 있는 로컬 경로는 origin URL로 전달합니다. 각 호스트는 `$DV_REPO_ROOT`(기본 `~/code`)의 같은 이름 clone을 확인하고, 없으면 낙찰 후 clone합니다. 이름이 같은 다른 origin은 덮어쓰지 않습니다. 원격 없는 경로는 해당 경로가 있는 호스트만 입찰합니다.

`dv-watch`가 submitted 이벤트를 받으면 각 호스트에 `dv bid --json --repo REPO --agent AGENT`를 실행합니다. 입찰은 읽기 전용이며 빈 자리, load5/논리 코어 수, 사용 가능 메모리(MiB), 기존 clone, 에이전트 로그인 여부를 반환합니다. `DV_MAX_JOBS`는 호스트별 설정이고 기본값은 `max(1, floor(코어 수 / 8))`입니다. 실행 중인 기존 dv 작업도 자리를 차지하며 done 또는 종료된 작업은 제외합니다. 만석, 로그인 불가, 사용할 수 없는 저장소·터미널, `DV_MIN_MEMORY_MB`(기본 512) 미만이면 거절합니다. 로그인 확인은 Codex `login status`, Claude/Devin `auth status`를 사용하며, 다른 CLI는 `DV_AGENT_READY_codex/claude/devin`에 읽기 전용 명령을 지정할 수 있습니다. `DV_AGENT_CMD_*`로 지정한 사용자 실행기는 준비된 것으로 간주합니다.

점수는 `100 × 빈 자리/수용량 − 20 × load5/코어 + min(64, 남은 메모리/1024) + clone 보너스 20`입니다. 조회·배정은 작업 호스트 → 관리자와 lina-os → gos 순으로 진행하며, 점수가 높아도 뒤 그룹이 앞 그룹을 추월하지 않습니다. 같은 그룹에서는 높은 점수가 먼저이고, 기본 관리자(lina-os)에서 동점 순서는 **hx-linux → amd-linux → go2-linux → lina-os → gos-linux**입니다(준 10-20 결정). 조회는 각 그룹 안에서 `DV_HOSTS`에 적힌 순서를 따릅니다. hx·amd·go2·gos 별칭에도 같은 우선순위를 적용합니다. gos는 명시적으로 `DV_HOSTS`에 넣을 때만 쓰는 최후 후보입니다. 낙찰 호스트는 잠금 안에서 수용량을 다시 확인하고 `dv start`를 실행합니다. 직접 실행하는 `dv start`는 수동 경로이므로 자동 배정 중에는 `submit`을 사용하세요.

관리자 상태는 `$DV_HOME/submissions/ISSUE/task.json`이고 `dv queue`로 봅니다. A2A 상태 `submitted/working/input-required/completed/failed/canceled`를 사용하며, 개별 입찰은 `submitted/rejected`입니다. 기존 개발·PR 상태(`dv status`의 running/pr/ready 등)는 그대로 유지합니다. `bids.json`에는 점수·거절 이유, `dispatch.log`에는 시작 결과가 남습니다. 모두 거절하면 submitted로 남고, 기존 done/failed/landed 이벤트가 올 때만 재입찰합니다. 별도 입찰 폴링이나 데몬은 없습니다. `dv cancel`은 아직 배정되지 않은 제출만 취소합니다.

로컬 저장소를 제출할 때는 HTTP(S)·SSH origin만 분산 clone 주소로 바꿉니다. 로컬 경로 또는 `file://` origin이면 작업 저장소 경로를 유지하므로 그 경로에 접근할 수 있는 호스트만 입찰할 수 있습니다. 성공한 `dv clean`은 `cleaned_at`을 기록해 done·agent.exit 없이도 수용량을 반환하며, dirty worktree 등으로 정리가 실패하면 자리를 유지합니다.

응답 없는 입찰, 낙찰 재검사의 거절, 확인된 시작 실패는 같은 회차의 다음 후보로 넘어갑니다. 새 submitted/done/failed/landed 이벤트에서 시작하는 회차에는 이전 실패 호스트도 다시 입찰합니다. 재시도 가능한 시작 실패의 상태·로그·영수증은 `$DV_STATE/.awards/ISSUE/failed.*/`에 보관하고 새 브랜치를 사용합니다. 낙찰 응답을 잃었으면 같은 요청 토큰의 호스트 영수증을 조회해 중복 시작을 막습니다. 실행 여부가 불명확하거나 실패한 worktree가 dirty이면 input-required로 유지하고 이후 호스트 이벤트로 결과를 확정합니다. 이전 회차의 실패 이벤트는 새로 실행 중인 작업을 실패 처리하지 않습니다. `DV_BID_TIMEOUT`(10초), `DV_AWARD_TIMEOUT`(90초)으로 조회와 시작 확인 시간을 정합니다. `.admission-lock`은 소유 PID가 죽은 경우에만 회수합니다. 소유자 기록이 없는 잠금과 SIGKILL로 남은 `.schedule-lock`은 프로세스 종료 확인 뒤 수동 정리가 필요합니다.

재시도 영수증은 수용량·준비·만료 검사에 통과한 뒤에만 보관 위치로 옮깁니다. 만료 전 absent 응답이면 호스트와 토큰을 고정한 submitted 상태로 기다리고, 다음 submitted/done/failed/landed 이벤트에서 영수증을 다시 확인합니다. 만료 후에도 absent일 때만 재배정합니다. 낙찰 작업은 meta의 `award_token`과 이벤트의 `token` 및 ID로 시도를 구별합니다. 토큰 없는 이전 버전의 failed 이벤트는 현재 배정 상태를 바꾸지 않으므로 운영자가 결과를 확인해야 합니다. 안전망의 done 복구는 SSH 별칭 대신 원본 meta의 host와 토큰을 사용해 직접 전달·pull과 같은 ID를 만듭니다.

`dv pr`은 공개 본문 `pr.md`가 있으면 그 내용을 그대로 게시하고 자동 퇴고를 시작하지 않습니다. 이미 열린 PR도 `pr.md`가 마지막 게시 본문과 달라지면 `gh pr edit --body-file`로 갱신합니다. 갱신 실패 시 마지막 게시 본문을 보존하므로 다시 실행해 재시도할 수 있습니다. 이전 퇴고가 실행 중이면 완료 후 `dv pr`을 다시 실행해야 합니다. 늦게 시작한 퇴고도 `pr.md`가 있거나 공개 본문 게시 이력이 있으면 건너뜁니다. 퇴고 도중 `pr.md`가 생긴 경우에도 게시 직전에 다시 확인합니다.

`pr.md` 없이 PR을 처음 만들면 `dv polish`를 백그라운드로 시작합니다. CI·봇 리뷰와 나란히 돌며 병합을 기다리게 하지 않습니다. 기본 명령은 로컬 `agy --model gemini-4-argon-high -p "<프롬프트>"`이며, `agy`가 없으면 `ssh lina-os`에서 같은 명령을 실행합니다. `DV_POLISH=0`으로 끄거나 `DV_POLISH_CMD`에 퇴고 명령을 지정할 수 있습니다. 명령에는 프롬프트가 마지막 인자로 전달되고, 표준 출력은 본문으로 사용됩니다(예: `DV_POLISH_CMD='my-polisher --model editor'`).

퇴고는 군더더기·AI 말투·설명용 줄표만 정리하도록 요청합니다. 코드 블록·인라인 코드·URL의 내용과 출현 횟수를 보존했는지 검사한 뒤 `gh api --method PATCH repos/OWNER/REPO/pulls/NUMBER -F body=@파일`로 본문만 바꿉니다. 대상은 `pr.json`의 URL에서 구하며, 적용 직전에 읽은 GitHub 본문이 원문과 다르거나 읽기에 실패하면 적용하지 않고 로그에 남깁니다. 최초 원문은 `pr-body.orig.md`, 적용한 본문은 `pr-body.md`, 실행 결과는 `polish.log`에 남습니다. 빈 출력·검증 실패·명령 오류·시간 초과(기본 180초, `DV_POLISH_TIMEOUT`)에는 원문을 유지하고 종료 코드 0으로 끝납니다. 사실·숫자·일반 문장과 모든 Markdown 변형의 의미 보존까지 자동으로 증명하는 검사는 아닙니다.

감시 호스트의 `$DV_HOME/kick.q`와 `events.log`는 JSON Lines입니다. 이벤트 ID(host/issue/kind/head)로 중복을 무시하며, 작업자 로그·프롬프트는 `workers/`에 남습니다. 3초 간격은 로컬 파일 읽기이며 원격 안전망은 30분 간격 `ssh HOST dv status --json`입니다(감시 호스트 자신은 ssh 없이). 원격 개발 호스트는 감시 호스트의 dv-watch가 `DV_PULL_HOSTS`에 적힌 호스트마다 `dv-kick-pull <host>`를 띄워, 그 호스트의 `kick.q`를 ssh 한 줄기로 `tail -f` 해 받아 옵니다(끊기면 dv-watch가 다시 띄움, 별도 데몬 없음). 개발 호스트에서 감시 호스트로 가는 ssh 키가 필요 없고, 폴링 없이 쓰는 즉시 도착하며, 줄 위치와 파일 inode를 이 쪽 큐에 쓴 뒤에만 저장해, 전달 실패·재접속·큐 교체 때도 빠짐없이 이어 받습니다. 원격 쪽은 그 호스트의 devflow 설정(DV_HOME)을 읽습니다. 그 호스트의 `DV_KICK_HOST`는 자기 자신(로컬 큐)으로 둡니다. `$DV_HOME/stop`을 만들면 새 작업을 멈추고 실행 중인 작업자를 기다립니다. 재시작할 때 stop 파일을 지우세요. 비정상 종료의 잠금은 PID와 실제 프로세스를 확인한 뒤 사람이 지웁니다.

Codex goal은 tmux에서 TUI 입력 마커를 기다린 후 `/goal`을 붙여넣고 Enter를 보냅니다. herdr에서는 Codex 감지를 기다린 뒤 `agent prompt`로 제출하고, 준비되지 않았거나 차단됐으면 시작 제한 시간 안에서 재시도합니다. hook 또는 폴더 신뢰 창이 보이면 자동 승인이나 입력 없이 `codex hook trust required` 또는 `codex folder trust required` failed 이벤트를 보내고 주입을 중단합니다. 제출 성공 후에도 `DV_START_WAIT`초 안에 herdr의 `working` 또는 화면의 `Pursuing goal`을 확인합니다. 같은 `/goal`이 입력 칸에 남아 있으면 1초 뒤 Enter를 한 번만 더 보내고, 시작이 확인되지 않으면 `codex goal did not start` failed 이벤트를 보냅니다. 실패한 시작은 `dv status`에서 `start-failed`로 표시하며, 터미널은 사람이 확인할 수 있게 남깁니다. 신뢰 문제를 해결한 뒤 `dv send`로 다시 지시할 수 있습니다.

Codex 기본 실행기는 운영자 설정 `~/.config/devflow/config.sh`의 `DV_TRUSTED_REPOS`에 있는 저장소만 시작합니다. 기본값은 빈 목록이며, 각 줄에 원본 저장소의 절대 경로 하나를 적습니다. 공백이 있는 경로도 지원하고, 부모 디렉터리나 glob은 허용 범위를 넓히지 않습니다. 심볼릭 링크는 실제 경로로 비교하며 linked worktree는 원본 저장소 루트를 확인합니다. 처음 clone할 호스트에도 예상 clone 경로를 미리 등록해야 합니다. 예:

```bash
DV_TRUSTED_REPOS="$HOME/code/my-app
$HOME/code/another-app"
```

Codex 0.163의 폴더 온보딩은 CLI 신뢰 덮어쓰기만으로 생략되지 않습니다. 따라서 허용 목록을 확인한 뒤 `${CODEX_HOME:-$HOME/.codex}/config.toml`에 원본 저장소의 신뢰 항목이 없으면 추가합니다. 기존 바이트와 권한은 보존하고, 여러 dv 시작은 잠금으로 중복 추가를 막습니다. 이미 trusted면 변경하지 않으며, untrusted나 신뢰 값 없는 기존 항목, 심볼릭 링크 설정 파일, 해석할 수 없는 형식은 덮어쓰지 않고 시작을 거절합니다. Codex가 쓰는 일반 테이블·문자열, literal 문자열, dotted key를 지원합니다. inline provider/project 테이블과 여러 줄 문자열 등은 운영자가 일반 테이블 형식으로 정리해야 합니다. 저장한 신뢰는 이후 Codex 실행에도 유지되므로 철회하려면 허용 목록과 Codex의 해당 신뢰 항목을 함께 정리합니다. 명시적인 `DV_AGENT_CMD_codex` 사용자 실행기는 이 자동 설정을 사용하지 않습니다.

비로그인 SSH와 오래된 터미널 서버에서도 인증을 준비하도록, Codex 입찰·시작·실제 에이전트 실행 때 호스트의 `DV_CODEX_ENV_FILE`을 읽습니다. 기본값은 `~/.opencodex/codex-auth-env.sh`이며 다른 인증을 쓰면 운영자가 경로를 지정하거나 빈 값으로 끌 수 있습니다. 이 파일은 신뢰할 수 있는 셸 코드여야 합니다. 활성 `model_provider`의 `env_key`가 비어 있으면 `login status`가 성공해도 입찰과 시작을 거절합니다. 파일에서 내보낸 인증 값은 에이전트에 상속하며 pane 명령이나 상태 파일에 넣지 않습니다. 터미널 서버 환경에만 의존하지 않도록 인증 변수는 이 파일에서 준비하세요.

exec는 한 번 실행 후 성공할 때 래퍼가 done을 호출합니다. goal은 Codex/Claude/Devin과 사용자 지정 실행기 모두 `dv done` 없이 종료되면 종료 코드가 0이어도 기존 failed 이벤트로 알립니다. 이미 done을 기록했다면 실패 이벤트를 보내지 않습니다. `dv send`로 재시작한 goal은 이전 완료 기록과 별개로 새 `dv done`이 필요합니다. `DV_AGENT_CMD_codex/claude/devin`은 전체 명령을 덮어쓰며 추가 CLI 플래그·TUI 입력을 넣지 않습니다. 해당 명령은 `DV_ISSUE`, `DV_STATE`, 작업 디렉터리와 첫 입력인 `DV_AGENT_INSTRUCTION`을 받습니다.

## Codex App Server

`DV_CODEX_MODE=auto`가 기본값입니다. 호스트에 이미 실행 중인 Codex App Server의
`initialize`가 성공하면 App Server를 사용하고, 연결할 수 없으면 기존 TUI로 시작합니다.
`DV_CODEX_MODE=appserver`는 이 경로만 사용하며 시작 실패 후 다른 backend로 중복 실행하지
않습니다. `DV_CODEX_MODE=tui`는 기존 herdr/tmux 경로, `DV_CODEX_MODE=exec` 또는
`dv start ... --mode exec`는 일회 실행 경로입니다. 사용자 지정 `DV_AGENT_CMD_codex`는
기존 실행기를 유지합니다. Claude와 Devin의 경로는 바뀌지 않습니다.

호스트 운영자가 준비한 `codex app-server daemon`에 `codex app-server proxy`로 연결합니다.
daemon과 proxy를 지원하는 Codex 및 표준 암호 도구 `openssl`이 필요합니다.
proxy는 원시 바이트를 전달하므로 Bash 전송 계층이 WebSocket upgrade, 클라이언트 masking,
분할 frame과 ping/pong을 처리합니다. dv는 데몬을 설치·시작·재시작하거나 인증
설정을 바꾸지 않습니다. 기본 control socket을 쓰며, 다른 소켓은 `DV_APPSERVER_SOCKET`에
지정합니다. 데몬의 provider 환경과 devflow 실행 경로는 운영자가 미리 준비해야 합니다.
새 thread의 cwd는 해당 worktree이며 기존 Codex 실행과 같은 model, effort,
`approvalPolicy=never`, `sandbox=danger-full-access`를 지정합니다.
App Server 경로는 폴더 trust 설정을 추가하지 않습니다. 서버에서 실행한 `dv done` 등이 같은
설정과 이슈 상태를 사용하도록 devflow 경로와 상태 환경만 thread에 지정하며 인증 값은 보내지 않습니다.

각 이슈는 터미널 pane 대신 연결을 유지하는 Bash 작업 클라이언트 하나를 사용합니다.
클라이언트는 시작 셸과 다른 프로세스 그룹을 사용해 SSH/실행 셸 종료 후에도 연결을 유지합니다.
`thread/start`로 받은 ID와 소켓 경로를 meta에 보존하고, 지원되는 서버에는 thread goal을
설정한 뒤 브리프 전체로 첫 turn을 시작합니다. `thread/goal/set`의 method-not-found만
goal 미지원으로 처리합니다. 연결 클라이언트가 종료된 뒤 새 `dv send`는 기존 thread를
resume하며, 이전 전송 결과가 불명확한 메시지는 재전송하지 않습니다.

`dv send ISSUE TEXT`는 서버에서 현재 turn을 확인해 idle이면 `turn/start`, 작업 중이면
`expectedTurnId`를 지정한 `turn/steer`를 보냅니다. `$DV_STATE/ISSUE/appserver/outbox/`에
요청 ID, 원문, 실제 JSON-RPC와 영수증을 남기고 JSON 결과를 출력합니다.

| outcome | 의미 |
| --- | --- |
| accepted | 해당 ID에 대한 서버 응답을 받음. 작업 완료를 의미하지 않음 |
| refused | 서버가 거절했거나 전송 전 로컬 검증이 거절함 |
| unknown | 응답 유실·연결 종료·잘못된 응답·대기 시간 초과. 실행됐을 수도 있음 |

전송 전에 unknown 영수증을 원자적으로 기록하므로 클라이언트가 죽어도 자동 재전송하지
않습니다. 같은 내용의 미확정 `dv send`도 기존 ID를 반환하고 실패합니다. 요청 ID는 서버의
멱등성 보장이 아닙니다. 운영자는 영수증과 thread 이력을 확인한 뒤 다음 지시를 결정해야
합니다. 기록은 프로세스 재시작을 견디며 전원 장애 시 디스크 flush까지 보장하지 않습니다.

`dv status --json`의 `appserver`에 thread와 최신 turn의 요약, goal 응답을 담고 `agent_status`를
`working`, `idle-with-goal-active`, `goal-complete`, `idle`, `failed`, `gone`, `unknown`으로
표시합니다. 서버의 명시적인 thread-not-found만 gone이며 통신 장애는 unknown입니다.
오류 turn, error item, capacity/rate-limit 오류는 failed입니다. 화면은 읽지 않습니다.
작업 클라이언트가 종료됐어도 상태 조회는 새 연결의 thread/read로 확인하며 turn을 시작하지 않습니다.
현재는 `thread/read(includeTurns=true)`를 사용하므로 긴 thread의 조회 비용이 증가합니다.
`DV_APPSERVER_TIMEOUT`(10초)은 응답 제한, `DV_APPSERVER_POLL`(5초)은 상태 갱신 주기입니다.

기존 `dv-watch`가 `DV_HOSTS`의 App Server 작업을 확인합니다. 활성 goal에서
`DV_STALL_AFTER`(300초) 동안 새 item이나 item delta가 없으면 stalled, 오류면 failed를
알립니다. 질문 대기 중에는 자동 복구하지 않습니다. 이슈당 한 번 같은 thread에서
`continue` turn을 시작합니다. 멈춘 활성 turn은 먼저 interrupt가 수락되고 idle이 확인돼야
합니다. 다시 멈추거나 복구 결과가 불명확하면 blocked로 운영자에게 전달합니다.
`appserver/recovery`는 이 한 번의 시도를 보존합니다.

서버의 `requestUserInput`은 requestId와 질문 원문을 기존 question 이벤트로 전달합니다.
단일 질문에는 평문으로 답할 수 있고, 여러 질문이나 요청에는 다음 형식을 사용합니다.

```bash
dv send APP-42 '{"requestId":42,"answers":{"format":{"answers":["JSON"]},"scope":{"answers":["local"]}}}'
```

키 입력 대신 JSON-RPC response를 보내며 `serverRequest/resolved`를 확인해야 accepted입니다.
이 알림은 서버에서 요청이 해제됐다는 확인이며 답변이 모델에 실제 사용됐다는 보장은 아닙니다.
질문 이벤트의 전달 실패는 같은 이벤트 ID로 재시도합니다. `dv done`은 지원되는 goal을
complete로 표시하고 기존 완료 기록을 남깁니다. `dv clean`은 dirty worktree나 실행 중·불명확한
thread를 보존합니다. 실제 provider를 사용하는 종단 검증은 합성 시험과 별도입니다.

프로토콜은 [공식 Codex App Server 문서](https://developers.openai.com/codex/app-server/)와
Codex가 생성하는 JSON schema를 기준으로 구현했습니다. 다른 relay의 코드는 포함하지 않습니다.

## 시험

```bash
tests/run.sh
shellcheck -x bin/* lib/*.sh install.sh config.example.sh tests/run.sh tests/fixtures/*
```

실제 에이전트·GitHub·SSH·Hermes를 시험에서 부르지 않습니다. 임시 bare 원격과 실제 tmux를 쓰며 tmux가 없을 때만 해당 시험을 skip합니다. `DV_TEST_TMP=/scratch/...`로 임시 위치를 지정할 수 있습니다. 큐·worker 기록은 운영자가 보관 주기를 정하고, worktree는 `dv clean`으로 정리하세요.

App Server 시험은 임시 Unix 소켓과 Bash JSON-RPC 스텁을 사용합니다. 시험에 OpenBSD `nc`가
필요합니다(macOS 기본 제공, Linux 패키지 `netcat-openbsd`). 실제 Codex 데몬·모델·계정은
사용하지 않습니다. 운영 코드에는 `nc` 의존성이 없습니다.

실제 herdr 연결 시험은 `DV_HERDR=1 tests/herdr-live.sh`로 별도 실행합니다. herdr가 없으면 skip하고, 있으면 임시 저장소와 `echo SMOKE-OK; sleep 15`만 실행하여 start·status·clean을 확인합니다. 사용자 설정은 읽거나 바꾸지 않습니다. 이 스크립트의 정적 검사는 `shellcheck tests/herdr-live.sh`로 실행합니다.
