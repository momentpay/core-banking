defmodule ECBPlatform.Commands.Sanitizer do
  @moduledoc """
  Keeps secrets out of the stored copy of a command.

  A command is stored as the JSON text it arrived with. For the commands that carry a password (the
  `USER` ones) the secret values are replaced with `***` before anything is written, and the stored
  command is marked sanitized, as Fineract does. The secret is only ever in memory while the command runs.

  A sanitized command cannot be approved later from its stored copy (the secret is gone); the pipeline
  refuses that.
  """

  @secret_keys %{"USER" => ~w(password repeatPassword)}

  @doc "The JSON to store and whether anything was masked: `{json, sanitized?}`."
  @spec sanitize(String.t(), String.t()) :: {String.t(), boolean}
  def sanitize(entity, json) when is_binary(json) do
    case Map.get(@secret_keys, entity) do
      nil ->
        {json, false}

      keys ->
        masked = Enum.reduce(keys, json, &mask(&2, &1))
        {masked, masked != json}
    end
  end

  # Replaces a text value `"key": "secret"` with `"key": "***"`, leaving the rest of the text untouched.
  defp mask(json, key) do
    pattern = Regex.compile!("(\"" <> Regex.escape(key) <> "\"\\s*:\\s*)\"(?:[^\"\\\\]|\\\\.)*\"")
    Regex.replace(pattern, json, "\\1\"***\"")
  end
end
