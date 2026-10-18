---
name: devflow
description: Use when running dev work through dv (devflow).
---

# 시온의 devflow

Linear 이슈를 정리한 뒤 호스트(lina-os, hx, go2, gos)의 로컬 저장소에서 이슈당 에이전트 하나·worktree 하나·브랜치 하나로 개발합니다. 개발 중 설계·비평·relay·리뷰 루프는 없습니다.

1. 구체적인 요구와 완료 기준을 brief 파일로 쓰고 `dv start <repo> <ISSUE> <slug> --brief FILE`로 시작합니다. Codex 기본은 goal입니다. 필요하면 `--agent claude|devin` 또는 Codex `--mode exec`, `--base BRANCH`를 선택합니다.
2. 에이전트는 실패 시험을 먼저 남기고 개발·관련 시험·커밋·보고서를 마칩니다. GitHub면 `dv pr`, 마지막에 `dv done`을 호출합니다.
3. 감시 호스트의 `dv-kick`은 이벤트를 파일에 쓰기만 합니다. `dv-watch`가 3초마다 로컬 큐를 읽고 시온 작업자를 최대 4개 실행합니다. 30분마다 상태 조회로 유실된 done 이벤트만 보완합니다(자기 호스트는 ssh 없이). 모델 폴링을 하지 않습니다. 10-19부터 감시 호스트는 lina-os(systemd user `dev.devflow.watch.service`, `DV_KICK_HOST=lina-os`)입니다.
4. done에서 보고서·diff·시험을 직접 확인합니다. GitHub는 PR이 없으면 `dv pr`, 로컬은 `dv review` 한 번을 실행합니다. PR 체크와 봇 리뷰 완료/시간 초과는 pr-ready 이벤트로 받습니다.
5. 리뷰 P0·P1만 `dv send <ISSUE> '<수정 지시>'`로 한 번 처리합니다. 이슈 상태 폴더에 review-fix.sent를 남겨 후속 이벤트에서도 중복 수정·재리뷰를 막습니다. 수정 후 커밋·관련 시험·PR push(`dv pr`)·done까지 지시합니다. 종료된 tmux는 자동 재시작하지 않으므로 차단으로 기록합니다.
6. 현재 PR head의 CI 전체가 초록이면 `dv land`로 squash merge합니다. 로컬은 `.devflow` 또는 설정의 `DV_TEST_CMD`를 후보 병합 결과에서 통과한 뒤 base를 갱신합니다. fast-forward 기본이며 `DV_LAND_MODE=merge`는 merge 커밋입니다. 원격 브랜치는 남습니다.
7. Linear 이슈에 결과를 한 줄 남깁니다. 준에게는 막힐 때만 알립니다.

| 명령 | 용도 |
|---|---|
| `dv status [ISSUE] [--json]` | 상태·에이전트·호스트·경과·tmux·마지막 로그 |
| `dv send ISSUE 'text'` | 실행 중인 tmux에 지시 붙여넣기 후 Enter |
| `dv done ISSUE [--note TEXT]` | head·파일 수·보고서 경로를 기록하고 이벤트 |
| `dv pr ISSUE` / `dv pr-wait ISSUE` | 브랜치 push·PR / 백그라운드 체크·리뷰 대기 |
| `dv review ISSUE` | 로컬 Codex 리뷰, 횟수와 출력 보관 |
| `dv land ISSUE` | 체크/시험을 통과한 변경 병합·worktree 정리 |
| `dv clean ISSUE` | 깨끗한 worktree와 tmux 정리, 머지된 로컬 브랜치만 삭제 |
| `dv kick kind ISSUE [msg]` | 이벤트 재전송; 전송 실패는 events.log에 기록 |

확인은 이벤트 host·issue·head와 현재 meta를 대조한 뒤 합니다. 보고서 주소만으로 시험 통과를 추정하지 않습니다. CI가 없거나 건너뜀·대기·실패면 land하지 않습니다. 한 번 수정한 P0·P1이 남거나 시험 실패면 차단입니다. base 직접 push, force push, 원격 브랜치 삭제를 하지 않습니다.

## 실사용에서 확인된 것 (10-18, 10-19)
- 10-19 Hermes가 lina-os로 옮겨오며 감시자도 lina-os로 옮겼다. lina-os는 자기 자신에게 ssh 키가 없으므로 같은 호스트 이벤트는 ssh 없이 처리한다(#6, #7). 기기의 `dv-kick-relay`는 lina-os의 `dv-kick`으로 바로 보낸다. 아래 Mac 관련 항목은 옛 구성이다.
- 기기(hx/go2/gos)는 Mac에 직접 ssh할 수 없고 lina-os로도 공인키가 없어 이벤트를 못 보낸다. `~/.local/bin/dv-kick-relay`(기기→lina-os→Mac)를 만들어 `DV_KICK`에 넣었지만, 기기→lina-os 키 허용이 없으면 exit 255로 실패한다. 기기에서 dv를 쓰려면 lina-os authorized_keys에 기기 키를 넣는 작업(셀레네 몫)이 먼저다.
- 기기에는 `gh`가 없다. 로컬 저장소 이슈(dv review/land 경로)만 쓸 수 있다.
- `dv status`의 마지막 로그 줄은 tmux 화면 캡처라 ANSI 코드가 섞인다. 상태 판단은 `--json`의 status/head로 하고 로그 줄은 참고만 한다.
- Mac에서 `launchctl bootstrap`은 Hermes 게이트웨이 안에서 막힌다. LaunchAgent 등록은 셀레네에게 부탁하고, 그 전까지는 `dv-watch`를 상주 프로세스로 돌린다(재부팅 시 죽음).
- 실제 회전 1회(JUN-303): dv start → Codex goal → dv done → Mac 이벤트 → 워커가 리뷰 1회·land까지 자동 수행. 약 15분.

설치는 개발 호스트에서 `./install.sh --host`, 감시 호스트(lina-os)에서 `./install.sh --host --watch`입니다. 출력된 `systemctl --user enable --now` 명령으로 등록하고, 모든 dv 호스트의 `DV_KICK_HOST`를 감시 호스트로 둡니다(기본값 lina-os). 옛 Mac 감시는 `./install.sh --mac --watch` + launchctl입니다. `~/.config/devflow/config.sh`의 경로·호스트·에이전트 실행 파일을 확인하세요. 중지는 `$DV_HOME/stop` 파일을 만들고 작업자가 끝나기를 기다립니다.
