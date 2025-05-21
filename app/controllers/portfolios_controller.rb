class PortfoliosController < ApplicationController
  require 'check_accounts'
  require 'check_login'  
  require 'check_user'
  before_action :require_login
  before_action :check_account_ids, only: [:account_history]
  
  # Home page for all users that are logged in
  def all

    # Checks existing transactions and retrieve the user's account balances that need to be displayed 
    @cash_balance = retrieve_balance(account_id("Cash"))/100
    @cash_account_id = account_id("Cash")

    @active_investments_balance = retrieve_balance(account_id("Active investments"))/100
    @active_investments_acocunt_id = account_id("Active investments")

    @pending_investments_balance = retrieve_balance(account_id("Pending investments"))/100
    @pending_investments_account_id = account_id("Pending investments")

    @distressed_investments_exists = transactions_exist("Distressed investments")
    @distressed_investments = retrieve_balance(account_id("Distressed investments"))/100
    @distressed_investments_account_id = account_id("Distressed investments")

    @outstanding_loans = retrieve_balance(account_id("Outstanding loans"))/100
    @outstanding_loans_account_id = account_id("Outstanding loans")

    @defaulted_loans_exists = transactions_exist("Defaulted loans")
    @defaulted_loans = retrieve_balance(account_id("Defaulted loans"))/100
    @defaulted_loans_account_id = account_id("Defaulted loans")

    # Render layout from views/layouts/portfolios.html.erb
    render layout: "portfolios"
  end

  def add_cash

    render layout: "portfolios"
  end

  def withdraw_cash

    render layout: "portfolios"
  end

  def withdraw_confirmation
    raw_amount = params[:amount]
    amount_in_cents = nil

    begin
      # Attempt to convert to float first to handle decimal inputs, then to cents
      amount_in_cents = (Float(raw_amount) * 100).to_i
    rescue ArgumentError, TypeError
      flash[:error] = "Invalid amount entered. Please enter a valid number."
      redirect_to withdraw_cash_path
      return
    end

    if amount_in_cents <= 0
      flash[:error] = "Withdrawal amount must be positive."
      redirect_to withdraw_cash_path
      return
    end

    ActiveRecord::Base.transaction do
      cash_account = current_user.accounts.find_by(label: "Cash")
      unless cash_account
        flash[:error] = 'Cash account not found.'
        redirect_to withdraw_cash_path # Or root_path, depending on desired UX
        raise ActiveRecord::Rollback # Ensure transaction is rolled back
      end

      # Lock the cash account row to prevent race conditions
      cash_account.lock!

      # Retrieve the current balance *after* locking
      # Assuming retrieve_balance takes an account ID and returns balance in cents
      current_cash_balance_in_cents = retrieve_balance(cash_account.id)

      if amount_in_cents <= current_cash_balance_in_cents
        bank_account = current_user.accounts.find_by(label: "Bank account")
        unless bank_account
          flash[:error] = 'Bank account not found for withdrawal.'
          redirect_to withdraw_cash_path
          raise ActiveRecord::Rollback
        end

        # For simplicity, not locking bank_account here, but could be done if necessary
        current_bank_balance_in_cents = retrieve_balance(bank_account.id)

        Transaction.create!(
          amount: amount_in_cents,
          from_account_id: cash_account.id,
          to_account_id: bank_account.id,
          from_account_balance: current_cash_balance_in_cents - amount_in_cents,
          to_account_balance: current_bank_balance_in_cents + amount_in_cents,
          transaction_type: "principal",
          description: "Withdrawal to bank account" # Optional: add description
        )
        # Use raw_amount for user-facing notice to show their original input
        redirect_to root_path, notice: "You have successfully withdrawn $#{raw_amount}."
      else
        # Use raw_amount for user-facing notice
        redirect_to withdraw_cash_path, notice: "You do not have enough cash in your account to withdraw $#{raw_amount}."
        # No need to raise ActiveRecord::Rollback here as it's a read operation that failed the check
      end
    end
  rescue ActiveRecord::RecordInvalid => e
    # This can happen if Transaction.create! fails validation
    flash[:error] = "Withdrawal failed: #{e.message}"
    redirect_to withdraw_cash_path
  rescue StandardError => e
    # Catch other potential errors during the transaction
    flash[:error] = "An unexpected error occurred during withdrawal. Please try again."
    Rails.logger.error "Withdrawal Error: #{e.message}\n#{e.backtrace.join("\n")}"
    redirect_to withdraw_cash_path
  end


  def account_history
    @acc_id = params[:id]
    unordered_transactions = Transaction.where(from_account_id: params[:id]).or(Transaction.where(to_account_id: params[:id]))
    @transactions = unordered_transactions.order('created_at DESC')

    @acc_name = Account.find(params[:id]).label
    render layout: "portfolios"
  end

  def my_loan_applications
    
    
    render layout: "portfolios"
  end

end
