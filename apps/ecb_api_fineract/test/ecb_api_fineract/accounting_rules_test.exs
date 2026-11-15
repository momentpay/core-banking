defmodule ECBApiFineract.AccountingRulesTest do
  @moduledoc """
  Accounting rules beyond the responses recorded from Fineract (those are in `ScenariosTest`): permissions,
  the accounts a tagged side allows, what deleting a rule leaves behind, and the order tags are reported in.
  """
  use ECBApiFineract.ApiCase

  alias ECBLedger.AccountingRules.JavaOrder
  alias ECBPlatform.TenantRepo

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp tag(code_id, name),
    do:
      body(send_json(:post, "/v1/codes/#{code_id}/codevalues", %{"name" => name}))[
        "subResourceId"
      ]

  defp account(code, type, tag_id) do
    body(
      send_json(:post, "/v1/glaccounts", %{
        "name" => "Account #{code}",
        "glCode" => code,
        "manualEntriesAllowed" => true,
        "type" => type,
        "usage" => 1,
        "tagId" => tag_id
      })
    )["resourceId"]
  end

  defp rule(extra),
    do:
      send_json(
        :post,
        "/v1/accountingrules",
        Map.merge(%{"name" => "Rule", "officeId" => 1}, extra)
      )

  setup do
    cash_tag = tag(7, "Cash")
    bank_tag = tag(7, "Bank")

    %{
      cash_tag: cash_tag,
      bank_tag: bank_tag,
      cash: account("1000", 1, cash_tag),
      bank: account("1100", 1, bank_tag)
    }
  end

  describe "a tagged side" do
    test "allows the accounts that carry its tags",
         %{cash_tag: cash_tag, bank_tag: bank_tag} = ctx do
      assert rule(%{"debitTags" => [cash_tag, bank_tag], "accountToCredit" => ctx.cash}).status ==
               200

      [listed] = body(send_json(:get, "/v1/accountingrules?associations=all"))

      assert listed["debitAccounts"] |> Enum.map(& &1["id"]) |> Enum.sort() ==
               Enum.sort([ctx.cash, ctx.bank])

      assert listed["creditAccounts"] |> Enum.map(& &1["id"]) == [ctx.cash]
      refute Map.has_key?(listed, "debitTags")
    end

    test "is listed with its tags when the accounts are not asked for", %{cash_tag: cash_tag} do
      rule(%{"debitTags" => [cash_tag], "accountToCredit" => 1})

      [listed] = body(send_json(:get, "/v1/accountingrules"))
      assert [%{"tag" => %{"id" => ^cash_tag}}] = listed["debitTags"]
      refute Map.has_key?(listed, "debitAccounts")
    end

    test "leaves the tags it uses out of its template options", %{
      cash_tag: cash_tag,
      bank_tag: bank_tag
    } do
      rule(%{"debitTags" => [cash_tag], "accountToCredit" => 1})

      template = body(send_json(:get, "/v1/accountingrules/1?template=true"))
      assert Enum.map(template["allowedDebitTagOptions"], & &1["id"]) == [bank_tag]
      assert Enum.map(template["allowedCreditTagOptions"], & &1["id"]) == [cash_tag, bank_tag]
    end
  end

  describe "deleting a rule" do
    test "takes its tags with it", %{cash_tag: cash_tag} do
      rule(%{"debitTags" => [cash_tag], "creditTags" => [cash_tag]})
      assert TenantRepo.aggregate("acc_rule_tags", :count) == 2

      assert send_json(:delete, "/v1/accountingrules/1").status == 200
      assert TenantRepo.aggregate("acc_rule_tags", :count) == 0
    end
  end

  describe "posting by a rule" do
    defp post_by_rule(rule_id, debits, credits) do
      send_json(:post, "/v1/journalentries", %{
        "officeId" => 1,
        "currencyCode" => "USD",
        "transactionDate" => "2025-03-01",
        "dateFormat" => "yyyy-MM-dd",
        "locale" => "en",
        "accountingRule" => rule_id,
        "debits" => Enum.map(debits, &%{"glAccountId" => &1, "amount" => 10}),
        "credits" => Enum.map(credits, &%{"glAccountId" => &1, "amount" => 10})
      })
    end

    test "a refused posting leaves nothing behind but the ids it used", ctx do
      rule(%{"accountToDebit" => ctx.bank, "accountToCredit" => ctx.cash})

      refused = post_by_rule(1, [ctx.cash], [ctx.bank])
      assert refused.status == 403
      assert body(send_json(:get, "/v1/journalentries"))["pageItems"] == []

      assert post_by_rule(1, [ctx.bank], [ctx.cash]).status == 200
      assert body(send_json(:get, "/v1/journalentries"))["totalFilteredRecords"] == 2
    end

    test "both sides tagged: several lines on tagged accounts are fine, others are not",
         %{
           cash_tag: cash_tag,
           bank_tag: bank_tag
         } = ctx do
      rule(%{"debitTags" => [cash_tag, bank_tag], "creditTags" => [cash_tag, bank_tag]})

      assert post_by_rule(1, [ctx.cash, ctx.bank], [ctx.cash, ctx.cash]).status == 200
      assert post_by_rule(1, [999], [ctx.cash]).status == 403

      loose = account("1900", 1, nil)
      refused = post_by_rule(1, [loose], [ctx.cash])
      assert refused.status == 403

      assert hd(body(refused)["errors"])["userMessageGlobalisationCode"] ==
               "error.msg.glJournalEntry.invalid.debits"
    end
  end

  describe "permissions" do
    test "reading needs READ_ACCOUNTINGRULE and each write its own", %{cash: cash, bank: bank} do
      reader = make_user("rule-reader", ["READ_ACCOUNTINGRULE"])
      assert send_json(:get, "/v1/accountingrules", nil, reader).status == 200
      assert send_json(:get, "/v1/accountingrules/template", nil, reader).status == 200

      body = %{
        "name" => "R",
        "officeId" => 1,
        "accountToDebit" => bank,
        "accountToCredit" => cash
      }

      assert send_json(:post, "/v1/accountingrules", body, reader).status == 403

      creator = make_user("rule-creator", ["CREATE_ACCOUNTINGRULE"])
      assert send_json(:post, "/v1/accountingrules", body, creator).status == 200
      assert send_json(:put, "/v1/accountingrules/1", %{"name" => "S"}, creator).status == 403
      assert send_json(:delete, "/v1/accountingrules/1", nil, creator).status == 403

      nobody = make_user("rule-nobody", ["READ_OFFICE"])
      assert send_json(:get, "/v1/accountingrules", nil, nobody).status == 403
    end
  end

  describe "the order of a set of tags" do
    test "follows Java's HashSet of the tag ids as text" do
      # "23" hashes to bucket 1, "24" to 2, "25" to 3 and so on, in a table of 16
      assert JavaOrder.order(["25", "23", "24"]) == ["23", "24", "25"]
      assert JavaOrder.order(["24", "24", "23"]) == ["23", "24"]
    end

    test "keeps the order of two entries that share a bucket" do
      # "2" (hash 50) and "B" (hash 66) both fall in bucket 2 of 16
      assert JavaOrder.order(["B", "2"]) == ["B", "2"]
      assert JavaOrder.order(["2", "B"]) == ["2", "B"]
    end
  end
end
