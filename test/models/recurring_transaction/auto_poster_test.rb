require "test_helper"

class RecurringTransaction::AutoPosterTest < ActiveSupport::TestCase
  Poster = RecurringTransaction::AutoPoster

  def setup
    @family = families(:dylan_family)
    @series = recurring_transactions(:netflix_subscription)
    @series.recurring_occurrences.delete_all
    @family.update!(recurring_auto_post_enabled: true)
  end

  # Builds one occurrence for the series without going through the generator,
  # so each test states the single date it cares about.
  def occurrence_due(date, series: @series, **attrs)
    series.recurring_occurrences.create!(
      family: series.family,
      original_due_on: date,
      due_on: date,
      currency: series.currency,
      status: "scheduled",
      **attrs
    )
  end

  test "posts a due occurrence and settles it with the entry it created" do
    occurrence = occurrence_due(Date.current)

    assert_difference -> { @series.account.entries.count }, 1 do
      assert_equal 1, Poster.new(@family).run!
    end

    entry = @series.account.entries.order(:created_at).last
    assert_equal Date.current, entry.date
    assert_equal @series.display_name, entry.name
    assert_equal @series.amount, entry.amount, "an expense series posts a positive (outflow) amount"
    assert_equal @series.currency, entry.currency
    assert entry.transaction?

    occurrence.reload
    assert occurrence.paid?, "the occurrence closes against its own entry"
    assert_equal entry, occurrence.allocations.sole.entry
    assert_equal "auto_posted", occurrence.allocations.sole.source
  end

  test "carries the series' category and merchant onto the posted transaction" do
    @series.update!(category: categories(:food_and_drink))
    occurrence_due(Date.current)

    Poster.new(@family).run!

    transaction = @series.account.entries.order(:created_at).last.transaction
    assert_equal categories(:food_and_drink), transaction.category
    assert_equal @series.merchant, transaction.merchant
  end

  test "an income series posts an inflow" do
    @series.update!(amount: -2_000, bill_type: "income")
    occurrence_due(Date.current)

    Poster.new(@family).run!

    entry = @series.account.entries.order(:created_at).last
    assert_equal(-2_000, entry.amount, "income is stored as a negative amount")
  end

  test "a second run posts nothing more" do
    occurrence_due(Date.current)

    assert_equal 1, Poster.new(@family).run!
    assert_difference -> { @series.account.entries.count }, 0 do
      assert_equal 0, Poster.new(@family).run!
    end
  end

  test "the entry's idempotency key refuses a duplicate even if the occurrence reopens" do
    occurrence = occurrence_due(Date.current)
    Poster.new(@family).run!

    # Simulate the occurrence being reopened with its entry detached, which is
    # the only way a second post could otherwise slip past the status guard.
    occurrence.allocations.delete_all
    occurrence.reopen!

    assert_difference -> { @series.account.entries.count }, 0 do
      assert_equal 0, Poster.new(@family).run!
    end
  end

  test "does not post before the due date" do
    occurrence_due(3.days.from_now.to_date)

    assert_equal 0, Poster.new(@family).run!
  end

  test "posts an approved future occurrence only once its date arrives" do
    @family.update!(recurring_auto_post_enabled: false)
    occurrence = occurrence_due(2.days.from_now.to_date)
    occurrence.approve_auto_post!

    assert_equal 0, Poster.new(@family).run!, "approval does not post early"

    travel_to 2.days.from_now do
      assert_equal 1, Poster.new(@family).run!
    end
  end

  test "does not post beyond the lookback window" do
    occurrence_due((Poster::LOOKBACK_DAYS + 1).days.ago.to_date)

    assert_equal 0, Poster.new(@family).run!
  end

  test "does not post a snoozed occurrence until its snooze expires" do
    occurrence_due(Date.current, snoozed_until: 3.days.from_now.to_date)

    assert_equal 0, Poster.new(@family).run!
  end

  test "does not post an occurrence that already carries a payment" do
    occurrence = occurrence_due(Date.current)
    occurrence.allocations.create!(allocated_amount: 5, currency: "USD", source: "user_created", state: "suggested")

    assert_equal 0, Poster.new(@family).run!
  end

  test "does not post on a provider-linked account" do
    @series.update!(account: accounts(:connected))
    occurrence_due(Date.current)

    assert_equal 0, Poster.new(@family).run!
  end

  test "does not post a series that opted out explicitly" do
    @series.update!(auto_post: false)
    occurrence_due(Date.current)

    assert_equal 0, Poster.new(@family).run!, "an explicit opt-out beats the family default"
  end

  test "posts a series that opted in while the family default is off" do
    @family.update!(recurring_auto_post_enabled: false)
    @series.update!(auto_post: true)
    occurrence_due(Date.current)

    assert_equal 1, Poster.new(@family).run!
  end

  test "does not post when neither the series nor the family opted in" do
    @family.update!(recurring_auto_post_enabled: false)
    occurrence_due(Date.current)

    assert_equal 0, Poster.new(@family).run!
  end

  test "does not post a paused series" do
    # Paused first: `status` reshapes the occurrence stream, so pausing after
    # building the row would delete it and the test would pass for the wrong
    # reason -- no occurrence at all, rather than a series that must not post.
    @series.update!(status: "paused")
    occurrence_due(Date.current)

    assert_equal 0, Poster.new(@family).run!
  end

  test "does not post when the family switched recurring transactions off" do
    occurrence_due(Date.current)
    @family.update!(recurring_transactions_disabled: true)

    assert_equal 0, Poster.new(@family).run!
  end

  test "post_occurrence! posts a due row whose series never opted in" do
    @family.update!(recurring_auto_post_enabled: false)
    occurrence = occurrence_due(Date.current)

    entry = Poster.new(@family).post_occurrence!(occurrence)

    assert_equal Date.current, entry.date
    assert occurrence.reload.paid?, "clicking the button is itself the opt-in"
  end

  test "post_occurrence! posts a row older than the sweep's lookback" do
    occurrence = occurrence_due((Poster::LOOKBACK_DAYS + 30).days.ago.to_date)

    assert_nothing_raised { Poster.new(@family).post_occurrence!(occurrence) }
    assert occurrence.reload.paid?
  end

  test "post_occurrence! refuses a future occurrence" do
    occurrence = occurrence_due(3.days.from_now.to_date)

    error = assert_raises(Poster::NotPostable) do
      Poster.new(@family).post_occurrence!(occurrence)
    end

    assert_equal :not_due, error.reason
  end

  test "post_occurrence! refuses a linked account" do
    @series.update!(account: accounts(:connected))
    occurrence = occurrence_due(Date.current)

    error = assert_raises(Poster::NotPostable) do
      Poster.new(@family).post_occurrence!(occurrence)
    end

    assert_equal :not_postable_shape, error.reason
  end

  test "post_occurrence! refuses a cycle that already carries a payment" do
    occurrence = occurrence_due(Date.current)
    occurrence.allocations.create!(allocated_amount: 5, currency: "USD", source: "user_created", state: "suggested")

    error = assert_raises(Poster::NotPostable) do
      Poster.new(@family).post_occurrence!(occurrence)
    end

    assert_equal :already_paid, error.reason
  end
end
