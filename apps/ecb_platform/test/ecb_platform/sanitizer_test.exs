defmodule ECBPlatform.SanitizerTest do
  use ExUnit.Case, async: true

  alias ECBPlatform.Commands.Sanitizer

  test "masks the passwords of a user command and says so" do
    json = ~s({"username":"ada","password":"S3cret!pw","repeatPassword":"S3cret!pw","officeId":1})

    assert {~s({"username":"ada","password":"***","repeatPassword":"***","officeId":1}), true} =
             Sanitizer.sanitize("USER", json)
  end

  test "keeps spacing and the order of the rest of the text" do
    json = ~s({ "a": 1, "password" : "x y",  "z": "last" })

    assert {~s({ "a": 1, "password" : "***",  "z": "last" }), true} =
             Sanitizer.sanitize("USER", json)
  end

  test "handles a password with escaped quotes in it" do
    json = ~S({"password":"a\"b\\","x":1})
    assert {~S({"password":"***","x":1}), true} = Sanitizer.sanitize("USER", json)
  end

  test "a user command without a password, and other entities, are left as they are" do
    assert {~s({"firstname":"Ada"}), false} = Sanitizer.sanitize("USER", ~s({"firstname":"Ada"}))
    assert {~s({"password":"x"}), false} = Sanitizer.sanitize("OFFICE", ~s({"password":"x"}))
  end
end
