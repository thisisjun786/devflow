---
name: devflow
description: Use when running dev work through dv (devflow).
---

# 시온의 devflow

Linear 이슈를 정리한 뒤 개발 호스트의 로컬 저장소에서 이슈당 에이전트 하나·worktree 하나·브랜치 하나로 개발합니다. 개발 중 설계·비평·relay·리뷰 루프는 없습니다.

herdr가 설치되어 있으면 `dv start`는 포커스를 유지하며 `dv-<ISSUE>` workspace에서 에이전트를 직접 실행하고(Codex hooks 유지), send·status·clean/land는 meta의 backend를 따릅니다(로그는 done/clean 화면 저장, `DV_HERDR=0`·미설치·backend 없는 기존 이슈는 tmux, herdr 시작 실패 시 상태 보존).

1. 구체적인 요구와 완료 기준을 brief 파일로 쓰고 `dv start <repo> <ISSUE> <slug> --brief FILE`로 시작합니다. Codex 기본은 goal입니다. 필요하면 `--agent claude|devin` 또는 Codex `--mode exec`, `--base BRANCH`를 선택합니다.
2. 에이전트는 실패 시험을 먼저 남기고 개발·관련 시험·커밋·보고서를 마칩니다. GitHub면 `dv pr`, 마지막에 `dv done`을 호출합니다.
3. 감시 호스트의 `dv-kick`은 이벤트를 파일에 쓰기만 합니다. `dv-watch`가 3초마다 로컬 큐를 읽고 시온 작업자를 최대 4개 실행합니다. 30분마다 상태 조회로 유실된 done 이벤트만 보완합니다(자기 호스트는 ssh 없이). 모델 폴링을 하지 않습니다. 10-19부터 감시 호스트는 lina-os(systemd user `dev.devflow.watch.service`, `DV_KICK_HOST=lina-os`)입니다.
4. done에서 보고서·diff·시험을 직접 확인합니다. GitHub는 PR이 없으면 `dv pr`, 로컬은 `dv review` 한 번을 실행합니다. PR 체크와 봇 리뷰 완료/시간 초과는 pr-ready 이벤트로 받습니다.
5. 리뷰 P0·P1만 `dv send <ISSUE> '<수정 지시>'`로 한 번 처리합니다. 이슈 상태 폴더에 review-fix.sent를 남겨 후속 이벤트에서도 중복 수정·재리뷰를 막습니다. 수정 후 커밋·관련 시험·PR push(`dv pr`)·done까지 지시합니다. 종료된 tmux는 자동 재시작하지 않으므로 차단으로 기록합니다.
6. 현재 PR head의 CI 전체가 초록이면 `dv land`로 저장소가 허용하는 병합 방식(squash 우선)을 사용합니다. 로컬은 `.devflow` 또는 설정의 `DV_TEST_CMD`를 후보 병합 결과에서 통과한 뒤 base를 갱신합니다. fast-forward 기본이며 `DV_LAND_MODE=merge`는 merge 커밋입니다. 원격 브랜치는 남습니다.
7. 이슈에 결과를 한 줄 남깁니다. 준에게 보내는 알림(준 10-22 "보내는 메시지 정돈해라"): 합친 결과는 바로 보내지 않고 `~/.local/state/devflow-mac/digest.tsv`에 `시각\t저장소\t쉬운 말 한 줄`로 덧붙인다. `~/dv/bin/sion-digest`가 09·12·15·18·21·00시에 저장소별로 묶어 한 통 보낸다(user timer `sion-digest`). 바로 보내는 건 준만 할 수 있는 일(돈·계정·공개·되돌릴 수 없는 일)과 시온이 풀 수 없는 막힘뿐, 두 줄(무엇이 막혔나 / 준이 할 일). 재시도·충돌·리뷰 수정처럼 시온이 처리할 막힘은 알리지 않고 처리한다. 번호·경로·PR·시험 개수·CI 같은 말을 쓰지 않는다.

| 명령 | 용도 |
|---|---|
| `dv status [ISSUE] [--json]` | 상태·에이전트·호스트·경과·backend·생존·에이전트 상태·마지막 로그 |
| `dv send ISSUE 'text'` | herdr agent prompt(차단 시 대기 후 한 번 재시도) / tmux 붙여넣기 후 Enter |
| `dv done ISSUE [--note TEXT]` | head·파일 수·보고서 경로를 기록하고 이벤트 |
| `dv pr ISSUE` / `dv pr-wait ISSUE` | 브랜치 push·PR / 백그라운드 체크·리뷰 대기 |
| `dv review ISSUE` | 로컬 Codex 리뷰, 횟수와 출력 보관 |
| `dv land ISSUE` | 체크/시험을 통과한 변경 병합·worktree 정리 |
| `dv clean ISSUE` | 깨끗한 worktree와 herdr/tmux 정리, 머지된 로컬 브랜치만 삭제 |
| `dv kick kind ISSUE [msg]` | 이벤트 재전송; 전송 실패는 events.log에 기록 |

확인은 이벤트 host·issue·head와 현재 meta를 대조한 뒤 합니다. 보고서 주소만으로 시험 통과를 추정하지 않습니다. CI가 없거나 건너뜀·대기·실패면 land하지 않습니다. 한 번 수정한 P0·P1이 남거나 시험 실패면 차단입니다. base 직접 push, force push, 원격 브랜치 삭제를 하지 않습니다.

## 실사용에서 확인된 것 (10-18, 10-19)
- 10-19 Hermes가 lina-os로 옮겨오며 감시자도 lina-os로 옮겼다. lina-os는 자기 자신에게 ssh 키가 없으므로 같은 호스트 이벤트는 ssh 없이 처리한다(#6, #7). 기기의 `dv-kick-relay`는 lina-os의 `dv-kick`으로 바로 보낸다. 아래 Mac 관련 항목은 옛 구성이다.
- 이슈 이름(10-21): 저장소 약칭 + GitHub 이슈 번호. devflow `DF-`, murmur `MM-`, lyric-studio `LS-`. 새 저장소는 대문자 두 글자를 정해 여기에 적는다. 저장소마다 번호가 겹치므로 `GH-<번호>`는 쓰지 않는다. **lina 저장소의 `LINA-<n>`은 Linear LINA 팀 이슈 키와 겹친다**: PR 제목·브랜치의 `LINA-<n>` 때문에 Linear GitHub 연동이 머지 순간 엉뚱한 Linear 이슈(대부분 10-01 Canceled)를 Done으로 바꾼다(10-20 16건 발생, 10-21 전부 Canceled로 되돌림). 새 lina 이슈는 `LN-<n>`으로 띄운다. 이미 `LINA-<n>`으로 돈 이슈는 land 뒤 Linear 같은 번호의 상태 이력을 보고 머지 직전 상태로 되돌린다. 봇이 `tool-issue`로 올린 도구 고장 이슈(`[도구 이슈 · <봇>] <url>`)도 같은 이름으로 띄우고, 처리 절차는 공용 스킬 `tool-issue-handoff`의 '시온이 받았을 때'를 따른다.
- 개발 호스트 동점 순서(준 10-20 결정): **hx-linux → amd-linux → go2-linux → lina-os → gos-linux(jun 계정만, 최후)**. 조회·배정은 작업 호스트 → 관리자와 lina-os → gos 그룹 순이며, 그룹 안의 배정은 점수가 높은 호스트부터다. gos는 점수가 높아도 lina-os보다 뒤이고 `DV_HOSTS`에 명시할 때만 쓴다. amd-linux는 OS hostname이 `oldamdlinux`라 기기 config에서 `DV_HOST=DV_KICK_HOST=amd-linux`로 고정한다. lina-os는 Hermes·상주 서비스 몫이라 작업용 기기가 찼을 때만 쓴다. gos의 OpenClaw 사용자(neolina·eunbot)는 외부용이라 건드리지 않는다.
- 원격 호스트 이벤트: 기기는 lina-os로 ssh 키가 없다. 대신 lina-os dv-watch가 `DV_PULL_HOSTS="hx-linux amd-linux go2-linux gos-linux"`로 기기마다 `dv-kick-pull`을 띄워 기기의 `kick.q`를 ssh `tail -f`로 받아 온다(#11). 기기 config는 `DV_KICK_HOST=<자기 hostname>`, `DV_KICK=`(로컬 큐). 옛 `dv-kick-relay`는 쓰지 않는다.
- 기기에서 시작: `ssh hx-linux 'bash -lc "dv start ~/code/<repo> ISSUE slug --brief ~/dv/briefs/brief-x.md"'`. 저장소·브리프는 그 기기에 있어야 한다. 개발 저장소는 전부 GitHub 비공개 원격(devflow, murmur 등)을 두고 기기마다 clone한다. 원격 없는 로컬 저장소는 기기에서 시작하지 말고 먼저 비공개 원격을 만든다(gitleaks로 히스토리 검사, CI 붙이기).
- 기기에는 `gh`(thisisjun786 로그인)가 있다.
- `dv status`의 마지막 로그 줄은 tmux 화면 캡처라 ANSI 코드가 섞인다. 상태 판단은 `--json`의 status/head로 하고 로그 줄은 참고만 한다.
- Mac에서 `launchctl bootstrap`은 Hermes 게이트웨이 안에서 막힌다. LaunchAgent 등록은 셀레네에게 부탁하고, 그 전까지는 `dv-watch`를 상주 프로세스로 돌린다(재부팅 시 죽음).
- 실제 회전 1회(JUN-303): dv start → Codex goal → dv done → Mac 이벤트 → 워커가 리뷰 1회·land까지 자동 수행. 약 15분.

설치는 개발 호스트에서 `./install.sh --host`, 감시 호스트(lina-os)에서 `./install.sh --host --watch`입니다. 출력된 `systemctl --user enable --now` 명령으로 등록하고, 모든 dv 호스트의 `DV_KICK_HOST`를 감시 호스트로 둡니다(기본값 lina-os). 옛 Mac 감시는 `./install.sh --mac --watch` + launchctl입니다. `~/.config/devflow/config.sh`의 경로·호스트·에이전트 실행 파일을 확인하세요. 중지는 `$DV_HOME/stop` 파일을 만들고 작업자가 끝나기를 기다립니다.
