# One expected instance of a recurring obligation: the August rent, this
# month's electric bill. Holds what is specific to the instance (due date,
# amount override, skip/snooze, payments via allocations); the rest inherits
# from the series.
#
# Stored status is minimal -- scheduled, plus the terminal paid / skipped /
# missed. Upcoming, due, overdue and partially paid all derive from dates and
# allocation sums, so they cannot drift stale. `missed` is only ever set by the
# user.
class RecurringOccurrence < ApplicationRecord
  include Monetizable

  # App defaults when the series leaves its per-bill knobs NULL.
  DEFAULT_NOTIFY_DAYS = 3
  DEFAULT_GRACE_DAYS = 3

  # Rounding epsilon for accumulation close: payments summing to within a
  # cent of the expected amount count as full payment.
  CLOSE_EPSILON = BigDecimal("0.01")

  belongs_to :recurring_transaction
  belongs_to :family
  has_many :allocations, class_name: "RecurringAllocation",
           foreign_key: :recurring_occurrence_id, dependent: :destroy, inverse_of: :recurring_occurrence

  monetize :expected_amount, allow_nil: true

  enum :status, { scheduled: "scheduled", paid: "paid", skipped: "skipped", missed: "missed" }

  validates :original_due_on, :due_on, :currency, presence: true
  validates :expected_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :open_status, -> { where(status: :scheduled) }
  scope :closed, -> { where.not(status: :scheduled) }
  scope :due_between, ->(from, to) { where(due_on: from..to) }
  scope :auto_post_approved, -> { where.not(auto_post_approved_at: nil) }

  # The amount this occurrence expects, resolving NULL through the series'
  # amount strategy, which is what lets a price edit update every open
  # occurrence with no sweep. `series_amount` overrides what the series says it
  # costs now, so a price change can pin what a row claimed before the edit.
  def resolved_expected_amount(series_amount: nil)
    return expected_amount if expected_amount.present?

    series = recurring_transaction
    fallback = series_amount || series.amount

    case series.amount_strategy
    when "average"
      series.expected_amount_avg.presence || fallback
    when "last"
      last_paid_total.presence || fallback
    else
      fallback
    end.abs
  end

  def resolved_expected_amount_money
    Money.new(resolved_expected_amount, currency)
  end

  # The amount as a ledger entry would carry it: the positive magnitude above,
  # re-signed from the series, because Sure records an inflow as a negative
  # amount. One definition, shared by the poster that writes the entry and the
  # Upcoming tab that previews it, so the two can never disagree about sign.
  def signed_expected_amount
    series = recurring_transaction
    magnitude = resolved_expected_amount(series_amount: series.amount)

    series.amount.negative? ? -magnitude : magnitude
  end

  def signed_expected_amount_money
    Money.new(signed_expected_amount, currency)
  end

  # Snoozing postpones the presentation-level due date without rewriting the
  # schedule.
  def effective_due_on
    [ due_on, snoozed_until ].compact.max
  end

  # List views preload allocation sums in one grouped query and inject them
  # here, so row rendering issues no per-occurrence SUM.
  attr_writer :cached_confirmed_allocated

  def confirmed_allocated
    @cached_confirmed_allocated || allocations.confirmed.sum(:allocated_amount)
  end

  def confirmed_allocated_money
    Money.new(confirmed_allocated, currency)
  end

  def remaining_amount
    [ resolved_expected_amount - confirmed_allocated, 0 ].max
  end

  def remaining_amount_money
    Money.new(remaining_amount, currency)
  end

  # Exact sum, not tolerance: $1,850 allocated against $2,000 rent is
  # partially paid with $150 remaining, always.
  def partially_paid?
    scheduled? && confirmed_allocated.positive? && confirmed_allocated < resolved_expected_amount
  end

  def overpaid?
    confirmed_allocated > resolved_expected_amount + CLOSE_EPSILON
  end

  # Presentation state for open occurrences: upcoming until the notify
  # window, due through the grace period, overdue after it.
  def derived_state
    return status.to_sym unless scheduled?

    today = Date.current

    if today > effective_due_on + grace_days
      :overdue
    elsif today >= effective_due_on - notify_days
      :due
    else
      :upcoming
    end
  end

  def overdue?
    derived_state == :overdue
  end

  # --- Lifecycle actions. Closing freezes the resolved amount so the row is
  # self-contained history; reopening keeps that value as an explicit override
  # rather than un-freezing it. ---

  def close!(new_status, source:)
    update!(
      status: new_status,
      expected_amount: resolved_expected_amount,
      closed_at: Time.current,
      closed_source: source
    )
  end

  def skip!(source: "user")
    close!("skipped", source: source)
  end

  def miss!
    close!("missed", source: "user")
  end

  def reopen!
    update!(status: "scheduled", closed_at: nil, closed_source: nil)
  end

  def snooze!(until_date)
    update!(snoozed_until: until_date)
  end

  # --- Auto-post approval. Clearing one future cycle to post on its due date,
  # independently of whether its series auto-posts. Nothing is written to the
  # ledger here: the poster acts on the stamp when the date arrives. ---

  def auto_post_approved?
    auto_post_approved_at.present?
  end

  def approve_auto_post!
    update!(auto_post_approved_at: Time.current)
  end

  def unapprove_auto_post!
    update!(auto_post_approved_at: nil)
  end

  # Whether the poster would act on this row today, which is also what decides
  # whether the Upcoming tab offers "post now" or "approve". Snooze-aware,
  # because a snoozed occurrence is not due however old its `due_on` is.
  def postable_now?
    scheduled? && effective_due_on <= Date.current
  end

  # The primary action the Upcoming tab should offer for this row. Derived here
  # rather than in the view so the template stays free of the sign, snooze and
  # toggle rules behind it.
  #
  #   :post      -- due now; write the entry
  #   :approve   -- still future; clear it to post on its own date
  #   :unapprove -- still future and already cleared
  #   :automatic -- the series posts by itself, nothing to decide
  #   nil        -- this surface has no action to offer
  #
  # A row that is due wins over :automatic on purpose: the nightly run may be
  # hours away, and "post it now" is a reasonable thing to want in the meantime.
  # Posting closes the occurrence, so the later run simply finds nothing.
  def auto_post_action
    return nil unless scheduled?
    return nil unless recurring_transaction.auto_postable_shape?
    # A payment already on the row means a real charge is in play, matched or
    # merely suggested. Offering to post beside it would double-count the bill.
    return nil if allocations.any?

    if postable_now?
      :post
    elsif recurring_transaction.auto_post_enabled?
      :automatic
    elsif auto_post_approved?
      :unapprove
    else
      :approve
    end
  end

  def override_amount!(amount)
    update!(expected_amount: amount.presence)
  end

  private
    def notify_days
      recurring_transaction.notify_days_before || DEFAULT_NOTIFY_DAYS
    end

    def grace_days
      recurring_transaction.overdue_grace_days || DEFAULT_GRACE_DAYS
    end

    # What the last settled cycle actually cost. `expected_amount` on a closed
    # row is the frozen estimate, so reading it would re-propose the guess and
    # strategy could never converge on a variable bill's real amount.
    # Memoized: every amount label on a row asks this same question.
    def last_paid_total
      return @last_paid_total if defined?(@last_paid_total)

      @last_paid_total = begin
        previous = recurring_transaction.recurring_occurrences
                                        .paid
                                        .where("due_on < ?", due_on)
                                        .order(due_on: :desc)
                                        .first
        if previous
          total = previous.allocations.confirmed.sum(:allocated_amount)
          total.positive? ? total : nil
        end
      end
    end
end
