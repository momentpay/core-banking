defmodule ECBPlatform.Changes do
  @moduledoc """
  What an update really changes, built the way Fineract's entities build their `update(command)`.

  Each `text/5`, `boolean/5`, ... looks at one parameter. If the request carries it and the value
  differs from what is stored, the change is remembered twice: how it is *shown* in the response
  (`public/1`: the text as the client wrote it, for a date the raw string) and what is to be *stored*
  (`set/1`: column and value). A parameter that is absent, or equal to the stored value, changes
  nothing.
  """
  alias ECBPlatform.Params

  defstruct public: %{}, set: %{}

  @type t :: %__MODULE__{public: map, set: map}

  @doc "No changes yet."
  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc "True when nothing has changed."
  @spec empty?(t) :: boolean
  def empty?(%__MODULE__{public: public}), do: map_size(public) == 0

  @doc "What the response shows."
  @spec public(t) :: map
  def public(%__MODULE__{public: public}), do: public

  @doc "Column values to store, as a keyword list."
  @spec set(t) :: keyword
  def set(%__MODULE__{set: set}), do: Map.to_list(set)

  @doc "Records `value` as the new stored value of `column` without showing it (for derived columns)."
  @spec store(t, atom, term) :: t
  def store(%__MODULE__{} = c, column, value), do: %{c | set: Map.put(c.set, column, value)}

  @doc """
  A text parameter. As in Fineract a blank value is the empty text for deciding whether something
  changed; it is stored as `nil`.
  """
  @spec text(t, Params.t(), String.t(), atom, String.t() | nil) :: t
  def text(%__MODULE__{} = c, params, key, column, existing) do
    if Params.changed_string?(params, key, existing) do
      value = Params.command_string(params, key)
      put(c, key, value, column, if(value == "", do: nil, else: String.trim(value)))
    else
      c
    end
  end

  @doc "A whole-number parameter."
  @spec long(t, Params.t(), String.t(), atom, integer | nil) :: t
  def long(%__MODULE__{} = c, params, key, column, existing) do
    if Params.changed_long?(params, key, existing),
      do: put(c, key, Params.long(params, key), column, Params.long(params, key)),
      else: c
  end

  @doc "A true or false parameter."
  @spec boolean(t, Params.t(), String.t(), atom, boolean | nil) :: t
  def boolean(%__MODULE__{} = c, params, key, column, existing) do
    if Params.changed_boolean?(params, key, existing),
      do: put(c, key, Params.boolean(params, key), column, Params.boolean(params, key)),
      else: c
  end

  @doc """
  A date parameter. The response shows the date as written, and with it the `dateFormat` and `locale`
  the client sent (as Fineract does).
  """
  @spec date(t, Params.t(), String.t(), atom, Date.t() | nil) :: t
  def date(%__MODULE__{} = c, params, key, column, existing) do
    if Params.changed_date?(params, key, existing) do
      c
      |> put(key, Params.string(params, key), column, Params.date(params, key))
      |> show("dateFormat", Params.date_format(params))
      |> show("locale", Params.locale(params))
    else
      c
    end
  end

  @doc "Shows `key` in the response without storing anything for it."
  @spec show(t, String.t(), term) :: t
  def show(%__MODULE__{} = c, key, value), do: %{c | public: Map.put(c.public, key, value)}

  defp put(c, key, shown, column, stored),
    do: %{c | public: Map.put(c.public, key, shown), set: Map.put(c.set, column, stored)}
end
