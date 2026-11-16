defmodule ECBLoans.Schedule.ChargeInput do
  @moduledoc """
  The `charges` of a loan application: each entry names a charge (`chargeId`), its amount or percentage
  (`amount`, as the loan is to take it, which may differ from the charge's own) and, for a charge with a
  specified due date, the `dueDate`.

  Entries are checked as Fineract does: an `amount` is mandatory and positive; the charge must exist; a charge
  with a specified due date needs a date within the loan's schedule (when the application is stored). A charge
  that is not yet supported (one that only applies when overdue or by tranche, a percentage of interest charged
  at disbursement, an account transfer, a cap, a tax group or a payment type) is refused with a plain "not
  supported yet", never ignored.
  """
  alias ECBCatalog.Charges, as: Catalog
  alias ECBLoans.Schedule.Dates
  alias ECBPlatform.Errors.{DomainRuleViolation, PlatformApiDataValidation}
  alias ECBPlatform.{Json, Params}

  @doc "The charges of the request `p`, each as `%{charge_id, name, time, calc, penalty, amount, due_date, ...}`."
  @spec parse!(Params.t()) :: [map]
  def parse!(%Params{} = p) do
    entries =
      case Params.value(p, "charges") do
        list when is_list(list) -> list
        _ -> []
      end

    given =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, index} -> {sub(p, entry), index} end)

    check!(given)
    Enum.map(given, fn {entry, _index} -> charge!(entry) end)
  end

  # an entry read with the locale and date format of the request that carries it
  defp sub(%Params{map: map} = p, entry) when is_map(entry) do
    shared = Map.take(map, ["locale", "dateFormat"])
    %Params{p | map: Map.merge(entry, shared)}
  end

  defp sub(%Params{} = p, _entry), do: %Params{p | map: Map.take(p.map, ["locale", "dateFormat"])}

  defp check!(given) do
    errors =
      for {entry, index} <- given, error <- entry_errors(entry, index), do: error

    if errors != [], do: raise(PlatformApiDataValidation, errors: errors)
  end

  defp entry_errors(entry, index) do
    case Params.decimal_with_locale(entry, "amount") do
      nil ->
        [
          error(
            "validation.msg.loan.charges.amount.cannot.be.blank",
            "The parameter `charges[#{index}][amount]` is mandatory.",
            "charges[#{index}][amount]",
            [index]
          )
        ]

      amount ->
        if Decimal.compare(amount, 0) == :gt,
          do: [],
          else: [
            error(
              "validation.msg.loan.charges.not.greater.than.zero",
              "The parameter `charges` must be greater than 0.",
              "charges",
              [Decimal.to_float(amount), 0]
            )
          ]
    end
  end

  defp error(code, message, parameter, args),
    do: %{
      code: code,
      developer_message: message,
      default_message: message,
      parameter: parameter,
      args: args
    }

  defp charge!(entry) do
    id = Json.long(entry, "chargeId")

    charge =
      case Catalog.get(id) do
        {:ok, charge} -> charge
        {:error, error} -> raise error
      end

    refuse!(charge)

    %{
      charge_id: charge.id,
      name: charge.name,
      time: charge.time,
      calc: charge.calculation,
      penalty: charge.penalty,
      amount: Params.decimal_with_locale(entry, "amount"),
      due_date: Params.date(entry, "dueDate"),
      payment_mode: charge.payment_mode,
      charge_amount: charge.amount,
      currency_code: charge.currency.code
    }
  end

  defp refuse!(charge) do
    reasons =
      [
        {charge.applies_to != 1, "a charge that does not apply to loans"},
        {charge.time not in [1, 2, 8],
         "a charge that falls due when a loan is overdue or by tranche"},
        {charge.time == 1 and charge.calculation in [3, 4],
         "a charge at disbursement as a percentage of interest"},
        {charge.time == 1 and charge.penalty, "a penalty at disbursement"},
        {charge.payment_mode != 0, "a charge paid by account transfer"},
        {charge.min_cap != nil or charge.max_cap != nil, "a charge with a minimum or maximum"},
        {charge.tax_group != nil, "a charge with a tax group"},
        {charge.payment_type_enabled == true, "a charge with a payment type"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    if reasons != [] do
      raise DomainRuleViolation,
        code: "error.msg.loan.feature.not.supported.yet",
        message:
          "These loan application settings are not supported yet by E-CoreBank: charges (" <>
            Enum.join(reasons, ", ") <> ")",
        args: ["charges"]
    end
  end

  @doc """
  Checks that a charge with a specified due date has a date within the loan's schedule: from the day the loan is
  paid out to the last repayment date.
  """
  @spec check_dates!(map, [map]) :: :ok
  def check_dates!(terms, charges) do
    last = Dates.last_repayment_date(terms)

    for %{time: 2} = charge <- charges,
        outside?(charge.due_date, terms.disbursement_date, last) do
      raise DomainRuleViolation,
        code: "error.msg.loanCharge.cannot.be.added.as.specified.due.date.outside.range",
        message:
          "This charge with specified due date cannot be added as the it is not in schedule range.",
        args: [Date.to_iso8601(terms.disbursement_date), charge.name]
    end

    :ok
  end

  defp outside?(nil, _from, _to), do: true

  defp outside?(date, from, to),
    do: Date.compare(date, from) == :lt or Date.compare(date, to) == :gt
end
