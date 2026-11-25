"""Regression coverage for the cross-platform development runner."""

from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import workspace


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.package = self.root / "package"
        (self.package / "src").mkdir(parents=True)
        (self.package / "gleam.toml").write_text('name = "fixture"\n')
        self.source = self.package / "src/main.gleam"
        self.source.write_text("pub fn main() { Nil }\n")
        for name, value in (("ROOT", self.root), ("PACKAGES", [self.package])):
            replacement = patch.object(workspace, name, value)
            replacement.start()
            self.addCleanup(replacement.stop)

    def test_watch_includes_sources_and_manifests_but_not_build_outputs(self):
        build = self.package / "build"
        build.mkdir()
        (build / "output.beam").write_bytes(b"generated")
        self.assertEqual(set(workspace.watch_files()), {
            self.source, self.package / "gleam.toml",
        })

    def test_digest_detects_added_deleted_and_renamed_sources(self):
        original = workspace.files_digest(workspace.watch_files())
        added = self.package / "src/new.gleam"
        added.write_text("pub fn value() { 1 }\n")
        self.assertNotEqual(original, workspace.files_digest(workspace.watch_files()))
        added.unlink()
        self.assertEqual(original, workspace.files_digest(workspace.watch_files()))
        self.source.rename(self.source.with_name("renamed.gleam"))
        self.assertNotEqual(original, workspace.files_digest(workspace.watch_files()))

    def test_dev_rediscovers_files_and_restarts_after_successful_build(self):
        first = Mock(stdout=[], returncode=0)
        first.poll.return_value = None
        second = Mock(stdout=["Campy window closed: done\n"], returncode=0)
        second.poll.return_value = 0
        def add_source(_seconds):
            (self.package / "src/new.gleam").write_text("pub fn value() { 1 }\n")
        with (
            patch.object(workspace, "launch_ide", side_effect=[first, second]) as launch,
            patch.object(workspace, "stop_process"),
            patch.object(workspace.time, "sleep", side_effect=add_source),
            patch.object(workspace, "require_tool", return_value="gleam"),
            patch.object(workspace.subprocess, "run", return_value=Mock(returncode=0)) as build,
        ):
            workspace.dev()
        self.assertEqual(launch.call_count, 2)
        build.assert_called_once()

    def test_build_app_passes_paths_and_module_ids_as_data(self):
        (self.package / "build/dev/erlang/fixture/ebin").mkdir(parents=True)
        project = self.root / 'quoted "project"' / "café.campy"
        module = 'quoted "module"\\name'
        with (
            patch.object(workspace, "BROKER", self.package),
            patch.object(workspace, "PROJECT", project),
            patch.object(workspace, "require_tool", return_value="erl"),
            patch.object(workspace.subprocess, "run", return_value=Mock(returncode=0, stdout="built\n")) as run,
        ):
            workspace.build_app(module)
        args = run.call_args.args[0]
        env = run.call_args.kwargs["env"]
        self.assertEqual(env["CAMPY_BUILD_PROJECT"], str(project))
        self.assertEqual(env["CAMPY_BUILD_MODULE"], module)
        self.assertNotIn(str(project), args[3])
        self.assertNotIn(module, args[3])

    def test_missing_external_nif_reports_build_instruction(self):
        target = self.root.parent / (self.root.name + "-external-target")
        with (
            patch.dict(workspace.os.environ, {"CARGO_TARGET_DIR": str(target)}),
            patch.object(workspace, "NATIVE", self.root / "native"),
        ):
            with self.assertRaisesRegex(SystemExit, "build Rust first"):
                workspace.stage_nif()


if __name__ == "__main__":
    unittest.main()
