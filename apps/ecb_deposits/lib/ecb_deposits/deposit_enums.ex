defmodule ECBDeposits.DepositEnums do
  @moduledoc """
  The fixed choices fixed and recurring deposits are built from, as `{id, code, value}` (Fineract's
  `SavingsEnumerations`, `InterestIncentivesEnumerations` and the dropdown lists of the deposit and interest rate
  chart services).
  """

  @fixed 200
  @recurring 300

  @doc "The deposit type of fixed deposits."
  def fixed, do: @fixed
  @doc "The deposit type of recurring deposits."
  def recurring, do: @recurring

  # the unit of a deposit term, a minimum or maximum, or the step a term goes up in
  @term_units [
    {0, "deposit.term.savingsPeriodFrequencyType.days", "Days"},
    {1, "deposit.term.savingsPeriodFrequencyType.weeks", "Weeks"},
    {2, "deposit.term.savingsPeriodFrequencyType.months", "Months"},
    {3, "deposit.term.savingsPeriodFrequencyType.years", "Years"}
  ]

  # the units the template offers, which also has the one Fineract calls invalid
  @frequency_options [
    {0, "frequencyperiodFrequencyType.days", "Days"},
    {1, "frequencyperiodFrequencyType.weeks", "Weeks"},
    {2, "frequencyperiodFrequencyType.months", "Months"},
    {3, "frequencyperiodFrequencyType.years", "Years"},
    {5, "periodFrequencyType.invalid", "Invalid"}
  ]

  @pre_closure_on [
    {1, "preClosurePenalInterestOnType.wholeTerm", "Whole term"},
    {2, "preClosurePenalInterestOnType.tillPrematureWithdrawal", "Till Premature Withdrawal"}
  ]

  # the period of a slab of an interest rate chart
  @chart_periods [
    {0, "periodFrequencyType.days", "Days"},
    {1, "periodFrequencyType.weeks", "Weeks"},
    {2, "periodFrequencyType.months", "Months"},
    {3, "periodFrequencyType.years", "Years"},
    {4, "periodFrequencyType.whole_term", "Whole Term"}
  ]

  @incentive_entities [
    {2, "InterestIncentiveEntityType.customer", "Customer"},
    {3, "InterestIncentiveEntityType.account", "account"}
  ]

  @incentive_attributes [
    {2, "InterestIncentiveAttributeName.gender", "Gender"},
    {3, "InterestIncentiveAttributeName.age", "age"},
    {4, "InterestIncentiveAttributeName.clientType", "Client Type"},
    {5, "InterestIncentiveAttributeName.clientClassification", "Client Classification"}
  ]

  @incentive_conditions [
    {1, "incentiveConditionType.lessthan", "lessthan"},
    {2, "incentiveConditionType.equal", "equal"},
    {3, "incentiveConditionType.greaterthan", "greaterthan"},
    {4, "incentiveConditionType.notequal", "notEqual"}
  ]

  @incentive_types [
    {2, "InterestIncentiveType.fixed", "Fixed"},
    {3, "InterestIncentiveType.incentive", "Incentive"}
  ]

  @doc "The units of a deposit term, as options."
  def term_units, do: options(@term_units)
  @doc "The ids a term unit may have."
  def term_unit_ids, do: ids(@term_units)
  @doc "A unit of a deposit term as Fineract shows it."
  def term_unit(id), do: one(@term_units, id)
  @doc "The units the template offers."
  def frequency_options, do: options(@frequency_options)
  @doc "What the pre-closure penalty is charged on, as options."
  def pre_closure_on, do: options(@pre_closure_on)
  @doc "The ids the pre-closure penalty's basis may have."
  def pre_closure_on_ids, do: ids(@pre_closure_on)
  @doc "The basis of the pre-closure penalty as Fineract shows it."
  def pre_closure_on(id), do: one(@pre_closure_on, id)
  @doc "The periods of a chart slab, as options."
  def chart_periods, do: options(@chart_periods)
  @doc "The ids a chart slab's period may have."
  def chart_period_ids, do: ids(@chart_periods)
  @doc "A period of a chart slab as Fineract shows it."
  def chart_period(id), do: one(@chart_periods, id)
  @doc "What an incentive can apply to, as options."
  def incentive_entities, do: options(@incentive_entities)
  @doc "The ids an incentive's entity may have."
  def incentive_entity_ids, do: ids(@incentive_entities)
  @doc "An incentive's entity as Fineract shows it."
  def incentive_entity(id), do: one(@incentive_entities, id)
  @doc "The attributes an incentive can depend on, as options."
  def incentive_attributes, do: options(@incentive_attributes)
  @doc "The ids an incentive's attribute may have."
  def incentive_attribute_ids, do: ids(@incentive_attributes)
  @doc "An incentive's attribute as Fineract shows it."
  def incentive_attribute(id), do: one(@incentive_attributes, id)
  @doc "The conditions an incentive can have, as options."
  def incentive_conditions, do: options(@incentive_conditions)
  @doc "The ids an incentive's condition may have."
  def incentive_condition_ids, do: ids(@incentive_conditions)
  @doc "An incentive's condition as Fineract shows it."
  def incentive_condition(id), do: one(@incentive_conditions, id)
  @doc "The kinds of incentive, as options."
  def incentive_types, do: options(@incentive_types)
  @doc "The ids an incentive's kind may have."
  def incentive_type_ids, do: ids(@incentive_types)
  @doc "An incentive's kind as Fineract shows it."
  def incentive_type(id), do: one(@incentive_types, id)

  @doc "Whether the attribute's value is the id of a code value (gender, client type, classification)."
  def code_value_attribute?(id), do: id in [2, 4, 5]

  defp options(list),
    do: Enum.map(list, fn {id, code, value} -> %{id: id, code: code, value: value} end)

  defp ids(list), do: Enum.map(list, &elem(&1, 0))

  defp one(_list, nil), do: nil

  defp one(list, id) do
    case Enum.find(list, &(elem(&1, 0) == id)) do
      nil -> nil
      {id, code, value} -> %{id: id, code: code, value: value}
    end
  end
end
