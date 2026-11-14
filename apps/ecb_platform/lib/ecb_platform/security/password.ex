defmodule ECBPlatform.Security.Password do
  @moduledoc """
  Checks a password against the hash Fineract stores in `m_appuser.password`.

  Fineract uses Spring Security's delegating encoder: the stored text starts with the scheme in
  braces. The seeded users carry the legacy scheme:

      {SHA-256}{<salt>}<64 hex digits>

  where the digits are the SHA-256 of `<password>{<salt>}` (the salt in braces appended to the
  password). This is Spring's `MessageDigestPasswordEncoder("SHA-256")`.

  Fineract writes **new** passwords as `{bcrypt}$2a$10$...`, which `encode/1` does and `matches?/2`
  checks. A stored password in any other scheme never matches, which fails closed.
  """

  @bcrypt_cost 10

  @doc "Encodes a new password the way Fineract does: `{bcrypt}` and a salted hash at cost 10."
  @spec encode(String.t()) :: String.t()
  def encode(raw) when is_binary(raw) do
    "{bcrypt}" <> Bcrypt.Base.hash_password(raw, Bcrypt.Base.gen_salt(@bcrypt_cost, true))
  end

  @doc "True when `raw` matches the stored hash."
  @spec matches?(String.t(), String.t() | nil) :: boolean
  def matches?(raw, "{SHA-256}" <> rest) when is_binary(raw) do
    case Regex.run(~r/\A\{([^}]*)\}([0-9a-fA-F]{64})\z/, rest) do
      [_, salt, hex] ->
        digest = :crypto.hash(:sha256, raw <> "{" <> salt <> "}") |> Base.encode16(case: :lower)
        constant_time_equal?(digest, String.downcase(hex))

      _ ->
        false
    end
  end

  def matches?(raw, "{bcrypt}" <> hash) when is_binary(raw), do: Bcrypt.verify_pass(raw, hash)

  def matches?(_raw, _stored), do: false

  # Both sides are 64 hex characters here, so the lengths always agree.
  defp constant_time_equal?(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp constant_time_equal?(_a, _b), do: false
end
