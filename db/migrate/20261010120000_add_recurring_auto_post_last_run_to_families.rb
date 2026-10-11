class AddRecurringAutoPostLastRunToFamilies < ActiveRecord::Migration[8.1]
  # When the daily auto-post run last completed for the family. A run that a
  # stopped server missed is detected from it and caught up at the next check,
  # posting every cycle due since this moment.
  def change
    add_column :families, :recurring_auto_post_last_run_at, :datetime
  end
end
