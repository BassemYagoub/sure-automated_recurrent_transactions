# Fork changelog

Changes this fork carries on top of [Sure](https://github.com/we-promise/sure),
currently tracking `0.7.5-alpha.10`. Upstream changes are not listed here.

## Unreleased

### Added

- **Missed recurring transactions are caught up** (2026-10-10). A daily run
  the server was down for happens at the first check after it is back, instead
  of being skipped. The job checks every 5 minutes, still posts once a day per
  family, and that run posts every cycle missed since the last completed run,
  each dated on its own due date. The first run after enabling the feature
  still reaches back only 7 days.
  - Migration `20261010120000_add_recurring_auto_post_last_run_to_families`:
    `families.recurring_auto_post_last_run_at`.
  - `app/jobs/auto_post_recurring_transactions_job.rb`,
    `app/models/recurring_transaction/auto_poster.rb`, `config/schedule.yml`,
    `docs/hosting/recurring-bills.md`, and their tests.

### Fixed

- **The Upcoming tab lists overdue cycles** (2026-10-10). Every unpaid past
  cycle appears, oldest first, ahead of the next 30 days, with "Add now" to
  post it. Before, the tab started at today, so a cycle that slipped past its
  date could not be posted from it.
  - `app/controllers/transactions_controller.rb` and its test.

- **Sure (NDJSON) import no longer fails on a month the family already has a
  budget for** (2026-10-10). Opening the Budgets page creates the current
  month's budget, so a family that had seen that page could not import an
  export containing the same month: the import stopped with "Start date has
  already been taken, End date has already been taken" and rolled back
  entirely. The imported budget now fills the family's existing shared budget
  for that month. A member's personal budget for the month is left untouched,
  and the imported one is added beside it as the shared budget.
  - `app/models/family/data_importer.rb` (`import_budgets`)
  - `test/models/family/data_importer_test.rb` (two tests)
  - Not yet reported upstream; upstream `main` has the same behaviour.

- **Advisory-lock pipeline test connects with the configured database user**
  (2026-09-20). `config/database.yml` sets the `user` key, which the test did
  not read, so its second connection fell back to the operating-system account
  and failed authentication. Test-only change.
  - `test/models/recurring_transaction/pipeline_test.rb`

### Added

- **Recurring transactions post themselves on their due date** (2026-09-20).
  - Posts only on or after the due date, never ahead of it, so the displayed
    balance never moves for a future charge.
  - Manual accounts only. A provider-linked account receives the real charge
    from its own feed.
  - A family default (off unless enabled), with a per-series override that can
    force it on or off.
  - A per-family run hour, read in the family's own timezone (see the catch-up
    entry above for runs the server misses).
  - The Upcoming tab on `/transactions` lists each expected cycle in the next 30
    days (name, amount, expected day, next date, last occurrence) with a link to
    the recurring settings. Each row offers:

    | Row | Button | Effect |
    | --- | --- | --- |
    | Due today or overdue | Add now | Writes the entry dated on its due date and marks the cycle paid |
    | Due later | Add on its due date | The daily run posts it on its due date; nothing is written today |
    | Due later, approved | Approved | Click to undo the approval |
    | Series already auto-posts | (icon) | Nothing to decide |
    | Any | Skip | Skips that cycle |

  - Migration `20260920120000_add_recurring_auto_post`: family default and run
    hour, the per-series override, the per-cycle approval, and an
    `auto_posted` payment source.
  - New: `app/models/recurring_transaction/auto_poster.rb`,
    `app/jobs/auto_post_recurring_transactions_job.rb`,
    `app/views/transactions/_upcoming_row.html.erb`,
    `app/views/transactions/_upcoming_settings_hint.html.erb`, and their tests.
  - Removed: `app/views/recurring_transactions/_projected_transaction.html.erb`,
    which the rebuilt Upcoming tab no longer renders.
  - Known limitations:
    - Recurring transfers are not posted (they need a paired inflow and outflow).
    - The per-series toggle is not shown on the new-bill dialog, so a new bill
      follows the family default until edited.

### Documentation

- `docs/llm-guides/agent-guidelines.md`: working rules for coding agents in
  this fork (test-first, mutation check, fork footprint, checks to run). Lowest
  priority: `AGENTS.md` and the other guides win on any contradiction.
- `FORK_CHANGELOG.md`: this file.
