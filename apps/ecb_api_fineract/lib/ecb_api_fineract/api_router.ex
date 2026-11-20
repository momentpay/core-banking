defmodule ECBApiFineract.ApiRouter do
  @moduledoc """
  The routes under `/fineract-provider/api`. Every request is resolved to a tenant and authenticated
  before it reaches a resource, except `/v1/authentication`, which is how a client logs in.

  An operation that exists in Fineract's API but is not built yet answers HTTP 501 with a clear
  message, so a client can tell "not implemented" from "not found". The inventory in
  `parity/inventory/endpoints.csv` says which operations are planned and which are deferred.
  """
  use Plug.Router
  use Plug.ErrorHandler

  alias ECBApiFineract.Errors

  alias ECBApiFineract.Resources.{
    AccountingRules,
    Administration,
    Audits,
    Authentication,
    BusinessDate,
    Charges,
    ClientIdentifiers,
    Clients,
    Codes,
    Delinquency,
    FamilyMembers,
    FinancialActivityAccounts,
    FloatingRates,
    Funds,
    GLAccounts,
    GLClosures,
    Holidays,
    Jobs,
    JournalEntries,
    LoanAccounts,
    LoanCharges,
    LoanCollaterals,
    LoanDisbursements,
    LoanGuarantors,
    LoanProducts,
    Loans,
    LoanTemplate,
    LoanTransactionTemplate,
    MakerCheckers,
    Notes,
    Offices,
    Organisation,
    PaymentTypes,
    Provisioning,
    Rates,
    RescheduleLoans,
    SavingsAccountCharges,
    SavingsAccounts,
    SavingsProducts,
    SavingsTransactions,
    Staff,
    Taxes
  }

  plug :match

  @parser_options Plug.Parsers.init(
                    parsers: [:json],
                    pass: ["*/*"],
                    json_decoder: Jason,
                    body_reader: {ECBApiFineract.BodyReader, :read_body, []}
                  )

  plug :parse_body

  plug ECBApiFineract.Plugs.Tenant
  plug ECBApiFineract.Plugs.Authenticate
  plug :dispatch

  post "/v1/authentication", do: Authentication.login(conn)

  # Excel templates for bulk import. A client that asks for JSON cannot be served one, and Fineract says so
  # with the web container's plain 406; the import itself is not built.
  get "/v1/:resource/downloadtemplate", do: excel_template(conn, resource)

  get "/v1/offices/template", do: Offices.template(conn)
  get "/v1/offices", do: Offices.index(conn)
  get "/v1/offices/:id", do: Offices.show(conn, id)
  post "/v1/offices", do: Offices.create(conn)
  put "/v1/offices/:id", do: Offices.update(conn, id)

  get "/v1/currencies", do: Organisation.currencies(conn)
  get "/v1/codes", do: Codes.index(conn)
  post "/v1/codes", do: Codes.create(conn)
  get "/v1/codes/name/:name", do: Codes.show_by_name(conn, name)
  get "/v1/codes/name/:name/codevalues", do: Codes.values_by_name(conn, name)
  post "/v1/codes/name/:name/codevalues", do: Codes.create_value_by_name(conn, name)
  get "/v1/codes/name/:name/codevalues/:id", do: Codes.show_value_by_name(conn, name, id)
  put "/v1/codes/name/:name/codevalues/:id", do: Codes.update_value_by_name(conn, name, id)
  delete "/v1/codes/name/:name/codevalues/:id", do: Codes.delete_value_by_name(conn, name, id)
  get "/v1/codes/:id", do: Codes.show(conn, id)
  put "/v1/codes/:id", do: Codes.update(conn, id)
  delete "/v1/codes/:id", do: Codes.delete(conn, id)
  get "/v1/codes/:id/codevalues", do: Codes.values(conn, id)
  post "/v1/codes/:id/codevalues", do: Codes.create_value(conn, id)
  get "/v1/codes/:id/codevalues/:value_id", do: Codes.show_value(conn, id, value_id)
  put "/v1/codes/:id/codevalues/:value_id", do: Codes.update_value(conn, id, value_id)
  delete "/v1/codes/:id/codevalues/:value_id", do: Codes.delete_value(conn, id, value_id)
  get "/v1/paymenttypes", do: PaymentTypes.index(conn)
  get "/v1/paymenttypes/:id", do: PaymentTypes.show(conn, id)
  post "/v1/paymenttypes", do: PaymentTypes.create(conn)
  put "/v1/paymenttypes/:id", do: PaymentTypes.update(conn, id)
  delete "/v1/paymenttypes/:id", do: PaymentTypes.delete(conn, id)
  get "/v1/workingdays/template", do: Organisation.working_days_template(conn)
  get "/v1/workingdays", do: Organisation.working_days(conn)
  put "/v1/workingdays", do: Organisation.update_working_days(conn)
  get "/v1/funds", do: Funds.index(conn)
  get "/v1/funds/:id", do: Funds.show(conn, id)
  post "/v1/funds", do: Funds.create(conn)
  put "/v1/funds/:id", do: Funds.update(conn, id)
  delete "/v1/funds/:id", do: LoanProducts.method_not_allowed(conn)
  get "/v1/holidays/template", do: Holidays.template(conn)
  get "/v1/holidays", do: Holidays.index(conn)
  post "/v1/holidays", do: Holidays.create(conn)
  get "/v1/holidays/:id", do: Holidays.show(conn, id)
  put "/v1/holidays/:id", do: Holidays.update(conn, id)
  post "/v1/holidays/:id", do: Holidays.command(conn, id)
  delete "/v1/holidays/:id", do: Holidays.delete(conn, id)
  get "/v1/staff", do: Staff.index(conn)
  get "/v1/staff/:id", do: Staff.show(conn, id)
  post "/v1/staff", do: Staff.create(conn)
  put "/v1/staff/:id", do: Staff.update(conn, id)
  get "/v1/clients/template", do: Clients.template(conn)
  get "/v1/clients", do: Clients.index(conn)
  post "/v1/clients", do: Clients.create(conn)

  get "/v1/clients/external-id/:external_id/accounts",
    do: Clients.accounts(conn, {:external_id, external_id})

  get "/v1/clients/external-id/:external_id/obligeedetails",
    do: Clients.obligee_details(conn, {:external_id, external_id})

  get "/v1/clients/external-id/:external_id/transferproposaldate",
    do: Clients.transfer_proposal_date(conn, {:external_id, external_id})

  get "/v1/clients/external-id/:external_id", do: Clients.show_by_external_id(conn, external_id)

  post "/v1/clients/external-id/:external_id",
    do: Clients.command(conn, {:external_id, external_id})

  put "/v1/clients/external-id/:external_id",
    do: Clients.update(conn, {:external_id, external_id})

  delete "/v1/clients/external-id/:external_id",
    do: Clients.delete(conn, {:external_id, external_id})

  get "/v1/clients/:client_id/identifiers/template",
    do: ClientIdentifiers.template(conn, client_id)

  get "/v1/clients/:client_id/identifiers", do: ClientIdentifiers.index(conn, client_id)
  post "/v1/clients/:client_id/identifiers", do: ClientIdentifiers.create(conn, client_id)
  get "/v1/clients/:client_id/identifiers/:id", do: ClientIdentifiers.show(conn, client_id, id)
  put "/v1/clients/:client_id/identifiers/:id", do: ClientIdentifiers.update(conn, client_id, id)

  delete "/v1/clients/:client_id/identifiers/:id",
    do: ClientIdentifiers.delete(conn, client_id, id)

  get "/v1/clients/:client_id/familymembers/template", do: FamilyMembers.template(conn, client_id)
  get "/v1/clients/:client_id/familymembers", do: FamilyMembers.index(conn, client_id)
  post "/v1/clients/:client_id/familymembers", do: FamilyMembers.create(conn, client_id)
  get "/v1/clients/:client_id/familymembers/:id", do: FamilyMembers.show(conn, client_id, id)
  put "/v1/clients/:client_id/familymembers/:id", do: FamilyMembers.update(conn, client_id, id)
  delete "/v1/clients/:client_id/familymembers/:id", do: FamilyMembers.delete(conn, client_id, id)
  get "/v1/clients/:id/accounts", do: Clients.accounts(conn, id)
  get "/v1/clients/:id/obligeedetails", do: Clients.obligee_details(conn, id)
  get "/v1/clients/:id/transferproposaldate", do: Clients.transfer_proposal_date(conn, id)
  get "/v1/clients/:id", do: Clients.show(conn, id)
  post "/v1/clients/:id", do: Clients.command(conn, id)
  put "/v1/clients/:id", do: Clients.update(conn, id)
  delete "/v1/clients/:id", do: Clients.delete(conn, id)
  get "/v1/savingsaccounts/template", do: SavingsAccounts.template(conn)

  get "/v1/savingsaccounts/external-id/:external_id/transactions/template",
    do: SavingsTransactions.template_by_external_id(conn, external_id)

  get "/v1/savingsaccounts/external-id/:external_id/transactions/:transaction_id",
    do: SavingsTransactions.show_of_external_account(conn, external_id, transaction_id)

  get "/v1/savingsaccounts/:id/charges/template", do: SavingsAccountCharges.template(conn, id)

  get "/v1/savingsaccounts/:id/charges/:charge_id",
    do: SavingsAccountCharges.show(conn, id, charge_id)

  get "/v1/savingsaccounts/:id/charges", do: SavingsAccountCharges.index(conn, id)

  post "/v1/savingsaccounts/:id/charges/:charge_id",
    do: SavingsAccountCharges.command(conn, id, charge_id)

  post "/v1/savingsaccounts/:id/charges", do: SavingsAccountCharges.create(conn, id)

  put "/v1/savingsaccounts/:id/charges/:charge_id",
    do: SavingsAccountCharges.update(conn, id, charge_id)

  delete "/v1/savingsaccounts/:id/charges/:charge_id",
    do: SavingsAccountCharges.delete(conn, id, charge_id)

  get "/v1/savingsaccounts/:id/transactions/template", do: SavingsTransactions.template(conn, id)

  get "/v1/savingsaccounts/:id/transactions/external-id/:external_id",
    do: SavingsTransactions.show_by_external_id(conn, id, external_id)

  get "/v1/savingsaccounts/:id/transactions/:transaction_id",
    do: SavingsTransactions.show(conn, id, transaction_id)

  post "/v1/savingsaccounts/:id/transactions", do: SavingsTransactions.command(conn, id)

  post "/v1/savingsaccounts/:id/transactions/:transaction_id",
    do: SavingsTransactions.adjust(conn, id, transaction_id)

  get "/v1/savingsaccounts/external-id/:external_id",
    do: SavingsAccounts.show_by_external_id(conn, external_id)

  get "/v1/savingsaccounts", do: SavingsAccounts.index(conn)
  post "/v1/savingsaccounts", do: SavingsAccounts.create(conn)
  get "/v1/savingsaccounts/:id", do: SavingsAccounts.show(conn, id)
  put "/v1/savingsaccounts/:id", do: SavingsAccounts.update(conn, id)
  delete "/v1/savingsaccounts/:id", do: SavingsAccounts.delete(conn, id)
  post "/v1/savingsaccounts/:id", do: SavingsAccounts.command(conn, id)

  get "/v1/savingsproducts/template", do: SavingsProducts.template(conn)
  get "/v1/savingsproducts", do: SavingsProducts.index(conn)
  post "/v1/savingsproducts", do: SavingsProducts.create(conn)
  get "/v1/savingsproducts/:id", do: SavingsProducts.show(conn, id)
  put "/v1/savingsproducts/:id", do: SavingsProducts.update(conn, id)
  delete "/v1/savingsproducts/:id", do: SavingsProducts.delete(conn, id)
  get "/v1/accounts/share/:id/notes", do: Notes.index(conn, "accounts/share", id)
  post "/v1/accounts/share/:id/notes", do: Notes.create(conn, "accounts/share", id)
  get "/v1/:type/:id/notes", do: Notes.index(conn, type, id)
  get "/v1/:type/:id/notes/:note_id", do: Notes.show(conn, type, id, note_id)
  post "/v1/:type/:id/notes", do: Notes.create(conn, type, id)
  put "/v1/:type/:id/notes/:note_id", do: Notes.update(conn, type, id, note_id)
  delete "/v1/:type/:id/notes/:note_id", do: Notes.delete(conn, type, id, note_id)
  get "/v1/loans", do: LoanAccounts.index(conn)
  get "/v1/loans/template", do: LoanTemplate.show(conn)
  post "/v1/loans", do: Loans.create(conn)

  get "/v1/loans/external-id/:external_id",
    do: LoanAccounts.show_by_external_id(conn, external_id)

  get "/v1/loans/external-id/:external_id/transactions/template",
    do: LoanTransactionTemplate.show_by_external_id(conn, external_id)

  get "/v1/loans/:id/transactions/template", do: LoanTransactionTemplate.show(conn, id)

  get "/v1/loans/external-id/:external_id/transactions/external-id/:transaction_external_id",
    do:
      LoanAccounts.show_transaction_by_both_external_ids(
        conn,
        external_id,
        transaction_external_id
      )

  get "/v1/loans/external-id/:external_id/transactions/:transaction_id",
    do: LoanAccounts.show_transaction_of_external_loan(conn, external_id, transaction_id)

  get "/v1/loans/external-id/:external_id/transactions",
    do: LoanAccounts.transactions_by_external_id(conn, external_id)

  get "/v1/loans/:id/transactions/external-id/:transaction_external_id",
    do: LoanAccounts.show_transaction_by_external_id(conn, id, transaction_external_id)

  get "/v1/loans/:id/transactions/:transaction_id",
    do: LoanAccounts.show_transaction(conn, id, transaction_id)

  get "/v1/loans/:id/transactions", do: LoanAccounts.transactions(conn, id)

  get "/v1/loans/:id/guarantors/template", do: LoanGuarantors.template(conn, id)
  get "/v1/loans/:id/guarantors/accounts/template", do: LoanGuarantors.accounts_template(conn, id)

  get "/v1/loans/:id/guarantors/:guarantor_id",
    do: LoanGuarantors.show(conn, id, guarantor_id)

  get "/v1/loans/:id/guarantors", do: LoanGuarantors.index(conn, id)
  post "/v1/loans/:id/guarantors", do: LoanGuarantors.create(conn, id)

  put "/v1/loans/:id/guarantors/:guarantor_id",
    do: LoanGuarantors.update(conn, id, guarantor_id)

  delete "/v1/loans/:id/guarantors/:guarantor_id",
    do: LoanGuarantors.delete(conn, id, guarantor_id)

  get "/v1/rescheduleloans/template", do: RescheduleLoans.template(conn)
  get "/v1/rescheduleloans/:id", do: RescheduleLoans.show(conn, id)
  get "/v1/rescheduleloans", do: RescheduleLoans.index(conn)
  post "/v1/rescheduleloans/:id", do: RescheduleLoans.command(conn, id)
  post "/v1/rescheduleloans", do: RescheduleLoans.create(conn)

  get "/v1/loans/:id/collaterals/template", do: LoanCollaterals.template(conn, id)

  get "/v1/loans/:id/collaterals/:collateral_id",
    do: LoanCollaterals.show(conn, id, collateral_id)

  get "/v1/loans/:id/collaterals", do: LoanCollaterals.index(conn, id)
  post "/v1/loans/:id/collaterals", do: LoanCollaterals.create(conn, id)

  put "/v1/loans/:id/collaterals/:collateral_id",
    do: LoanCollaterals.update(conn, id, collateral_id)

  delete "/v1/loans/:id/collaterals/:collateral_id",
    do: LoanCollaterals.delete(conn, id, collateral_id)

  put "/v1/loans/:id/disbursements/editDisbursements",
    do: LoanDisbursements.update_all(conn, id)

  get "/v1/loans/:id/disbursements/:disbursement_id",
    do: LoanDisbursements.show(conn, id, disbursement_id)

  put "/v1/loans/:id/disbursements/:disbursement_id",
    do: LoanDisbursements.update(conn, id, disbursement_id)

  get "/v1/loans/:id/delinquencytags", do: Delinquency.tags(conn, id)
  get "/v1/loans/:id/delinquency-actions", do: Delinquency.actions(conn, id)
  post "/v1/loans/:id/delinquency-actions", do: Delinquency.create_action(conn, id)

  get "/v1/delinquency/ranges", do: Delinquency.ranges(conn)
  post "/v1/delinquency/ranges", do: Delinquency.range_create(conn)
  get "/v1/delinquency/ranges/:id", do: Delinquency.range_show(conn, id)
  put "/v1/delinquency/ranges/:id", do: Delinquency.range_update(conn, id)
  delete "/v1/delinquency/ranges/:id", do: Delinquency.range_delete(conn, id)
  get "/v1/delinquency/buckets/template", do: Delinquency.bucket_template(conn)
  get "/v1/delinquency/buckets", do: Delinquency.buckets(conn)
  post "/v1/delinquency/buckets", do: Delinquency.bucket_create(conn)
  get "/v1/delinquency/buckets/:id", do: Delinquency.bucket_show(conn, id)
  put "/v1/delinquency/buckets/:id", do: Delinquency.bucket_update(conn, id)
  delete "/v1/delinquency/buckets/:id", do: Delinquency.bucket_delete(conn, id)

  get "/v1/loans/:id/charges/template", do: LoanCharges.template(conn, id)
  get "/v1/loans/:id/charges/:charge_id", do: LoanCharges.show(conn, id, charge_id)
  get "/v1/loans/:id/charges", do: LoanCharges.index(conn, id)
  post "/v1/loans/:id/charges/:charge_id", do: LoanCharges.command(conn, id, charge_id)
  post "/v1/loans/:id/charges", do: LoanCharges.create(conn, id)
  put "/v1/loans/:id/charges/:charge_id", do: LoanCharges.update(conn, id, charge_id)
  delete "/v1/loans/:id/charges/:charge_id", do: LoanCharges.delete(conn, id, charge_id)
  get "/v1/loans/:id", do: LoanAccounts.show(conn, id)

  post "/v1/loans/:id/transactions/:transaction_id",
    do: LoanAccounts.adjust_transaction(conn, id, transaction_id)

  post "/v1/loans/:id/transactions", do: LoanAccounts.transaction_command(conn, id)
  post "/v1/loans/:id", do: LoanAccounts.command(conn, id)
  put "/v1/loans/:id", do: LoanAccounts.update(conn, id)
  delete "/v1/loans/:id", do: LoanAccounts.delete(conn, id)
  get "/v1/loanproducts/template", do: LoanProducts.template(conn)
  get "/v1/loanproducts", do: LoanProducts.index(conn)
  post "/v1/loanproducts", do: LoanProducts.create(conn)
  get "/v1/loanproducts/:id", do: LoanProducts.show(conn, id)
  put "/v1/loanproducts/:id", do: LoanProducts.update(conn, id)
  delete "/v1/loanproducts/:id", do: LoanProducts.method_not_allowed(conn)
  get "/v1/accountnumberformats/template", do: Organisation.account_number_formats_template(conn)
  get "/v1/accountnumberformats", do: Organisation.account_number_formats(conn)

  get "/v1/configurations/name/:name", do: Administration.configuration_by_name(conn, name)
  put "/v1/configurations/name/:name", do: Administration.update_configuration_by_name(conn, name)
  get "/v1/configurations/:id", do: Administration.configuration_by_id(conn, id)
  put "/v1/configurations/:id", do: Administration.update_configuration(conn, id)
  get "/v1/configurations", do: Administration.configurations(conn)
  get "/v1/permissions", do: Administration.permissions(conn)
  put "/v1/permissions", do: Administration.update_permissions(conn)
  get "/v1/roles/:id/permissions", do: Administration.role_permissions(conn, id)
  put "/v1/roles/:id/permissions", do: Administration.update_role_permissions(conn, id)
  get "/v1/roles/:id", do: Administration.role_by_id(conn, id)
  put "/v1/roles/:id", do: Administration.update_role(conn, id)
  post "/v1/roles/:id", do: Administration.role_command(conn, id)
  delete "/v1/roles/:id", do: Administration.delete_role(conn, id)
  get "/v1/roles", do: Administration.roles(conn)
  post "/v1/roles", do: Administration.create_role(conn)
  get "/v1/users/template", do: Administration.users_template(conn)
  get "/v1/users", do: Administration.users(conn)
  get "/v1/users/:id", do: Administration.user_by_id(conn, id)
  post "/v1/users", do: Administration.create_user(conn)
  put "/v1/users/:id", do: Administration.update_user(conn, id)
  delete "/v1/users/:id", do: Administration.delete_user(conn, id)
  post "/v1/users/:id/pwd", do: Administration.change_user_password(conn, id)
  get "/v1/financialactivityaccounts/template", do: FinancialActivityAccounts.template(conn)
  get "/v1/financialactivityaccounts", do: FinancialActivityAccounts.index(conn)
  post "/v1/financialactivityaccounts", do: FinancialActivityAccounts.create(conn)
  get "/v1/financialactivityaccounts/:id", do: FinancialActivityAccounts.show(conn, id)
  put "/v1/financialactivityaccounts/:id", do: FinancialActivityAccounts.update(conn, id)
  delete "/v1/financialactivityaccounts/:id", do: FinancialActivityAccounts.delete(conn, id)

  get "/v1/glclosures", do: GLClosures.index(conn)
  post "/v1/glclosures", do: GLClosures.create(conn)
  get "/v1/glclosures/:id", do: GLClosures.show(conn, id)
  put "/v1/glclosures/:id", do: GLClosures.update(conn, id)
  delete "/v1/glclosures/:id", do: GLClosures.delete(conn, id)

  get "/v1/accountingrules/template", do: AccountingRules.template(conn)
  get "/v1/accountingrules", do: AccountingRules.index(conn)
  post "/v1/accountingrules", do: AccountingRules.create(conn)
  get "/v1/accountingrules/:id", do: AccountingRules.show(conn, id)
  put "/v1/accountingrules/:id", do: AccountingRules.update(conn, id)
  delete "/v1/accountingrules/:id", do: AccountingRules.delete(conn, id)

  get "/v1/rates", do: Rates.index(conn)
  post "/v1/rates", do: Rates.create(conn)
  get "/v1/rates/:id", do: Rates.show(conn, id)
  put "/v1/rates/:id", do: Rates.update(conn, id)

  get "/v1/floatingrates", do: FloatingRates.index(conn)
  post "/v1/floatingrates", do: FloatingRates.create(conn)
  get "/v1/floatingrates/:id", do: FloatingRates.show(conn, id)
  put "/v1/floatingrates/:id", do: FloatingRates.update(conn, id)

  get "/v1/charges/template", do: Charges.template(conn)
  get "/v1/charges", do: Charges.index(conn)
  post "/v1/charges", do: Charges.create(conn)
  get "/v1/charges/:id", do: Charges.show(conn, id)
  put "/v1/charges/:id", do: Charges.update(conn, id)
  delete "/v1/charges/:id", do: Charges.delete(conn, id)

  get "/v1/taxes/component/template", do: Taxes.component_template(conn)
  get "/v1/taxes/component", do: Taxes.components(conn)
  post "/v1/taxes/component", do: Taxes.create_component(conn)
  get "/v1/taxes/component/:id", do: Taxes.component(conn, id)
  put "/v1/taxes/component/:id", do: Taxes.update_component(conn, id)

  get "/v1/taxes/group/template", do: Taxes.group_template(conn)
  get "/v1/taxes/group", do: Taxes.groups(conn)
  post "/v1/taxes/group", do: Taxes.create_group(conn)
  get "/v1/taxes/group/:id", do: Taxes.group(conn, id)
  put "/v1/taxes/group/:id", do: Taxes.update_group(conn, id)

  get "/v1/provisioningcategory", do: Provisioning.categories(conn)
  post "/v1/provisioningcategory", do: Provisioning.create_category(conn)
  get "/v1/provisioningcategory/:id", do: Provisioning.method_not_allowed(conn)
  put "/v1/provisioningcategory/:id", do: Provisioning.update_category(conn, id)
  delete "/v1/provisioningcategory/:id", do: Provisioning.delete_category(conn, id)

  get "/v1/provisioningcriteria/template", do: Provisioning.criteria_template(conn)
  get "/v1/provisioningcriteria", do: Provisioning.criteria(conn)
  get "/v1/provisioningcriteria/:id", do: Provisioning.one_criteria(conn, id)

  get "/v1/provisioningentries/entries", do: Provisioning.entries(conn)
  get "/v1/provisioningentries", do: Provisioning.entries(conn)
  get "/v1/provisioningentries/:id", do: Provisioning.one_entry(conn, id)

  get "/v1/journalentries", do: JournalEntries.index(conn)
  post "/v1/journalentries", do: JournalEntries.create(conn)
  get "/v1/journalentries/openingbalance", do: JournalEntries.opening_balance(conn)
  get "/v1/journalentries/provisioning", do: JournalEntries.provisioning(conn)
  get "/v1/journalentries/:id", do: JournalEntries.show(conn, id)
  post "/v1/journalentries/:transaction_id", do: JournalEntries.reverse(conn, transaction_id)

  get "/v1/glaccounts/template", do: GLAccounts.template(conn)
  get "/v1/glaccounts", do: GLAccounts.index(conn)
  post "/v1/glaccounts", do: GLAccounts.create(conn)
  get "/v1/glaccounts/:id", do: GLAccounts.show(conn, id)
  put "/v1/glaccounts/:id", do: GLAccounts.update(conn, id)
  delete "/v1/glaccounts/:id", do: GLAccounts.delete(conn, id)
  get "/v1/jobs/short-name/:short_name/runhistory", do: Jobs.history(conn, short_name)
  get "/v1/jobs/short-name/:short_name", do: Jobs.show(conn, short_name)
  post "/v1/jobs/short-name/:short_name", do: Jobs.execute(conn, short_name)
  get "/v1/jobs/:id/runhistory", do: Jobs.history(conn, id)
  get "/v1/jobs/:id", do: Jobs.show(conn, id)
  post "/v1/jobs/:id", do: Jobs.execute(conn, id)
  get "/v1/jobs", do: Jobs.index(conn)

  get "/v1/businessdate", do: BusinessDate.index(conn)
  get "/v1/businessdate/:type", do: BusinessDate.show(conn, type)
  post "/v1/businessdate", do: BusinessDate.update(conn)
  get "/v1/makercheckers/searchtemplate", do: MakerCheckers.search_template(conn)
  get "/v1/makercheckers", do: MakerCheckers.index(conn)
  post "/v1/makercheckers/:id", do: MakerCheckers.command(conn, id)
  delete "/v1/makercheckers/:id", do: MakerCheckers.delete(conn, id)
  get "/v1/audits/searchtemplate", do: Audits.search_template(conn)
  get "/v1/audits", do: Audits.index(conn)
  get "/v1/audits/:id", do: Audits.show(conn, id)

  get "/v1/passwordpreferences/template", do: Administration.password_preferences_template(conn)
  get "/v1/passwordpreferences", do: Administration.password_preferences(conn)
  put "/v1/passwordpreferences", do: Administration.update_password_preferences(conn)

  match _ do
    Errors.not_implemented(conn, conn.method, conn.request_path)
  end

  @excel_resources ~w(offices staff users glaccounts journalentries clients groups centers loans
                      savingsaccounts fixeddepositaccounts recurringdepositaccounts shareaccounts
                      charges products)

  defp excel_template(conn, resource) when resource in @excel_resources do
    if excel_accepted?(conn),
      do: Errors.not_implemented(conn, conn.method, conn.request_path),
      else: Errors.spring(conn, 406, "Not Acceptable")
  end

  defp excel_template(conn, _resource),
    do: Errors.not_implemented(conn, conn.method, conn.request_path)

  defp excel_accepted?(conn) do
    conn
    |> Plug.Conn.get_req_header("accept")
    |> Enum.any?(&(String.contains?(&1, "excel") or String.contains?(&1, "*/*")))
  end

  # Reads the JSON body. A body that is not JSON is answered here, as Fineract does, rather than
  # crashing the request.
  defp parse_body(conn, _opts) do
    Plug.Parsers.call(conn, @parser_options)
  rescue
    error in Plug.Parsers.ParseError ->
      conn |> Errors.render(parse_error(conn, error)) |> halt()
  end

  # Fineract reads some bodies straight into a typed object, which fails with "invalid JSON data" on text
  # that is not JSON; the rest it reads as text and complains about the syntax.
  @typed_bodies ["accountingrules", "taxes", "charges", "rates", "floatingrates"]

  defp parse_error(%{path_info: ["v1", resource | _]}, _error) when resource in @typed_bodies,
    do: %ECBPlatform.Errors.InvalidJsonData{}

  defp parse_error(%{path_info: ["v1", "clients", _id, "familymembers" | _]}, _error),
    do: %ECBPlatform.Errors.InvalidJsonData{}

  defp parse_error(_conn, error), do: error

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
    Errors.render(conn, Exception.normalize(kind, reason, stack))
  end
end
