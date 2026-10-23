#!/usr/bin/env python3
"""Unit tests for summarize.py."""

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from summarize import (
    build_summary,
    compare_metrics,
    delta_pct,
    median,
    render_markdown,
    scenario_metrics,
    summarize_values,
)


def exe_summary(n_spawns, wall, user, sys_, by_mnemonic):
    return {
        "n_spawns": n_spawns,
        "total_wall_s": wall,
        "total_cpu_user_s": user,
        "total_cpu_sys_s": sys_,
        "by_mnemonic": {
            m: {"count": c, "wall_s": 0.0, "cpu_user_s": 0.0,
                "cpu_sys_s": 0.0}
            for m, c in by_mnemonic.items()
        },
    }


def replay_report(instructions_list, failures=0, truncated=False,
                  cpu_s=0.0, sample_failure=None):
    by_mnemonic = {}
    if failures or cpu_s or sample_failure is not None:
        by_mnemonic["FlutterAotMacho"] = {"failures": failures,
                                          "user_s_total": cpu_s,
                                          "sys_s_total": 0.0}
        if sample_failure is not None:
            by_mnemonic["FlutterAotMacho"]["sample_failure"] = sample_failure
    return {
        "truncated": truncated,
        "n_replayed": len(instructions_list),
        "by_mnemonic": by_mnemonic,
        "actions": [
            {"mnemonic": "FlutterAotMacho", "instructions": v, "real_s": 1.0,
             "user_s": 0.9, "sys_s": 0.1}
            for v in instructions_list
        ],
    }


class StatsTest(unittest.TestCase):
    def test_median_odd(self):
        self.assertEqual(median([3, 1, 2]), 2)

    def test_median_single(self):
        self.assertEqual(median([7]), 7)

    def test_median_empty(self):
        self.assertIsNone(median([]))

    def test_summarize_values(self):
        self.assertEqual(summarize_values([1, 2, 3]),
                         {"n": 3, "median": 2, "min": 1, "max": 3})
        self.assertEqual(summarize_values([]),
                         {"n": 0, "median": None, "min": None, "max": None})

    def test_delta_pct(self):
        self.assertAlmostEqual(delta_pct(110.0, 100.0), 10.0)
        self.assertIsNone(delta_pct(1.0, 0))
        self.assertIsNone(delta_pct(None, 100.0))


class CompareTest(unittest.TestCase):
    def test_compare_medians_and_deltas(self):
        base = scenario_metrics(
            [exe_summary(10, 100.0, 60.0, 5.0, {"Genrule": 9}),
             exe_summary(12, 110.0, 66.0, 6.0, {"Genrule": 11}),
             exe_summary(11, 105.0, 63.0, 5.5, {"Genrule": 10})],
            [replay_report([100]), replay_report([110]),
             replay_report([105])])
        head = scenario_metrics(
            [exe_summary(10, 200.0, 120.0, 10.0, {"Genrule": 9}),
             exe_summary(10, 210.0, 126.0, 11.0, {"Genrule": 9}),
             exe_summary(10, 205.0, 123.0, 10.5, {"Genrule": 9})],
            [replay_report([200]), replay_report([210]),
             replay_report([205])])
        compared = compare_metrics(base, head)
        self.assertEqual(compared["wall_s"]["base"]["median"], 105.0)
        self.assertEqual(compared["wall_s"]["base"]["min"], 100.0)
        self.assertEqual(compared["wall_s"]["base"]["max"], 110.0)
        self.assertAlmostEqual(compared["wall_s"]["delta_pct"],
                               (205.0 - 105.0) / 105.0 * 100.0)
        self.assertEqual(compared["n_actions"]["head"]["median"], 10)
        self.assertEqual(
            compared["by_mnemonic"]["Genrule"]["base"]["median"], 10)
        self.assertTrue(compared["instructions_complete"]["base"])

    def test_incomplete_instructions(self):
        metrics = scenario_metrics(
            [exe_summary(1, 1.0, 0.5, 0.1, {})],
            [{"actions": [{"mnemonic": "X", "instructions": None}]}])
        self.assertEqual(metrics["instructions"], [])
        self.assertFalse(metrics["instructions_complete"])

    def test_skipped_counts_compared_and_rendered(self):
        import summarize as summarize_mod
        exe = [exe_summary(5, 100.0, 50.0, 0.5, {"Genrule": 2})]
        rep = [dict(replay_report([10]),
                    skipped_by_mnemonic={"host tools (not replayed)": 4,
                                         "Genrule": 1})]
        metrics = summarize_mod.scenario_metrics(exe, rep)
        compared = summarize_mod.compare_metrics(metrics, metrics)
        self.assertEqual(
            compared["skipped"]["host tools (not replayed)"]["base"]
            ["median"], 4)
        md = summarize_mod.render_markdown({
            "base_ref": "base", "head_ref": "head", "meta": {},
            "configs": {"cfg": {"scenarios": {"clean": compared}}}})
        self.assertIn("Not replayed", md)
        self.assertIn("host tools (not replayed)", md)

    def test_generator_version_mismatch_warns(self):
        import summarize as summarize_mod
        exe = [exe_summary(5, 100.0, 50.0, 0.5, {"Genrule": 2})]
        rep = [replay_report([10])]
        metrics = summarize_mod.scenario_metrics(exe, rep)
        compared = summarize_mod.compare_metrics(metrics, metrics)
        base = {"base_ref": "base", "head_ref": "head",
                "meta": {"base_stats": {"generator_version": 1},
                         "head_stats": {"generator_version": 2}},
                "configs": {"cfg": {"scenarios": {"clean": compared}}}}
        self.assertIn("not comparable",
                      summarize_mod.render_markdown(base))
        same = {"base_ref": "base", "head_ref": "head",
                "meta": {"base_stats": {"generator_version": 2},
                         "head_stats": {"generator_version": 2}},
                "configs": {"cfg": {"scenarios": {"clean": compared}}}}
        self.assertNotIn("not comparable",
                         summarize_mod.render_markdown(same))


class TreeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="summarize-test-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_rep(self, ref, config, scenario, rep, wall, instr):
        rep_dir = os.path.join(self.tmp, ref, config, scenario,
                               "rep%d" % rep)
        os.makedirs(rep_dir)
        with open(os.path.join(rep_dir, "execlog.json"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(exe_summary(
                5, wall, wall / 2, 0.5, {"FlutterAotMacho": 1})) + "\n")
        with open(os.path.join(rep_dir, "replay.json"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(replay_report([instr])) + "\n")

    def test_build_summary_end_to_end(self):
        for rep, (wall, instr) in enumerate(
                [(100.0, 1000), (110.0, 1100), (105.0, 1050)]):
            self.write_rep("base", "sim_debug", "clean", rep, wall, instr)
        for rep, (wall, instr) in enumerate(
                [(200.0, 2000), (210.0, 2100), (205.0, 2050)]):
            self.write_rep("head", "sim_debug", "clean", rep, wall, instr)
        self.write_rep("base", "device_release", "clean", 0, 50.0, 500)
        self.write_rep("head", "device_release", "clean", 0, 60.0, 600)
        summary = build_summary(self.tmp, "base", "head",
                                {"target_loc": 500000})
        self.assertEqual(sorted(summary["configs"]),
                         ["device_release", "sim_debug"])
        scenarios = summary["configs"]["sim_debug"]["scenarios"]
        self.assertEqual(sorted(scenarios), ["clean"])
        clean = scenarios["clean"]
        self.assertEqual(clean["wall_s"]["base"]["median"], 105.0)
        self.assertEqual(clean["wall_s"]["head"]["median"], 205.0)
        self.assertEqual(clean["instructions"]["base"]["median"], 1050)
        md = render_markdown(summary)
        self.assertIn("## sim_debug / clean", md)
        self.assertIn("## device_release / clean", md)
        self.assertIn("wall_s", md)
        self.assertIn("FlutterAotMacho", md)

    def test_missing_ref_is_error(self):
        self.write_rep("base", "sim_debug", "clean", 0, 100.0, 1000)
        summary = build_summary(self.tmp, "base", "head", {})
        scenarios = summary["configs"]["sim_debug"]["scenarios"]
        self.assertIn("error", scenarios["clean"])

    def test_repeats_one_states_no_spread(self):
        self.write_rep("base", "sim_debug", "clean", 0, 100.0, 1000)
        self.write_rep("head", "sim_debug", "clean", 0, 200.0, 2000)
        summary = build_summary(self.tmp, "base", "head", {})
        md = render_markdown(summary)
        self.assertIn("repeats=1", md)
        self.assertIn("no spread", md)

    def test_truncated_and_failures_shown(self):
        import summarize as summarize_mod
        base_exe = [exe_summary(5, 100.0, 50.0, 0.5,
                                {"FlutterAotMacho": 1})]
        head_exe = [exe_summary(5, 200.0, 100.0, 1.0,
                                {"FlutterAotMacho": 1})]
        base_rep = [replay_report([100], failures=0, truncated=True)]
        head_rep = [replay_report([200], failures=2, truncated=False,
                                  cpu_s=1.5,
                                  sample_failure={
                                      "target": "//app:app_ios",
                                      "exit_code": 1,
                                      "stderr_tail": "clang: error: boom"})]
        compared = summarize_mod.compare_metrics(
            summarize_mod.scenario_metrics(base_exe, base_rep),
            summarize_mod.scenario_metrics(head_exe, head_rep))
        self.assertTrue(compared["truncated"]["base"])
        self.assertFalse(compared["truncated"]["head"])
        self.assertEqual(
            compared["replay_failures"]["FlutterAotMacho"]["head"]["median"],
            2)
        self.assertEqual(
            compared["replay_cpu_s"]["FlutterAotMacho"]["head"]["median"],
            1.5)
        self.assertEqual(
            compared["failure_samples"]["FlutterAotMacho"]["head"],
            {"target": "//app:app_ios", "exit_code": 1,
             "stderr_tail": "clang: error: boom"})
        md = summarize_mod.render_markdown({
            "base_ref": "base", "head_ref": "head", "meta": {},
            "configs": {"sim_debug": {"scenarios": {"clean": compared}}}})
        self.assertIn("time budget", md)
        self.assertIn("Replay failures", md)
        self.assertIn("FlutterAotMacho", md)
        self.assertIn("Replay CPU", md)
        self.assertIn("clang: error: boom", md)

    def test_every_scenario_section_has_its_table(self):
        # Regression: the scenario table body once bound to the outer
        # config loop, so only each config's last scenario got tables.
        import summarize as summarize_mod
        exe = [exe_summary(5, 100.0, 50.0, 0.5, {"Genrule": 2})]
        rep = [replay_report([10])]
        metrics = summarize_mod.scenario_metrics(exe, rep)
        compared = summarize_mod.compare_metrics(metrics, metrics)
        md = summarize_mod.render_markdown({
            "base_ref": "base", "head_ref": "head", "meta": {},
            "configs": {"cfg": {"scenarios": {
                "app_edit": compared, "clean": compared}}}})
        for scenario in ["app_edit", "clean"]:
            header = "## cfg / %s" % scenario
            start = md.index(header)
            nxt = md.find("## cfg / ", start + len(header))
            section = md[start:] if nxt < 0 else md[start:nxt]
            self.assertIn("| n_actions |", section)
            self.assertIn("Genrule", section)

    def test_no_instruction_counter_states_pmu_note(self):
        import summarize as summarize_mod
        exe = [exe_summary(5, 100.0, 50.0, 0.5, {"Genrule": 2})]
        rep = [{"n_replayed": 1, "truncated": False, "by_mnemonic": {},
                "actions": [{"mnemonic": "Genrule", "instructions": None,
                             "real_s": 1.0, "user_s": 0.9, "sys_s": 0.1}]}]
        metrics = summarize_mod.scenario_metrics(exe, rep)
        compared = summarize_mod.compare_metrics(metrics, metrics)
        self.assertFalse(compared["instructions_available"]["base"])
        md = summarize_mod.render_markdown({
            "base_ref": "base", "head_ref": "head", "meta": {},
            "configs": {"cfg": {"scenarios": {"clean": compared}}}})
        self.assertIn("no PMU", md)
        self.assertIn("Replay CPU", md)


if __name__ == "__main__":
    unittest.main()
