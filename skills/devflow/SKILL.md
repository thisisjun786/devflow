---
name: devflow
description: Use when running dev work through dv (devflow).
---

# 시온의 devflow

GitHub 이슈(저장소별 Issues·마일스톤)를 정리한 뒤 개발 호스트의 로컬 저장소에서 이슈당 에이전트 하나·worktree 하나·브랜치 하나로 개발합니다. 개발 중 설계·비평·relay·리뷰 루프는 없습니다.

herdr가 설치되어 있으면 `dv start`는 포커스를 유지하며 `dv-<ISSUE>` workspace에서 에이전트를 직접 실행하고(Codex hooks 유지), send·status·clean/land는 meta의 backend를 따릅니다(로그는 done/clean 화면 저장, `DV_HERDR=0`·미설치·backend 없는 기존 이슈는 tmux, herdr 시작 실패 시 상태 보존).

1. 구체적인 요구와 완료 기준을 brief 파일로 쓰고 `dv start <repo> <ISSUE> <slug> --brief FILE`로 시작합니다. 브랜치는 `<type>/<번호>-<slug>`이며 slug 앞의 종류 단어로 type을 정합니다(`fix-save` → `fix/42-save`, 없으면 `feat`). Codex 기본은 goal입니다. 필요하면 `--agent claude|devin|omp|agy|grok|cursor` 또는 Codex `--mode exec`, `--base BRANCH`를 선택합니다. `dv submit`은 `--agent` 없이 brief의 `Route: writing`이면 agy, `Route: small`이면 omp로 보냅니다(`DV_ROUTE_WRITING`·`DV_ROUTE_SMALL`, 비우면 끔).
2. 에이전트는 실패 시험을 먼저 남기고 개발·관련 시험·커밋·보고서를 마칩니다. GitHub면 `dv pr` 후 `dv pr-wait <ISSUE> --foreground`(`--review-handled`)로 CI와 리뷰를 처리하고, 현재 head의 초록 CI와 깨끗한 Codex 리뷰(`checks=green review=handled`)를 확인한 뒤에만 `dv done`을 호출합니다. PR 제목은 마지막 커밋 제목 `type(scope): subject`(영어, 이슈 키 없음)이고 본문은 `pr.md`에 `.github/PULL_REQUEST_TEMPLATE.md`의 Summary·`Closes #n`·Verification·Checklist로 씁니다. dv pr이 둘 다 push 전에 확인합니다. 원격 없는 로컬 저장소는 바로 `dv done`을 호출합니다.
3. 감시 호스트의 `dv-kick`은 이벤트를 파일에 쓰기만 합니다. `dv-watch`가 3초마다 로컬 큐를 읽고 시온 작업자를 최대 4개 실행합니다. 30분마다 상태 조회로 유실된 done 이벤트만 보완합니다(자기 호스트는 ssh 없이). 모델 폴링을 하지 않습니다. 10-19부터 감시 호스트는 lina-os(systemd user `dev.devflow.watch.service`, `DV_KICK_HOST=lina-os`)입니다.
4. GitHub 작업자는 `dv pr-wait <ISSUE> --foreground`의 CI와 현재 head의 최신 Codex 리뷰를 읽습니다. P0·P1을 수정·시험·커밋·`dv pr`로 push하고 새 리뷰를 기다리는 루프를 반복하며 `--review-handled`로 현재 head의 깨끗한 리뷰를 확인합니다. 첫 리뷰는 PR-open 자동 트리거, 이후는 devflow의 `@codex review` 댓글입니다. `DV_REVIEW_BOTS=codex`, `DV_REVIEW_ROUNDS=4`가 기본입니다.
5. 같은 head 재조회는 회차를 늘리지 않습니다. 상한에 P0·P1이 남으면 `review-rounds`와 열린 지적으로 차단하며 관리자가 처리합니다. 리뷰가 `DV_REVIEW_WAIT` 동안 없으면 한 번 더 요청하고 다시 기다린 뒤 `review-timeout`으로 차단합니다. P2·P3은 최종 리뷰에서 PR당 후속 이슈 하나로 같은 저장소·같은 milestone에 남깁니다(파일:줄·한 줄 내용, `Depends on #<원 이슈>`). 후속 번호는 report.md와 PR 본문에 기록하며 병합을 막지 않습니다.
6. 관리자는 `done`(`checks=green review=handled`)에서 보고서·diff·시험을 이슈 완료 조건·범위와 대조합니다. 현재 PR head의 CI 전체가 초록이고 최신 Codex 리뷰에 P0·P1이 없으면 `dv land`로 저장소가 허용하는 병합 방식(squash 우선)을 사용합니다. 로컬은 `dv review` 한 번 후 `.devflow` 또는 설정의 `DV_TEST_CMD`를 후보 병합 결과에서 통과한 뒤 base를 갱신합니다. fast-forward 기본이며 `DV_LAND_MODE=merge`는 merge 커밋입니다. 원격 브랜치는 남습니다.
7. 이슈에 결과를 한 줄 남깁니다. 준에게 보내는 알림(준 10-22 "보내는 메시지 정돈해라"): 합친 결과는 바로 보내지 않고 `~/.local/state/devflow-mac/digest.tsv`에 `시각\t저장소\t쉬운 말 한 줄`로 덧붙인다. `~/dv/bin/sion-digest`가 09·12·15·18·21·00시에 저장소별로 묶어 한 통 보낸다(user timer `sion-digest`). 바로 보내는 건 준만 할 수 있는 일(돈·계정·공개·되돌릴 수 없는 일)과 시온이 풀 수 없는 막힘뿐, 두 줄(무엇이 막혔나 / 준이 할 일). 재시도·충돌·리뷰 수정처럼 시온이 처리할 막힘은 알리지 않고 처리한다. 번호·경로·PR·시험 개수·CI 같은 말을 쓰지 않는다.

| 명령 | 용도 |
|---|---|
| `dv status [ISSUE] [--json]` | 상태·에이전트·호스트·경과·backend·생존·에이전트 상태·마지막 로그 |
| `dv send ISSUE 'text'` | herdr agent prompt(차단 시 대기 후 한 번 재시도) / tmux 붙여넣기 후 Enter |
| `dv done ISSUE [--note TEXT] [--already-merged PR\|COMMIT]` | head·파일 수·보고서 경로(GitHub는 `checks=green review=handled`)를 기록하고 이벤트; 다른 PR로 base에 들어간 작업은 ancestry 확인 후 ready |
| `dv park ISSUE --on N[,N...] [--note TEXT]` | 열린 선행 이슈를 기다리는 작업 보류(브랜치 push·이슈 댓글·슬롯 반환), `dv send`로 재개 |
| `dv pr ISSUE` / `dv pr-wait ISSUE [--foreground [--review-handled]]` | 브랜치 push·PR / foreground CI·리뷰 확인(기본은 조기 종료 작업자 재개 안전망) |
| `dv review ISSUE` | 로컬 Codex 리뷰, 횟수와 출력 보관 |
| `dv land ISSUE` | 체크/시험을 통과한 변경 병합·worktree 정리 |
| `dv clean ISSUE` | 깨끗한 worktree와 herdr/tmux 정리, 머지된 로컬 브랜치만 삭제; QA는 멈춘 깨끗한 임시 clone 정리 |
| `dv kick kind ISSUE [msg]` | 이벤트 재전송; 전송 실패는 events.log에 기록 |

확인은 이벤트 host·issue·head와 현재 meta를 대조한 뒤 합니다. 보고서 주소만으로 시험 통과를 추정하지 않습니다. CI가 없거나 건너뜀·대기·실패면 land하지 않습니다. GitHub done과 land는 현재 head의 최신 Codex 리뷰를 다시 검증합니다. pr-loop.json의 회차 기록을 보존하며 --review-handled로 과거 리뷰나 시간 초과를 승인할 수 없습니다. 원격 없는 로컬 저장소는 dv review 한 번 후 P0·P1 수정·시험을 확인해 병합합니다. base 직접 push, force push, 원격 브랜치 삭제를 하지 않습니다.

## devflow의 범위 (준 10-21)
- devflow는 리나 개발의 일부이고, 실제로 쓰면서 계속 고친다(devflow#93).
- 목적은 하나다. 자동화 관점에서 작업이 끊기지 않게 한다.
- 작업 자체는 하네스로 만들지 않는다. 구현 방법, 쪼개기·묶기, 지시 해석, 순서·마일스톤 판단은 Codex·Claude Code·관리 세션의 판단을 믿고 맡긴다.
- devflow 코드에는 배관만 넣는다. 시작, 확실한 메시지 전달, 상태를 사실대로 읽기, 멈춤·죽음 감지와 복구, 초록일 때 병합, 보고가 여기에 해당한다.
- 작업 자체를 통제하는 규칙·템플릿·계획기·게이트는 넣지 않는다(#95~97은 이 이유로 닫았다).
- 현재 head의 CI·Codex 리뷰 조건(#167)은 전달 배관의 병합 조건으로 관리한다.
- 실사용에서 본 문제가 배관이 아니면 에이전트 지시문이나 리나 설계로 보낸다.

## omh 스킬 활용 (준 10-23)
oh-my-hermes에서 들여온 개발 스킬(카테고리 omh-dev, 원본 `~/.hermes/shared-skills/omh-dev/`)을 시온과 작업자 둘 다 쓴다. 작업 기기에는 `~/omh-skills/`로 복사해 두었다(skill 갱신 뒤 `rsync -a --delete ~/.hermes/shared-skills/omh-dev/ <host>:omh-skills/`). 브리프에는 맞는 것 하나의 경로만 적는다.
| 상황 | 스킬 |
|---|---|
| 원인 모르는 버그 | app-debugging (재현 → 경쟁 가설 3개 → 증명된 원인만 수정) |
| 느림·CI 무거움·비용 | perf (기준선 → 가장 큰 비용 하나씩 → 같은 명령으로 재측정) |
| 합친 뒤 QA·실사용 확인 | qa (적대적 시나리오, 관찰한 통과/실패만) |
| 에이전트·모델 비교, 평가 세트 | agent-evaluation (같은 입력 쌍 비교, 결과와 과정 따로 채점) |
| LLM 호출 기능 | llm-app-dev (모델 id·스키마 고정, 평가 세트 동봉) |
| 작업자의 '끝났다' 확인 | verification-gate (실제로 돈 명령만 근거, PASS/HOLD/BLOCK) |
| 멈추거나 헤매는 작업자 | agent-debug (기록 읽기 전용, 가장 작은 되돌릴 수 있는 복구) |
| CI 실패 묶음 | build-failure-triage (원인·출처별로 묶고 최소 수정) |
| 실패가 초록으로 덮이는지 | failure-signal-audit |
| 이슈 요구가 빈약함 | issue-requirements |

## 실사용에서 확인된 것 (10-18, 10-19)
- **PR·이슈 글은 영어가 기본이다(준 10-23).** 제목·본문·PR 템플릿·브리프가 요구하는 `pr.md`, 시온과 작업자가 올리는 이슈·댓글 모두 영어로 쓴다. 준에게 하는 보고와 제품 UI 문구는 한국어 그대로다. 기존 한국어 이슈는 영어로 옮겨 두었다.
- 10-19 Hermes가 lina-os로 옮겨오며 감시자도 lina-os로 옮겼다. lina-os는 자기 자신에게 ssh 키가 없으므로 같은 호스트 이벤트는 ssh 없이 처리한다(#6, #7). 기기의 `dv-kick-relay`는 lina-os의 `dv-kick`으로 바로 보낸다. 아래 Mac 관련 항목은 옛 구성이다.
- 이슈 이름(10-21, 10-22 정정): 준에게 말하거나 보고할 때는 `lina #12`처럼 저장소 이름 + GitHub 번호만 쓴다. 약칭(`LN-12` 등)은 dv 작업 폴더·workspace 이름이 저장소를 가리지 않고 한 곳에 모이기 때문에 dv 내부 키로만 쓴다. devflow `DF-`, murmur `MM-`, lyric-studio `LS-`. 새 저장소는 대문자 두 글자를 정해 여기에 적는다. 저장소마다 번호가 겹치므로 `GH-<번호>`는 쓰지 않는다. **lina 저장소의 `LINA-<n>`은 Linear LINA 팀 이슈 키와 겹친다**: PR 제목·브랜치의 `LINA-<n>` 때문에 Linear GitHub 연동이 머지 순간 엉뚱한 Linear 이슈(대부분 10-01 Canceled)를 Done으로 바꾼다(10-20 16건 발생, 10-21 전부 Canceled로 되돌림). 새 lina 이슈는 `LN-<n>`으로 띄운다. 이미 `LINA-<n>`으로 돈 이슈는 land 뒤 Linear 같은 번호의 상태 이력을 보고 머지 직전 상태로 되돌린다. 봇이 `tool-issue`로 올린 도구 고장 이슈(`[도구 이슈 · <봇>] <url>`)도 같은 이름으로 띄우고, 처리 절차는 공용 스킬 `tool-issue-handoff`의 '시온이 받았을 때'를 따른다.
- **gos-linux는 10-23부터 작업용에서 뺀다(준: 성능이 너무 나쁘다).** lina-os config `DV_HOSTS`에서 지웠고(새 배정 없음), `DV_PULL_HOSTS`에는 남은 작업의 이벤트를 받으려고 당분간 둔다. 남은 작업은 브랜치에 push한 뒤 다른 기기로 옮긴다. 다시 넣으라고 할 때까지 gos에 작업을 띄우지 않는다.
- 개발 호스트 동점 순서(준 10-20 결정, 10-23 gos 제외): **hx-linux → amd-linux → go2-linux → lina-os**. 조회·배정은 작업 호스트 → 관리자와 lina-os → gos 그룹 순이며, 그룹 안의 배정은 점수가 높은 호스트부터다. gos는 점수가 높아도 lina-os보다 뒤이고 `DV_HOSTS`에 명시할 때만 쓴다. amd-linux는 OS hostname이 `oldamdlinux`라 기기 config에서 `DV_HOST=DV_KICK_HOST=amd-linux`로 고정한다. lina-os는 Hermes·상주 서비스 몫이라 작업용 기기가 찼을 때만 쓴다. gos의 OpenClaw 사용자(neolina·eunbot)는 외부용이라 건드리지 않는다.
- 원격 호스트 이벤트: 기기는 lina-os로 ssh 키가 없다. 대신 lina-os dv-watch가 `DV_PULL_HOSTS="hx-linux amd-linux go2-linux gos-linux"`로 기기마다 `dv-kick-pull`을 띄워 기기의 `kick.q`를 ssh `tail -f`로 받아 온다(#11). 기기 config는 `DV_KICK_HOST=<자기 hostname>`, `DV_KICK=`(로컬 큐). 옛 `dv-kick-relay`는 쓰지 않는다.
- 기기에서 시작: `ssh hx-linux 'bash -lc "dv start ~/code/<repo> ISSUE slug --brief ~/dv/briefs/brief-x.md"'`. 저장소·브리프는 그 기기에 있어야 한다. 개발 저장소는 전부 GitHub 비공개 원격(devflow, murmur 등)을 두고 기기마다 clone한다. 원격 없는 로컬 저장소는 기기에서 시작하지 말고 먼저 비공개 원격을 만든다(gitleaks로 히스토리 검사, CI 붙이기).
- 기기에는 `gh`(thisisjun786 로그인)가 있다.
- `dv status`의 마지막 로그 줄은 tmux 화면 캡처라 ANSI 코드가 섞인다. 상태 판단은 `--json`의 status/head로 하고 로그 줄은 참고만 한다.
- Mac에서 `launchctl bootstrap`은 Hermes 게이트웨이 안에서 막힌다. LaunchAgent 등록은 셀레네에게 부탁하고, 그 전까지는 `dv-watch`를 상주 프로세스로 돌린다(재부팅 시 죽음).
- 실제 회전 1회(JUN-303): dv start → Codex goal → dv done → Mac 이벤트 → 워커가 리뷰 1회·land까지 자동 수행. 약 15분.

설치는 개발 호스트에서 `./install.sh --host`, 감시 호스트(lina-os)에서 `./install.sh --host --watch`입니다. 출력된 `systemctl --user enable --now` 명령으로 등록하고, 모든 dv 호스트의 `DV_KICK_HOST`를 감시 호스트로 둡니다(기본값 lina-os). 옛 Mac 감시는 `./install.sh --mac --watch` + launchctl입니다. `~/.config/devflow/config.sh`의 경로·호스트·에이전트 실행 파일을 확인하세요. 중지는 `$DV_HOME/stop` 파일을 만들고 작업자가 끝나기를 기다립니다.
