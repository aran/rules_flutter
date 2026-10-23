#!/usr/bin/env python3
"""Unit tests for execlog.py."""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from execlog import load_spawns, parse_duration, summarize_spawns

# Fixture shaped like the real --execution_log_json_file output (concatenated
# spawn objects; the Genrule spawn mirrors a build captured on Linux, the
# FlutterAotMacho spawn carries macOS-style user/sys times).
GENRULE_SPAWN = {
    "commandArgs": ["/bin/bash", "-c", "echo hi"],
    "environmentVariables": [{"name": "PATH", "value": "/bin:/usr/bin"}],
    "mnemonic": "Genrule",
    "runner": "processwrapper-sandbox",
    "cacheHit": False,
    "exitCode": 0,
    "targetLabel": "//:hello",
    "metrics": {
        "totalTime": "0.003s",
        "executionWallTime": "0.003s",
    },
}

AOT_SPAWN = {
    "commandArgs": ["gen_snapshot", "--macho", "out.dill"],
    "environmentVariables": [{"name": "PATH", "value": "/usr/bin:/bin"}],
    "mnemonic": "FlutterAotMacho",
    "runner": "local",
    "cacheHit": False,
    "exitCode": 0,
    "targetLabel": "//app:app_ios",
    "metrics": {
        "executionWallTime": "12.5s",
        "userTime": "48.25s",
        "systemTime": "1.5s",
    },
}


class ParseDurationTest(unittest.TestCase):
    def test_string_seconds(self):
        self.assertAlmostEqual(parse_duration("0.003s"), 0.003)
        self.assertAlmostEqual(parse_duration("12s"), 12.0)
        self.assertAlmostEqual(parse_duration("0s"), 0.0)

    def test_numbers_are_seconds(self):
        self.assertAlmostEqual(parse_duration(2), 2.0)
        self.assertAlmostEqual(parse_duration(0.5), 0.5)

    def test_object_form(self):
        self.assertAlmostEqual(
            parse_duration({"seconds": 3, "nanos": 500000000}), 3.5)

    def test_none_is_zero(self):
        self.assertEqual(parse_duration(None), 0.0)

    def test_garbage_raises(self):
        with self.assertRaises(ValueError):
            parse_duration("soon")


class LoadSpawnsTest(unittest.TestCase):
    def write(self, text):
        tmp = tempfile.NamedTemporaryFile(
            "w", suffix=".json", delete=False, encoding="utf-8")
        try:
            tmp.write(text)
            tmp.close()
            return tmp.name
        finally:
            pass

    def test_concatenated_objects(self):
        path = self.write(json.dumps(GENRULE_SPAWN) + json.dumps(AOT_SPAWN))
        try:
            spawns = load_spawns(path)
            self.assertEqual(len(spawns), 2)
            self.assertEqual(spawns[0]["mnemonic"], "Genrule")
            self.assertEqual(spawns[1]["mnemonic"], "FlutterAotMacho")
        finally:
            os.remove(path)

    def test_spawns_wrapper(self):
        path = self.write(json.dumps({"spawns": [GENRULE_SPAWN]}))
        try:
            self.assertEqual(len(load_spawns(path)), 1)
        finally:
            os.remove(path)

    def test_empty_file(self):
        path = self.write("")
        try:
            self.assertEqual(load_spawns(path), [])
        finally:
            os.remove(path)


class SummarizeTest(unittest.TestCase):
    def test_counts_and_cpu(self):
        summary = summarize_spawns(
            [GENRULE_SPAWN, GENRULE_SPAWN, AOT_SPAWN])
        self.assertEqual(summary["n_spawns"], 3)
        self.assertEqual(summary["by_mnemonic"]["Genrule"]["count"], 2)
        self.assertEqual(
            summary["by_mnemonic"]["FlutterAotMacho"]["count"], 1)
        self.assertAlmostEqual(summary["total_cpu_user_s"], 48.25)
        self.assertAlmostEqual(summary["total_cpu_sys_s"], 1.5)
        self.assertAlmostEqual(summary["total_wall_s"], 12.506)
        self.assertTrue(summary["cpu_time_available"])

    def test_missing_cpu_flagged_not_zeroed(self):
        summary = summarize_spawns([GENRULE_SPAWN])
        self.assertFalse(summary["cpu_time_available"])
        self.assertEqual(summary["total_cpu_user_s"], 0.0)

    def test_empty_log(self):
        summary = summarize_spawns([])
        self.assertEqual(summary["n_spawns"], 0)
        self.assertEqual(summary["by_mnemonic"], {})


if __name__ == "__main__":
    unittest.main()
