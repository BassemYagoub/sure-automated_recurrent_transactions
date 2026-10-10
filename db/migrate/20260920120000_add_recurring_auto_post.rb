class AddRecurringAutoPost < ActiveRecord::Migration[8.1]
  # Written as up/down rather than `change`: swapping a check constraint is not
  # something the schema statements can invert on their own, and a migration
  # that cannot roll back cleanly is worse than a verbose one.

  OLD_ALLOCATION_SOURCES = "source::text = ANY (ARRAY['auto_matched'::character varying::text, " \
                           "'user_confirmed'::character varying::text, " \
                           "'user_created'::character varying::text])".freeze

  NEW_ALLOCATION_SOURCES = "source IN ('auto_matched', 'user_confirmed', 'user_created', 'auto_posted')".freeze

  def up
    # The family default, plus the hour the poster runs. The hour is read in the
    # family's own `timezone`, so the cron entry fires hourly and each family
    # posts when its own local hour arrives.
    add_column :families, :recurring_auto_post_enabled, :boolean, default: false, null: false
    add_column :families, :recurring_auto_post_hour, :integer, default: 6, null: false

    add_check_constraint :families,
                         "recurring_auto_post_hour >= 0 AND recurring_auto_post_hour <= 23",
                         name: "chk_families_recurring_auto_post_hour"

    # Nullable on purpose: NULL means "inherit the family default", so one
    # column expresses all three states a per-series toggle with a default
    # needs. A boolean with a default could not tell "never set" from
    # "explicitly off", and turning the family default on would then silently
    # re-enable series the user had switched off by hand.
    add_column :recurring_transactions, :auto_post, :boolean

    # The per-occurrence approval behind the Upcoming tab's check button: a
    # single future cycle cleared to post on its due date, even when its series
    # does not auto-post. A timestamp rather than a boolean so the row records
    # when the decision was made.
    add_column :recurring_occurrences, :auto_post_approved_at, :datetime

    # Auto-posted payments are neither user-created nor matched against an
    # existing entry -- they created the entry themselves. The Bills UI reads
    # `source` to explain why a payment is attached to an occurrence, so
    # reusing one of the existing values would misreport provenance there.
    remove_check_constraint :recurring_allocations, name: "chk_recurring_allocations_source"
    add_check_constraint :recurring_allocations, NEW_ALLOCATION_SOURCES,
                         name: "chk_recurring_allocations_source"
  end

  def down
    # Anything already written as auto_posted has to become a value the old
    # constraint admits, or re-adding it fails. user_created is the closest:
    # the payment is real and was not matched against a pre-existing entry.
    execute(<<~SQL.squish)
      UPDATE recurring_allocations SET source = 'user_created' WHERE source = 'auto_posted'
    SQL

    remove_check_constraint :recurring_allocations, name: "chk_recurring_allocations_source"
    add_check_constraint :recurring_allocations, OLD_ALLOCATION_SOURCES,
                         name: "chk_recurring_allocations_source"

    remove_column :recurring_occurrences, :auto_post_approved_at
    remove_column :recurring_transactions, :auto_post
    remove_check_constraint :families, name: "chk_families_recurring_auto_post_hour"
    remove_column :families, :recurring_auto_post_hour
    remove_column :families, :recurring_auto_post_enabled
  end
end
