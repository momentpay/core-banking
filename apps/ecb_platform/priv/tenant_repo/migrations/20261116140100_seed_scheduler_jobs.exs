defmodule ECBPlatform.TenantRepo.Migrations.SeedSchedulerJobs do
  @moduledoc """
  Derived from the data of Apache Fineract 1.16.1 (Apache License 2.0): the scheduler jobs it ships with,
  with the cron expression and whether each is switched on. Only the jobs listed here are known to the API;
  running one needs the code behind it (see `ECBPlatform.Jobs`).
  """
  use Ecto.Migration

  def up do
    execute(~S"""
    INSERT INTO public.job
        (id, name, display_name, cron_expression, create_time, task_priority, is_active, updates_allowed, scheduler_group, short_name)
    OVERRIDING SYSTEM VALUE VALUES
        (2, 'Update Loan Arrears Ageing', 'Update Loan Arrears Ageing', '0 1 0 1/1 * ? *', now(), 5, true, true, 0, 'LA_ARAG'),
        (4, 'Apply Annual Fee For Savings', 'Apply Annual Fee For Savings', '0 20 22 1/1 * ? *', now(), 5, true, true, 0, 'SA_AANF'),
        (5, 'Apply Holidays To Loans', 'Apply Holidays To Loans', '0 0 12 * * ?', now(), 5, true, true, 0, 'LA_AHOL'),
        (6, 'Post Interest For Savings', 'Post Interest For Savings', '0 0 0 1/1 * ? *', now(), 5, true, true, 1, 'SA_PINT'),
        (7, 'Transfer Fee For Loans From Savings', 'Transfer Fee For Loans From Savings', '0 1 0 1/1 * ? *', now(), 5, true, true, 0, 'LA_TFFS'),
        (8, 'Pay Due Savings Charges', 'Pay Due Savings Charges', '0 0 12 * * ?', now(), 5, true, true, 0, 'SA_PDCH'),
        (9, 'Update Accounting Running Balances', 'Update Accounting Running Balances', '0 1 0 1/1 * ? *', now(), 5, true, true, 0, 'ACC_RBAL'),
        (10, 'Execute Standing Instruction', 'Execute Standing Instruction', '0 0 0 1/1 * ? *', now(), 5, true, true, 0, 'STI_EXEC'),
        (11, 'Add Accrual Transactions', 'Add Accrual Transactions', '0 1 0 1/1 * ? *', now(), 3, true, true, 3, 'ACC_AATR'),
        (12, 'Apply penalty to overdue loans', 'Apply penalty to overdue loans', '0 0 0 1/1 * ? *', now(), 5, true, true, 0, 'LA_OPEN'),
        (13, 'Update Non Performing Assets', 'Update Non Performing Assets', '0 0 0 1/1 * ? *', now(), 6, true, true, 3, 'LA_UNPA'),
        (14, 'Transfer Interest To Savings', 'Transfer Interest To Savings', '0 2 0 1/1 * ? *', now(), 4, true, true, 1, 'SA_TINT'),
        (15, 'Update Deposit Accounts Maturity details', 'Update Deposit Accounts Maturity details', '0 0 0 1/1 * ? *', now(), 5, true, true, 0, 'SA_MATD'),
        (16, 'Add Periodic Accrual Transactions', 'Add Periodic Accrual Transactions', '0 2 0 1/1 * ? *', now(), 2, true, true, 3, 'ACC_APTR'),
        (17, 'Recalculate Interest For Loans', 'Recalculate Interest For Loans', '0 1 0 1/1 * ? *', now(), 4, true, true, 3, 'LA_RINT'),
        (18, 'Generate Mandatory Savings Schedule', 'Generate Mandatory Savings Schedule', '0 5 0 1/1 * ? *', now(), 5, true, true, 0, 'SA_GSCH'),
        (19, 'Generate Loan Loss Provisioning', 'Generate Loan Loss Provisioning', '0 0 0 1/1 * ? *', now(), 5, true, true, 0, 'LA_GLPR'),
        (20, 'Post Dividends For Shares', 'Post Dividends For Shares', '0 0 0 1/1 * ? *', now(), 5, true, true, 0, 'SH_PDIV'),
        (21, 'Update Savings Dormant Accounts', 'Update Savings Dormant Accounts', '0 0 0 1/1 * ? *', now(), 3, true, true, 1, 'SA_UDOR'),
        (22, 'Add Accrual Transactions For Loans With Income Posted As Transactions', 'Add Accrual Transactions For Loans With Income Posted As Transactions', '0 1 0 1/1 * ? *', now(), 5, true, true, 3, 'LA_AATR'),
        (23, 'Execute Report Mailing Jobs', 'Execute Report Mailing Jobs', '0 0/15 * * * ?', now(), 5, true, true, 0, 'RMJ_EXEC'),
        (24, 'Update SMS Outbound with Campaign Message', 'Update SMS Outbound with Campaign Message', '0 0 5 1/1 * ? *', now(), 3, true, true, 4, 'SMS_UOUT'),
        (25, 'Send Messages to SMS Gateway', 'Send Messages to SMS Gateway', '0 0 5 1/1 * ? *', now(), 2, true, true, 4, 'SMS_SMSG'),
        (26, 'Get Delivery Reports from SMS Gateway', 'Get Delivery Reports from SMS Gateway', '0 0 5 1/1 * ? *', now(), 1, true, true, 4, 'SMS_DRPT'),
        (27, 'Execute Email', 'Execute Email', '0 0/10 * * * ?', now(), 5, true, true, 0, 'EM_EXEC'),
        (28, 'Update Email Outbound with campaign message', 'Update Email Outbound with campaign message', '0 0/15 * * * ?', now(), 5, true, true, 0, 'EM_UOUT'),
        (29, 'Generate AdhocClient Schedule', 'Generate AdhocClient Schedule', '0 0 12 1/1 * ? *', now(), 5, true, true, 0, 'ADH_GSCH'),
        (30, 'Update Trial Balance Details', 'Update Trial Balance Details', '0 1 0 1/1 * ? *', now(), 5, true, true, 0, 'TBL_UDET'),
        (31, 'Execute All Dirty Jobs', 'Execute All Dirty Jobs', '0 1 0 1/1 * ? *', now(), 5, true, true, 0, 'JOB_EXEC'),
        (32, 'Increase Business Date by 1 day', 'Increase Business Date by 1 day', '0 0 0 1/1 * ? *', now(), 99, false, true, 1, 'BDT_INC1'),
        (33, 'Increase COB Date by 1 day', 'Increase COB Date by 1 day', '0 0 0 1/1 * ? *', now(), 98, false, true, 1, 'BDT_COB1'),
        (34, 'Loan COB', 'Loan COB', '0 0 0 * * ?', now(), 5, false, true, 1, 'LA_ECOB'),
        (35, 'Loan Delinquency Classification', 'Loan Delinquency Classification', '0 0 22 1/1 * ? *', now(), 5, true, true, 0, 'LA_DECL'),
        (36, 'Send Asynchronous Events', 'Send Asynchronous Events', '0 0/1 * * *  ?', now(), 5, true, true, 0, 'ASE_SEND'),
        (37, 'Purge External Events', 'Purge External Events', '0 1 0 1/1 * ? *', now(), 5, false, true, 0, 'EXE_PURG'),
        (38, 'Purge Processed Commands', 'Purge Processed Commands', '0 0 1 * * ?', now(), 5, false, true, 0, 'COM_PURG'),
        (39, 'Accrual Activity Posting', 'Accrual Activity Posting', '0 0 1 * * ?', now(), 5, false, true, 0, 'ACC_ACPO'),
        (40, 'Journal Entry Aggregation', 'Journal Entry Aggregation', '0 0 6 * * ?', now(), 5, false, true, 0, 'JRNL_AGG'),
        (41, 'Retained Earning Job', 'Retained Earning Job', '0 0 6 * * ?', now(), 5, false, true, 0, 'RE_ERNG'),
        (42, 'Add Accrual Transactions For Savings', 'Add Accrual Transactions For Savings', '0 1 0 1/1 * ? *', now(), 5, false, true, 0, 'ADD_ATFS'),
        (43, 'Working Capital Loan COB', 'Working Capital Loan COB', '0 0 0 * * ?', now(), 5, false, true, 1, 'WC_COB');
    """)
  end

  def down, do: execute("DELETE FROM public.job")
end
