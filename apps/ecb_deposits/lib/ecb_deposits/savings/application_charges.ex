defmodule ECBDeposits.Savings.ApplicationCharges do
  @moduledoc """
  The charges an application for a savings account carries (`charges`), after Fineract's
  `SavingsAccountChargeAssembler.fromParsedJson`: each names a charge and may give its amount, the day it falls due
  and the day of the month or the interval it repeats on. A charge a request changes the time or the calculation of,
  or one that gives free withdrawals or belongs to a payment type, is refused as not supported yet.
  """
  alias ECBDeposits.Savings.Charges
  alias ECBPlatform.Errors.{DomainRuleViolation, PlatformApiDataValidation}
  alias ECBPlatform.{Params, Validation}
  alias ECBPlatform.Params.DatePattern

  @doc "Every charge of an application must give its amount, as the validation of the application asks."
  @spec validate!(Params.t()) :: :ok
  def validate!(%Params{} = p) do
    case Params.value(p, "charges") do
      list when is_list(list) ->
        list
        |> Enum.reduce(Validation.new("savingsaccount"), &require_amount(p, &1, &2))
        |> Validation.raise_if_errors!()

      _ ->
        :ok
    end
  end

  defp require_amount(p, item, v) do
    amount = if is_map(item), do: Params.decimal_with_locale(%{p | map: item}, "amount")
    v |> Validation.param("amount", amount) |> Validation.not_null()
  end

  @doc "The charges of an application for an account of `product`, made but not stored."
  @spec build!(Params.t(), map) :: [map]
  def build!(%Params{} = p, product) do
    charges =
      case Params.value(p, "charges") do
        list when is_list(list) -> Enum.filter(list, &is_map/1)
        _ -> []
      end

    built =
      for item <- charges do
        element = element(p, item)
        refuse_overrides!(item)

        definition =
          Charges.definition(element.charge_id) ||
            raise(ECBCatalog.Charges.not_found(element.charge_id))

        refuse_unsupported!(definition)

        if definition.applies_to != 2 do
          raise DomainRuleViolation,
            code: "error.msg.charge.cannot.be.applied.to",
            message:
              "Charge with identifier #{definition.id} cannot be applied to Savings product.",
            args: ["savings.product", definition.id]
        end

        {definition, Charges.build(definition, element.attrs, product.currency.decimal_places)}
      end

    validate!(built, product)
    Enum.map(built, &elem(&1, 1))
  end

  # one charge of the list, read as the request's formats say
  defp element(p, item) do
    sub = %{p | map: item}

    %{
      charge_id: Params.long(sub, "chargeId"),
      attrs: %{
        amount: Params.decimal_with_locale(sub, "amount"),
        due_date: Params.date(sub, "dueDate"),
        month_day: month_day(p, item),
        fee_interval: Params.integer_with_locale(sub, "feeInterval")
      }
    }
  end

  defp month_day(p, item) do
    case item["feeOnMonthDay"] do
      nil ->
        nil

      text ->
        format = Params.string(p, "monthDayFormat") || "dd MMMM"
        with_year = if String.contains?(format, ["y", "u"]), do: format, else: format <> " yyyy"
        shown = if with_year == format, do: text, else: text <> " 2000"

        case DatePattern.parse(shown, with_year) do
          {:ok, date} -> {date.month, date.day}
          :error -> nil
        end
    end
  end

  defp refuse_overrides!(item) do
    asked =
      Enum.filter(["id", "chargeTimeType", "chargeCalculationType"], &Map.has_key?(item, &1))

    if asked != [] do
      raise DomainRuleViolation,
        code: "error.msg.savingsaccount.feature.not.supported.yet",
        message:
          "These savings account charge settings are not supported yet by E-CoreBank: " <>
            Enum.join(asked, ", "),
        args: asked
    end
  end

  defp refuse_unsupported!(definition) do
    asked =
      [
        {"isFreeWithdrawal", definition.free_withdrawal == true},
        {"isPaymentType", definition.payment_type == true}
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    if asked != [] do
      raise DomainRuleViolation,
        code: "error.msg.savingsaccount.feature.not.supported.yet",
        message:
          "These savings charge settings are not supported yet by E-CoreBank: " <>
            Enum.join(asked, ", "),
        args: asked
    end
  end

  # `validateSavingsCharges`: the currency of the charge is the product's, and there is one annual fee at most
  defp validate!(built, product) do
    v = Validation.new("savingsaccount")

    v =
      Enum.reduce(built, v, fn {definition, _charge}, v ->
        if definition.currency_code == product.currency.code,
          do: v,
          else:
            v
            |> Validation.param("currency", definition.id)
            |> Validation.fail_without_parameter("currency.and.charge.currency.not.same")
      end)

    annual = Enum.count(built, fn {_d, c} -> Charges.annual?(c) end)

    v =
      if annual > 1,
        do: Validation.fail_without_parameter(v, "multiple.annual.fee.per.account.not.supported"),
        else: v

    if Validation.errors?(v), do: raise(%PlatformApiDataValidation{errors: v.errors}), else: :ok
  end
end
