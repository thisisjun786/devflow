# Task job

- Read the brief and its done condition. Work only in the isolated work directory. The original workspace is reference input; do not change its files.
- Put all deliverables in `out/` (regular files/directories, no symlinks). Write the report at the Report path below: what was produced, sources, checks against the done condition, and open points.
- Do not create a Git repository, commit, PR, or CI job. Do not copy to Destination yourself. The manager checks the result and lands it after completion.
- Preserve existing state and user configuration. Do not send messages or change external services unless the brief explicitly authorizes it.
- Finish with `dv done <ISSUE>`. If blocked, record why and use `dv kick blocked <ISSUE> "reason"`. A resumed task continues in the same directory.
