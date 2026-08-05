from __future__ import annotations

import importlib.util
import base64
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


TOOL_PATH = Path(__file__).resolve().parents[1] / "scripts" / "dependency_state.py"
SPEC = importlib.util.spec_from_file_location("kwiken_dependency_state", TOOL_PATH)
dependency_state = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = dependency_state
SPEC.loader.exec_module(dependency_state)


def run_git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    return result.stdout.strip()


def initialize_repository(path: Path, files: dict[str, str]) -> str:
    path.mkdir(parents=True)
    run_git(path, "init", "--quiet")
    run_git(path, "config", "user.email", "kwiken-tests@example.invalid")
    run_git(path, "config", "user.name", "Kwiken Tests")
    run_git(path, "config", "core.autocrlf", "false")
    for relative, contents in files.items():
        destination = path / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(contents, encoding="utf-8", newline="\n")
    run_git(path, "add", "--all")
    run_git(path, "commit", "--quiet", "-m", "fixture")
    return run_git(path, "rev-parse", "HEAD")


class DependencyStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        self.source = self.checkout / "src"
        self.source_revision = initialize_repository(
            self.source, {"brand.txt": "Chromium\n", ".gitignore": "out/\n"}
        )
        self.dependency = self.source / "third_party" / "fixture"
        self.dependency_revision = initialize_repository(
            self.dependency, {"dependency.txt": "pinned\n"}
        )
        (self.source / "brand.txt").write_text("Kwiken\n", encoding="utf-8", newline="\n")
        self.source_delta = dependency_state._source_delta_sha256(
            self.source, self.source_revision, timeout_seconds=10
        )

        self.cipd_key = "src/buildtools/win:gn/gn/${platform}"
        self.cipd_instance = "A" * 44
        self.cipd_package = "gn/gn/windows-amd64"
        slot = self.checkout / ".cipd" / "pkgs" / "0"
        (slot / self.cipd_instance / ".cipdpkg").mkdir(parents=True)
        self.cipd_description = slot / "description.json"
        self.cipd_description.write_text(
            json.dumps(
                {"subdir": "src/buildtools/win", "package_name": self.cipd_package}
            ),
            encoding="utf-8",
        )
        (slot / "_current.txt").write_text(self.cipd_instance, encoding="ascii")
        cipd_contents = b"synthetic gn executable\n"
        cipd_hash = base64.urlsafe_b64encode(hashlib.sha256(cipd_contents).digest()).decode(
            "ascii"
        ).rstrip("=")
        cipd_file = self.checkout / "src" / "buildtools" / "win" / "gn.exe"
        cipd_file.parent.mkdir(parents=True)
        cipd_file.write_bytes(cipd_contents)
        self.cipd_manifest = slot / self.cipd_instance / ".cipdpkg" / "manifest.json"
        self.cipd_manifest.write_text(
            json.dumps(
                {
                    "files": [
                        {"hash": cipd_hash, "name": "gn.exe", "size": len(cipd_contents)}
                    ],
                    "format_version": "1.1",
                    "package_name": self.cipd_package,
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

        self.gcs_object = "fixture-object.tar.gz"
        self.gcs_key = f"src/test/data:{self.gcs_object}"
        self.gcs_url = f"gs://kwiken-test/{self.gcs_object}"
        self.gcs_directory = self.checkout / "src" / "test" / "data"
        self.gcs_directory.mkdir(parents=True)
        self.gcs_artifact = self.gcs_directory / f".{self.gcs_object}"
        tar_contents = b"verified extracted content\n"
        member = tarfile.TarInfo("fixture/hello.txt")
        member.size = len(tar_contents)
        member.mtime = 0
        with tarfile.open(self.gcs_artifact, "w:gz") as archive:
            archive.addfile(member, io.BytesIO(tar_contents))
        extracted = self.gcs_directory / "fixture" / "hello.txt"
        extracted.parent.mkdir()
        extracted.write_bytes(tar_contents)
        self.gcs_sha256 = hashlib.sha256(self.gcs_artifact.read_bytes()).hexdigest()
        self.gcs_size = self.gcs_artifact.stat().st_size
        gcs_prefix = self.gcs_object.replace(".", "_")
        (self.gcs_directory / f".{gcs_prefix}_hash").write_text(
            self.gcs_sha256 + "\n", encoding="ascii"
        )
        (self.gcs_directory / f".{gcs_prefix}_is_first_class_gcs").write_text(
            "1\n", encoding="ascii"
        )
        (self.gcs_directory / f".{gcs_prefix}_content_names").write_text(
            json.dumps(["fixture/hello.txt"]) + "\n", encoding="utf-8"
        )
        (self.checkout / ".gcs_entries").write_text(
            json.dumps(
                {"src": {"src/test/data": [self.gcs_object]}},
                sort_keys=True,
            ),
            encoding="utf-8",
        )

        self.expected = {
            "src": {
                "url": "https://chromium.googlesource.com/chromium/src.git",
                "rev": self.source_revision,
            },
            "src/third_party/fixture": {
                "url": "https://example.invalid/fixture.git",
                "rev": self.dependency_revision,
            },
        }
        self.actual = {path: dict(record) for path, record in self.expected.items()}
        gcs_payload = base64.urlsafe_b64encode(
            json.dumps(
                {
                    "outputFile": None,
                    "sha256": self.gcs_sha256,
                    "sizeBytes": self.gcs_size,
                },
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
        ).decode("ascii").rstrip("=")
        self.declarations = {
            **{path: dict(record) for path, record in self.expected.items()},
            self.cipd_key: {
                "url": f"{dependency_state.CIPD_SERVICE}/gn/gn/${{platform}}",
                "rev": "version:3@fixture-resolution",
            },
            self.gcs_key: {
                "url": self.gcs_url,
                "rev": dependency_state.GCS_PROBE_REVISION_PREFIX + gcs_payload,
            },
        }
        gclient_entries = {
            "src": self.expected["src"]["url"],
            "src/third_party/fixture": (
                f"{self.expected['src/third_party/fixture']['url']}"
                f"@{self.dependency_revision}"
            ),
            self.cipd_key: (
                f"{self.declarations[self.cipd_key]['url']}"
                f"@{self.declarations[self.cipd_key]['rev']}"
            ),
            self.gcs_key: self.gcs_url,
        }
        (self.checkout / ".gclient_entries").write_text(
            "entries = " + repr(gclient_entries) + "\n", encoding="utf-8"
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def collect(self) -> dict:
        return dependency_state.collect_dependency_state(
            self.checkout,
            self.expected,
            self.actual,
            self.declarations,
            cipd_deployment_verified=True,
            source_delta_sha256=self.source_delta,
            command_timeout_seconds=10,
        )

    def test_collects_deterministic_git_cipd_and_gcs_state(self) -> None:
        first = self.collect()
        second = self.collect()
        self.assertEqual(first, second)
        self.assertEqual(first["schemaVersion"], 1)
        self.assertEqual(first["summary"], {
            "cipdPackages": 1,
            "gcsObjects": 1,
            "gitRepositories": 2,
            "gitSubmodules": 0,
        })
        self.assertEqual(
            first["treeSha256"],
            dependency_state.dependency_tree_sha256(first["entries"]),
        )
        source_entry = next(
            item for item in first["entries"] if item["type"] == "git" and item["path"] == "src"
        )
        self.assertEqual(source_entry["workingTreeSha256"], self.source_delta)
        cipd_entry = next(item for item in first["entries"] if item["type"] == "cipd")
        self.assertEqual(
            cipd_entry["verificationLevel"],
            "cipd-deployment-check-and-package-manifest-sha256",
        )
        self.assertEqual(cipd_entry["version"], "version:3@fixture-resolution")
        gcs_entry = next(item for item in first["entries"] if item["type"] == "gcs")
        self.assertEqual(
            gcs_entry["verificationLevel"],
            "expected-artifact-and-installed-content-sha256",
        )

    def test_command_stdout_override_remains_bounded(self) -> None:
        command = [sys.executable, "-c", "import sys; sys.stdout.write('x' * 1024)"]
        output = dependency_state._run_process(
            command,
            cwd=self.root,
            timeout_seconds=10,
            label="bounded fixture",
            maximum_stdout_bytes=2048,
        )
        self.assertEqual(len(output), 1024)
        with self.assertRaisesRegex(
            dependency_state.DependencyStateError, "bounded output limit"
        ):
            dependency_state._run_process(
                command,
                cwd=self.root,
                timeout_seconds=10,
                label="bounded fixture",
                maximum_stdout_bytes=512,
            )

    def test_git_tree_listings_use_the_large_bounded_limit(self) -> None:
        original_run_git = dependency_state._run_git
        calls: list[dict] = []

        def fake_run_git(*args, **kwargs):
            calls.append(kwargs)
            return b""

        dependency_state._run_git = fake_run_git
        try:
            self.assertEqual(
                dependency_state._gitlinks_from_index(
                    self.source, timeout_seconds=10
                ),
                {},
            )
            self.assertEqual(
                dependency_state._gitlinks_from_head(
                    self.source, timeout_seconds=10
                ),
                {},
            )
        finally:
            dependency_state._run_git = original_run_git
        self.assertEqual(len(calls), 2)
        self.assertTrue(
            all(
                call["maximum_stdout_bytes"]
                == dependency_state.MAX_GIT_TREE_OUTPUT_BYTES
                for call in calls
            )
        )

    def test_rejects_tracked_dependency_modification(self) -> None:
        (self.dependency / "dependency.txt").write_text(
            "modified\n", encoding="utf-8", newline="\n"
        )
        with self.assertRaisesRegex(
            dependency_state.DependencyStateError, "Tracked modifications"
        ):
            self.collect()

    def test_rejects_untracked_file_hidden_by_info_exclude(self) -> None:
        (self.source / ".git" / "info" / "exclude").write_text(
            "rogue.cc\n", encoding="utf-8"
        )
        (self.source / "rogue.cc").write_text("int rogue;\n", encoding="utf-8")
        with self.assertRaisesRegex(
            dependency_state.DependencyStateError, "Relevant untracked source inputs"
        ):
            self.collect()

    def test_allows_checked_in_gitignore_build_output(self) -> None:
        output = self.source / "out" / "Kwiken" / "chrome.exe"
        output.parent.mkdir(parents=True)
        output.write_bytes(b"fixture")
        self.collect()

    def test_rejects_dependency_revision_mismatch(self) -> None:
        (self.dependency / "second.txt").write_text("second\n", encoding="utf-8")
        run_git(self.dependency, "add", "second.txt")
        run_git(self.dependency, "commit", "--quiet", "-m", "second")
        with self.assertRaisesRegex(
            dependency_state.DependencyStateError, "revision mismatch"
        ):
            self.collect()

    def test_rejects_missing_cipd_installation_metadata(self) -> None:
        replacement_package = "gn/other/windows-amd64"
        self.cipd_description.write_text(
            json.dumps(
                {"subdir": "src/buildtools/win", "package_name": replacement_package}
            ),
            encoding="utf-8",
        )
        manifest = json.loads(self.cipd_manifest.read_text(encoding="utf-8"))
        manifest["package_name"] = replacement_package
        self.cipd_manifest.write_text(
            json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(
            dependency_state.DependencyStateError, "Installed CIPD metadata"
        ):
            self.collect()

    def test_cipd_probe_revision_roundtrip_preserves_resolved_tag(self) -> None:
        version = "version:3@httpd2.4.55-php8.2.5.chromium.6"
        encoded = dependency_state._encode_cipd_probe_revision(version)
        self.assertNotIn("@", encoded)
        self.assertEqual(
            dependency_state._decode_cipd_probe_revision(encoded, self.cipd_key),
            version,
        )

    def test_rejects_truncated_mutable_cipd_sync_entry(self) -> None:
        entries = dependency_state._load_gclient_entries(self.checkout)
        entries[self.cipd_key] = (
            f"{self.declarations[self.cipd_key]['url']}@version:3"
        )
        (self.checkout / ".gclient_entries").write_text(
            "entries = " + repr(entries) + "\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(
            dependency_state.DependencyStateError, "does not match"
        ):
            self.collect()

    def test_rejects_modified_gcs_artifact(self) -> None:
        with self.gcs_artifact.open("ab") as stream:
            stream.write(b"tampered")
        with self.assertRaisesRegex(
            dependency_state.DependencyStateError, "wrong size"
        ):
            self.collect()

    def test_rejects_modified_gcs_extracted_content(self) -> None:
        (self.gcs_directory / "fixture" / "hello.txt").write_text(
            "tampered but same purpose\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(
            dependency_state.DependencyStateError, "Installed GCS tar member"
        ):
            self.collect()

    def test_rejects_missing_gcs_sync_metadata(self) -> None:
        (self.checkout / ".gcs_entries").write_text("{}\n", encoding="utf-8")
        with self.assertRaisesRegex(
            dependency_state.DependencyStateError, "GCS sync metadata"
        ):
            self.collect()

    def test_validates_and_records_git_submodule(self) -> None:
        origin = self.root / "submodule-origin"
        submodule_revision = initialize_repository(origin, {"module.txt": "module\n"})
        subprocess.run(
            [
                "git",
                "-c",
                "protocol.file.allow=always",
                "-c",
                "core.autocrlf=false",
                "-C",
                str(self.source),
                "submodule",
                "add",
                "--quiet",
                str(origin),
                "modules/fixture",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        run_git(self.source, "add", ".gitmodules", "modules/fixture")
        run_git(self.source, "commit", "--quiet", "-m", "add submodule")
        self.source_revision = run_git(self.source, "rev-parse", "HEAD")
        self.expected["src"]["rev"] = self.source_revision
        self.actual["src"]["rev"] = self.source_revision
        self.declarations["src"]["rev"] = self.source_revision
        submodule_path = "src/modules/fixture"
        submodule_record = {
            "url": origin.as_uri(),
            "rev": submodule_revision,
        }
        self.expected[submodule_path] = dict(submodule_record)
        self.actual[submodule_path] = dict(submodule_record)
        self.declarations[submodule_path] = dict(submodule_record)
        gclient_entries = dependency_state._load_gclient_entries(self.checkout)
        gclient_entries[submodule_path] = (
            f"{submodule_record['url']}@{submodule_record['rev']}"
        )
        (self.checkout / ".gclient_entries").write_text(
            "entries = " + repr(gclient_entries) + "\n", encoding="utf-8"
        )
        self.source_delta = dependency_state._source_delta_sha256(
            self.source, self.source_revision, timeout_seconds=10
        )

        manifest = self.collect()
        self.assertEqual(manifest["summary"]["gitSubmodules"], 1)
        submodule = next(
            item for item in manifest["entries"] if item["type"] == "git-submodule"
        )
        self.assertEqual(submodule["path"], "src/modules/fixture")
        self.assertEqual(submodule["revision"], submodule_revision)

    def test_inactive_submodule_must_be_absent_or_empty(self) -> None:
        origin = self.root / "inactive-submodule-origin"
        initialize_repository(origin, {"internal.txt": "internal\n"})
        subprocess.run(
            [
                "git",
                "-c",
                "protocol.file.allow=always",
                "-c",
                "core.autocrlf=false",
                "-C",
                str(self.source),
                "submodule",
                "add",
                "--quiet",
                str(origin),
                "internal/conditional",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        run_git(self.source, "add", ".gitmodules", "internal/conditional")
        run_git(self.source, "commit", "--quiet", "-m", "add inactive submodule")
        self.source_revision = run_git(self.source, "rev-parse", "HEAD")
        self.expected["src"]["rev"] = self.source_revision
        self.actual["src"]["rev"] = self.source_revision
        self.declarations["src"]["rev"] = self.source_revision
        inactive_path = self.source / "internal" / "conditional"
        shutil.rmtree(inactive_path)
        inactive_path.mkdir(parents=True)
        self.source_delta = dependency_state._source_delta_sha256(
            self.source, self.source_revision, timeout_seconds=10
        )

        self.collect()
        (inactive_path / "undeclared.txt").write_text(
            "undeclared\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(
            dependency_state.DependencyStateError, "undeclared content"
        ):
            self.collect()

    def test_depot_tools_validation_ignores_user_excludes(self) -> None:
        tools = self.root / "depot_tools"
        revision = initialize_repository(tools, {"gclient.py": "# fixture\n"})
        dependency_state._validate_clean_tool_checkout(
            tools, revision, timeout_seconds=10
        )
        (tools / ".git" / "info" / "exclude").write_text(
            "shadow.py\n", encoding="utf-8"
        )
        (tools / "shadow.py").write_text("# shadows an import\n", encoding="utf-8")
        with self.assertRaisesRegex(
            dependency_state.DependencyStateError, "relevant untracked"
        ):
            dependency_state._validate_clean_tool_checkout(
                tools, revision, timeout_seconds=10
            )


if __name__ == "__main__":
    unittest.main()
