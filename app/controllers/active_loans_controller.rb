class ActiveLoansController < ApplicationController
  require 'check_accounts'
  require 'check_login'
  before_action :require_login
  before_action :require_admin, only: [:approve]
  before_action :validate_active_loan_status, only: [:index, :my_index, :my_investments]

  VALID_ACTIVE_LOAN_STATUSES = ["unfunded", "funded", "settled", "defaulted"]

  def index
    @status = params[:status]

    @start = params[:start].to_i
    @finish = params[:finish].to_i

    @active_loans = (ActiveLoan.where(status: params[:status]).where.not(user_id: current_user.id))[@start..@finish]

    @total_count = (ActiveLoan.where(status: params[:status]).where.not(user_id: current_user.id)).count

    render layout: "portfolios"
  end

  def my_index
    @status = params[:status]
    
    @active_loans = ActiveLoan.where(user_id: current_user.id).where(status: params[:status])

    render layout: "portfolios"
  end

  def my_investments
    all_currnet_users_investments = Investment.where(user_id: current_user.id)
    @status = params[:status]
    @investments_by_status = []
    dummy_count = 0
    all_currnet_users_investments.each do |investment|
      if investment.active_loan.status == params[:status]
        @investments_by_status.push(investment)
      else
        dummy_count += 1
      end
    end

    
    
    render layout: "portfolios"
  end

  def approve
    loan = LoanApplication.find(params[:id])

    annual_basis_points = rand(600..900)

    ActiveLoan.create!([
      {
        user_id: loan.user_id,
        status: "unfunded",
        opening_balance: loan.loan_amount,
        loan_term: loan.loan_term,
        purpose: loan.purpose,
        category: LoanCategory.find(loan.loan_category_id).label,
        interest_rate: (annual_basis_points.to_f / 100).round(2),
        periodic_repayment_amount: calculate_monthly_repayment(loan.loan_amount, loan.loan_term, annual_basis_points).round(2),
        repayment_capacity: (loan.weekly_income - loan.weekly_expenses),
        employment_type: EmploymentType.find(loan.employment_type_id).label,
        work_gap_months: loan.work_gap_months
      }
    ])

    if loan.update(status: "assessed")
      redirect_to awaiting_assessment_path, notice: 'Loan application successfully approved. It is now live.'
    else
      redirect_to awaiting_assessment_path, notice: 'Error please try again.'
    end

  end

  def show
    begin
      @active_loan = ActiveLoan.find(params[:id])

      is_borrower = @active_loan.user_id == current_user.id
      is_investor = Investment.exists?(active_loan_id: @active_loan.id, user_id: current_user.id)

      unless is_borrower || is_investor
        redirect_to root_path, notice: 'You are not authorized to view this loan.'
        return
      end

      render layout: "portfolios"
    rescue ActiveRecord::RecordNotFound
      redirect_to root_path, notice: 'Loan not found.'
    end
  end

  def invest
    begin
      @active_loan = ActiveLoan.find(params[:id].to_i)
    rescue ActiveRecord::RecordNotFound
      redirect_to root_path, notice: 'Loan not found.'
      return
    end

    if current_user.id == @active_loan.user_id
      redirect_to root_path, notice: 'You cannot invest in your own loan.'
      return
    end

    if @active_loan.status != 'unfunded'
      redirect_to root_path, notice: 'This loan is not currently accepting investments.'
      return
    end

    investment_amount = (params[:investment_amount].to_f * 100)

    # Checks if the user has enough money in their Cash account to invest
    if (retrieve_balance(account_id("Cash")).to_f ) >= investment_amount
      
      # Checks if the new investment amount pushes the loan to become fully funded      
      # Calculate total invested in the loan so far
      amount_invested_so_far = 0.0
      relevant_investment_records = Investment.where(active_loan_id: @active_loan.id)
      relevant_investment_records.each do |investment_record|
        amount_invested_so_far += investment_record.opening_balance.to_f
      end

      
      
      # If the new investment amount pushes the loan to become over funded, tells them so
      if (amount_invested_so_far + investment_amount) > @active_loan.opening_balance.to_f
        redirect_to root_path, notice: "The borrower doesn't need that much. Please invest a lower amount"
        # redirect_to show_active_loan_path(id: @active_loan.id), notice: "The borrower doesn't need that much. Please invest a lower amount"
        
      # Elsif the new investment amount pushes the loan to become 100% funded, execute required Logic
      elsif (amount_invested_so_far + investment_amount) == @active_loan.opening_balance.to_f
        # Calculate the investor's share of borrower's monthly repayment obligation 
        percentage_of_loan_amount = (investment_amount * 100) / (@active_loan.opening_balance.to_f)
        repayment_amount = ((@active_loan.periodic_repayment_amount.to_f * percentage_of_loan_amount)).round(2)
        
        # Logic to create an investment record
        investment_details = ({
          active_loan_id: @active_loan.id,
          user_id: current_user.id,
          opening_balance: investment_amount,
          repayment_amount: repayment_amount,
        })

        # Logic to transfer cash from cash account to pending investment
        investor_transaction_details = ({
          amount: investment_amount,
          from_account_id: Account.where(user_id: current_user.id).where(label: "Cash").first.id,
          to_account_id: Account.where(user_id: current_user.id).where(label: "Pending investments").first.id,
          from_account_balance: (retrieve_balance(account_id("Cash")).to_i - (investment_amount.to_i)),
          to_account_balance: (retrieve_balance(account_id("Pending investments")).to_i + (investment_amount.to_i)), 
          transaction_type: "principal"
        })
        
        if Investment.create!(investment_details) && Transaction.create!(investor_transaction_details) && 
          # Changes status of loan from unfunded to funded
          investments = Investment.where(active_loan_id: @active_loan.id)

          # Create the transactions to move outstanding lonas into the cash account for the borrower
          lender_user_id = @active_loan.user_id
          loan_amount = @active_loan.opening_balance
          lender_outstanding_loans_account_id = Account.where(user_id: lender_user_id).where(label: "Outstanding loans").first.id
          lender_cash_account_id = Account.where(user_id: lender_user_id).where(label: "Cash").first.id
          lender_transaction_details = ({
          amount: loan_amount,
          from_account_id: lender_outstanding_loans_account_id,
          to_account_id: lender_cash_account_id,
          from_account_balance: (retrieve_balance(lender_outstanding_loans_account_id).to_i - loan_amount),
          to_account_balance: (retrieve_balance(lender_cash_account_id).to_i + loan_amount), 
          transaction_type: "principal"
          })
          Transaction.create!(lender_transaction_details)

          # Create the transactions to move pending investments into active investments for all investors
          investments.each do |investment|
          user_id = investment.user_id
          pending_investments_account_id = Account.where(user_id: investment.user_id).where(label: "Pending investments").first.id
          active_investments_account_id = Account.where(user_id: investment.user_id).where(label: "Active investments").first.id
          Transaction.create!([
            {
              amount: investment.opening_balance,
              from_account_id: pending_investments_account_id,
              to_account_id: active_investments_account_id,
              from_account_balance: (retrieve_balance(pending_investments_account_id).to_i - (investment.opening_balance)),
              to_account_balance: (retrieve_balance(active_investments_account_id).to_i + (investment.opening_balance)),
              transaction_type: "principal"
            }
          ])
          end

          @active_loan.update(status: "funded")
          redirect_to root_path, notice: "You have invested $#{investment_amount / 100} to active loan #{@active_loan.id}!" 
        else
          redirect_to root_path, notice: "Something went wrong. Please try again."
          # redirect_to show_active_loan_path(id: @active_loan.id), notice: "Something went wrong. Please try again."
        end

        # Elsif the new investment amount doesn't pushes the loan to become 100% funded, execute required Logic
      elsif (amount_invested_so_far + investment_amount) < @active_loan.opening_balance.to_f
        # Calculate the investor's share of borrower's monthly repayment obligation 
        percentage_of_loan_amount = (investment_amount * 100) / (@active_loan.opening_balance.to_f)
        repayment_amount = ((@active_loan.periodic_repayment_amount.to_f * percentage_of_loan_amount)).round(2)
        
        # Logic to create an investment record
        investment_details = ({
          active_loan_id: @active_loan.id,
          user_id: current_user.id,
          opening_balance: investment_amount,
          repayment_amount: repayment_amount,
          })

        # Logic to transfer cash from cash account to pending investment
        transaction_details = ({
          amount: investment_amount,
          from_account_id: Account.where(user_id: current_user.id).where(label: "Cash").first.id,
          to_account_id: Account.where(user_id: current_user.id).where(label: "Pending investments").first.id,
          from_account_balance: (retrieve_balance(account_id("Cash")).to_i - (investment_amount.to_i)),
          to_account_balance: (retrieve_balance(account_id("Pending investments")).to_i + (investment_amount.to_i)), 
          transaction_type: "principal"
        })

        if Investment.create!(investment_details) && Transaction.create!(transaction_details)
          redirect_to root_path, notice: "You have committed $#{investment_amount / 100} to active loan #{@active_loan.id}!" 
        else
          redirect_to root_path, notice: "Something went wrong. Please try again."
          # redirect_to show_active_loan_path(id: @active_loan.id), notice: "Something went wrong. Please try again."
        end

      end
      
    else
      redirect_to root_path, notice: "You do not have enough in your Cash account to commit $#{investment_amount / 100} for investment."
    end

  end

  def repay_loan_confirmation
    @active_loan = ActiveLoan.find_by(id: params[:id])

    unless @active_loan
      redirect_to root_path, notice: 'Loan not found.'
      return
    end

    if @active_loan.user_id != current_user.id
      redirect_to root_path, notice: 'You are not authorized to repay this loan.'
      return
    end

    if @active_loan.status == 'settled'
      redirect_to root_path, notice: 'This loan is already settled.'
      return
    end

    repayment_amount_str = params[:repayment_amount]
    repayment_amount_in_cents = nil

    begin
      repayment_amount_in_cents = (Float(repayment_amount_str) * 100).to_i
    rescue ArgumentError, TypeError
      flash[:error] = "Invalid amount entered: '#{repayment_amount_str}'. Please enter a valid number."
      redirect_to show_active_loan_path(@active_loan) # Or appropriate path
      return
    end

    if repayment_amount_in_cents <= 0
      flash[:error] = "Repayment amount must be positive."
      redirect_to show_active_loan_path(@active_loan) # Or appropriate path
      return
    end

    ActiveRecord::Base.transaction do
      @active_loan.lock! # Lock the loan record

      borrower_cash_account = current_user.accounts.find_by!(label: "Cash") # Assuming find_by! to raise error if not found
      borrower_cash_account.lock! # Lock borrower's cash account

      borrower_cash_balance_in_cents = retrieve_balance(borrower_cash_account.id)

      if borrower_cash_balance_in_cents < repayment_amount_in_cents
        redirect_to show_active_loan_path(@active_loan), notice: "Insufficient funds to make this repayment."
        raise ActiveRecord::Rollback # Rollback transaction
      end

      amount_repaid_so_far_in_cents = Repayment.where(active_loan_id: @active_loan.id).sum(:amount)

      if (amount_repaid_so_far_in_cents + repayment_amount_in_cents) > @active_loan.opening_balance
        redirect_to show_active_loan_path(@active_loan), notice: "This repayment would exceed the loan's outstanding balance. Please enter a lower amount."
        raise ActiveRecord::Rollback
      end

      # Borrower's transaction: Cash to Outstanding Loans
      borrower_outstanding_loans_account = current_user.accounts.find_by!(label: "Outstanding loans")
      # No need to lock borrower_outstanding_loans_account if its balance isn't critical for a check here,
      # but its balance will be updated.
      borrower_outstanding_loans_balance_in_cents = retrieve_balance(borrower_outstanding_loans_account.id)

      Transaction.create!(
        amount: repayment_amount_in_cents,
        from_account_id: borrower_cash_account.id,
        to_account_id: borrower_outstanding_loans_account.id,
        from_account_balance: borrower_cash_balance_in_cents - repayment_amount_in_cents,
        to_account_balance: borrower_outstanding_loans_balance_in_cents + repayment_amount_in_cents,
        transaction_type: "principal",
        description: "Loan repayment by borrower for loan ##{@active_loan.id}"
      )

      # Distribute repayment to investors
      investments = Investment.where(active_loan_id: @active_loan.id)
      total_investment_amount = @active_loan.opening_balance # Assuming this is the total principal invested by all

      # Simplified proportional distribution - acknowledge potential for penny issues
      # For more complex scenarios, a more robust distribution algorithm is needed.
      investments.each do |investment|
        investment.lock! # Lock each investment

        investor = investment.user # User.find(investment.user_id)
        investor_active_investments_account = investor.accounts.find_by!(label: "Active investments")
        investor_active_investments_account.lock!
        investor_cash_account = investor.accounts.find_by!(label: "Cash")
        investor_cash_account.lock!

        # Calculate this investor's share of the repayment
        # Using integer math for cents to avoid floating point issues as much as possible.
        # (investment_principal / total_loan_principal) * repayment_amount
        # Ensure all these are in cents
        individual_repayment_in_cents = (investment.opening_balance.to_f / total_investment_amount.to_f * repayment_amount_in_cents).round.to_i
        
        # Ensure individual_repayment_in_cents is not zero if there's a tiny share
        # This logic might need refinement for edge cases (e.g. very small repayments or investments)
        if individual_repayment_in_cents > 0
          Repayment.create!(
            active_loan_id: @active_loan.id,
            investment_id: investment.id,
            amount: individual_repayment_in_cents
          )

          current_investor_active_inv_balance = retrieve_balance(investor_active_investments_account.id)
          current_investor_cash_balance = retrieve_balance(investor_cash_account.id)

          Transaction.create!(
            amount: individual_repayment_in_cents,
            from_account_id: investor_active_investments_account.id,
            to_account_id: investor_cash_account.id,
            from_account_balance: current_investor_active_inv_balance - individual_repayment_in_cents,
            to_account_balance: current_investor_cash_balance + individual_repayment_in_cents,
            transaction_type: "principal",
            description: "Repayment received for investment in loan ##{@active_loan.id}"
          )
        end
      end
      
      new_total_repaid_so_far_in_cents = amount_repaid_so_far_in_cents + repayment_amount_in_cents
      final_notice_message = "You have successfully repaid $#{repayment_amount_str} for Loan ID: #{@active_loan.id}."

      if new_total_repaid_so_far_in_cents >= @active_loan.opening_balance
        # Ensure it doesn't exceed opening balance due to rounding, cap it.
        # This should ideally be handled by precise distribution logic.
        # For now, if it's very close, assume it's settled.
        @active_loan.status = "settled"
        @active_loan.save! # Save the change in loan status
        final_notice_message += " This loan is now fully settled."
      end

      redirect_to root_path, notice: final_notice_message

    end # End of ActiveRecord::Base.transaction
  rescue ActiveRecord::RecordNotFound => e
    # This can happen if find_by! fails for accounts
    flash[:error] = "Required account not found: #{e.message}"
    redirect_to show_active_loan_path(@active_loan || params[:id]) # Redirect back
  rescue ActiveRecord::RecordInvalid => e
    flash[:error] = "Repayment failed due to validation errors: #{e.message}"
    redirect_to show_active_loan_path(@active_loan || params[:id])
  rescue StandardError => e
    Rails.logger.error "Repay Loan Confirmation Error: #{e.message}\n#{e.backtrace.join("\n")}"
    flash[:error] = "An unexpected error occurred during repayment. Please try again."
    redirect_to show_active_loan_path(@active_loan || params[:id])
  end

  private

  def require_admin
    unless current_user.is_admin?
      redirect_to root_path, notice: 'You are not authorized to perform this action.'
    end
  end

  def validate_active_loan_status
    if params[:status].present? && !VALID_ACTIVE_LOAN_STATUSES.include?(params[:status])
      # Determine the appropriate redirect path based on the action
      # For simplicity, redirecting to root_path if the action isn't immediately clear for a default
      default_path = case action_name
                     when 'index'
                       active_loans_path(status: "unfunded") # Or a more general path if preferred
                     when 'my_index'
                       my_loans_path(status: "unfunded") # Assuming this is the correct helper
                     when 'my_investments'
                       my_investments_path(status: "funded") # Assuming this is the correct helper
                     else
                       root_path # Fallback
                     end
      redirect_to default_path, notice: 'Invalid status provided.'
    end
  end
end