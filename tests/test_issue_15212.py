"""Isolated regression tests for Issue #15212 destructive/mutation helpers."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


def executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def make_series(calendar: Path) -> tuple[Path, Path]:
    (calendar / ".caldir").mkdir(parents=True, exist_ok=True)
    (calendar / ".caldir/config.toml").write_text("read_only = false\n", encoding="utf-8")
    master = calendar / "master.ics"
    master.write_text(
        "\r\n".join([
            "BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "UID:fixture-series",
            "DTSTAMP:20260101T000000Z", "DTSTART;VALUE=DATE:20260101",
            "DTEND;VALUE=DATE:20260102", "RRULE:FREQ=DAILY;COUNT=3",
            "SUMMARY:Original master", "SEQUENCE:0", "END:VEVENT", "END:VCALENDAR", "",
        ]), encoding="utf-8")
    override = calendar / "override.ics"
    override.write_text(
        "\r\n".join([
            "BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "UID:fixture-series",
            "RECURRENCE-ID;VALUE=DATE:20260102", "DTSTART;VALUE=DATE:20260103",
            "DTEND;VALUE=DATE:20260104", "SUMMARY:Original override", "SEQUENCE:0",
            "END:VEVENT", "END:VCALENDAR", "",
        ]), encoding="utf-8")
    return master, override


class Issue15212Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="issue15212-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def mutation_fixture(self):
        scripts = self.root / "scripts"
        scripts.mkdir(parents=True, exist_ok=True)
        calendar_root = self.root / "calendar-root"
        calendar = calendar_root / "fixture"
        master, override = make_series(calendar)
        mutate = scripts / "calendar-mutate"
        shutil.copy2(REPO / "scripts/calendar-mutate", mutate)
        mutate.chmod(0o755)
        executable(scripts / "calendar-caldir", """#!/bin/sh
if [ "$1" = config ] && [ "$2" = --json ]; then
  printf '{"config":{"calendar_dir":"%s"}}\\n' "$FIXTURE_CALENDAR_ROOT"
  exit 0
fi
echo FIXTURE_ONLY_CALDIR_REJECTED >&2
exit 90
""")
        executable(scripts / "calendar-cache-update", """#!/bin/sh
printf 'called\\n' >> "$FIXTURE_CACHE_LOG"
if [ "${FIXTURE_CACHE_EXIT:-0}" != 0 ]; then
  echo FIXTURE_CACHE_REFRESH_FAILURE >&2
  exit "$FIXTURE_CACHE_EXIT"
fi
exit 0
""")
        inject = self.root / "inject"
        inject.mkdir()
        (inject / "sitecustomize.py").write_text("""import os
from pathlib import Path
_real_replace = os.replace
def _replace(src, dst, *args, **kwargs):
    if os.environ.get('FIXTURE_FAIL_REPLACE') == Path(dst).name:
        raise OSError('FIXTURE_INJECTED_REPLACE:' + Path(dst).name)
    return _real_replace(src, dst, *args, **kwargs)
os.replace = _replace
_real_unlink = Path.unlink
def _unlink(self, *args, **kwargs):
    if os.environ.get('FIXTURE_FAIL_UNLINK') == self.name:
        raise OSError('FIXTURE_INJECTED_UNLINK:' + self.name)
    return _real_unlink(self, *args, **kwargs)
Path.unlink = _unlink
""", encoding="utf-8")
        env = os.environ.copy()
        env.update(
            HOME=str(self.root / "home"),
            XDG_CONFIG_HOME=str(self.root / "config"),
            XDG_DATA_HOME=str(self.root / "data"),
            XDG_STATE_HOME=str(self.root / "state"),
            FIXTURE_CALENDAR_ROOT=str(calendar_root),
            FIXTURE_CACHE_LOG=str(self.root / "cache.log"),
            PYTHONPATH=str(inject),
        )
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"):
            Path(env[key]).mkdir(parents=True, exist_ok=True)
        return mutate, master, override, env

    def run_mutation(self, args, *, fail_replace=None, fail_unlink=None, cache_exit=None):
        mutate, master, override, env = self.mutation_fixture()
        if fail_replace:
            env["FIXTURE_FAIL_REPLACE"] = fail_replace
        if fail_unlink:
            env["FIXTURE_FAIL_UNLINK"] = fail_unlink
        if cache_exit is not None:
            env["FIXTURE_CACHE_EXIT"] = str(cache_exit)
        result = subprocess.run(
            [sys.executable, str(mutate), *args], env=env, text=True,
            capture_output=True, timeout=10, check=False,
        )
        return result, master, override

    def test_uninstall_yes_alone_preserves_optional_data(self) -> None:
        case = self.root / "uninstall"
        home, config, data, state, bin_dir, copied = [case / x for x in ("home", "config", "data", "state", "bin", "copy")]
        for path in (home, config, data, state, bin_dir, copied): path.mkdir(parents=True, exist_ok=True)
        script = copied / "uninstall"
        shutil.copy2(REPO / "uninstall", script); script.chmod(0o755)
        plugin_id = "io.github.guiestrela.omarchy-google-calendar-clock"
        install = data / plugin_id; install.mkdir(parents=True); (install / "marker").write_text("FIXTURE_ONLY")
        cache = state / "omarchy/calendar-cache.json"; cache.parent.mkdir(parents=True); cache.write_text("FIXTURE_ONLY")
        google = config / "caldir/providers/google"; google.mkdir(parents=True); (google / "marker").write_text("FIXTURE_ONLY")
        calendar = data / "caldir"; calendar.mkdir(parents=True); (calendar / "fixture.ics").write_text("FIXTURE_ONLY")
        executable(bin_dir / "omarchy", '#!/bin/sh\necho "$*" >> "$FIXTURE_OMARCHY_LOG"\nexit 0\n')
        executable(bin_dir / "jq", '#!/bin/sh\necho UNEXPECTED_JQ >> "$FIXTURE_JQ_LOG"\nexit 98\n')
        env = os.environ.copy(); env.update(HOME=str(home), XDG_CONFIG_HOME=str(config), XDG_DATA_HOME=str(data), XDG_STATE_HOME=str(state), PATH=f"{bin_dir}:/usr/bin:/bin", FIXTURE_OMARCHY_LOG=str(case/"omarchy.log"), FIXTURE_JQ_LOG=str(case/"jq.log"))
        result = subprocess.run([str(script), "--yes"], cwd=case, env=env, stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(google.is_dir(), "--yes must not imply OAuth deletion")
        self.assertTrue(calendar.is_dir(), "--yes must not imply calendar-data deletion")
        self.assertFalse(install.exists())
        self.assertFalse(cache.exists())

    def test_uninstall_optional_opt_ins_are_independent(self) -> None:
        for flag, remove_google, remove_calendar in (
            ("--delete-google-credentials", True, False),
            ("--delete-calendar-data", False, True),
        ):
            with self.subTest(flag=flag):
                case = self.root / flag[2:]
                home, config, data, state, bin_dir, copied = [case / x for x in ("home", "config", "data", "state", "bin", "copy")]
                for path in (home, config, data, state, bin_dir, copied): path.mkdir(parents=True, exist_ok=True)
                script = copied / "uninstall"; shutil.copy2(REPO / "uninstall", script); script.chmod(0o755)
                plugin_id = "io.github.guiestrela.omarchy-google-calendar-clock"
                (config / "omarchy/plugins" / plugin_id).mkdir(parents=True)
                (data / plugin_id).mkdir(parents=True)
                google = config / "caldir/providers/google"; google.mkdir(parents=True); (google / "marker").write_text("FIXTURE_ONLY")
                calendar = data / "caldir"; calendar.mkdir(parents=True); (calendar / "fixture.ics").write_text("FIXTURE_ONLY")
                (state / "omarchy").mkdir(parents=True)
                executable(bin_dir / "omarchy", '#!/bin/sh\nexit 0\n')
                executable(bin_dir / "jq", '#!/bin/sh\nexit 98\n')
                env = os.environ.copy(); env.update(HOME=str(home), XDG_CONFIG_HOME=str(config), XDG_DATA_HOME=str(data), XDG_STATE_HOME=str(state), PATH=f"{bin_dir}:/usr/bin:/bin")
                result = subprocess.run([str(script), "--yes", flag], cwd=case, env=env, stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(google.exists(), not remove_google)
                self.assertEqual(calendar.exists(), not remove_calendar)

    def test_series_edit_rolls_back_master_when_override_replace_fails(self) -> None:
        result, master, override = self.run_mutation(
            ["edit", "series", "fixture", "fixture-series", "", "2026-01-01T09:30:00", "2026-01-01T10:30:00", "false", "Edited", "09:30", "keep", ""],
            fail_replace="override.ics")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FIXTURE_INJECTED_REPLACE:override.ics", result.stderr)
        self.assertIn("SUMMARY:Original master", master.read_text())
        self.assertIn("RECURRENCE-ID;VALUE=DATE:20260102", override.read_text())
        self.assertIn("DTSTART;VALUE=DATE:20260101", master.read_text())

    def test_instance_delete_rolls_back_master_when_override_unlink_fails(self) -> None:
        result, master, override = self.run_mutation(
            ["delete", "instance", "fixture", "fixture-series", "fixture-series__20260102", "--confirm"],
            fail_unlink="override.ics")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(override.exists())
        self.assertNotIn("EXDATE", master.read_text())
        self.assertIn("DTSTART;VALUE=DATE:20260101", master.read_text())

    def test_series_delete_rolls_back_after_second_unlink_failure(self) -> None:
        result, master, override = self.run_mutation(
            ["delete", "series", "fixture", "fixture-series", "", "--confirm"],
            fail_unlink="override.ics")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(master.exists(), "failed series deletion must restore the already removed master")
        self.assertTrue(override.exists(), "failed series deletion must leave the later override intact")
        self.assertIn("SUMMARY:Original master", master.read_text())
        self.assertIn("SUMMARY:Original override", override.read_text())

    def test_instance_delete_preserves_files_when_master_commit_fails(self) -> None:
        result, master, override = self.run_mutation(
            ["delete", "instance", "fixture", "fixture-series", "fixture-series__20260102", "--confirm"],
            fail_replace="master.ics")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(override.exists(), "failed master commit must leave the override intact")
        self.assertNotIn("EXDATE", master.read_text())
        self.assertIn("SUMMARY:Original master", master.read_text())

    def test_cache_refresh_error_reports_local_commit_as_exit_two(self) -> None:
        result, master, override = self.run_mutation(
            ["edit", "series", "fixture", "fixture-series", "", "2026-01-01T09:30:00", "2026-01-01T10:30:00", "false", "Edited", "09:30", "keep", ""],
            cache_exit=7)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("Updated the whole series locally", result.stdout)
        self.assertIn("cache refresh failed", result.stderr.lower())
        self.assertIn("SUMMARY:Edited", master.read_text(), "local mutation must remain committed")
        self.assertIn("RECURRENCE-ID;TZID=", override.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
