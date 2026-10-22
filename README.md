# devflow

시온이 Linear 이슈를 잡고, 코딩 에이전트 하나가 worktree 하나에서 개발하는 작은 bash 도구입니다. 개발·자기 시험 → 리뷰 한 번 → P0·P1 수정 한 번 → CI/시험 통과 후 병합. 완료는 SSH 이벤트로 알립니다.

## 개발 외 task 작업

Git이 없는 조사·문서·분석 폴더도 백그라운드 작업으로 제출할 수 있습니다.

```bash
dv submit --kind task /path/to/workspace TK-1 summary --brief /path/to/brief.md
# Claude Code: 위 명령 끝에 --agent claude
dv status TK-1 --json
dv send TK-1 '출처를 보완하고 같은 작업을 마무리하세요'
```

브리프에는 한 줄짜리 `Destination: /absolute/path`와 완료 조건을 씁니다. task는 제출한 호스트에서 실행하고 같은 호스트의 목적지로 전달합니다. 호스트 입찰·원격 파일 전송은 하지 않으며, GitHub 이슈 없이 브리프와 `TK-<n>` 식별자만으로 실행할 수 있습니다. 기존 코드 제출은 그대로입니다(`--kind code`도 가능).

새 임시 작업 폴더와 빈 `out/`를 만들고 원래 workspace는 참고용 입력으로 안내합니다. 이는 파일시스템 샌드박스가 아닙니다. Codex는 코드 작업과 같은 모드 선택을 사용합니다: 기본 auto는 연결 가능한 App Server를 사용하고 없으면 JSON exec로 실행합니다. App Server는 Git 없는 작업 폴더를 thread의 cwd로 전달하며 사용자 설정을 다시 쓰지 않습니다. exec는 `--skip-git-repo-check`와 기존 stall/재시도를 사용하고, `DV_CODEX_MODE=exec`로 명시할 수 있습니다. goal/tui, Claude와 사용자 지정 명령은 기존 herdr/tmux 경로를 사용합니다. Codex의 원래 workspace는 `DV_TRUSTED_REPOS`에 등록되어 있어야 하며, exec/TUI에서는 해당 작업 폴더에만 신뢰를 이어 줍니다. 같은 로컬 수용량, 상태·경과 시간·파일 수와 완료 이벤트를 사용합니다. 로컬 슬롯이 없으면 제출을 거절하며, task 상태는 `dv status`에서 봅니다(`dv queue`는 호스트 입찰용).

에이전트는 `out/`에 일반 파일을 만들고 `$DV_STATE/<ISSUE>/report.md`에 산출물·출처·미해결 사항을 쓴 뒤 `dv done <ISSUE>`를 실행합니다. 빈 산출물, 누락/빈 보고서, 심볼릭 링크·특수 파일은 완료를 거절합니다. done은 `out/`과 보고서를 revision별 스냅샷으로 보존하고 복사 전후 내용이 같은지 확인합니다. done의 head는 산출물 경로·내용과 보고서의 SHA-256이며 수정되면 다시 완료·확인해야 합니다. land는 확인된 스냅샷만 전달하며, 스냅샷이 없거나 훼손됐으면 거절합니다.

herdr/tmux 작업도 land 전에 저장된 래퍼 PID의 종료와 `agent.exit=0`이 확인되어야 합니다. 살아 있거나 실패한 실행, 종료 증거가 없는 실행은 거절합니다. 정상 종료 후와 전달 후에 산출물을 다시 읽어 확인한 head와 비교하고, 전달 중 변경되면 landed로 기록하지 않습니다. 작업·상태 폴더와 목적지는 물리 경로로 비교하므로 심볼릭 경로를 거쳐도 `out/`이나 스냅샷 하위로 재귀 복사하지 않습니다.

App Server task의 done은 산출물 검사 후 goal 완료 응답을 확인합니다. land는 thread를 새로 조회해 진행 중인 turn이나 미응답 질문이 없는 성공한 idle 상태를 요구한 다음 manifest를 다시 비교합니다. 실패·불명·사라진 thread는 전달하지 않습니다. clean은 idle 상태에서 클라이언트만 종료하고 task 파일을 보존합니다.

관리자는 브리프의 완료 조건과 실제 파일·보고서를 확인한 뒤 `dv land TK-1 --checked <done.json의 head>`를 실행합니다. 이 인자는 확인한 버전을 기록하는 것으로, 내용의 품질 판단은 관리자가 합니다. 결과는 `Destination/TK-1/`로 복사하며 기존 이름(링크 포함)이 있으면 `TK-1-v2/`, `-v3/` 순서로 새 폴더를 만듭니다. 복사 후 내용도 대조하고 `landed_path`를 기록합니다. 성공한 land 재호출은 같은 경로를 반환합니다. 실패/중단된 복사 폴더는 보존하며 다음 시도는 새 이름을 사용합니다. manager worker가 완료 후 Telegram에 한 줄 알리고, PR이나 CI는 실행하지 않습니다. `dv clean`은 터미널만 닫고 작업 파일과 보고서를 보존합니다.

## 설치

```bash
./install.sh --host            # hx / go2 / gos 등 개발 호스트
./install.sh --host --watch    # 감시 호스트(lina-os): 스킬 링크와 systemd user 유닛 생성
# 출력된 systemctl --user enable --now 명령은 직접 실행
./install.sh --mac --watch     # (옛 구성) Mac LaunchAgent; 출력된 launchctl 명령 직접 실행
```

감시 호스트는 Hermes의 sion 프로필로 작업자를 띄우므로 Hermes가 도는 호스트(10-19부터 lina-os)여야 합니다. 리눅스 감시는 로그아웃 뒤에도 돌도록 `loginctl enable-linger $USER`가 켜져 있어야 합니다(설치가 상태를 알려 줍니다). 모든 dv 호스트의 `DV_KICK_HOST`는 감시 호스트로 둡니다(기본 lina-os). 감시 호스트 자신은 ssh 없이 로컬 큐에 씁니다. git, gh, tmux, jq가 필요합니다. 설치는 `~/.local/bin`에 링크하고 기존 `~/.config/devflow/config.sh`를 보존합니다. 저장소는 링크 대상이므로 이동하지 마세요. `~/.local/bin`을 로컬과 SSH 비대화형 PATH에 추가하고 `gh auth login`은 사람이 준비합니다.

[config.example.sh](config.example.sh)에 모든 기본값이 있습니다. Codex 경로는 호스트에 따라 `~/node/bin/codex` 또는 `~/.opencodex/bin/codex`로 설정하세요. 기본 모델은 gpt-6-astra/xhigh이고, hooks와 crw 플러그인을 해당 실행에서만 끕니다. `DV_CODEX_DISABLE_HOOKS=0`, `DV_CODEX_DISABLE_CRW=0`으로 바꿀 수 있습니다. Claude는 opus/xhigh, Devin은 fusion-gpt-6-astra-xhigh-sidekick-swe-2-high입니다.

## 무거운 명령의 호스트 슬롯

전체 시험 모음, e2e/Playwright, `go test ./...`, race 시험, production build는
`dv heavy -- <명령과 인자>`로 실행합니다. 집중된 단일 패키지 시험은 직접 실행해도 됩니다.

```bash
dv heavy -- go test ./...
dv heavy -- npm run build
dv heavy -- bash -c 'go test -race ./... && npm run test:e2e'
```

`DV_HEAVY_SLOTS`는 호스트 공용 동시 실행 수이며 기본값은 논리 CPU 수 / 8의 내림값,
최소 1입니다. 호스트 설정 파일에 양의 정수로 지정하고 모든 작업이 같은 `DV_STATE`와
슬롯 수를 사용하게 하세요. `DV_MAX_JOBS`와 독립적이며 작업 수 제한을 바꾸지 않습니다.
설정 변경은 실행 중인 heavy 명령이 모두 끝난 뒤 적용하세요.

잠금은 `$DV_STATE/.heavy/slot-N.lock`에 보존하며 `flock`으로 관리합니다. 실행 중에는
잠금 파일을 삭제하지 마세요. worktree·sandbox별 임시 경로로 대체하지 않습니다.
Codex workspace-write에서는 공용 `DV_STATE` 절대 경로가 쓰기 허용 루트에 포함되어야 합니다
(기존 `sandbox_workspace_write.writable_roots` 또는 해당 버전의 permissions profile).
허용되지 않은 경로는 오류로 알리며 별도 잠금 경로로 우회하지 않습니다.

모든 슬롯이 사용 중이면 stderr에 `waiting for heavy slot N/M` 한 줄을 쓰고 빈 슬롯이
생길 때까지 기다립니다. 대기 시간 제한은 없습니다. 명령의 인자, 입출력, 종료 코드를
보존하며 종료·crash·kill 시 커널이 슬롯을 해제합니다. 명령의 자식이 잠금 FD를 상속해
계속 실행 중이면 마지막 자식이 종료될 때까지 슬롯을 유지합니다. 중첩된 `dv heavy`는
사용하지 말고 하나의 셸 명령으로 묶으세요.

`nice -n 10`과, 설치되어 있으면 `ionice -c 2 -n 7 -t`를 적용합니다. Linux에서는
util-linux의 flock/ionice를 사용하고, macOS에서는 `brew install flock`이 필요하며
ionice가 없으면 nice만 적용합니다. `dv status`와 `dv bid`는 `heavy=사용/전체 waiting=대기`
형태로 표시합니다. JSON은 기존 이슈 배열의 각 행(status)과 호스트 객체(bid)에
`heavy: {slots, in_use, waiting}`를 추가합니다. 이슈가 없는 호스트의 JSON 집계는
`dv bid --json`으로 조회하세요. 읽기 실패는 사용·대기 수를 null로 표시합니다.
강제 종료된 대기자의 파일이 남아도 잠겨 있지 않으면 대기 수에 포함하지 않습니다.

실제 Codex sandbox의 경로 허용과 두 workspace 간 직렬 실행은
`bash tests/heavy-sandbox.sh /절대/경로/codex /workspace/밖/검증결과/디렉터리`로
검증할 수 있습니다. 모델을 호출하지 않으며, 현재 `codex sandbox -- <명령>` CLI를
사용합니다. 허용 전 쓰기 실패와 공용 루트 허용 후 성공을 모두 검사하고 증거를 남깁니다.

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

`check`는 각 도구의 `ok` / `missing` / `wrong-version`, 실제 버전과 실행 경로, gh·codex·claude·devin 로그인 상태를 보여 줍니다. `--json`은 `tools[].login/ssh`, `auth`, `codex` 객체로 같은 결과를 냅니다. `watcher`에는 살아 있는 로컬 감시자가 시작할 때 읽은 `commit`, 그 체크아웃의 `origin_main`, `current` / `outdated` / `unknown` / `not-running` 상태가 나옵니다. Git 비교는 마지막 fetch 기준입니다. 조회는 사용자 설정을 바꾸지 않으며 drift가 있어도 종료 코드 0입니다. 모든 `dv` 호출에 적용되는 아래 자동 갱신은 실행될 수 있습니다. 조회 자체 실패나 요청한 probe 실패는 1입니다. 오래된 체크아웃을 가리킬 수 있는 gitleaks 심볼릭 링크는 버전이 같아도 `wrong-version`과 `reason=symlink`로 표시합니다.

`dv`는 실행 파일이 있는 devflow 체크아웃의 `origin/main`을 최대 5분에 한 번 fetch하고, 깨끗한 `main`만 fast-forward한 뒤 원래 인자로 다시 실행합니다. RPC 응답 제한을 지키기 위해 `_`로 시작하는 내부 명령과 `bid`, 그 자식 CLI는 갱신을 다음 일반 호출로 미룹니다. 감시자는 자기 저장소의 `landed` 이벤트와 30분 안전망에서 갱신을 확인합니다. 큐 커서와 이벤트를 저장한 뒤 같은 PID로 재실행하므로 실행 중인 작업자·관리자·QA와 큐 상태는 유지됩니다. 감시자의 내부 CLI 호출은 갱신하지 않으며, 다른 CLI가 체크아웃을 갱신해도 감시자는 다음 안전 지점에서 새 코드를 읽습니다. dirty checkout과 분기된 이력은 경고만 남기고, 작업 브랜치와 detached HEAD는 건드리지 않습니다. fetch는 10초로 제한하며 오프라인이어도 원래 명령을 실행합니다. `DV_AUTO_UPDATE=0`으로 자동 갱신을 끌 수 있습니다. 이 기능이 없는 기존 감시자는 최초 한 번 운영자가 갱신·재시작해야 합니다.

PATH 검사는 상속된 개발 세션 PATH를 제외하고 계정 셸(`SHELL`, 필요하면 `DV_HOST_SHELL`로 지정)의 로그인 `-lc`와 SSH 비대화형 `-c` 시작을 **로컬에서** 재현합니다. 후자는 `SSH_CLIENT`를 설정하여 bash의 SSH 시작 파일 처리도 포함합니다. 실제 SSH 접속이나 sshd/PAM의 환경 정책까지 검증하는 것은 아닙니다. 셸의 실행 파일 경로를 검사하며 alias/function은 대상이 아닙니다. `sync`는 `~/.profile`과 `~/.zshenv`의 `# BEGIN devflow PATH` / `# END devflow PATH` 블록만 관리하며 중복된 자체 블록을 하나로 합칩니다. 그 밖의 사용자 줄·예전 수동 PATH 블록은 유지합니다. zsh는 비대화형에서도 `.zshenv`를 읽습니다. bash의 `.bashrc` 또는 `.bash_profile`이 `.profile`을 읽지 않으면 해당 모드의 drift는 남으며, `check`가 보여 줍니다. 이 파일들을 자동 편집하지는 않습니다.

Claude 온보딩은 `check`의 텍스트 출력과 JSON의 `claude.onboarding`에 `hasCompletedOnboarding`, `skipDangerousModePermissionPrompt` 두 boolean으로 표시합니다. 파일이 없거나 읽을 수 없거나 올바른 JSON 객체가 아니면 해당 값은 false입니다. 이 검사도 설정을 변경하지 않습니다.

`sync`는 설치 경로의 버전도 직접 확인하므로 PATH만 틀린 도구를 다시 받지 않습니다. 다운로드는 배포자의 SHA-256 목록(herdr는 GitHub release asset digest)과 대조한 후 압축을 풀거나 실행합니다. 체크섬을 구하지 못하거나 일치하지 않으면 설치를 거절합니다. 실패한 다운로드와 버전 불일치는 기존 도구를 교체하지 않습니다. npm global 설치는 현재 Node prefix의 임시 복사본에서 수행하고, 버전 검증을 통과한 뒤 교체합니다. 실패한 npm 설치는 현재 Claude Code·pnpm을 보존합니다. 교체하는 기존 설치·링크는 같은 위치의 `.dv-backup.*`에 남기고 링크 대상에는 쓰지 않습니다. Node 업그레이드 시 이전 global 패키지도 백업에 남습니다. 새 Node에는 목록의 global 패키지(Claude Code·pnpm)를 설치하며, 그 밖의 패키지는 운영자가 옮깁니다. 셸 파일이 심볼릭 링크이거나 표시 블록이 깨졌으면 변경 전에 거절합니다. 성공 후 다시 실행하면 다운로드·npm 설치·PATH 파일 변경이 없습니다. 설치 잠금은 `~/.local/state/devflow-host/sync.lock`이며 강제 종료로 남으면 실행 중인 sync가 없는지 확인한 뒤 운영자가 제거합니다.

`npm bundled` 검사는 PATH의 npm이 고정된 `~/node` 배포본 내부에 있고 같은 배포본의 node가 실행되는지 확인합니다. 다른 npm이면 `reason=not-bundled`로 표시합니다. 로그인 검사는 `DV_CODEX_BIN`, `DV_CLAUDE_BIN`, `DV_DEVIN_BIN`에 지정한 실행 파일을 사용합니다. 시간 제한은 명령의 하위 프로세스도 종료하며, 별도 세션으로 이탈한 프로세스까지 추적하지는 않습니다.

`codex` 항목은 PATH상의 도구 검사와 별도로 **실제 `DV_CODEX_BIN`**의 두 모드 실행 경로를 보여 줍니다. `~/.opencodex` 디렉터리, OpenCodex 토큰 환경 변수 또는 Codex 설정의 OpenCodex 표기가 있으면 프록시 호스트로 판단하고 `~/.opencodex/bin/codex`로 연결되지 않는 실행기를 `wrong-launcher`로 표시합니다. 설정은 바꾸지 않으므로 운영자가 `DV_CODEX_BIN="$HOME/.opencodex/bin/codex"`를 지정해야 합니다. 로그인 성공만으로 공급자 준비를 보장하지 않습니다.

`--probe-codex`는 SSH 모드에서 선택된 실행기로 기존 공급자에 `OK` 응답을 요청합니다. 기본 조회에는 이 요청이 없습니다. 임시 작업 폴더·읽기 전용 sandbox·승인 거절·ephemeral 실행을 사용하고 hooks와 shell tool을 끕니다. 프록시 자동 시작도 요청하지 않습니다. 최대 60초 후 실패로 보고하며 공급자 출력·토큰은 결과에 담지 않습니다. **실제 모델 요청이므로 사용량이 발생하며 비용 0을 보장하지 않습니다.** `sync`는 로그인, 토큰, SSH 키, 네트워크 설정을 다루지 않습니다.

## 하루 흐름

```bash
dv start ~/code/my-app APP-42 fix-save --brief /path/brief.md
# 에이전트: 개발·시험·커밋 → dv pr APP-42 → dv pr-wait APP-42 --foreground
# CI 실패와 P0/P1 리뷰를 처리한 뒤 pr-wait APP-42 --foreground --review-handled → dv done APP-42
dv status APP-42
# 시온: green done의 보고서·diff·시험을 이슈 완료 조건·범위와 대조
dv land APP-42                 # 현재 PR head의 체크가 전부 성공해야 함
```

원격이 없으면 로컬 기본 브랜치(main, master, 현재 브랜치 순)를 사용합니다. 원격이 있으면 fetch 후 원격 기본 브랜치에서 시작합니다. `--base`로 지정할 수 있습니다. 로컬 저장소는 `dv review APP-42` 한 번 후 `dv land`; `DV_TEST_CMD` 또는 저장소의 `.devflow`에 `DV_TEST_CMD='bash tests/run.sh'`가 필요합니다. `.devflow`는 신뢰하는 shell 설정이며, 후보 병합을 임시 worktree에서 시험한 뒤 base를 갱신합니다. 기본 ff, `DV_LAND_MODE=merge`는 merge 커밋입니다.

GitHub의 `dv land`는 저장소의 허용 병합 방식을 한 번 조회하고 squash → merge commit → rebase 순으로 선택합니다. `DV_LAND_METHOD=squash|merge|rebase`를 환경변수 또는 작업 worktree의 `.devflow`에 지정하면 해당 방식을 사용합니다(비어 있지 않은 환경변수가 우선). 예: `DV_LAND_METHOD=merge dv land APP-42`. 잘못된 값, 저장소가 허용하지 않는 지정값, 허용 방식 없음, 조회 실패 시 병합하지 않고 worktree를 보존합니다. 현재 PR head 고정과 병합 후 MERGED 확인은 그대로 적용됩니다. 로컬 저장소는 기존 `DV_LAND_MODE`를 사용합니다.

쌓인 PR은 `pr.md` 또는 GitHub PR 본문에 `Depends on #123`처럼 선행 PR 번호를 한 줄씩 적습니다(같은 저장소, 여러 줄 가능). 관리자는 다른 PR과 똑같이 이슈 범위를 검증하고 `dv land`를 실행합니다. 선행 PR이 모두 MERGED가 아니면 land는 실패를 반환하고 `waiting-base`로 보존합니다. 닫혔지만 병합하지 않은 PR도 통과하지 않습니다. 선행 PR의 병합 결과 커밋도 fetch한 대상 브랜치에 포함되어야 하므로 다른 브랜치에만 병합된 PR은 계속 기다립니다. 순서는 dv가 관리합니다.

선행 PR의 landed 이벤트를 받으면 `dv-watch`는 자신과 `DV_HOSTS`의 모든 `waiting-base` 작업을 기존 재시도 큐에 넣습니다. `stack_head`가 없는 과거 기록도 포함합니다. 주기적 상태 안전망도 같은 호스트들을 조회하므로 대기에 들어오기 전에 병합된 기반과 놓친 이벤트를 복구합니다. 선행 PR이 모두 병합되고 병합 결과가 실제 `origin/<BASE>`에 포함되면, 해당 작업자에게 `dv send`로 base 병합·필요한 시험 재실행·일반 push·현재 head의 초록 CI·`dv done`을 요청합니다. 기존 land 승인(`stack_head`)이 있는 작업은 새 done 뒤 자동 병합을 이어가고, 승인 기록이 없으면 완료를 관리자에게 전달합니다. 미병합 기반은 다음 이벤트나 안전망까지 유예하며 `DV_MAX_WORKERS`의 동시 실행 한도를 공유합니다.

대기 시작 시각은 `stack_waiting_since`에 보존합니다. 대기가 `DV_STALL_AFTER`를 넘었고 모든 기반이 대상 브랜치에 병합됐으면 `stalled` 이벤트의 메시지로 `bases-merged`를 보냅니다. 시각이 없는 과거 기록은 처음 관측한 시각부터 셉니다. 재개 요청은 `stack_resume`과 `stack-resume.log`에 기록하여 watcher 재시작과 이벤트 재전달에도 중복 전송하지 않습니다. 전송 실패는 `blocked`로 알리고 로그를 남깁니다.

자동 land는 현재 작업 episode의 `done.json`을 확인합니다. 완료 head가 현재 head 또는 devflow가 base를 병합하기 전의 완료 head와 일치해야 합니다. 재개 전의 완료 기록, 다른 head의 기록, 완료 기록이 없는 작업으로는 자동 병합하지 않습니다. 미완료 작업의 land 시도가 실패해도 `pr`·`running`·`waiting-base` 상태를 `ready`로 승격하지 않습니다.

업데이트 충돌은 worktree에 남기고 해당 에이전트에 `dv send`를 한 번 요청합니다. 요청은 `stack-conflict.sent`, 전달 결과는 `stack-conflict.log`에 보존합니다. 에이전트가 충돌을 해결·커밋·push하면 큐가 새 head의 CI를 확인하여 이어갑니다. 전달 실패는 자동으로 중복 전송하지 않으므로 로그를 확인해야 합니다. dirty worktree, API 오류, 비어 있거나 실패한 CI는 병합하지 않으며 기존 완료·리뷰 기록과 원격 브랜치를 보존합니다.

Codex 기본 모드는 `DV_CODEX_MODE=auto`입니다. 실행 호스트에 연결 가능한 App Server가 있으면 사용하고, 없으면 exec를 선택합니다. `DV_CODEX_MODE=exec` 또는 `--mode exec`는 `codex exec --json --dangerously-bypass-approvals-and-sandbox`를 worktree에서 백그라운드 래퍼로 실행하며 herdr·tmux가 필요 없습니다. `$DV_STATE/ISSUE/agent.jsonl`에 JSONL 이벤트를 누적하고 `agent.stderr`에 진단 출력을, `agent.exit`에 마지막 실행의 실제 종료 코드를 기록합니다. `DV_CODEX_MODE=goal`/`tui` 또는 `--mode goal`로 기존 TUI를 선택합니다. 명시적인 `--mode`와 기존 `DV_MODE` 설정은 기본값보다 우선하며, Claude·Devin 기본값은 goal입니다. auto 제출은 큐에서도 auto를 보존해 실제 실행 호스트에서 backend를 선택합니다.

goal과 사용자 지정 실행기는 herdr가 PATH 또는 `~/.local/bin/herdr`에 있으면 포커스를 바꾸지 않고 `dv-<ISSUE>` workspace에서 실행합니다(Codex hooks 유지). send·status·clean/land는 기록된 backend를 따르며 herdr 로그는 done/clean 시 화면을 저장합니다. 미설치 또는 `DV_HERDR=0`이면 tmux를 사용하고, 기존 backend 없는 이슈도 tmux로 처리합니다. herdr 시작 오류는 상태를 보존하고 실패를 알립니다.

exec의 `alive`는 래퍼 프로세스의 생존 여부입니다. 새 JSON 이벤트가 있으면 `agent_status=working`, App Server와 공유하는 `DV_STALL_AFTER`초(기본 300) 동안 새 이벤트가 없으면 stalled로 판단합니다. 비정상 종료·오류 이벤트·무응답 또는 `dv done` 없는 정상 종료(failed-to-finish)는 같은 worktree에서 한 번 자동 재시도하고 다시 실패하면 blocked를 알립니다. 기록된 세션 ID로 `codex exec resume`하며, ID를 받기 전 실패했다면 원래 요청을 담아 새 exec를 실행합니다. `exec/`에는 시도별 종료 코드·실패 이유·완료 표시를 보존합니다. 종료 코드 0만으로 완료 처리하지 않습니다.

종료된 exec에 `dv send`를 보내면 같은 worktree·브랜치·세션에서 후속 exec를 실행합니다. 실행 중이면 중복 실행을 거절하므로 종료 후 다시 보내세요. 이전 done 기록은 보존하지만 새 실행도 `dv done`을 호출해야 합니다. 미커밋 변경·PR·`review-fix.sent`를 보존하고 자동 재시도는 이슈 전체에서 한 번만 허용합니다. `dv clean`은 실행 중인 exec와 dirty worktree를 보존합니다.

자동 재시도 중의 실패는 로그에 남기며, 재시도를 소진하면 `agent.exit`를 기록한 뒤 `failed`와 `blocked` 이벤트를 보냅니다. 스케줄러는 최종 `failed`로 제출 작업의 실패를 확인하고 대기 작업을 다시 입찰합니다. 에이전트의 `dv done` 이후에도 CLI가 실패할 수 있으므로, `dv land`는 병합 전에 exec 래퍼의 종료, 종료 코드 0, 감독 상태 `done`을 모두 확인합니다. 정상·실패 반환과 신호 종료 시 exec 잠금을 해제합니다.

herdr 0.9.1에서 `alive`는 pane 존재 여부를 뜻합니다. 사용자 지정 명령처럼 에이전트가 감지되지 않아도 `alive=true`, `agent_status=unknown`일 수 있습니다. `dv send`는 전달 실패 후 에이전트 종료가 확인되면 같은 worktree·브랜치·에이전트 종류·실행 모드로 한 번 자동 재시작합니다. 요청 문장을 첫 입력에 넣고 기존 brief·보고서 경로를 함께 전달합니다. 미커밋 변경과 PR, `review-fix.sent`는 보존하며 같은 수정 요청을 이어가므로 두 번째 리뷰 수정으로 세지 않습니다.

tmux는 사라진 세션이나 종료된 pane을 확인하고, herdr는 `agent_not_found`와 래퍼 종료를 함께 확인합니다. pane이 사라졌어도 살아 있는 래퍼는 재시작하지 않으며 통신 오류, 감지 지연에도 재시작하지 않습니다. 기존 herdr pane이 있으면 재사용하고 없으면 같은 작업 폴더에 새 workspace를 만듭니다. `$DV_STATE/ISSUE/revive/`에 최초 요청과 이전 실행·완료 기록을 보존하며 이슈당 자동 재시작은 한 번입니다. 새 에이전트의 시작·실행이 실패하거나 goal이 새 `dv done` 없이 끝나면 `blocked` 이벤트를 한 번 보냅니다. 강제 종료로 래퍼까지 사라져 종료 처리가 실행되지 않았다면 다음 `dv send`가 종료를 확인해 차단을 알립니다. 이전 버전의 herdr 이슈에서 래퍼 PID와 종료 기록이 모두 없으면 `pane process-info`가 셸만 있는 전경 프로세스를 확인할 때 종료로 봅니다. 다른 명령이 실행 중이거나 프로세스 정보가 없거나 조회에 실패하면 재시작하지 않습니다.

Claude 기본 실행은 먼저 `~/.claude.json`의 `projects[worktree 경로].hasTrustDialogAccepted=true`를 기록합니다. `CLAUDE_CONFIG_DIR`가 비어 있지 않으면 Claude Code와 같이 `$CLAUDE_CONFIG_DIR/.claude.json`에 기록하고 `$CLAUDE_CONFIG_DIR/settings.json`에서 설정을 읽습니다. `CLAUDE_CONFIG_DIR`를 명시적으로 `~/.claude`로 지정해도 신뢰·온보딩 파일은 그 디렉터리 **안의** `.claude.json`입니다. `dv host check`도 같은 프로필을 읽으며, 선택한 프로필에 파일이 없거나 손상되어도 기본 프로필로 돌아가지 않습니다.

없는 프로필 디렉터리와 신뢰 파일은 만들고(새 파일 권한 600), 다른 키는 보존하며, 같은 디렉터리의 임시 파일을 rename하여 교체합니다. 기존 파일은 `cp -p`로 소유권·권한·ACL을 복사한 뒤 내용을 갱신하고 원래 mode를 복원합니다. Linux의 GNU cp와 macOS의 cp는 `-p`로 ACL도 보존합니다. 복사·권한 복원·쓰기 중 오류가 나면 원본을 교체하지 않습니다. 선택한 파일 옆의 `.claude.json.dv-lock`으로 dv의 동시 기록을 직렬화하며 약 10초 동안 잠금을 얻지 못하면 시작 실패로 끝납니다. 손상된 JSON과 심볼릭 링크는 보존하고 시작을 거절합니다. SIGKILL 등으로 잠금이 남으면 실행 중인 기록 작업이 없는지 확인한 뒤 운영자가 잠금 파일을 제거해야 합니다. 이 잠금을 사용하지 않는 Claude 자체나 다른 도구의 동시 설정 변경까지 직렬화하지는 않습니다.

선택한 프로필의 `.claude.json`에서 `hasCompletedOnboarding`, `settings.json`에서 `skipDangerousModePermissionPrompt`가 모두 true여야 Claude를 띄웁니다. 환경 변수가 없거나 비어 있으면 각각 `~/.claude.json`과 `~/.claude/settings.json`을 읽습니다. 남은 온보딩이 있으면 `start-failed` 상태와 실패 이벤트를 남기며 화면에 키를 보내지 않습니다. 같은 `CLAUDE_CONFIG_DIR` 환경에서 `claude --dangerously-skip-permissions`를 한 번 대화형으로 실행해 테마·보안 안내·바이패스 경고를 끝내고 `dv host check`로 확인하세요. dv는 온보딩 플래그를 대신 설정하지 않습니다. `DV_AGENT_CMD_claude`로 전체 명령을 지정하면 이 준비 절차도 해당 명령에서 관리합니다.

`DV_AGENT_QUESTIONS=sion`이 기본값이며 herdr에서 Codex goal의 `request_user_input*`와 Claude의 `AskUserQuestion` 도구를 켜 둡니다. `DV_AGENT_QUESTIONS=off`이면 두 에이전트의 질문 도구를 끕니다. 질문 감시자가 없는 tmux와 백그라운드 exec에서는 항상 질문 도구를 끕니다. exec는 브리프의 지침에 따라 결정과 이유를 보고서에 기록합니다. `DV_AGENT_CMD_*`로 전체 명령을 지정한 경우에는 CLI 인자를 추가하지 않으므로 질문 도구 설정도 해당 명령에서 정합니다.

에이전트는 브리프 안의 작거나 되돌릴 수 있는 선택을 직접 결정하고 보고서의 "결정"에 이유를 남깁니다. 설계 방향·범위·사용자에게 보이는 동작·데이터 형식처럼 결과를 바꾸는 선택만 시온에게 물으며, 선택지 2–3개와 추천안을 제시합니다. Codex의 `request_user_input_async`는 질문을 열어 둔 채 작업을 계속할 수 있으므로, 답에 의존하지 않는 작업은 진행합니다.

herdr에서는 에이전트와 함께 실행되는 작은 감시자가 `agent wait`로 상태 전환을 기다리며, 약 1초마다 세션 기록의 미응답 질문도 확인합니다. `working` 상태의 비동기 질문도 호출마다 `question` 이벤트를 보냅니다. 전달 성공 뒤에만 전송 기록을 남기므로 실패한 호출은 다음 감시에서 재시도합니다. 겹친 호출도 각각 추적하며, 비동기 도구의 즉시 `accepted:true` 응답은 답변으로 보지 않습니다. 사용자 답변의 `questionItemId`가 그 호출의 모든 질문에 대응하면 닫습니다. 기록에 질문이 없으면 `blocked`가 `DV_BLOCKED_GRACE`초(기본 20) 지속될 때 화면으로 알립니다. 답변된 호출은 재사용하지 않습니다. `dv status --json`의 `question_pending`은 전달에 성공한 질문 중 하나라도 열려 있는 동안 true입니다. 감시자 오류는 pane 대신 이슈의 `question.log`에 기록합니다. 시온은 준의 맥락(기억·이전 결정·이슈)을 바탕으로 답하고 이유를 이슈에 기록하며, 되돌릴 수 없는 행동·외부 효과·비용·권한에 관한 질문만 준에게 올립니다.

질문 본문은 herdr의 `agent_session.value`와 일치하는 세션 기록을 먼저 읽습니다. Codex는 `~/.codex/sessions/**/rollout-*.jsonl`의 미응답 `request_user_input` 계열 function call의 `arguments`, Claude는 `~/.claude/projects/**/<세션 ID>.jsonl`의 미응답 `AskUserQuestion` tool use의 `input`을 사용합니다. 호출 ID에 대응하는 답변만 해당 호출을 닫습니다. 세션 ID를 기록 안에서도 확인하고, 질문·선택지의 JSON을 호출당 최대 2,000자로 전달합니다(긴 JSON은 중간에 잘릴 수 있습니다). 기록·질문을 찾지 못하거나 읽을 수 없으면 기존처럼 마지막 화면 8줄을 정리해 최대 1,000자로 보냅니다. 기록 경로는 `DV_CODEX_SESSIONS`·`DV_CLAUDE_SESSIONS`로 지정할 수 있으며, 기본값은 `CODEX_HOME`·`CLAUDE_CONFIG_DIR`도 따릅니다. 기록과 사용자 설정은 읽기만 합니다.

| 명령 | 기능 |
|---|---|
| `dv submit REPO ISSUE SLUG --brief FILE [--agent AGENT] [--base BRANCH] [--mode MODE]` | 관리자에게 제출, 호스트는 입찰로 결정 |
| `dv bid --json [--repo REPO] [--agent AGENT]` | 수용량·부하·메모리·디스크·clone·로그인 조회, 상태 변경 없음 |
| `dv queue [ISSUE] [--json]` / `dv cancel ISSUE` | 관리자 배정 상태 조회 / 미배정 제출 취소 |
| `dv start REPO ISSUE SLUG [--agent codex\|claude\|devin] [--brief FILE] [--base BRANCH] [--mode auto\|goal\|exec]` | worktree·브랜치·상태 및 선택한 backend 생성 |
| `dv done ISSUE [--note TEXT]` | head·변경 파일 수·보고서 경로·완료 이벤트 |
| `dv pr ISSUE` | force 없이 push, PR 생성/기존 PR 갱신, 대기 시작. 제목은 HEAD 커밋 제목. 상태 폴더의 `pr.md`(공개용 본문)를 그대로 쓰고, 없으면 짧은 보고서 요약으로 만든다 |
| `dv polish ISSUE` | PR 본문 퇴고·코드/URL 보존 검증 후 본문만 갱신 |
| `dv pr-wait ISSUE [--foreground [--review-handled]]` | foreground는 CI·리뷰·인라인 지적 JSON 반환. 처리 후 --review-handled로 기록. 기본 모드는 조기 종료 작업자 재개 안전망 |
| `dv review ISSUE` | 로컬 리뷰 출력과 횟수 저장 |
| `dv land ISSUE` | PR 허용 방식 선택 / 로컬 시험 후 병합, worktree 정리 |
| `dv status [ISSUE] [--json]` | 상태, 에이전트, 호스트, 경과, backend·생존·에이전트 상태, 마지막 로그 |
| `dv metrics [--since 6h] [--json]` | 작업별 유휴 분, 이벤트 처리 지연, 완료→병합 지연, revive/resume 횟수 |
| `dv send ISSUE 'text'` | 실행 중이면 입력 전달; 종료가 확인되면 같은 작업을 한 번 자동 재시작 |
| `dv clean ISSUE` | 깨끗한 worktree·herdr/tmux 정리; 병합된 로컬 브랜치만 삭제 |
| `dv kick KIND ISSUE [msg]` | 완료 알림 전송, 실패 로그 보관 |
| `dv-kick KIND ISSUE [msg [host [head]]]` | 감시 호스트 로컬 큐와 로그에 이벤트 추가 |
| `dv-watch` | 로컬 큐 소비, 최대 4개 시온 작업자, 느린 상태 점검 |
| `dv manager start REPO [--agent hermes]` | 저장소별 Hermes 초기 프롬프트 실행·세션 ID 저장, 재호출 시 재사용 |
| `dv manager status [REPO] [--json]` / `dv manager stop REPO` | 등록·세션·실행 상태 조회 / 관리자 라우팅 중지 |
| `dv manager note REPO FILE` | 활성 관리자의 다음 배치에 파일 내용으로 운영자 메모 추가 |

`dv metrics`는 로컬 기록과 감시자가 수집한 원격 기록을 호스트·이슈별로 합칩니다. `--since`는 `30m`, `6h`, `7d`처럼 초(s)·분(m)·시간(h)·일(d)을 받습니다. 유휴 시간은 조회 구간과 겹치는 관측 구간만 합산하고, 이벤트 지연은 그 구간에 성공 처리가 끝난 이벤트의 평균 초입니다. `--json`에는 처리 건수·최대 지연·마지막 관측 시각(`observed_at`)·현재 유휴 초도 나옵니다. 완료→병합은 조회 구간 안의 마지막 병합과 **같은 head**의 마지막 완료 사이 초이며, 완료가 조회 구간 전이어도 연결합니다. 아직 관측하거나 완료하지 못한 값은 표에서 `-`, JSON에서 `null`입니다.

기존 `dv-watch`가 `DV_HOSTS`를 `DV_METRICS_INTERVAL`초(기본 60)마다 수집합니다. 각 호스트에도 이 기능을 지원하는 dv가 필요합니다. Git의 추적 파일·무시되지 않은 새 파일의 내용/속성, HEAD, 작업 상태·이벤트가 두 관측 사이 같으면 그 구간을 유휴 시간으로 셉니다. 무시된 빌드 산출물과 터미널 화면 재출력은 진행으로 세지 않습니다. 첫 관측 이전과 관측 사이에 바뀌었다가 원상복구된 내용은 알 수 없으며, 긴 수집 간격에서는 근사값입니다. `DV_STALL_AFTER`초(기본 300)를 **초과**하면 에이전트가 working·idle·종료 중 어느 상태든 `idle` 이벤트를 보냅니다. 파일/이벤트가 바뀌기 전까지 재시작 후에도 한 번만 알립니다. 병합·취소·정리한 작업은 알리지 않습니다.

같은 작업의 현재 정체 구간을 상태 점검도 관측하면 `idle`과 `stalled` 알림을 하나로 합칩니다. 상태 점검이 먼저 관측한 구간은 `stalled`로 알리며, 이미 `idle`을 보냈다면 추가 알림 없이 기존 stall 복구를 계속합니다. 두 알림 자체는 파일·이벤트 진행으로 세지 않습니다.

revive는 자동 재시작/exec 재시도 횟수, resume은 살아 있는 에이전트에 성공적으로 전달한 후속 입력, Codex exec resume 시도, 관리자 세션 재개 시도의 합입니다. JSON은 `agent_resume_count`와 `manager_resume_count`도 구분합니다. exec의 JSON 이벤트도 유휴 관측을 갱신합니다. 이벤트는 큐 등록이 아니라 작업자·관리자 성공 종료 때 처리된 것으로 기록하며, 실패·재시도·전송·관리자 대기 시간도 지연에 포함합니다. 중복 이벤트 ID는 한 번만 집계합니다. GitHub에서 직접 병합한 PR도 수집 때 서버의 `mergedAt`으로 확인합니다.

지표는 작업 호스트의 `$DV_STATE/ISSUE/metrics/`와 감시 호스트의 `$DV_HOME/metrics/`에 별도로 보존합니다. 기존 meta·설정은 교체하지 않습니다. 조회는 읽기 전용이며, 연결 불가·시간 초과인 호스트는 마지막 관측을 유지하므로 `observed_at`의 신선도를 확인하세요. 수집은 감시자의 자식 프로세스 하나가 호스트별 `DV_BID_TIMEOUT` 한도 안에서 실행하여 큐 처리를 기다리게 하지 않습니다. 감시자 재시작 때 살아 있는 수집자를 재사용하고, 정상 종료 때 수집자와 하위 프로세스를 종료합니다. 오류는 `metrics.log`에 남깁니다. 도입 전 이벤트·재개 횟수는 소급하지 않습니다.

상태는 `$DV_STATE/ISSUE/`의 `meta`(JSON), `brief.md`, `log`, `report.md`, `done.json`, 리뷰·PR 결과입니다. GitHub의 done은 현재 head의 CI 성공과 리뷰 처리 기록을 확인하고 ready로 바꿉니다. done.json에 checks=green, review=handled를 기록하며 완료 이벤트 메시지에도 담습니다. pr-wait는 결과를 pr-ready.json에 저장하지만 관리자에게 pr-ready를 보내지 않습니다. land는 빈 체크·skipped·pending·실패·head 불일치를 모두 거절합니다. 원격 브랜치를 지우지 않으며 squash 후 로컬 브랜치도 조상이 아니면 보존합니다.

작업자는 foreground 결과를 읽고 P0·P1 리뷰를 한 번 수정하며 review-fix.sent에 기록합니다. 처리 후 다음 push 전에 `--review-handled`로 마지막 스냅샷의 리뷰를 처리했다고 확인합니다. 이 기록이 있으면 후속 CI 수정에서 새 리뷰를 기다리지 않습니다. 리뷰 시간 초과도 결과와 보고서에 남깁니다. pr-loop.json은 리뷰 처리와 실패한 head를 보존하고, 서로 다른 head의 세 번째 CI 실패에서 blocked를 한 번 보냅니다. 관리자는 이슈 완료 조건·범위를 확인해 병합하며, 범위 누락만 한 번 보완 요청합니다.

PR 체크가 아직 없거나 실행 중이면 `DV_POLL_INTERVAL` 간격으로 다시 확인합니다. 체크가 종료된 뒤 `DV_REVIEW_WAIT`의 봇 리뷰 제한 시간이 시작되므로, CI가 아예 없는 PR은 체크 등록을 계속 기다립니다. `dv pr`의 대기자는 Linux에서 `setsid`로 분리하며, `setsid`가 없는 환경에서는 Bash job control로 별도 프로세스 그룹을 만듭니다. `.pr-wait`의 PID 소유자가 죽었으면 다음 대기자가 잠금을 회수합니다. 30분 상태 안전망도 `pr` 상태의 호스트에서 대기자 생존을 확인하고 필요하면 다시 시작합니다.

감시자는 작업자가 성공 종료한 이벤트만 `seen`에 기록합니다. 실패한 이벤트는 `$DV_HOME/pending/`에 보존하고 `DV_WORKER_RETRY`초(기본 15) 후 다시 실행하며, 재시작 후에도 이어집니다. 실행 중인 중복 이벤트는 한 작업자로 묶습니다. 작업자가 외부 작업을 끝내고 성공 기록 전에 죽으면 다시 실행될 수 있으므로 작업은 재실행을 견딜 수 있어야 합니다. 상태 안전망은 `done`과, `done_at`이 있고 완료 head가 현재 head와 같은 `pr/ready`의 완료 이벤트를 복구합니다. `dv status --json`의 `done_head`는 기존 `done.json`에서 읽으며, 완료 기록을 읽을 수 없으면 `null`입니다. 이전 완료 시각은 보존하므로 수정본의 `dv pr`이 작업 중 슬롯 계산을 바꾸지 않습니다.

## 프로젝트 관리자

`DV_MANAGER_HOST`(기본 lina-os)에서 `dv manager start ~/code/devflow`를 실행합니다. `DV_MANAGER_AGENT` 기본값과 지원 에이전트는 `hermes`입니다. start는 로그인된 `DV_HERMES_BIN`의 sion 프로필로 초기 역할 프롬프트를 한 번 실행하고 stderr의 `session_id:`를 저장합니다. 이후 같은 저장소의 이벤트는 `hermes -p sion chat -Q --yolo -t terminal,connections -s devflow --resume ID --query-file FILE`로 같은 대화를 이어갑니다. 매 배치마다 프로세스는 종료되며 대화 세션만 유지합니다.

관리자는 GitHub와 dv의 현재 상태에서 의존 이슈가 닫힌 작업을 milestone 순으로 골라 brief와 `dv submit`을 준비하고 빈 호스트 자리를 채웁니다. `templates/manager-prompt.md`가 참조하는 `templates/worker-prompt.md`를 초기 입력에 원문 그대로 포함합니다. 이후 입력에도 기존 worker 규칙을 포함하고, 해당 저장소의 대기 이벤트 전부를 한 배치로 보냅니다. 이슈별 최신 이벤트를 처리하며 이전 이벤트는 `superseded`와 `superseded_by`로 표시해 문맥으로만 읽습니다. 최신 순서는 이벤트의 `time`, 같은 시간이면 큐 순서로 정합니다. 실행 도중 도착한 이벤트는 다음 배치에 포함합니다.

등록과 세션 ID는 `$DV_HOME/managers/<저장소 키>/meta.json`, 대기 이벤트는 `pending/`, 실행 결과는 `events.log`와 각 실행의 `.out`/`.err`에 남습니다. 저장소는 submission 또는 이슈 meta에서 찾으며 GitHub HTTPS/SSH URL을 같은 식별자로 정규화합니다. 원격 이슈는 설정된 `DV_HOSTS`에서만 상태와 origin을 조회하고 저장소 이름만으로 매칭하지 않습니다. 같은 저장소의 관리자 배치는 디스크 큐와 실행 잠금으로 한 번에 하나씩 처리합니다. 활성 관리자는 저장소마다 별도 실행 자리 하나를 가지며, 일반·fallback·QA worker는 `DV_MAX_WORKERS`(기본 4, 범위 1–8)를 공유합니다. 관리자가 실행 중이거나 watcher가 재시작해도 일반 worker 자리를 차지하지 않습니다.

대기 파일명은 `<cursor>-<event ID checksum>-<ID 길이>.json`입니다. 기존 숫자 슬롯과 새 슬롯 모두 실제 이벤트 ID를 비교해 재실행을 막습니다. 다른 이벤트가 차지한 슬롯은 `conflict/`에 보존하고 `queue_conflict`를 `events.log`와 `manager.log`에 기록합니다. 이미 실행 중인 배치나 fallback이 참조하는 파일은 사본을 보존하고 원래 경로에서 완료할 수 있게 둡니다. 새 이벤트는 다른 이름으로 계속 수신합니다. 운영자 메모는 큐 파일을 직접 만들지 않고 `dv manager note REPO FILE`로 넣습니다. `notices/note-*.json`에 파일 내용을 그대로 저장하며, 실행 중 도착한 메모는 다음 배치에서 fallback 처리 결과와 구분해 읽습니다.

충돌한 파일이 정상 형식의 미처리 이벤트라면 보관본을 유지하면서 원래 `pending/` 또는 `fallback/` 큐에 별도 이름으로 복구합니다. 보관 직후 watcher가 재시작해도 이어서 복구하고, 이미 처리한 기록이 있으면 다시 실행하지 않습니다. 완료 기록이나 이벤트 형식을 갖추지 않은 수동 메모는 보관만 합니다.

큐 처리가 실패해 같은 줄을 `DV_STALL_AFTER`초(기본 300) 넘게 재시도하면 `watcher-stuck` 이벤트를 기존 큐·이벤트 로그에 남기고 stderr와 `watch.log`에도 줄 번호·원인을 출력합니다. 한 멈춤 구간에 한 번 알리며, 커서가 진행하면 다음 멈춤을 다시 감지합니다. 큐가 비어 있는 유휴 상태에는 이 경보를 내지 않습니다. 경보 이벤트의 worker 전달은 막힌 줄이 풀린 뒤 이루어지므로, 멈춘 동안에는 stderr/로그로 확인할 수 있습니다.

관리자 턴이 `DV_MANAGER_MAX_WAIT`(기본 120초)를 넘으면 그 턴과 다른 이슈의 대기 이벤트를 세션 없는 기존 worker 경로로 보냅니다. fallback worker는 `DV_MAX_WORKERS`를 지키며, 같은 이슈가 실행 중이면 해당 이슈의 후속 이벤트는 기다립니다. `fallback/`에 전달을 먼저 보존하고 기존 worker 재시도·재시작 복구를 사용합니다. 성공 결과는 `notices/`에 저장해 관리자의 다음 입력에 덧붙입니다. 새 이벤트가 없어도 결과 전달을 위한 턴을 실행합니다. `events.log`의 `event_handled`에는 이벤트별 `event_id`, `event_time`, `handled_at`, `latency_seconds`(초), `route`(`manager` 또는 `fallback`), `exit_code`, `disposition`이 남습니다. 관리자 배치 실패도 종료 코드와 함께 기록하고, fallback 실패는 기존 worker 규칙으로 재시도하여 성공했을 때 기록합니다. 미래 시각의 이벤트는 지연을 0으로 기록합니다.

재개가 실패하거나 세션 ID를 받지 못하면 실패를 기록하고 초기 역할과 해당 이벤트로 새 세션을 한 번 실행해 새 ID를 저장합니다. 새 실행까지 실패하면 이벤트를 `failed/`에 보관하며 자동으로 계속 재시도하지 않습니다. 재개 실패 전에 일부 동작이 실행됐을 수 있으므로 기존 worker의 head·중복·review-fix 확인 규칙이 계속 필요합니다. Hermes가 압축 후 새 ID를 반환하면 그 ID를 이어 사용합니다.

`stop`은 기록과 세션을 삭제하지 않고 다음 이벤트부터 기존 worker 경로를 사용합니다. 실행 중이면 busy로 거절하므로 현재 turn이 끝난 뒤 다시 실행하세요. 다시 start하면 현재 checkout 경로를 갱신하고 저장된 세션을 재사용합니다. watcher가 멈추면 대기 파일은 남고 다시 시작할 때 이어 처리합니다. 비정상 종료로 남은 run.lock/pid는 소유 프로세스와 하위 worker의 종료를 확인한 뒤 사람이 정리해야 합니다. 사용자 지정 `DV_WORKER_CMD`는 관리 이벤트에서 기존 첫 인자인 프롬프트 경로 뒤에 `--pass-session-id`, 필요한 경우 `--resume ID --no-restore-cwd`를 받고 stderr에 `session_id: ID`를 출력해야 합니다. 미관리 저장소의 명령 호출 방식은 바뀌지 않습니다.

## 기기 자동 배정

### 준비된 이슈 자동 채우기

관리자 설정에 저장소를 한 번 등록하면 기존 `dv-watch`가 커밋된
`done`/`landed`/`failed`/`canceled`, `bid-changed`, 이슈 열림·닫힘·label 변경 이벤트에서 빈 호스트 자리를
채웁니다. idle tick에는 GitHub 준비 이슈를 조회하지 않습니다. 시작 시와 기존
`DV_RECONCILE_INTERVAL`(기본 1800초) 안전 점검만 누락 이벤트를 보완하며,
체크별 timer나 daemon을 추가하지 않습니다. 예:

```bash
DV_AUTOFILL_REPOS='example/app example/library'
DV_AUTOFILL_BRIEF_example_app='/path/to/app-brief.md'
```

기본값은 빈 목록(비활성)입니다. 목록은 공백으로 구분한 GitHub `owner/repo`이며,
brief override 변수는 소문자로 바꾼 `owner/repo`의 `/`, `.`, `-`를 `_`로
치환합니다. override가 없으면 해당 저장소 기본 branch의 `.devflow/brief.md`를
읽습니다. template은 shell로 실행하지 않습니다. 이슈 URL, 댓글 조회 명령,
stacked 의존 PR, `Closes`와 `dv done` 지시를 덧붙여 기존 submit 경로로 전달합니다.
template에는 저장소별 검증·승인·전달 규칙을 적으세요. 자동 ID는
`AF-<owner>-<repo>-<repo checksum>-<issue number>`입니다.

준비된 이슈는 열려 있고, 열린 sub-issue가 없고, 모든 `Depends on #N`이
닫혔거나 열린 closing PR이 있으며, `needs-owner` label과 기존 제출·열린 PR이
없는 이슈입니다. `Depends on owner/repo#N`과 GitHub issue URL도 읽습니다.
열린 PR 의존성은 작업 전에 그 PR head를 fetch/merge하도록 brief에 남기며,
같은 저장소에서는 PR 본문에 `Depends on #<PR 번호>`를 넣어 기존 stack landing
gate를 사용합니다. 기존 수동 제출은 저장소 identity와 ID의 마지막 이슈 번호로도
중복을 확인합니다. 이미 취소·실패한 제출은 자동으로 새 작업으로 덮어쓰지 않습니다.

가장 낮은 열린 milestone 번호부터 진행하고, 같은 milestone에서는 `qa` label이
먼저입니다. 그 뒤 다음 milestone, 마지막으로 milestone 없는 작업을 진행합니다.
milestone/QA 완료 gate는 의존성이 없는 다음 코드를 막지 않습니다. 이는 별도
milestone 스크립트 `fill-m1.sh`, `start-m2-worker.sh`와 고정 12개 임계값을
대체합니다. 기존 스크립트를 함께 실행하지 말고 allowlist, template, host 설정으로
운영하세요. 병합 후 QA 자체는 아래 `DV_QA` 설정을 따릅니다.

`dv queue --summary` 또는 `dv queue --summary --json`은 host별 effective slots,
running, free, ready-but-not-started와 이유를 보여 줍니다. API 실패는 준비 상태로
추측하지 않고 오류를 표시하며, 누락된 brief도 제출하지 않습니다. 마지막 제출
시도 이유는 `last_attempt_reason`으로 구별합니다. 알림과 최근 snapshot은
`$DV_HOME/autofill/`에 남습니다. 준비 작업과 빈 슬롯이 함께 10분을 초과하면
`stalled`, reason=`fleet-underused`를 저장소 manager notices에 한 번 보냅니다.
owner에게 전달하지 않으며 manager가 아직 없으면 시작될 때까지 notice를 보관합니다.
10분 초과 여부는 다음 관련 이벤트나 안전 점검에서 판단합니다.

devflow는 PR 생성, QA finding 등록, 입찰 snapshot 변경, 확인된 병합·완료·실패를
기존 이벤트 큐에 직접 발행합니다. 병합 알림은 worktree 정리보다 먼저 발행하므로
정리 재시도가 QA를 막지 않습니다. 외부 GitHub 이슈 변경을 전달하는 기존 hook은
`dv kick issue-opened ISSUE URL`, `dv kick issue-closed ISSUE URL`을 사용합니다.
재열림은 `issue-reopened`, label 변경은 `issue-labeled`/`issue-unlabeled`,
의존성 변경은 `issue-edited`, 외부 host 입찰 변경은
`bid-changed`로 전달할 수 있습니다. 동일 webhook 재전송은 `dv-kick`의 여섯 번째
인자에 원래 delivery ID를 넣어 중복을 제거합니다. 별도 GitHub webhook 서버를
설치하지 않으며 전달되지 않은 외부 변경은 느린 안전 점검에서 발견합니다.

시온은 lina-os에서 `dv submit ~/code/my-app APP-42 fix-save --brief /path/brief.md`를 실행합니다. `DV_MANAGER_HOST` 기본값은 lina-os이며, 다른 호스트의 submit은 기존 SSH 연결로 관리자에게 브리프 내용을 전송합니다. 개발 호스트에 관리자 방향 SSH 키가 없어도 관리자에서 제출하면 됩니다. `DV_HOSTS`에는 배정 가능한 SSH 별칭을 적고, 모든 호스트에 같은 버전의 dv를 둡니다. 원격 저장소가 있는 로컬 경로는 origin URL로 전달합니다. 각 호스트는 `$DV_REPO_ROOT`(기본 `~/code`)의 같은 이름 clone을 확인하고, 없으면 낙찰 후 clone합니다. 이름이 같은 다른 origin은 덮어쓰지 않습니다. 원격 없는 경로는 해당 경로가 있는 호스트만 입찰합니다.

`dv-watch`가 submitted 이벤트를 받으면 각 호스트에 `dv bid --json --repo REPO --agent AGENT`를 실행합니다. 입찰은 읽기 전용이며 빈 자리, load5/논리 코어 수, 사용 가능 메모리(MiB), 기존 clone, 에이전트 로그인 여부를 반환합니다. `DV_MAX_JOBS`는 학습한 상한에 적용하는 선택적 upper bound이며 기본값은 비어 있습니다. 실행 중인 기존 dv 작업도 자리를 차지하며 done 또는 종료된 작업은 제외합니다. 로그인 확인은 Codex `login status`, Claude/Devin `auth status`를 사용하며, 다른 CLI는 `DV_AGENT_READY_codex/claude/devin`에 읽기 전용 명령을 지정할 수 있습니다. `DV_AGENT_CMD_*`로 지정한 사용자 실행기는 준비된 것으로 간주합니다.

자동 채우기를 활성화한 관리자는 기존 watcher tick마다 각 호스트의 active jobs,
load5, available memory를 수집합니다. 호스트는 `$DV_STATE/.host-capacity/samples.jsonl`에
샘플을 기록하고 한 시간마다 모델을 갱신합니다. 별도 timer나 daemon은 없습니다.
최근 `DV_HOST_CAPACITY_WINDOW`초(기본 24시간, 최소 1시간)의 샘플을 작업 수별로
묶고, 정렬한 load의 `ceil(0.75 × 샘플 수)`번째 값(p75)이
`DV_TARGET_LOAD × cores` 이하인 가장 큰 작업 수를 `observed_cap`으로 선택합니다.
`DV_TARGET_LOAD` 기본값은 1.2입니다. `learned_cap`은 이전 상한보다 시간당 최대
2까지만 커지고, 현재 active 아래로 내려가지 않습니다. 줄어든 목표(`target_cap`)는
별도로 보존해 기존 작업이 끝나는 동안 빈자리를 다시 채우지 않습니다. idle 샘플만 있으면 이전
상한을 보존합니다. 샘플 기록은 매 tick, 비싼 집계·오래된 샘플 정리는 시간당 한 번입니다.

첫 관측 시간에는 [측정된 knee](https://github.com/thisisjun786/devflow/issues/176#issuecomment-6339544059)를
초기값으로 사용합니다: hx 24코어/14작업, amd·go2 16코어/12작업, gos 8코어/6작업.
이름과 코어 수가 일치할 때만 적용하며, lina-os는 코어의 절반을 상한으로 남겨 둡니다.
처음 보는 호스트는 1작업부터 관측하고 기존 실행 작업은 보존합니다. 새 샘플이
쌓인 뒤에는 초기값 대신 p75 모델을 사용합니다. 관측한 적 없는 더 높은 작업 수를
임의로 허용하지 않으므로, 측정 이력이 없는 구간의 상한을 스스로 추정하지 않습니다.

`capacity`/`effective_slots`는 학습값, 선택적 `DV_MAX_JOBS`, 관리자 예약 상한,
`floor(memory_available_mb / DV_MIN_MEMORY_MB)`를 함께 적용합니다. 메모리 기본값은
슬롯당 512MiB이고 0이면 제한을 끕니다. 현재 load5/cores가 목표 이상이면 새 시작을
막습니다. 어떤 경우에도 effective slots는 현재 active보다 작지 않으며
`free_slots=max(0, effective_slots−active)`입니다. 자원 측정 실패는 시작을 거절합니다.
실행 중인 작업은 종료하지 않으며 미래 CPU·메모리 사용량을 격리하는 장치는 아닙니다.

`dv bid --json`과 `dv queue --summary --json`의 `learned_cap`, `capacity_model`
(계산 시각·observed cap·p75 곡선·샘플 수), `max_jobs`, `memory_slots`,
`capacity_reason`으로 근거를 확인합니다. 일반 bid 출력은 기존 다섯 열 뒤에
learned/effective slots를 덧붙입니다. 모델이나 사용 가능한 슬롯이 바뀌면
`bid-changed` 이벤트가 refill을 깨우며, 단순한 샘플 추가는 GitHub 재조회를 일으키지 않습니다.

점수는 `100 × 빈 자리/max(1, 수용량) − 20 × load5/코어 + min(64, 남은 메모리/1024) + clone 보너스 20 − 디스크 감점`입니다. 조회·배정은 작업 호스트 → 관리자와 lina-os → gos 순으로 진행하며, 점수가 높아도 뒤 그룹이 앞 그룹을 추월하지 않습니다. 같은 그룹에서는 높은 점수가 먼저이고, 기본 관리자(lina-os)에서 동점 순서는 **hx-linux → amd-linux → go2-linux → lina-os → gos-linux**입니다(준 10-20 결정). 조회는 각 그룹 안에서 `DV_HOSTS`에 적힌 순서를 따릅니다. hx·amd·go2·gos 별칭에도 같은 우선순위를 적용합니다. gos는 명시적으로 `DV_HOSTS`에 넣을 때만 쓰는 최후 후보입니다. 낙찰 호스트는 잠금 안에서 수용량과 디스크를 다시 확인하고 `dv start`를 실행합니다. 직접 `dv start`와 task 시작도 같은 admission 잠금 아래 현재 부하·메모리 슬롯을 재검사합니다.

`disk_available_gb`는 `DV_WORK`가 있는 파일시스템의 남은 GiB이며 `cache_disk_available_gb`는 Go 캐시 파일시스템의 남은 GiB입니다. 캐시 경로는 `GOCACHE`를 우선하고 비어 있으면 `go env GOCACHE`로 구합니다. 아직 없는 경로는 가장 가까운 기존 상위 디렉터리를 조회하며 생성하지 않습니다. 두 디스크 중 하나라도 `DV_MIN_DISK_GB`(기본 15) 미만이면 `low disk`, 조회 실패는 `disk unavailable`로 거절합니다. 디스크 감점은 더 작은 남은 용량을 기준으로 `max(0, 20 × (2 × 최소 용량 − 남은 용량) / 최소 용량)`이며, 기본값에서는 양쪽 모두 30GiB 이상이면 0점, 작은 쪽이 15GiB이면 20점입니다. 최소 용량 0은 용량 거절·감점을 끄지만 조회 실패는 계속 거절합니다. Go 미설치·`GOCACHE=off` 등으로 캐시 경로를 구할 수 없으면 캐시 측정은 null이고 작업 디스크만 판단합니다. `dv host check`는 두 경로·남은 용량과 Go 캐시, `~/.cache` 전체 크기를 표시합니다. JSON에는 `work_root`, `go_cache_path`, 두 디스크 측정값, `cache_sizes_kb.go_build`와 `cache_sizes_kb.total`(KiB, 각각 Go 캐시와 `~/.cache`)이 추가되며 측정 실패는 null입니다.

기존 `dv-watch`는 로컬 및 `DV_HOSTS`의 각 호스트에서 `DV_DISK_INTERVAL`초(기본 1800) 간격으로 디스크 안전 정리가 실행되도록 요청합니다. 별도 수집 프로세스가 실행하므로 큐 처리는 기다리지 않습니다. 각 호스트의 잠금·마지막 실행 시각이 중복 실행과 watcher 재시작에 따른 반복 정리를 막습니다. 먼저 구한 Go 캐시 경로에서 접근한 지 `DV_CACHE_TRIM_DAYS`일(기본 2, 분 단위 판정)이 지난 일반 파일을 지웁니다. 이후에도 **캐시 파일시스템**의 남은 용량이 최소값 미만일 때만 해당 `GOCACHE`를 지정해 `go clean -cache`를 실행합니다. 작업 디스크만 부족할 때 다른 디스크의 캐시를 전부 비우지는 않습니다. 삭제 전에 물리 경로를 구하고 루트·홈·홈의 상위 디렉터리를 거절합니다(`..`·심볼릭 링크를 통한 별칭 포함). 캐시 디렉터리 자체가 심볼릭 링크이면 정리하지 않습니다. 검증된 물리 경로를 파일 삭제와 Go 명령에 동일하게 사용하며, Go 미설치·실행 실패·디스크 조회 실패를 로그에 남깁니다. 접근 시각을 갱신하지 않는 파일시스템에서는 최근 사용 여부를 정확히 알 수 없고, 실행 중인 빌드가 삭제된 캐시를 다시 생성할 수 있습니다.

같은 정리는 `landed`·`canceled`·`cancelled` 상태가 된 지 하루를 초과한 작업의 worktree도 제거합니다. `landed_at`, `canceled_at`/`cancelled_at`을 사용하며 기존 기록에 시각이 없으면 meta 파일 수정 시각을 사용합니다. 작업 잠금, work root 내부의 linked worktree, 저장소·브랜치 일치, 깨끗한 Git 상태, 에이전트 종료/유휴를 확인합니다. dirty·실행 중·상태 불명·잠긴 작업은 보존합니다. 상태 기록은 남기고 성공 시 `cleaned_at`을 기록합니다. 호스트별 `$DV_STATE/.disk/cleanup.log`에 정리 종류·대상·전후 KiB·회수 KiB와 종료 시 남은 디스크를 누적하며, 요청 실패는 watcher의 `$DV_HOME/disk.log`에 남깁니다. 크기 차이는 동시에 실행되는 빌드의 영향을 받을 수 있습니다.

정리 간격은 각 호스트의 마지막 **시작** 시각을 기준으로 계산합니다. watcher는 최대 60초 간격(`DV_DISK_INTERVAL`이 더 짧으면 해당 간격)으로 기한을 확인합니다. 정리가 오래 걸리거나 watcher가 기한 직전에 재시작되어도 다음 정리를 30분 더 미루지 않으며, 호스트 잠금과 실행 중인 수집 프로세스 확인으로 중복 정리를 막습니다.

개행이 포함된 캐시 경로는 지원하지 않습니다. `go env GOCACHE` 출력과 심볼릭 링크를 해석한 캐시·홈 경로도 개행을 잃지 않고 검사합니다. 경로를 안전하게 비교할 수 없으면 캐시를 정리하지 않고 보존합니다.

관리자 상태는 `$DV_HOME/submissions/ISSUE/task.json`이고 `dv queue`로 봅니다. A2A 상태 `submitted/working/input-required/completed/failed/canceled`를 사용하며, 개별 입찰은 `submitted/rejected`입니다. 기존 개발·PR 상태(`dv status`의 running/pr/ready 등)는 그대로 유지합니다. `bids.json`에는 점수·거절 이유, `dispatch.log`에는 시작 결과가 남습니다. 모두 거절하면 submitted로 남고, 기존 done/failed/landed 이벤트가 올 때만 재입찰합니다. 별도 입찰 폴링이나 데몬은 없습니다. `dv cancel`은 아직 배정되지 않은 제출만 취소합니다.

로컬 저장소를 제출할 때는 HTTP(S)·SSH origin만 분산 clone 주소로 바꿉니다. 로컬 경로 또는 `file://` origin이면 작업 저장소 경로를 유지하므로 그 경로에 접근할 수 있는 호스트만 입찰할 수 있습니다. 성공한 `dv clean`은 `cleaned_at`을 기록해 done·agent.exit 없이도 수용량을 반환하며, dirty worktree 등으로 정리가 실패하면 자리를 유지합니다.

응답 없는 입찰, 낙찰 재검사의 거절, 확인된 시작 실패는 같은 회차의 다음 후보로 넘어갑니다. 새 submitted/done/failed/landed 이벤트에서 시작하는 회차에는 이전 실패 호스트도 다시 입찰합니다. 재시도 가능한 시작 실패의 상태·로그·영수증은 `$DV_STATE/.awards/ISSUE/failed.*/`에 보관하고 새 브랜치를 사용합니다. 낙찰 응답을 잃었으면 같은 요청 토큰의 호스트 영수증을 조회해 중복 시작을 막습니다. 실행 여부가 불명확하거나 실패한 worktree가 dirty이면 input-required로 유지하고 이후 호스트 이벤트로 결과를 확정합니다. 이전 회차의 실패 이벤트는 새로 실행 중인 작업을 실패 처리하지 않습니다. `DV_BID_TIMEOUT`(10초), `DV_AWARD_TIMEOUT`(90초)으로 조회와 시작 확인 시간을 정합니다. `.admission-lock`은 소유 PID가 죽은 경우에만 회수합니다. 소유자 기록이 없는 잠금과 SIGKILL로 남은 `.schedule-lock`은 프로세스 종료 확인 뒤 수동 정리가 필요합니다.

재시도 영수증은 수용량·준비·만료 검사에 통과한 뒤에만 보관 위치로 옮깁니다. 만료 전 absent 응답이면 호스트와 토큰을 고정한 submitted 상태로 기다리고, 다음 submitted/done/failed/landed 이벤트에서 영수증을 다시 확인합니다. 만료 후에도 absent일 때만 재배정합니다. 낙찰 작업은 meta의 `award_token`과 이벤트의 `token` 및 ID로 시도를 구별합니다. 토큰 없는 이전 버전의 failed 이벤트는 현재 배정 상태를 바꾸지 않으므로 운영자가 결과를 확인해야 합니다. 안전망의 done 복구는 SSH 별칭 대신 원본 meta의 host와 토큰을 사용해 직접 전달·pull과 같은 ID를 만듭니다.

`dv pr`은 공개 본문 `pr.md`가 있으면 그 내용을 그대로 게시하고 자동 퇴고를 시작하지 않습니다. 첫 게시 전에 준비한 이전 형식의 `pr-body.md`도 `pr.md`가 없으면 그대로 사용합니다. 둘 다 없으면 보고서의 첫 문단을 최대 10줄·1,000자로 요약하여 `pr-body.generated.md`에 만들며, 브리프는 읽지 않습니다. `/`·`~`로 시작하는 경로 토큰, 홈·worktree·저장소·상태 디렉터리 경로, `$HOME`·`$WT`·`$REPO`·`$DV_STATE`·`$S` 표현(중괄호 형식 포함), 기본 `.local/state/devflow` 경로가 든 줄은 제외합니다. 설정된 `DV_HOSTS`·`DV_PULL_HOSTS`·`DV_HOST` 이름이 든 줄도 제외합니다. 상대 경로와 공개 URL은 유지하며, 보고서가 없거나 필터 후 내용이 없으면 짧은 안내문을 사용합니다. 공개 본문의 내용은 작업자가 확인해야 하며, 설정에 없는 호스트나 일반 문장 속 모든 민감한 정보를 자동으로 판별하는 필터는 아닙니다.

생성과 갱신 모두 제목은 HEAD 커밋 제목을 사용합니다. 이미 열린 PR의 제목과 변경된 `pr.md`는 `gh api -X PATCH repos/OWNER/REPO/pulls/NUMBER`로 갱신합니다. `pr.md`가 없거나 마지막 게시 본문과 같으면 본문은 건드리지 않습니다. 갱신 실패 시 마지막 게시 본문을 보존하므로 다시 실행해 재시도할 수 있습니다. 이전 퇴고가 실행 중이면 완료 후 `dv pr`을 다시 실행해야 합니다. 늦게 시작한 퇴고도 `pr.md`가 있거나 공개 본문 게시 이력이 있으면 건너뜁니다. 퇴고 도중 `pr.md`가 생긴 경우에도 게시 직전에 다시 확인합니다.

보고서 요약으로 PR을 처음 만들면 `dv polish`를 백그라운드로 시작합니다. CI·봇 리뷰와 나란히 돌며 병합을 기다리게 하지 않습니다. 기본 명령은 로컬 `agy --model gemini-4-argon-high -p "<프롬프트>"`이며, `agy`가 없으면 `ssh lina-os`에서 같은 명령을 실행합니다. 먼저 비대화형 SSH 연결을 확인하며(연결 제한 5초, 전체 제한 `DV_POLISH_TIMEOUT`), 연결할 수 없으면 퇴고를 시작하지 않고 `polish.log`에 건너뛴 이유를 기록합니다. `DV_POLISH=0`으로 끄거나 `DV_POLISH_CMD`에 퇴고 명령을 지정할 수 있습니다. 명령에는 프롬프트가 마지막 인자로 전달되고, 표준 출력은 본문으로 사용됩니다(예: `DV_POLISH_CMD='my-polisher --model editor'`).

퇴고는 군더더기·AI 말투·설명용 줄표만 정리하도록 요청합니다. 코드 블록·인라인 코드·URL의 내용과 출현 횟수를 보존했는지 검사한 뒤 `gh api -X PATCH repos/OWNER/REPO/pulls/NUMBER -F body=@파일`로 본문만 바꿉니다. 대상은 `pr.json`의 URL에서 구하며, 적용 직전에 읽은 GitHub 본문이 원문과 다르거나 읽기에 실패하면 적용하지 않고 로그에 남깁니다. 최초 원문은 `pr-body.orig.md`, 적용한 본문은 `pr-body.md`, 실행 결과는 `polish.log`에 남습니다. 빈 출력·검증 실패·명령 오류·시간 초과(기본 180초, `DV_POLISH_TIMEOUT`)에는 원문을 유지하고 종료 코드 0으로 끝납니다. 사실·숫자·일반 문장과 모든 Markdown 변형의 의미 보존까지 자동으로 증명하는 검사는 아닙니다.

감시 호스트의 `$DV_HOME/kick.q`와 `events.log`는 JSON Lines입니다. 이벤트 ID(host/issue/kind/head)로 중복을 무시하며, 작업자 로그·프롬프트는 `workers/`에 남습니다. 3초 간격은 로컬 파일 읽기이며 원격 안전망은 `ssh HOST dv status --json`입니다(감시 호스트 자신은 ssh 없이). 점검 간격은 `DV_RECONCILE_INTERVAL`, `DV_STALL_AFTER`, 60초 중 최솟값입니다. 원격 개발 호스트는 감시 호스트의 dv-watch가 `DV_PULL_HOSTS`에 적힌 호스트마다 `dv-kick-pull <host>`를 띄워, 그 호스트의 `kick.q`를 ssh 한 줄기로 `tail -f` 해 받아 옵니다(끊기면 dv-watch가 다시 띄움, 별도 데몬 없음). 개발 호스트에서 감시 호스트로 가는 ssh 키가 필요 없고, 폴링 없이 쓰는 즉시 도착하며, 줄 위치와 파일 inode를 이 쪽 큐에 쓴 뒤에만 저장해, 전달 실패·재접속·큐 교체 때도 빠짐없이 이어 받습니다. 원격 쪽은 그 호스트의 devflow 설정(DV_HOME)을 읽습니다. 그 호스트의 `DV_KICK_HOST`는 자기 자신(로컬 큐)으로 둡니다. `$DV_HOME/stop`을 만들면 새 작업을 멈추고 실행 중인 작업자를 기다립니다. 재시작할 때 stop 파일을 지우세요. 비정상 종료의 잠금은 PID와 실제 프로세스를 확인한 뒤 사람이 지웁니다.

`DV_STALL_AFTER`는 양의 정수 초이며 기본값은 App Server와 공유하는 300입니다. `DV_HOSTS`의 `running` 작업에서 `idle`, 현재 Codex 화면의 `Goal stalled`, 또는 `unknown`이면서 에이전트 종료가 확인된 상태를 이 시간 이상 관측하면 `stalled` 이벤트를 보냅니다. 화면 기록이나 로그의 옛 문구는 사용하지 않으며, 현재의 명시적 정체 배너는 herdr의 `working`보다 우선합니다. 마지막 배너가 `Pursuing goal` 또는 `Working`이면 활동 중으로 보호합니다. 현재 화면에 여러 문구가 남아 있으면 마지막 goal 상태·capacity 문구를 사용합니다. `dv status --json`은 `goal_stalled`, `goal_active`, `agent_dead`, `agent_state_seq`, `agent_session`도 제공합니다. `agent_dead`는 단순한 감지 실패와 구별되는 종료 증거입니다. 첫 정체 관측부터 시간을 재므로 알림에는 점검 주기와 호스트 조회 시간이 추가될 수 있습니다. tmux에서는 명시적인 정체 화면이나 종료된 pane·세션으로 감지하고 `Pursuing goal`·`Working`으로 활동 재개를 확인합니다.

정체 구간과 고유 이벤트 ID는 watcher의 `$DV_HOME/stalls.json`에 보관합니다. 같은 구간은 watcher 재시작 후에도 한 번만 알리고, 활동이 확인되면 새 구간으로 계산합니다. 명시적인 정체 화면이 계속되는 동안은 재개 시도에 따른 herdr 상태 번호 변경만으로 구간을 초기화하지 않습니다. 종료 증거 없는 상태 불명·통신 실패에서는 타이머를 멈추고, 긴 점검 공백 뒤에는 다시 시간을 잽니다. `done`·`landed` 등 실행 중이 아닌 작업과 완료·정리 기록이 있는 작업은 제외합니다.

기존 상태 점검에서 이슈 호스트의 잠금 아래 현재 token·상태·화면을 다시 확인하고 복구합니다. 살아 있는 Codex goal의 용량 오류가 아닌 정체 화면에는 `/goal resume`을 즉시 한 번 보내고, 같은 구간이 계속되면 5분 이상 간격으로 총 3회까지 시도합니다. 시도 기록은 `$DV_STATE/ISSUE/stall-recovery.json`에 저장해 watcher 재시작과 전달 오류에도 제한을 유지하며, 마지막 시도 5분 뒤에도 정체가 남으면 `blocked`를 한 번 보냅니다. 종료된 에이전트는 기존 revive 경로로 같은 worktree·브랜치에서 한 번 재시작하며 미커밋 작업과 보고서를 보존합니다. 작업자는 `stalled` 이벤트에서 복구 기록과 현재 화면을 확인하며 위 자동 복구 대상에 별도 재시작이나 추가 재개를 하지 않습니다. 그 밖의 idle은 기존 정책대로 원인을 조사하고, 오래된 pane의 provider 환경 누락처럼 복구 가능하면 WIP 커밋으로 보존하고 정상 종료를 확인한 뒤 같은 worktree에서 한 번 재시작합니다. 원인 불명·권한 필요는 차단으로 보고하고 provider 토큰이나 신뢰 설정을 임의로 바꾸지 않습니다.

Codex goal은 tmux에서 TUI 입력 마커를 기다린 후 `/goal`을 붙여넣고 Enter를 보냅니다. herdr에서는 Codex 감지를 기다린 뒤 `agent prompt`로 제출하고, 준비되지 않았거나 차단됐으면 시작 제한 시간 안에서 재시도합니다. hook 또는 폴더 신뢰 창이 보이면 자동 승인이나 입력 없이 `codex hook trust required` 또는 `codex folder trust required` failed 이벤트를 보내고 주입을 중단합니다. 제출 성공 후에도 `DV_START_WAIT`초 안에 herdr의 `working` 또는 화면의 `Pursuing goal`을 확인합니다. 같은 `/goal`이 입력 칸에 남아 있으면 1초 뒤 Enter를 한 번만 더 보내고, 시작이 확인되지 않으면 `codex goal did not start` failed 이벤트를 보냅니다. 실패한 시작은 `dv status`에서 `start-failed`로 표시하며, 터미널은 사람이 확인할 수 있게 남깁니다. 신뢰 문제를 해결한 뒤 `dv send`로 다시 지시할 수 있습니다.

Codex 기본 실행기는 운영자 설정 `~/.config/devflow/config.sh`의 `DV_TRUSTED_REPOS`에 있는 저장소만 시작합니다. 기본값은 빈 목록이며, 각 줄에 원본 저장소의 절대 경로 하나를 적습니다. 공백이 있는 경로도 지원하고, 부모 디렉터리나 glob은 허용 범위를 넓히지 않습니다. 심볼릭 링크는 실제 경로로 비교하며 linked worktree는 원본 저장소 루트를 확인합니다. 처음 clone할 호스트에도 예상 clone 경로를 미리 등록해야 합니다. 예:

```bash
DV_TRUSTED_REPOS="$HOME/code/my-app
$HOME/code/another-app"
```

Codex 0.163의 폴더 온보딩은 CLI 신뢰 덮어쓰기만으로 생략되지 않습니다. 따라서 허용 목록을 확인한 뒤 `${CODEX_HOME:-$HOME/.codex}/config.toml`에 원본 저장소의 신뢰 항목이 없으면 추가합니다. 기존 바이트와 권한은 보존하고, 여러 dv 시작은 잠금으로 중복 추가를 막습니다. 이미 trusted면 변경하지 않으며, untrusted나 신뢰 값 없는 기존 항목, 심볼릭 링크 설정 파일, 해석할 수 없는 형식은 덮어쓰지 않고 시작을 거절합니다. Codex가 쓰는 일반 테이블·문자열, literal 문자열, dotted key를 지원합니다. inline provider/project 테이블과 여러 줄 문자열 등은 운영자가 일반 테이블 형식으로 정리해야 합니다. 저장한 신뢰는 이후 Codex 실행에도 유지되므로 철회하려면 허용 목록과 Codex의 해당 신뢰 항목을 함께 정리합니다. 명시적인 `DV_AGENT_CMD_codex` 사용자 실행기는 이 자동 설정을 사용하지 않습니다.

비로그인 SSH와 오래된 터미널 서버에서도 인증을 준비하도록, Codex 입찰·시작·실제 에이전트 실행 때 호스트의 `DV_CODEX_ENV_FILE`을 읽습니다. 기본값은 `~/.opencodex/codex-auth-env.sh`이며 다른 인증을 쓰면 운영자가 경로를 지정하거나 빈 값으로 끌 수 있습니다. 이 파일은 신뢰할 수 있는 셸 코드여야 합니다. 활성 `model_provider`의 `env_key`가 비어 있으면 `login status`가 성공해도 입찰과 시작을 거절합니다. 파일에서 내보낸 인증 값은 에이전트에 상속하며 pane 명령이나 상태 파일에 넣지 않습니다. 터미널 서버 환경에만 의존하지 않도록 인증 변수는 이 파일에서 준비하세요.

goal은 Codex/Claude/Devin과 사용자 지정 실행기 모두 `dv done` 없이 종료되면 종료 코드가 0이어도 기존 failed 이벤트로 알립니다. 이미 done을 기록했다면 실패 이벤트를 보내지 않습니다. `dv send`로 재시작한 goal은 이전 완료 기록과 별개로 새 `dv done`이 필요합니다. `DV_AGENT_CMD_codex/claude/devin`은 전체 명령을 덮어쓰며 추가 CLI 플래그·TUI 입력을 넣지 않습니다. 해당 명령은 `DV_ISSUE`, `DV_STATE`, 작업 디렉터리와 첫 입력인 `DV_AGENT_INSTRUCTION`을 받습니다. 사용자 지정 실행기와 이전 버전의 터미널 exec 작업은 기존 실행·완료·revive 동작을 유지합니다.

## Codex App Server

`DV_CODEX_MODE=auto`가 기본값입니다. 호스트에 이미 실행 중인 Codex App Server의
`initialize`가 성공하면 App Server를 사용하고, 연결할 수 없으면 백그라운드 exec로 시작합니다.
`DV_CODEX_MODE=appserver`는 이 경로만 사용하며 시작 실패 후 다른 backend로 중복 실행하지
않습니다. `DV_CODEX_MODE=goal`/`tui`는 기존 herdr/tmux 경로, `DV_CODEX_MODE=exec` 또는
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
일반 오류 turn과 error item은 failed이며 용량 오류는 아래 대기 정책을 따릅니다. 화면은 읽지 않습니다.
작업 클라이언트가 종료됐어도 상태 조회는 새 연결의 thread/read로 확인하며 turn을 시작하지 않습니다.
현재는 `thread/read(includeTurns=true)`를 사용하므로 긴 thread의 조회 비용이 증가합니다.
`DV_APPSERVER_TIMEOUT`(10초)은 응답 제한, `DV_APPSERVER_POLL`(5초)은 상태 갱신 주기입니다.

기존 `dv-watch`가 `DV_HOSTS`의 App Server 작업을 확인합니다.
`DV_STALL_AFTER`(300초) 동안 새 item이나 item delta가 없으면 stalled를 알립니다.
`idle`, `goal-complete`, 활성 goal의 idle도 `dv done` 기록이 없으면 브리프와
push·PR·CI·리뷰 처리를 마치고 `dv done ISSUE`를 실행하라는 continuation을 한 번 보냅니다.
이후 다시 idle인데 done이 없으면 마지막 에이전트 메시지를 포함해 blocked를 알립니다.
질문 대기 중이거나 현재 커밋의 done이 기록된 작업은 자동 복구하지 않습니다.

멈춘 활성 turn은 interrupt가 수락되고 idle이 확인돼야 같은 thread에 `continue`를
보냅니다. 복구 turn에서 새 item이나 delta가 오면 해당 복구 episode를 끝내고 다음
정체를 복구할 수 있습니다. turn 시작 알림이나 이전 turn의 이벤트만으로 초기화하지
않습니다. `DV_RECOVER_MAX`(기본 3)는 재시작을 포함한 작업 전체의 복구 시도 상한입니다.
진행 없는 재정체, 예산 소진, 거부되거나 불명확한 복구는 blocked로 전달하며 자동 재전송하지
않습니다. 기존 `appserver/recovery` 표시도 보존해 미확정 작업을 반복하지 않습니다.

공급자의 `usage limit`, `usageLimitExceeded`, `rate_limit_exceeded`, HTTP 429,
`at capacity`, `overloaded` 오류는 공통 분류기로 판별해 **waiting-capacity**로 기다립니다.
Codex exec·App Server·QA 및 Claude·Devin의 터미널 경로에 적용합니다.
기본 대기는 2분 → 5분 → 15분 → 이후 매 15분이며,
`DV_CAPACITY_BACKOFF`(양의 정수 초, 기본 120)의 1배·2.5배·7.5배로 계산합니다.
`DV_CAPACITY_MAX_WAIT`는 첫 용량 오류부터의 최대 대기 시간(양의 정수 초, 기본 21600 = 6시간)입니다.
`Try again at`의 날짜는 사용하지 않으며 마지막 간격은 남은 시간으로 제한합니다.
상한에 도달하면 `provider usage limit for N h` 이유와 함께 blocked로 종료합니다.

대기 중에도 작업 슬롯과 worktree를 유지하고, 시작할 때 `waiting-capacity` kick을 한 번만 보냅니다.
`dv status`는 상태와 UTC `next_try`를, JSON은 Unix 초 `capacity_retry_at`을 표시합니다.
App Server의 기존 `appserver.capacity_retry_at`도 유지합니다. 대기 정보는 기존 meta의
`capacity`에 저장하므로 App Server 클라이언트 재연결에도 시간 상한을 보존합니다.
용량이 돌아오면 같은 thread/session 또는 같은 worktree에서 “Continue the interrupted request”로
이어갑니다. 살아 있는 Codex goal 터미널에는 `/goal resume`을 보냅니다. QA도 기존 checkout·산출물·
finding 기록을 보존하며 Codex가 thread ID를 제공했다면 `exec resume`으로 이어갑니다.
Claude QA는 세션을 저장하지 않는 기존 설정을 유지하고 같은 checkout과 원래 브리프로 이어갑니다.
터미널은 현재 화면을 사용하고, 이후 `Pursuing goal`·`Working`·`Thinking` 배너가 나오면 옛 오류를 무시합니다.

용량 대기는 exec의 단발 재시도, terminal revive, `DV_RECOVER_MAX`를 소모하지 않습니다.
일반 오류는 기존 복구 정책을 유지합니다. `dv status`와 JSON의 `recoveries`,
`last_recovery_reason`에는 일반 복구 누적 횟수와 이유(`stalled`, `idle-without-done`, `failed`)가 남습니다.
기존 복구 기록은 `appserver/recoveries.json`에 보존하며 불명확한 전달 결과는 자동 재전송하지 않습니다.

서버의 `requestUserInput`은 requestId와 질문 원문을 기존 question 이벤트로 전달합니다.
단일 질문에는 평문으로 답할 수 있고, 여러 질문이나 요청에는 다음 형식을 사용합니다.

```bash
dv send APP-42 '{"requestId":42,"answers":{"format":{"answers":["JSON"]},"scope":{"answers":["local"]}}}'
```

키 입력 대신 JSON-RPC response를 보내며 `serverRequest/resolved`를 확인해야 accepted입니다.
이 알림은 서버에서 요청이 해제됐다는 확인이며 답변이 모델에 실제 사용됐다는 보장은 아닙니다.
질문 이벤트의 전달 실패는 같은 이벤트 ID로 재시도합니다. `dv done`은 지원되는 goal을
complete로 표시하고 기존 완료 기록을 남깁니다. 완료 응답이 불명확하거나 거절되면 done 기록과
이벤트를 만들지 않습니다. 다시 done을 요청하면 먼저 서버의 goal을 읽어 이미 완료됐는지 확인합니다.
`dv clean`은 dirty worktree나 실행 중·불명확한 thread를 보존하며, `dv land`도 병합 전에 같은
서버 상태 조건을 확인합니다. 실제 provider를 사용하는 종단 검증은 합성 시험과 별도입니다.

프로토콜은 [공식 Codex App Server 문서](https://developers.openai.com/codex/app-server/)와
Codex가 생성하는 JSON schema를 기준으로 구현했습니다. 다른 relay의 코드는 포함하지 않습니다.

## 시험

```bash
tests/run.sh
shellcheck -x bin/* lib/*.sh install.sh config.example.sh tests/run.sh tests/fixtures/*
```

실제 에이전트·GitHub·SSH·Hermes를 시험에서 부르지 않습니다. 임시 bare 원격과 실제 tmux를 쓰며 tmux가 없을 때만 해당 시험을 skip합니다. `DV_TEST_TMP=/scratch/...`로 임시 위치를 지정할 수 있습니다. 디스크 시험은 `df`·Go 스텁과 임시 캐시를 사용합니다. 큐·worker 기록은 운영자가 보관 주기를 정하고, 자동 정리 대상이 아닌 worktree는 `dv clean`으로 정리하세요.

App Server 시험은 임시 Unix 소켓과 Bash JSON-RPC 스텁을 사용합니다. 시험에 OpenBSD `nc`가
필요합니다(macOS 기본 제공, Linux 패키지 `netcat-openbsd`). 실제 Codex 데몬·모델·계정은
사용하지 않습니다. 운영 코드에는 `nc` 의존성이 없습니다.

실제 herdr 연결 시험은 `DV_HERDR=1 tests/herdr-live.sh`로 별도 실행합니다. herdr가 없으면 skip하고, 있으면 임시 저장소와 `echo SMOKE-OK; sleep 15`만 실행하여 start·status·clean을 확인합니다. 사용자 설정은 읽거나 바꾸지 않습니다. 이 스크립트의 정적 검사는 `shellcheck tests/herdr-live.sh`로 실행합니다.

## 병합 후 실사용 QA

`DV_QA=1`을 호스트 설정 또는 저장소의 `.devflow`에 두면 `landed` 뒤에
새 QA 작업이 실행됩니다. 기본값은 `0`입니다. QA는 최신 merged base를 별도
임시 clone으로 가져와 그 revision의 `.devflow`를 읽습니다. 소유자의 checkout과
설정은 바꾸지 않습니다. QA 설정은 `DV_QA=1`, `DV_QA_AGENT=claude` 같은
literal 대입만 읽으며 `.devflow`의 shell 코드를 실행하지 않습니다.
`DV_QA_AGENT=codex`는 새 Codex exec 세션,
`claude`는 새 Claude Code 세션입니다. `DV_QA_AGENT_CMD`는 prompt 파일을
받는 명령으로 시험 또는 별도 실행기에 쓸 수 있습니다.

QA 저장소의 승인 기준은 watcher가 보관한 작업 기록입니다. 로컬 landed meta
또는 원래 제출의 repo·host·head·발급 token과 맞는 이벤트만 받으며, 원격 호스트의
status/origin 응답으로 저장소를 선택하지 않습니다. 기록 없는 원격 수동 작업은
QA를 시작하지 않으므로 해당 watcher를 통해 `dv submit`으로 배정하세요.

watcher가 저장소마다 한 작업만 실행하고, 실행 중 들어온 병합은 다음 최신
head 작업 하나로 합칩니다. 작업 이름은 `QA-<repo identifier>-<short sha>`이고
repo identifier에는 owner, 안전한 repo 이름과 구분용 checksum이 들어갑니다.
같은 head는 다시 실행하지 않습니다. 개발 task backend와 독립적인 로컬 작업이며
watcher의 worker 슬롯을 씁니다. `dv qa status --json`은 저장소별 pending/running을,
`dv status`는 시작한 QA 작업과 결과를 보여 줍니다.

QA는 `docs/qa.md`, 없으면 AGENTS.md의 QA 절, README·milestone·설계 문서에서
여정을 읽습니다. 제품 실행은 임시 HOME·상태 디렉터리와 합성 자료·provider stub만
사용합니다. 실제 계정·사용자 데이터·배포는 사용하지 않고 코드를 고치지 않습니다.
발견은 현재 milestone에 `qa`와 `bug` 또는 `feature`로 기록합니다. merged PR의
milestone을 우선하고, 없으면 그 PR이 닫는 이슈들의 공통 milestone을 씁니다.
둘 다 milestone이 없으면 `Milestone: none`으로 QA를 진행하고 새 발견 이슈에는
milestone 없이 라벨만 붙입니다. 기존 이슈의 milestone은 그대로 둡니다.
서로 다른 milestone이 여럿이면 blocked로 남습니다. 병합 직후 PR 연결이 비어
있으면 최대 6회(5초 간격) 재시도합니다. 실패 단계는 meta의 `failure_reason`과
runner log에 기록하며, job 생성 전 실패는 runner 디렉터리의 meta에 남깁니다.

```sh
dv qa search QA-owner-repo-sha 'conversation input'
dv qa finding QA-owner-repo-sha finding.json
dv done QA-owner-repo-sha
```

finding JSON에는 `title`, `kind` (`bug`/`feature`), `steps`, `expected`, `actual`,
`evidence` 문자열을 넣습니다. 검색한 기존 이슈가 같은 문제면 숫자 `match`를
추가합니다. 등록 명령은 열린 이슈를 다시 확인하고, 같은 제목 또는 지정한 match에는
댓글을 달며 새 이슈를 중복 생성하지 않습니다. `report.md`를 쓴 뒤 `dv done`을
실행하면 merged PR에 여정·발견 링크·시험 head를 요약한 댓글 하나를 남깁니다.
manager는 현재 milestone의 열린 `qa` 이슈를 먼저 제출하고, 이들이 닫히고
pending/running QA가 끝나기 전까지 milestone 완료를 보류합니다. 의존성이 없는
다음 milestone 코드의 시작은 막지 않습니다.

예약·로그는 `$DV_HOME/qa/`, 작업 meta·발견 영수증·보고서는 `$DV_STATE/QA-*/`에
남습니다. watcher 재시작은 살아 있는 QA를 중복 실행하지 않습니다. 실패한 QA는
자동 재실행하지 않으며 로그와 임시 clone을 보존합니다. 관리자는 blocked 원인을
확인해야 합니다. 다음 병합은 새 head를 대상으로 실행할 수 있습니다. QA prompt는
데이터 격리를 지시하지만 OS sandbox는 아닙니다. 실제 agent/provider QA 품질은
stub 시험이 보증하지 않습니다.
