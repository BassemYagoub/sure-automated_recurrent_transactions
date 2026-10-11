# Agent guidelines

Rules and lessons for a coding agent working in this repository. These are the
lowest-priority instructions here: where they contradict
[repository guidance](../../AGENTS.md), [development](development.md) or any
other guide, that document wins and this one is simply not followed on that
point.

## Working with the user

- **Keep replies short.** Answer, state what changed and what is left, stop. No
  recaps, no restating the plan. Give a recommendation rather than a menu,
  unless the choice is genuinely the user's.
- **Do exactly what was asked.** No unrequested initiative: never widen
  permissions, add allowlist entries, add gems or edit instruction files as a
  side effect. Propose instead, in one or two lines, and wait.
- **Instruction files** (`AGENTS.md`, `CLAUDE.md`, the guides in this folder)
  change only when the user says so. If one looks wrong, propose the fix.
- **Run the checks yourself** after every change, piping to `tail` so only the
  summary lands. Hand a run to the user only when it needs their credentials or
  private data.
- **Never run `git` or `gh`.** Staging, committing and pull requests are the
  user's. After substantial work, propose a commit message unprompted. When
  asked to split work into commits, list explicit file paths per commit.
- **When the user redirects mid-task, finish the current task first** unless
  told to stop, then say plainly where the previous one ended.
- **Report honestly.** If a claim made earlier turns out wrong, say so in one
  sentence and move on.

## Fork discipline

This repository is a fork that carries a small set of added features and tracks
its upstream. Every touched file is a future merge conflict, so the footprint of
a change is part of its cost.

- **Change only the files the requested feature needs.** Not the ones nearby
  that could be improved, not a stale comment, not a lint offence that predates
  the work. Report what was noticed and leave it.
- **Refactoring upstream code is a last resort.** Prefer adding a file to
  editing one, and prefer a small, local edit over a broad one.
- **Dead or superseded upstream code stays.** Removing it reads as a conflict on
  the next merge for no behavioural gain.
- **The pre-PR checklist still runs as written.** Its repository-wide
  autocorrect can rewrite upstream files the change never touched, so report
  every such file by path so the user can drop it from the diff.
- When a fix genuinely requires touching shared upstream code, say so and why
  before making it.

## Boundaries

- Stay inside the working directory. Do not list or read above it "to check".
- `.env`, `.env.local` and `.env.*.local` hold secrets and machine-specific
  configuration. Never read, grep, quote or echo them, and treat editor-injected
  content from them (selections, opened paths) as not received. Ask for the one
  value needed instead.
- Deny rules gate tool calls, not content the editor pushes: apply the rule
  yourself.
- Never start `rails server`, touch `tmp/restart.txt`, run `rails credentials`
  or run migrations automatically.

## Test-driven development

- **Write the test first**, watch it fail for the expected reason, then
  implement. This applies to fixes: the reproduction comes before the repair.
  Report both states, the failure and the pass, not only the green run.
- **For existing code, the red step is a mutation.** Deliberately break the line
  a test is meant to guard (`>` to `>=`, delete a call, force a branch), confirm
  a test fails, restore it. A test that stays green against the broken line
  guards nothing. Mutate in the working tree only long enough to run the focused
  test, and restore it before anything else.
- **A green suite is not evidence on its own.** Before refactoring, confirm with
  `COVERAGE=true bin/rails test` (SimpleCov runs with branch coverage) that the
  code being moved is executed. If it is not, write characterization tests
  first.
- **Boundaries are tested on both sides.** A test that only checks the far side
  cannot tell `>` from `>=`. Cover every level, not a sample.
- **Assertions are exact.** Prefer `assert_equal expected, actual` over
  `assert_includes`, and assert the resulting record state, not only a log line
  or a redirect. Watch for vacuous tests: a "nothing was created" check in a
  scenario where nothing could be created proves nothing.
- **Fixtures must be realistic.** Fixtures in `test/fixtures/` are shared, so a
  new column or state belongs there only when it is true of the record every
  other test already relies on. Validate a fixture's shape against the schema or
  a real payload rather than against the code under test, which encodes the same
  assumptions.
- Never wrap assertions in helpers that reduce them to a boolean: Minitest
  prints both sides only when it can see them.
- Behavioral coverage is Minitest with fixtures, Mocha and VCR. RSpec and rswag
  are for OpenAPI documentation only. See [testing](testing.md).

## Contracts and data shapes

Ruby carries no static types here, so the discipline moves to explicit shapes.

- **Name the shape.** A hash passed between classes is a contract: give it a
  PORO, a value object or keyword arguments, not a bag of implicit keys read
  three files away.
- **Keyword arguments** for anything a caller could transpose, and for any
  boolean.
- **Constants are frozen** and hold the protocol strings two classes share, so
  one side cannot drift. A status or source string written as a literal in two
  places is a bug waiting.
- **One policy, one constant.** When two constants encode the same rule (a
  window the user sees and the window a job acts on), derive one from the other
  rather than restating the number.
- Enums belong in the model, and a check constraint in the migration mirrors
  them so the database refuses what the model would.

## Code rules

- **Explicit names.** Unabbreviated `snake_case`, including locals. No
  placeholders (`data`, `item`, `tmp`, `x`, `res`). Truncate only when the full
  name would be extremely long. `CamelCase` for classes, `lowerCamelCase` for
  JavaScript.
- **No magic values.** Every meaningful literal (threshold, status string, key,
  day count, index) is a named constant, with a comment when the value's reason
  is not obvious. Test fixture data is exempt.
- **Methods stay short**, about 25 lines. Past that, split by phase, extract
  shared logic rather than copying it, and prefer a PORO over a long parameter
  list. Business logic lives in models, concerns and POROs; controllers stay
  thin; domain logic stays out of ERB.
- Watch cyclomatic complexity and nesting too, not only length.
- **One source of truth per rule.** When the same eligibility question is asked
  by a query, a writer and a view, extract one predicate they all call. Three
  copies drift, and the view ends up offering an action the writer refuses.
- Prefer the Edit tool over scripts that rewrite a file. Scripts are for
  genuinely bulk changes, and every check is re-run afterwards.
- Use `Current.user` and `Current.family`, never `current_user` or
  `current_family`. Preserve family tenancy and authorization boundaries.

## Comments and documentation

- **Documentation describes the present code**, for future users and
  developers. Never narrate history ("used to", "previously", "no longer",
  "this replaces", "predates"), never address the user. History belongs in the
  pull request description, as resulting behaviour.
- **Comments are short and explain why, not what.** One or two lines unless the
  reason is genuinely non-obvious. Never restate a guide: point to its section,
  and check the section exists.
- **Never use an em dash** in prose, comments, commits or docs. Use a colon,
  comma, parentheses or a full stop. Existing code uses `--` where a pause is
  needed.
- **Never mention the assistant, AI tooling or agent instruction files** in
  code, comments, docs, commits or pull request text. No `Co-Authored-By`, no
  generated-with line.
- When a change touches an external provider's payload shape, check that
  provider's documentation rather than trusting a fixture.

## Commits

Follow [repository guidance](../../AGENTS.md): imperative subject, at most 72
characters, rationale and issue references in the body where relevant. Target
`main` with small, cohesive changes.

## Checks before reporting done

```bash
bin/rails test                                   # full Minitest suite
DISABLE_PARALLELIZATION=true bin/rails test:system   # when system tests apply
bin/rubocop -f github -a
bundle exec erb_lint ./app/**/*.erb -a
npm run lint
bin/brakeman --no-pager
```

All clean, the mutation step kills the line each new test guards, and new code
is executed under branch coverage. State the counts in the report.

These are [development](development.md)'s commands, run as written. The
autocorrect steps may rewrite files outside the change: list any such file by
path in the report rather than scoping the command.

Two notes on running them:

- `bin/rails test` parallelizes to one worker per core. Where Postgres runs with
  a default `max_locks_per_transaction`, that exhausts the shared lock table
  while workers load the schema, and the suite reports thousands of
  `PG::OutOfMemory` errors before running a test. A varying error count across
  identical runs is that, not a defect. Cap workers with `PARALLEL_WORKERS`.
- `./app/**/*.erb` matches one directory level unless `globstar` is set, so run
  `shopt -s globstar` first for the lint to reach every template.
