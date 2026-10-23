# Issue format (all repos)

Every issue in every repo follows this format, whether a person, sion, `dv` or a script files it. Write it in English.

## Title
`type(scope): what changes`

- type is one of: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `ci`, `chore`, `research`.
- scope is the area touched: a package, module or screen (`a2a`, `tui`, `delivery`). Leave it out only when nothing narrower fits.
- After the colon, write a lowercase imperative phrase of 72 characters or fewer. It should tell a reader what the issue is about without opening it.
- No PR numbers, internal job keys (`LN-123`), dates, or words like "follow up" or "misc".
  - Good: `fix(a2a): check decoded JSON strings for reflected credentials`
  - Bad: `Follow up on Codex review of PR #1127`

## Body
```
## Summary
One to three sentences: what is wrong or missing, and why it matters.

## Done when
- [ ] checkable result 1
- [ ] checkable result 2

## Context
Depends on #n (one line per blocker; omit if none)
Source: review of #PR / audit / owner request
Links, logs, file:line references
```

- Bugs also get `## Steps`, `## Expected` and `## Actual` between Summary and Done when.
- Research issues name the question in Summary. Their Done when lists the note path and the decision it must enable.
- Done when items are things a reviewer can check: a test name, a command, a screenshot, a number. Don't write "works well".
- No raw HTML or badge images in the body. Write file references as `path:line`.

## Review follow-ups (P2/P3 left after a clean Codex review)
- One issue per source PR, as now. The title comes from the first finding: `fix(<scope from its path>): <finding headline, lowercased first letter>`. If there are more findings, add ` (+N more)`.
  - The scope is the finding's parent directory. For a generic directory (`lib`, `src`, `internal`, `cmd`, `scripts`, `docs`, `tests`, `test`, `pkg`, `app`, `core`, `bin`) it is the file stem instead. A finding from the review summary has no file, so its title has no scope.
  - The title is cut to 90 characters with an ellipsis.
- Summary: "P2/P3 findings left after the review of #PR."
- Findings list: `- P2 path:line — headline. One-line detail.`
- Done when: "- [ ] each finding fixed, or answered here with the reason it stays."
- Context: `Depends on #<source issue>`, plus the source PR link and the hidden marker comment.
