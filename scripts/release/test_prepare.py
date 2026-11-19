import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import prepare


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.addCleanup(os.chdir, Path.cwd())
        os.chdir(scratch.name)
        prepare.git("init", "-b", "main")
        prepare.git("config", "user.name", "Release test")
        prepare.git("config", "user.email", "release@example.com")
        prepare.git("config", "commit.gpgsign", "false")
        self.zon = '.{\n    .version = "0.2.0",\n    .minimum_zig_version = "0.17.0",\n}\n'
        prepare.ZON.write_text(self.zon)
        prepare.PIN.parent.mkdir(parents=True)
        prepare.write_json(prepare.PIN, {"version": "0.2.0", "hash": "previous"})
        prepare.write_json(prepare.MANIFEST, {"version": "0.1.0", "files": ["lib"]})
        Path("src").mkdir()
        Path("src/napi.zig").touch()
        self.commit("initial packages")
        prepare.git("tag", "0.2.0")

    def commit(self, message):
        prepare.git("add", ".")
        prepare.git("commit", "-m", message)

    def test_only_shipped_cli_changes_open_a_cli_release(self):
        Path("README.md").write_text("docs")
        self.commit("feat(docs): document the CLI")
        self.assertEqual(prepare.prepare_cli("0.2.0"), {})
        (prepare.CLI / "lib/cli.cjs").touch()
        self.commit("feat(cli): add option")
        self.assertEqual(prepare.prepare_zig()["changed"], "false")
        self.assertEqual(prepare.prepare_cli("0.2.0"), {"version": "0.2.0"})
        self.commit("chore(npm): publish")
        self.assertEqual(prepare.prepare_cli("0.2.0"), {})

    def test_new_zig_release_updates_both_cli_version_and_pin(self):
        Path("src/napi.zig").write_text("updated")
        self.commit("fix(napi): fix conversion")
        self.assertEqual(prepare.prepare_zig()["version"], "0.2.1")
        self.assertIn('.minimum_zig_version = "0.17.0"', prepare.ZON.read_text())
        self.commit("chore(release): zig-napi 0.2.1")
        prepare.git("tag", "0.2.1")
        self.assertEqual(prepare.prepare_zig()["changed"], "false")

        # Intercept only the archive fetch. Git comparisons use the real checkout.
        run = subprocess.check_output
        fetched = []

        def fetch(command, **options):
            if command[:2] == ["zig", "fetch"]:
                fetched.append(command[2])
                return "zig_napi-0.2.1-verified_hash\n"
            return run(command, **options)

        with patch.object(subprocess, "check_output", side_effect=fetch):
            self.assertEqual(prepare.prepare_cli("0.2.1"), {"version": "0.1.1"})
        self.assertEqual(
            fetched, ["https://github.com/openharmony-zig/zig-napi/archive/refs/tags/0.2.1.tar.gz"]
        )
        self.assertEqual(
            json.loads(prepare.PIN.read_text()), {"version": "0.2.1", "hash": "zig_napi-0.2.1-verified_hash"}
        )
        self.commit("publish CLI")
        self.assertEqual(prepare.prepare_cli("0.2.1"), {})

    def test_breaking_change_and_explicit_version(self):
        Path("src/napi.zig").write_text("updated")
        self.commit("feat(napi)!: change ABI")
        self.assertEqual(prepare.prepare_zig()["version"], "1.0.0")
        prepare.ZON.write_text(self.zon.replace('"0.2.0"', '"2.0.0"'))
        self.commit("select a version")
        self.assertEqual(prepare.prepare_zig()["version"], "2.0.0")


if __name__ == "__main__":
    unittest.main()
