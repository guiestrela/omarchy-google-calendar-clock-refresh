"""Exercise calendar-auth-mode's session persistence/rollback with a fake Caldir.

These tests simulate the child-process outcomes only; they do not perform OAuth,
open a browser, contact Google, or read any calendar data.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
AUTH_MODE = PROJECT / "scripts" / "calendar-auth-mode"


class AuthModeSimulationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="calendar-auth-sim-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.home = root / "home"
        self.config_home = root / "config"
        self.data_home = root / "data"
        self.fake_bin = self.data_home / "io.github.guiestrela.omarchy-google-calendar-clock" / "bin"
        self.fake_bin.mkdir(parents=True)
        self.home.mkdir()

        fake_caldir = self.fake_bin / "caldir"
        fake_caldir.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, sys\n"
            "if sys.argv[1:3] != ['connect', 'google']:\n"
            "    sys.exit(64)\n"
            "mode = os.environ.get('CALDIR_SIMULATION', 'error')\n"
            "session_dir = pathlib.Path(os.environ['XDG_CONFIG_HOME']) / 'caldir/providers/google/session'\n"
            "session_dir.mkdir(parents=True, exist_ok=True)\n"
            "if mode == 'success':\n"
            "    (session_dir / 'simulated-session.toml').write_text('auth_mode = \\\"hosted\\\"\\n')\n"
            "    sys.exit(0)\n"
            "(session_dir / 'partial-callback.toml').write_text('auth_mode = \\\"hosted\\\"\\n')\n"
            "if mode == 'cancel':\n"
            "    print('SIMULATED_CANCEL', file=sys.stderr)\n"
            "    sys.exit(130)\n"
            "if mode == 'timeout':\n"
            "    print('SIMULATED_TIMEOUT', file=sys.stderr)\n"
            "    sys.exit(124)\n"
            "print('SIMULATED_CALLBACK_ERROR', file=sys.stderr)\n"
            "sys.exit(1)\n",
            encoding="utf-8",
        )
        fake_caldir.chmod(0o755)

    def environment(self, simulation: str) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            HOME=str(self.home),
            XDG_CONFIG_HOME=str(self.config_home),
            XDG_DATA_HOME=str(self.data_home),
            CALDIR_SIMULATION=simulation,
        )
        return env

    def seed_previous_direct_session(self) -> Path:
        session_dir = self.config_home / "caldir/providers/google/session"
        session_dir.mkdir(parents=True, exist_ok=True)
        session = session_dir / "previous-session.toml"
        session.write_text('auth_mode = "direct"\nfixture_marker = "preserve"\n', encoding="utf-8")
        self.app_config = self.config_home / "caldir/providers/google/app_config.toml"
        self.app_config.parent.mkdir(parents=True, exist_ok=True)
        self.app_config.write_text('fixture_marker = "not-a-credential"\n', encoding="utf-8")
        return session

    def switch(self, simulation: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(AUTH_MODE), "switch", "hosted", "--yes"],
            env=self.environment(simulation),
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )

    def assert_previous_session_restored(self, previous: Path) -> None:
        self.assertTrue(previous.is_file())
        self.assertIn('fixture_marker = "preserve"', previous.read_text(encoding="utf-8"))
        session_dir = previous.parent
        self.assertEqual(sorted(p.name for p in session_dir.glob("*.toml")), [previous.name])
        self.assertEqual(list(session_dir.glob(".session.auth-switch.*")), [])
        self.assertTrue(self.app_config.is_file())
        self.assertFalse(self.app_config.with_name("app_config.toml.direct").exists())

    def test_fake_caldir_success_persists_hosted_session(self) -> None:
        result = self.switch("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        status = subprocess.run(
            [str(AUTH_MODE), "status", "--json"],
            env=self.environment("success"),
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        )
        data = json.loads(status.stdout)
        self.assertEqual(data["mode"], "hosted")
        self.assertTrue(data["session"])
        self.assertFalse(data["app_config"])

    def test_fake_caldir_error_restores_previous_session(self) -> None:
        previous = self.seed_previous_direct_session()
        result = self.switch("error")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Authentication did not complete", result.stderr)
        self.assert_previous_session_restored(previous)

    def test_fake_caldir_cancellation_restores_previous_session(self) -> None:
        previous = self.seed_previous_direct_session()
        result = self.switch("cancel")
        self.assertEqual(result.returncode, 130)
        self.assertIn("Authentication did not complete", result.stderr)
        self.assert_previous_session_restored(previous)

    def test_fake_caldir_timeout_restores_previous_session(self) -> None:
        previous = self.seed_previous_direct_session()
        result = self.switch("timeout")
        self.assertEqual(result.returncode, 124)
        self.assertIn("Authentication did not complete", result.stderr)
        self.assert_previous_session_restored(previous)


if __name__ == "__main__":
    unittest.main(verbosity=2)
