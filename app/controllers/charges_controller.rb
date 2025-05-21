class ChargesController < ApplicationController
  require 'check_accounts'
  require 'check_login'
  before_action :require_login

  def new
    @amount = params[:amount]

    render layout: "portfolios"
  end
  
  def create
    # Amount from params, converted to float for validation
    amount_from_params = params[:amount].to_f
    min_amount = 5.00
    max_amount = 1000.00

    # Validate the amount
    if amount_from_params < min_amount
      flash[:error] = "Amount must be at least $#{sprintf('%.2f', min_amount)}."
      redirect_to new_charge_path(amount: params[:amount]) # Pass amount back to prefill
      return
    elsif amount_from_params > max_amount
      flash[:error] = "Amount must be no more than $#{sprintf('%.2f', max_amount)}."
      redirect_to new_charge_path(amount: params[:amount]) # Pass amount back to prefill
      return
    end

    # Validated amount in cents for Stripe and local Transaction
    @amount_in_cents = (amount_from_params * 100).to_i
  
    customer = Stripe::Customer.create(
      :email => params[:stripeEmail],
      :source  => params[:stripeToken]
    )
  
    charge = Stripe::Charge.create(
      :customer    => customer.id,
      :amount      => @amount_in_cents,
      :description => 'Rails Stripe customer', # This can be more specific if needed
      :currency    => 'aud',
      :metadata    => {
        user_id: current_user.id,
        email: params[:stripeEmail], # Or current_user.email
        purpose: 'Account top-up'
      }
    )

    # Assuming Transaction.amount stores amounts in cents as per existing logic
    credit_card_balance = retrieve_balance(account_id("Credit card"))
    cash_balance = retrieve_balance(account_id("Cash"))
    # The balance calculations should use the same unit as stored in Transaction.amount (cents)
    credit_card_closing_balance = credit_card_balance - @amount_in_cents
    cash_closing_balance = cash_balance + @amount_in_cents
    Transaction.create!([
      {
        amount: @amount_in_cents,
        from_account_id: account_id("Credit card")[0],
        to_account_id: account_id("Cash")[0],
        from_account_balance: credit_card_closing_balance,
        to_account_balance: cash_closing_balance,
        transaction_type: "principal",
        description: "Account top-up via Stripe charge" # Added description
      }
    ])
    
    render layout: "portfolios"

  rescue Stripe::CardError => e
    flash[:error] = e.message
    # Pass amount back to prefill form even on Stripe error
    redirect_to new_charge_path(amount: params[:amount])
  end

end
