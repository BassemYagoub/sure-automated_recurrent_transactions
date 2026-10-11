# Posts due recurring transactions for families whose chosen hour has arrived.
#
# The cron entry fires every few minutes and this job decides who is due,
# rather than the schedule naming a single time for the whole installation: the
# hour is a per-family setting read in that family's own timezone, so an
# installation spanning several zones still posts each family's bills at the
# hour they chose. A run the server was down for is owed, not lost: it happens
# at the first check after the server is back.
class AutoPostRecurringTransactionsJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform(family_id = nil)
    if family_id.nil?
      fan_out
    else
      post_for_family(family_id)
    end
  end

  private
    def fan_out
      eligible_families.find_each do |family|
        next unless run_due?(family)

        self.class.perform_later(family.id)
      end
    end

    # Owed once the family's latest scheduled run time has passed since its
    # last completed run. Comparing against that time, rather than checking for
    # the hour itself, is what lets a missed run happen late instead of never.
    # A family that never ran owes nothing from before today.
    def run_due?(family)
      now = Time.current.in_time_zone(family_zone(family))
      todays_run = now.change(hour: family.recurring_auto_post_hour)
      last_run_at = family.recurring_auto_post_last_run_at
      return now >= todays_run if last_run_at.nil?

      latest_scheduled_run = now >= todays_run ? todays_run : todays_run - 1.day
      last_run_at < latest_scheduled_run
    end

    def post_for_family(family_id)
      family = Family.find_by(id: family_id)
      return unless family
      return if family.recurring_transactions_disabled?

      # Shares the pipeline's per-family lock, so posting cannot interleave with
      # a detection run that is busy materializing or matching the very
      # occurrences this would settle.
      RecurringTransaction::Pipeline.with_family_lock(family_id) do
        posted = RecurringTransaction::AutoPoster.new(family).run!
        # Recorded only once the run completed under the lock, so a run that
        # did not happen stays owed. update_columns: bookkeeping, not an edit.
        family.update_columns(recurring_auto_post_last_run_at: Time.current)
        Rails.logger.info("Auto-posted #{posted} recurring transaction(s) for family #{family_id}") if posted.positive?
      end
    end

    # Families that could post anything at all: the default is on, or a series
    # opted in by hand, or a single future cycle was approved from the Upcoming
    # tab. Without this every check would walk every family on the
    # installation to find nothing.
    def eligible_families
      opted_in_series = RecurringTransaction
        .where("recurring_transactions.family_id = families.id")
        .where(auto_post: true)

      approved_occurrences = RecurringOccurrence
        .where("recurring_occurrences.family_id = families.id")
        .open_status
        .auto_post_approved

      Family.where(recurring_transactions_disabled: false).merge(
        Family.where(recurring_auto_post_enabled: true)
              .or(Family.where(opted_in_series.arel.exists))
              .or(Family.where(approved_occurrences.arel.exists))
      )
    end

    # Resolved defensively for the same reason Localize#resolved_timezone is:
    # families.timezone is free text and can hold a blank, a stale name, or one
    # the tzdata maintainers have since renamed. A bad value must not take the
    # whole sweep down with it.
    def family_zone(family)
      ActiveSupport::TimeZone[family.timezone.to_s] || Time.zone
    end
end
