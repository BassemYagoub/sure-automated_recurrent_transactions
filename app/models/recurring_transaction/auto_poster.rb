class RecurringTransaction
  # Turns a due occurrence into a real Transaction entry and settles the
  # occurrence with it. The one place that does so, shared by the nightly job
  # and the Upcoming tab's "post now" button, so the two can never disagree
  # about what is eligible or what the resulting entry looks like.
  #
  # Nothing is ever written ahead of its date: an entry is created on or after
  # the occurrence's due date, never before. That is not a detail -- the app
  # refuses future dates on hand-entered transactions, and an entry dated in the
  # future would drag the account's displayed balance with it, because
  # Balance::ForwardCalculator runs the series out to the newest entry date and
  # Balance::Materializer reads the newest balance row as "current".
  #
  # A future cycle the user wants posted is approved instead (see
  # RecurringOccurrence#approve_auto_post!), and this class picks the approval
  # up when the date arrives.
  class AutoPoster
    # Raised when a caller asks for an occurrence this class will not post.
    # The sweep never sees it -- it filters first -- but the button path needs
    # to tell the user why nothing happened, so the reason travels as a symbol
    # rather than as prose the controller would have to match on.
    class NotPostable < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason.to_s)
      end
    end

    # How far back the sweep will reach. Without a bound, switching the feature
    # on would post every open cycle the family ever accumulated in one run.
    # A deliberate click is not bounded this way: see post_occurrence!.
    LOOKBACK_DAYS = 7

    ALLOCATION_SOURCE = "auto_posted".freeze

    attr_reader :family

    def initialize(family)
      @family = family
    end

    # The nightly sweep. Returns how many entries were posted.
    def run!
      return 0 if family.nil? || family.recurring_transactions_disabled?

      due_occurrences.count { |occurrence| post_quietly(occurrence) }
    end

    # The button path. Posts one occurrence the user picked out, whatever its
    # series' toggle says -- clicking it IS the opt-in -- and without the
    # sweep's lookback, since an old cycle someone deliberately settles is not
    # the backlog that bound exists to prevent.
    #
    # Returns the created Entry. Raises NotPostable when the row is not
    # something this class will write.
    def post_occurrence!(occurrence)
      series = occurrence.recurring_transaction

      raise NotPostable.new(:not_open) unless occurrence.scheduled?
      raise NotPostable.new(:not_due) unless occurrence.postable_now?
      raise NotPostable.new(:already_paid) if occurrence.allocations.any?
      raise NotPostable.new(:series_inactive) unless series.active?
      raise NotPostable.new(:not_postable_shape) unless series.auto_postable_shape?
      raise NotPostable.new(:no_amount) unless postable_amount?(occurrence, series)
      raise NotPostable.new(:no_name) if entry_name(series).blank?

      post!(occurrence)
    end

    private
      # Deliberately loads the window and filters in Ruby. The window is a week
      # of one family's occurrences -- a handful of rows -- and eligibility asks
      # questions (snooze, the three-state toggle, approval, existing payments)
      # that are far clearer here than as a merged multi-join.
      def due_occurrences
        family.recurring_occurrences
              .open_status
              .where(due_on: (Date.current - LOOKBACK_DAYS)..Date.current)
              # :family because auto_post_enabled? falls through to the family
              # default; :account_providers because auto_postable_shape? asks
              # Account#manual?, which counts them.
              .includes(:allocations, recurring_transaction: [ :family, { account: :account_providers } ])
              .select { |occurrence| eligible?(occurrence) }
      end

      def eligible?(occurrence)
        series = occurrence.recurring_transaction

        return false unless series.active?
        return false unless series.auto_postable_shape?
        # The series toggle and a one-off approval are two doors into the same
        # room: either is enough.
        return false unless series.auto_post_enabled? || occurrence.auto_post_approved?
        return false unless occurrence.postable_now?
        # A payment already on the row means a real charge is in play, matched
        # or suggested. Posting beside it would double-count the bill.
        return false if occurrence.allocations.any?
        return false unless postable_amount?(occurrence, series)
        return false if entry_name(series).blank?

        true
      end

      # A zero expected amount can never close its occurrence (Allocator's
      # close_worthy? asks for a positive amount), so posting one would leave a
      # row open forever and re-propose itself on every run.
      def postable_amount?(occurrence, series)
        occurrence.resolved_expected_amount(series_amount: series.amount).positive?
      end

      def post_quietly(occurrence)
        post!(occurrence)
        true
      rescue ActiveRecord::RecordNotUnique
        # A previous run already posted this occurrence; the entry's
        # idempotency key is what said so.
        false
      rescue Allocator::OverAllocationError, Allocator::MissingRateError,
             ActiveRecord::RecordInvalid => e
        Rails.logger.error(
          "AutoPoster skipped occurrence #{occurrence.id} for family #{family.id}: #{e.message}"
        )
        false
      end

      def post!(occurrence)
        series = occurrence.recurring_transaction

        entry = ActiveRecord::Base.transaction do
          new_entry = series.account.entries.create!(
            name: entry_name(series),
            date: occurrence.effective_due_on,
            amount: occurrence.signed_expected_amount,
            currency: occurrence.currency,
            idempotency_key: idempotency_key_for(occurrence),
            entryable: Transaction.new(category: series.category, merchant: series.merchant)
          )

          # Same protection a hand-entered transaction gets, so nothing
          # downstream mistakes this for a provider-owned row.
          new_entry.lock_saved_attributes!
          new_entry.mark_user_modified!

          # The only supported way to record a payment: it freezes the expected
          # amount and closes the occurrence as paid.
          Allocator.new(occurrence).allocate!(entry: new_entry, source: ALLOCATION_SOURCE)

          new_entry
        end

        # Outside the transaction: the job must not be able to run against a
        # state that has not committed yet.
        entry.sync_account_later
        entry
      end

      def entry_name(series)
        series.display_name
      end

      # Deterministic, so a concurrent second run collides on the partial unique
      # index over (account_id, idempotency_key) instead of writing the bill
      # twice. This is the last of three guards -- the occurrence leaves
      # open_status once allocated, and eligible? rejects a row that already
      # carries a payment -- and the only one that holds across processes.
      def idempotency_key_for(occurrence)
        "recurring_occurrence:#{occurrence.id}"
      end
  end
end
