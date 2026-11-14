defmodule ECBApiFineract.Resources.BusinessDate do
  @moduledoc """
  `/v1/businessdate`: the business dates, one by type, and setting one.

  Reading needs no permission beyond being signed in, as in Fineract. Setting needs `UPDATE_BUSINESS_DATE`
  and is refused with the web container's plain 403 without it. The request is validated the way
  Fineract's typed requests are: every problem is listed with a rule name and the field's path
  (`updateBusinessDate.request.type`). Like Fineract's, this operation leaves no stored command.
  """
  alias ECBApiFineract.{Errors, Response}
  alias ECBPlatform.BusinessDate
  alias ECBPlatform.Errors.PlatformApiDataValidation
  alias ECBPlatform.Params.DatePattern
  alias ECBPlatform.Security.User

  @prefix "org.apache.fineract."
  @path "updateBusinessDate.request"

  @doc "`GET /businessdate`"
  def index(conn), do: Response.json(conn, 200, Enum.map(BusinessDate.list(), &entry/1))

  @doc "`GET /businessdate/:type`"
  def show(conn, type) do
    case BusinessDate.get(type) do
      {:ok, row} -> Response.json(conn, 200, entry(row))
      {:error, error} -> Errors.render(conn, error)
    end
  end

  @doc "`POST /businessdate`"
  def update(conn) do
    user = conn.assigns.current_user

    if User.has_permission?(user, "ALL_FUNCTIONS") or
         User.has_permission?(user, "UPDATE_BUSINESS_DATE") do
      do_update(conn, user)
    else
      Errors.forbidden(conn)
    end
  end

  defp do_update(conn, user) do
    body =
      if is_map(conn.body_params) and not is_struct(conn.body_params),
        do: conn.body_params,
        else: %{}

    {type, date} = validate!(body)
    result = BusinessDate.update!(type, date, user.id)

    Response.json(conn, 200, %{
      "description" => result.description,
      "type" => result.type,
      "date" => result.date,
      "changes" => result.changes
    })
  rescue
    error ->
      if ECBPlatform.Errors.to_api(error),
        do: Errors.render(conn, error),
        else: reraise(error, __STACKTRACE__)
  end

  defp validate!(body) do
    format = text(body["dateFormat"])
    type = text(body["type"])
    date_text = text(body["date"])
    locale = text(body["locale"])

    date = if format != "" and locale != "", do: parse(date_text, format)

    errors =
      Enum.reject(
        [
          blank(format, "date-format", "dateFormat"),
          if(type not in BusinessDate.types(),
            do:
              rule(
                "type.invalid",
                "type",
                "The parameter 'type' must be valid BusinessDateType value. Provided value: '#{type}'."
              )
          ),
          blank(type, "type", "type"),
          blank(date_text, "date", "date"),
          blank(locale, "locale", "locale"),
          if(locale == "" or not valid_locale?(locale),
            do:
              ECBPlatform.Errors.parameter_error(
                @prefix <> "validation.locale",
                "The parameter `locale` has an invalid language value: `#{locale}`.",
                @path <> ".locale"
              )
          ),
          if(is_nil(date),
            do:
              ECBPlatform.Errors.parameter_error(
                @prefix <> "validation.local-date",
                "Wrong local date fields.",
                @path
              )
          )
        ],
        &is_nil/1
      )

    if errors != [], do: raise(PlatformApiDataValidation, errors: errors)
    {type, date}
  end

  defp blank("", rule, field),
    do: rule(rule <> ".not-blank", field, "The parameter '#{field}' is mandatory.")

  defp blank(_value, _rule, _field), do: nil

  defp rule(rule, field, message),
    do:
      ECBPlatform.Errors.parameter_error(
        @prefix <> "businessdate." <> rule,
        message,
        @path <> "." <> field
      )

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_), do: ""

  defp valid_locale?(locale), do: Regex.match?(~r/^[a-z]{2,3}([_-][A-Za-z]{2})?$/, locale)

  defp parse("", _format), do: nil

  defp parse(text, format) do
    case DatePattern.parse(text, format) do
      {:ok, date} -> date
      :error -> nil
    end
  end

  defp entry(row), do: %{"description" => row.description, "type" => row.type, "date" => row.date}
end
