defmodule ECBOrg.OfficesTest do
  use ECBPlatform.TenantCase, database: "ecb_org_test", reset: false

  alias ECBOrg.Errors.{InvalidOrdering, OfficeNotFound}
  alias ECBOrg.Offices
  alias ECBPlatform.Security.User

  # The seeded head office (id 1, hierarchy ".") is part of the migrated database; tests add branches.
  setup do
    TenantRepo.query!("DELETE FROM m_office WHERE id > 1")
    :ok
  end

  defp head_office_user, do: User.new(1, "mifos", ["ALL_FUNCTIONS"], office_id: 1)

  # Fineract builds a child's hierarchy as the parent's hierarchy plus the child's id and a dot.
  defp add_office(name, parent_id, opts \\ []) do
    %{rows: [[parent_hierarchy]]} =
      TenantRepo.query!("SELECT hierarchy FROM m_office WHERE id = $1", [parent_id])

    %{rows: [[id]]} =
      TenantRepo.query!(
        "INSERT INTO m_office (parent_id, hierarchy, name, opening_date, external_id) VALUES ($1, $2, $3, $4, $5) RETURNING id",
        [
          parent_id,
          parent_hierarchy,
          name,
          Keyword.get(opts, :opening_date, ~D[2020-01-15]),
          opts[:external_id]
        ]
      )

    hierarchy = parent_hierarchy <> Integer.to_string(id) <> "."
    TenantRepo.query!("UPDATE m_office SET hierarchy = $1 WHERE id = $2", [hierarchy, id])
    id
  end

  describe "the seeded head office" do
    test "is what Fineract's own database starts with" do
      assert {:ok, [office]} = Offices.list(head_office_user())

      assert office == %{
               id: 1,
               name: "Head Office",
               name_decorated: "Head Office",
               external_id: "1",
               opening_date: ~D[2009-01-01],
               hierarchy: ".",
               parent_id: nil,
               parent_name: nil
             }
    end
  end

  describe "list/2" do
    test "decorates child names with four dots per level and orders by hierarchy" do
      branch = add_office("Nairobi", 1)
      sub = add_office("Westlands", branch)

      assert {:ok, offices} = Offices.list(head_office_user())

      assert Enum.map(offices, & &1.name_decorated) == [
               "Head Office",
               "....Nairobi",
               "........Westlands"
             ]

      assert Enum.map(offices, & &1.id) == [1, branch, sub]
      assert Enum.find(offices, &(&1.id == sub)).parent_name == "Nairobi"
    end

    test "a user sees only their own branch of the tree unless include_all is set" do
      branch = add_office("Nairobi", 1)
      sub = add_office("Westlands", branch)
      _other = add_office("Mombasa", 1)
      branch_user = User.new(2, "branch", ["READ_OFFICE"], office_id: branch)

      assert {:ok, visible} = Offices.list(branch_user)
      assert Enum.map(visible, & &1.id) == [branch, sub]

      assert {:ok, everything} = Offices.list(branch_user, include_all: true)
      assert length(everything) == 4
    end

    test "orders by a whitelisted field and direction" do
      add_office("Zeta", 1)
      add_office("Alpha", 1)

      assert {:ok, asc} = Offices.list(head_office_user(), order_by: "name")
      assert Enum.map(asc, & &1.name) == ["Alpha", "Head Office", "Zeta"]

      assert {:ok, desc} = Offices.list(head_office_user(), order_by: "name", sort_order: "DESC")
      assert Enum.map(desc, & &1.name) == ["Zeta", "Head Office", "Alpha"]

      assert {:ok, by_date} =
               Offices.list(head_office_user(), order_by: "openingDate", sort_order: "desc")

      assert hd(by_date).opening_date == ~D[2020-01-15]
    end

    test "every documented order field works" do
      add_office("Alpha", 1)

      for field <- ~w(id name externalId openingDate hierarchy parentId parentName) do
        assert {:ok, [_ | _]} = Offices.list(head_office_user(), order_by: field),
               "orderBy #{field}"
      end
    end

    test "refuses an order field or direction that is not allowed" do
      assert {:error,
              %InvalidOrdering{detail: "invalid orderBy value 'name; DROP TABLE m_office'"}} =
               Offices.list(head_office_user(), order_by: "name; DROP TABLE m_office")

      assert {:error, %InvalidOrdering{detail: "invalid sortOrder value 'sideways'"}} =
               Offices.list(head_office_user(), order_by: "name", sort_order: "sideways")

      assert %{rows: [[1]]} = TenantRepo.query!("SELECT count(*) FROM m_office")
    end
  end

  describe "get/1" do
    test "returns an office by id, with its parent" do
      id = add_office("Nairobi", 1, external_id: "NBO")

      assert {:ok,
              %{
                name: "Nairobi",
                external_id: "NBO",
                parent_id: 1,
                parent_name: "Head Office",
                name_decorated: "....Nairobi"
              }} = Offices.get(id)
    end

    test "is not limited to the user's branch" do
      assert {:ok, %{id: 1}} = Offices.get(1)
    end

    test "an unknown id is reported" do
      assert {:error, %OfficeNotFound{office_id: 999}} = Offices.get(999)

      assert Exception.message(%OfficeNotFound{office_id: 999}) ==
               "Office with identifier 999 does not exist"
    end
  end

  describe "template/1" do
    test "offers today as the opening date and the user's branch as possible parents" do
      branch = add_office("Nairobi", 1)
      add_office("Mombasa", 1)

      template = Offices.template(head_office_user())
      assert template.opening_date == Date.utc_today()

      assert Enum.map(template.allowed_parents, & &1.name) == [
               "Head Office",
               "Nairobi",
               "Mombasa"
             ]

      assert hd(template.allowed_parents) == %{
               id: 1,
               name: "Head Office",
               name_decorated: "Head Office"
             }

      scoped = Offices.template(User.new(2, "b", [], office_id: branch))
      assert Enum.map(scoped.allowed_parents, & &1.name) == ["Nairobi"]
    end
  end

  describe "name_decorated/2" do
    test "is four dots per level below the head office, at most forty" do
      assert Offices.name_decorated(".", "Head Office") == "Head Office"
      assert Offices.name_decorated(".2.", "A") == "....A"
      assert Offices.name_decorated(".2.3.", "A") == "........A"

      assert Offices.name_decorated(".1.2.3.4.5.6.7.8.9.10.11.", "Deep") ==
               String.duplicate(".", 40) <> "Deep"
    end
  end
end
