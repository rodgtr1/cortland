"""Unit tests for bin/run. A fake runner stands in for every command; the
tests never run the real CLI."""

import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import unittest

sys.dont_write_bytecode = True

_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "bin", "run")
_loader = importlib.machinery.SourceFileLoader("extension_run", _SCRIPT)
_spec = importlib.util.spec_from_loader("extension_run", _loader)
ext = importlib.util.module_from_spec(_spec)
_loader.exec_module(ext)

LIVE_SESSION = '{"logged_in": true}'
TWO_WIDGETS = '[{"name": "alpha", "status": "running"}, {"name": "beta"}]'


class FakeRunner:
    """Answers each argv from a table. A value that is an exception is raised.
    Records every call, and fails the test on an argv it does not know."""

    def __init__(self, answers):
        self.answers = {tuple(argv): value for argv, value in answers}
        self.calls = []

    def __call__(self, argv):
        self.calls.append(list(argv))
        value = self.answers[tuple(argv)]
        if isinstance(value, Exception):
            raise value
        return value


def live(listing=TWO_WIDGETS):
    return FakeRunner([(ext.SESSION_COMMAND, LIVE_SESSION), (ext.LIST_COMMAND, listing)])


def call(args, run):
    out, err = io.StringIO(), io.StringIO()
    status = ext.main(["run"] + args, run=run, out=out, err=err)
    return status, out.getvalue(), err.getvalue()


class PanelTests(unittest.TestCase):
    def test_live_session_lists_rows_and_actions(self):
        status, out, _ = call(["panel"], live())
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out), {
            "sections": [{
                "title": "Widgets",
                "empty": "No widgets",
                "rows": [
                    {"id": "widget/alpha", "title": "alpha", "icon": "cube",
                     "actions": [{"id": "open", "title": "Open"}], "detail": "running"},
                    {"id": "widget/beta", "title": "beta", "icon": "cube",
                     "actions": [{"id": "open", "title": "Open"}]},
                ],
            }],
            "actions": [{"id": "new", "title": "New Widget", "icon": "plus"}],
        })

    def test_skips_records_without_a_name_and_repeats(self):
        listing = '[{"name": "a"}, {"name": "a"}, {"status": "x"}, "junk", {"name": "  "}]'
        _, out, _ = call(["panel"], live(listing))
        rows = json.loads(out)["sections"][0]["rows"]
        self.assertEqual([row["id"] for row in rows], ["widget/a"])

    def test_logged_out_lists_nothing_and_offers_no_actions(self):
        for answer in ['{"logged_in": false}', "{}", '{"logged_in": "yes"}', "not json", "[]",
                       ext.CommandError("session expired")]:
            run = FakeRunner([(ext.SESSION_COMMAND, answer)])
            status, out, _ = call(["panel"], run)
            panel = json.loads(out)
            self.assertEqual(status, 0)
            self.assertIn("Not logged in", panel["message"])
            self.assertNotIn("actions", panel)
            self.assertEqual(panel["sections"][0]["rows"], [])
            # The listing never runs without proof of a live session.
            self.assertEqual(run.calls, [ext.SESSION_COMMAND])

    def test_tool_missing_is_a_message_not_a_failure(self):
        run = FakeRunner([(ext.SESSION_COMMAND, ext.ToolNotFound("widgets not found on PATH"))])
        status, out, _ = call(["panel"], run)
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out)["message"], "widgets not found on PATH")

    def test_listing_failure_is_a_message_without_actions(self):
        run = FakeRunner([
            (ext.SESSION_COMMAND, LIVE_SESSION),
            (ext.LIST_COMMAND, ext.CommandError("widgets timed out after 20s")),
        ])
        status, out, _ = call(["panel"], run)
        panel = json.loads(out)
        self.assertEqual(status, 0)
        self.assertEqual(panel["message"], "widgets timed out after 20s")
        self.assertNotIn("actions", panel)


class ActionTests(unittest.TestCase):
    def test_new_opens_a_tab(self):
        status, out, _ = call(["action", "new"], FakeRunner([]))
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out), {"open_tab": {"command": [ext.TOOL, "new"]}})

    def test_open_opens_a_tab_for_the_row(self):
        run = FakeRunner([])
        status, out, _ = call(["action", "open", "widget/alpha"], run)
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out), {"open_tab": {"command": [ext.TOOL, "open", "alpha"]}})
        self.assertEqual(run.calls, [])

    def test_open_rejects_bad_row_ids(self):
        for row_id, reason in [
            ("other/alpha", "must start with widget/"),
            ("widget/", "nothing after"),
            ("widget/--force", "starts with '-'"),
        ]:
            status, out, err = call(["action", "open", row_id], FakeRunner([]))
            self.assertEqual(status, 1, row_id)
            self.assertEqual(out, "")
            self.assertIn(reason, err)

    def test_open_without_a_row_id(self):
        status, _, err = call(["action", "open"], FakeRunner([]))
        self.assertEqual(status, 1)
        self.assertIn("needs a row id", err)

    def test_new_with_a_row_id(self):
        status, _, _ = call(["action", "new", "widget/alpha"], FakeRunner([]))
        self.assertEqual(status, 1)

    def test_unknown_action(self):
        status, out, err = call(["action", "bogus"], FakeRunner([]))
        self.assertEqual(status, 1)
        self.assertEqual(out, "")
        self.assertEqual(err, "unknown action: bogus\n")


class UsageTests(unittest.TestCase):
    def test_anything_else_prints_usage_and_exits_2(self):
        for args in [[], ["list"], ["panel", "extra"], ["action"], ["action", "open", "widget/a", "x"]]:
            status, out, err = call(args, FakeRunner([]))
            self.assertEqual(status, 2, args)
            self.assertEqual(out, "")
            self.assertEqual(err, ext.USAGE + "\n")


class RunCommandTests(unittest.TestCase):
    """The real subprocess helper, on commands that exist on every Mac."""

    def test_returns_stdout(self):
        self.assertEqual(ext.run_command(["/bin/echo", "hi"]), "hi\n")

    def test_stdin_is_dev_null(self):
        self.assertEqual(ext.run_command(["/bin/cat"]), "")

    def test_missing_tool(self):
        with self.assertRaises(ext.ToolNotFound):
            ext.run_command(["no-such-tool-for-cortland-tests"])

    def test_non_zero_exit_carries_first_stderr_line(self):
        with self.assertRaises(ext.CommandError) as caught:
            ext.run_command(["/bin/sh", "-c", "echo; echo '  bad thing  ' >&2; exit 3"])
        self.assertEqual(str(caught.exception), "bad thing")


if __name__ == "__main__":
    unittest.main()
