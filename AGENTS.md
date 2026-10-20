# devflow 개발 규칙

- bash와 표준 도구, jq만 사용합니다. Mac 기본 bash 3.2와 Linux에서 실행할 수 있게 유지합니다.
- 이 worktree와 이 이슈의 파일만 고칩니다. CRW 코드·설정·스킬·relay를 사용하지 않습니다. 데몬·DB·웹 UI·개발 리뷰 루프를 추가하지 않습니다.
- 실패하는 시험부터 확인하고 변경 범위 시험을 돌립니다. 시험은 임시 Git 저장소·가짜 에이전트·gh 스텁을 사용하며 실제 에이전트나 PR을 만들지 않습니다. 실제 tmux가 없으면 해당 시험만 skip으로 셉니다.
- 검증: `tests/run.sh`, `shellcheck -x bin/* lib/*.sh install.sh config.example.sh tests/run.sh tests/fixtures/*`.
- 보고서에는 변경, red/green과 명령 결과, 남은 한계를 씁니다. 커밋은 `<ISSUE>: ...` 형식입니다.
- 실제 이슈 전달은 해당 브리프의 승인을 따릅니다. base에 직접 push·force push·원격 브랜치 삭제는 금지합니다.
- 리뷰는 최종 `codex review --base main` 한 번 또는 PR 봇 리뷰 한 번입니다. P0·P1만 한 번 고치고 재리뷰하지 않습니다.
- 상태 파일과 사용자 설정을 덮어쓰지 않고, dirty worktree는 제거하지 않습니다.

## CI

- main 대상 PR에서는 Linux 검사만 실행합니다.
- main 병합 후 push에서는 macOS를 포함한 전체 matrix를 실행합니다.
- PR 실행에 macOS를 추가하지 않습니다.
