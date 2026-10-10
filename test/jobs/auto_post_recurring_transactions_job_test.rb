require "test_helper"

class AutoPostRecurringTransactionsJobTest < ActiveJob::TestCase
  setup do
    @paris = families(:dylan_family)
    @new_york = families(:empty)
  end

  # Noon UTC is 14:00 in Paris and 08:00 in New York on this date, so one fixed
  # instant gives two different local hours to assert against.
  NOON_UTC = Time.utc(2026, 9, 20, 12, 0, 0)

  def enqueued_family_ids
    enqueued_jobs
      .select { |job| job["job_class"] == "AutoPostRecurringTransactionsJob" }
      .flat_map { |job| job["arguments"] }
  end

  test "enqueues only the families whose own local hour has arrived" do
    @paris.update!(timezone: "Europe/Paris", recurring_auto_post_enabled: true, recurring_auto_post_hour: 14)
    @new_york.update!(timezone: "America/New_York", recurring_auto_post_enabled: true, recurring_auto_post_hour: 14)

    travel_to NOON_UTC do
      AutoPostRecurringTransactionsJob.new.perform
    end

    assert_includes enqueued_family_ids, @paris.id, "14:00 in Paris is noon UTC"
    assert_not_includes enqueued_family_ids, @new_york.id, "it is only 08:00 in New York"
  end

  test "an hour later the other family's turn comes" do
    @new_york.update!(timezone: "America/New_York", recurring_auto_post_enabled: true, recurring_auto_post_hour: 8)

    travel_to NOON_UTC do
      AutoPostRecurringTransactionsJob.new.perform
    end

    assert_includes enqueued_family_ids, @new_york.id
  end

  test "an unknown timezone falls back rather than taking the sweep down" do
    @paris.update!(recurring_auto_post_enabled: true)
    # update_columns to get past the model's own zone validation: the point is
    # a row that already holds a stale name, which is how these arrive.
    @paris.update_columns(timezone: "Nowhere/Atlantis")

    travel_to NOON_UTC do
      # Whatever zone the app is configured with, the fallback must land on
      # that zone's hour rather than raising or skipping the family.
      @paris.update_columns(recurring_auto_post_hour: Time.current.in_time_zone(Time.zone).hour)

      assert_nothing_raised { AutoPostRecurringTransactionsJob.new.perform }
      assert_includes enqueued_family_ids, @paris.id
    end
  end

  test "skips a family that switched recurring transactions off" do
    @paris.update!(
      timezone: "Europe/Paris",
      recurring_auto_post_enabled: true,
      recurring_auto_post_hour: 14,
      recurring_transactions_disabled: true
    )

    travel_to NOON_UTC do
      AutoPostRecurringTransactionsJob.new.perform
    end

    assert_not_includes enqueued_family_ids, @paris.id
  end

  test "skips a family with nothing opted in" do
    @paris.update!(timezone: "Europe/Paris", recurring_auto_post_enabled: false, recurring_auto_post_hour: 14)

    travel_to NOON_UTC do
      AutoPostRecurringTransactionsJob.new.perform
    end

    assert_not_includes enqueued_family_ids, @paris.id
  end

  test "a single opted-in series makes an otherwise-default family eligible" do
    @paris.update!(timezone: "Europe/Paris", recurring_auto_post_enabled: false, recurring_auto_post_hour: 14)
    recurring_transactions(:netflix_subscription).update!(auto_post: true)

    travel_to NOON_UTC do
      AutoPostRecurringTransactionsJob.new.perform
    end

    assert_includes enqueued_family_ids, @paris.id
  end

  test "a single approved occurrence makes an otherwise-default family eligible" do
    @paris.update!(timezone: "Europe/Paris", recurring_auto_post_enabled: false, recurring_auto_post_hour: 14)
    series = recurring_transactions(:netflix_subscription)
    series.recurring_occurrences.create!(
      family: @paris,
      original_due_on: Date.current,
      due_on: Date.current,
      currency: series.currency,
      status: "scheduled",
      auto_post_approved_at: Time.current
    )

    travel_to NOON_UTC do
      AutoPostRecurringTransactionsJob.new.perform
    end

    assert_includes enqueued_family_ids, @paris.id
  end

  test "the per-family branch runs the poster under the family lock" do
    @paris.update!(recurring_auto_post_enabled: true)

    RecurringTransaction::Pipeline.expects(:with_family_lock).with(@paris.id).once
    RecurringTransaction::AutoPoster.any_instance.expects(:run!).never

    AutoPostRecurringTransactionsJob.new.perform(@paris.id)
  end

  test "the per-family branch posts due occurrences" do
    series = recurring_transactions(:netflix_subscription)
    series.recurring_occurrences.delete_all
    @paris.update!(recurring_auto_post_enabled: true)
    series.recurring_occurrences.create!(
      family: @paris,
      original_due_on: Date.current,
      due_on: Date.current,
      currency: series.currency,
      status: "scheduled"
    )

    assert_difference -> { series.account.entries.count }, 1 do
      AutoPostRecurringTransactionsJob.new.perform(@paris.id)
    end
  end
end
