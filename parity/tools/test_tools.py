"""Unit tests for the parity tools. Run from the repository root:

    python -m unittest discover -s parity/tools -v
"""
import json
import tempfile
import unittest
from pathlib import Path

import contract_probe as probe
import inventory as inv
import junit_report as jr


class ShapeComparison(unittest.TestCase):
    def test_equal_ignores_values(self):
        a = {"id": 1, "name": "x", "tags": ["a"]}
        b = {"id": 99, "name": "y", "tags": ["b", "c"]}
        self.assertTrue(probe.compare_shapes(a, b)["equal"])

    def test_missing_field_is_reported(self):
        diff = probe.compare_shapes({"id": 1, "name": "x"}, {"id": 1})
        self.assertFalse(diff["equal"])
        self.assertEqual(diff["missing"], ["$.name"])

    def test_extra_field_is_reported(self):
        diff = probe.compare_shapes({"id": 1}, {"id": 1, "surprise": True})
        self.assertEqual(diff["extra"], ["$.surprise"])

    def test_type_mismatch_is_reported(self):
        diff = probe.compare_shapes({"amount": 1.5}, {"amount": "1.5"})
        self.assertEqual(len(diff["type_mismatch"]), 1)

    def test_null_is_compatible_with_any_type(self):
        self.assertTrue(probe.compare_shapes({"x": None}, {"x": 5})["equal"])
        self.assertTrue(probe.compare_shapes({"x": 5}, {"x": None})["equal"])

    def test_int_and_float_are_both_numbers(self):
        self.assertTrue(probe.compare_shapes({"x": 1}, {"x": 1.25})["equal"])

    def test_fields_under_an_empty_array_are_not_compared(self):
        full = {"items": [{"id": 1, "name": "a"}]}
        empty = {"items": []}
        self.assertTrue(probe.compare_shapes(full, empty)["equal"])
        self.assertTrue(probe.compare_shapes(empty, full)["equal"])

    def test_array_element_shape_is_compared_when_both_have_elements(self):
        diff = probe.compare_shapes({"items": [{"id": 1}]}, {"items": [{"id": 1, "x": 2}]})
        self.assertEqual(diff["extra"], ["$.items[].x"])

    def test_top_level_array(self):
        self.assertTrue(probe.compare_shapes([{"id": 1}], [{"id": 2}, {"id": 3}])["equal"])


def _resp(status, body=None, error=None):
    return {"status": status, "content_type": "application/json", "body": body, "error": error, "ms": 1}


ROW = {"method": "GET", "path": "/v1/offices", "group": "org-reference", "priority": "must"}


class Judging(unittest.TestCase):
    def test_pass(self):
        r = probe.judge(ROW, _resp(200, [{"id": 1}]), _resp(200, [{"id": 2}]))
        self.assertEqual(r["outcome"], "PASS")

    def test_status_diff(self):
        self.assertEqual(probe.judge(ROW, _resp(200, []), _resp(404, {}))["outcome"], "STATUS_DIFF")

    def test_shape_diff(self):
        r = probe.judge(ROW, _resp(200, {"a": 1}), _resp(200, {"b": 1}))
        self.assertEqual(r["outcome"], "SHAPE_DIFF")
        self.assertIn("counts", r["detail"])

    def test_target_error(self):
        r = probe.judge(ROW, _resp(200, []), _resp(None, error="ConnectionRefusedError"))
        self.assertEqual(r["outcome"], "TARGET_ERROR")

    def test_oracle_5xx_is_skipped_even_if_target_is_down(self):
        r = probe.judge(ROW, _resp(500, {}), _resp(None, error="boom"))
        self.assertEqual(r["outcome"], "SKIPPED")

    def test_without_oracle_a_2xx_passes(self):
        self.assertEqual(probe.judge(ROW, None, _resp(200, {}))["outcome"], "PASS")
        self.assertEqual(probe.judge(ROW, None, _resp(404, {}))["outcome"], "STATUS_DIFF")

    def test_pass_rate_excludes_skipped(self):
        results = [{"outcome": "PASS"}, {"outcome": "SHAPE_DIFF"}, {"outcome": "SKIPPED"}]
        self.assertEqual(probe.pass_rate(results), (1, 2))


class Classification(unittest.TestCase):
    index = {"Client": ("clients", "must"), "Calendar": ("org-reference", "defer")}
    overrides = [
        {"prefix": "/v1/{entityType}", "group": "org-reference", "priority": "should"},
        {"prefix": "/v1/internal", "group": "test-support", "priority": "test-support", "applies_to_tagged": True},
    ]

    def test_tag_decides_for_tagged_operations(self):
        out = inv.classify("/v1/{entityType}/{entityId}/calendars", {"tags": ["Calendar"]}, self.index, self.overrides)
        self.assertEqual(out[1:3], ("org-reference", "defer"))

    def test_override_covers_untagged_operations(self):
        out = inv.classify("/v1/{entityType}/x", {}, self.index, self.overrides)
        self.assertEqual(out[1:3], ("org-reference", "should"))

    def test_override_can_beat_a_tag_when_asked(self):
        out = inv.classify("/v1/internal/cob", {"tags": ["Client"]}, self.index, self.overrides)
        self.assertEqual(out[1:3], ("test-support", "test-support"))

    def test_unclassified_is_empty(self):
        self.assertEqual(inv.classify("/v1/mystery", {"tags": ["New"]}, self.index, self.overrides)[1:3], ("", ""))

    def test_duplicate_tag_is_a_problem(self):
        groups = {"groups": {"a": {"tags": {"must": ["X"]}}, "b": {"tags": {"defer": ["X"]}}}}
        _, problems = inv.tag_index(groups)
        self.assertTrue(any("classified twice" in p for p in problems))

    def test_unknown_priority_is_a_problem(self):
        _, problems = inv.tag_index({"groups": {"a": {"tags": {"urgent": ["X"]}}}})
        self.assertTrue(any("unknown priority" in p for p in problems))


class RealInventory(unittest.TestCase):
    """The committed groups.json must classify every operation in the committed spec."""

    def test_every_operation_is_classified(self):
        groups = inv.load_groups()
        spec = inv.load_spec(groups)
        self.assertEqual(inv.problems_for(spec, groups), [])

    def test_committed_csv_is_up_to_date(self):
        groups = inv.load_groups()
        spec = inv.load_spec(groups)
        rows = inv.build_rows(spec, groups)
        committed = (inv.INVENTORY_DIR / "endpoints.csv").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(committed) - 1, len(rows), "endpoints.csv is stale: run inventory.py build")


JUNIT = """<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="x" tests="4">
  <testcase classname="org.apache.fineract.integrationtests.ClientTest" name="a"/>
  <testcase classname="org.apache.fineract.integrationtests.ClientTest" name="b"><failure message="boom"/></testcase>
  <testcase classname="org.apache.fineract.integrationtests.LoanProductTest" name="c"/>
  <testcase classname="org.apache.fineract.integrationtests.LoanProductTest" name="d"><skipped/></testcase>
</testsuite>
"""


class JunitReport(unittest.TestCase):
    def test_groups_and_pass_rates(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "TEST-x.xml").write_text(JUNIT, encoding="utf-8")
            cases = jr.parse_results(Path(d))
        self.assertEqual(len(cases), 4)
        summary = jr.summarize(cases, jr.load_rules())
        self.assertEqual(jr.pass_rate(summary["by_group"]["clients"]), (1, 2))
        self.assertEqual(jr.pass_rate(summary["by_group"]["loans"]), (1, 1))  # skipped not counted
        self.assertEqual(jr.pass_rate(summary["total"]), (2, 3))

    def test_group_for_uses_the_first_matching_rule(self):
        rules = jr.load_rules()
        self.assertEqual(jr.group_for("a.b.FeignWorkingCapitalLoanRateChangeTest", rules), "working-capital")
        self.assertEqual(jr.group_for("a.b.ClientLoanIntegrationTest", rules), "loans")
        self.assertEqual(jr.group_for("a.b.ClientSavingsIntegrationTest", rules), "deposits")
        self.assertEqual(jr.group_for("a.b.SomethingNew", rules), "other")


if __name__ == "__main__":
    unittest.main()
