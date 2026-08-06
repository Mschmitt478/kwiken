from __future__ import annotations

import importlib.util
import hashlib
import json
import os
import stat
import struct
import sys
import tempfile
import unittest
import zipfile
from unittest import mock
from pathlib import Path


TOOL_PATH = Path(__file__).resolve().parents[1] / "distribution" / "runtime_archive.py"
SPEC = importlib.util.spec_from_file_location("kwiken_runtime_archive", TOOL_PATH)
assert SPEC is not None and SPEC.loader is not None
runtime_archive = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runtime_archive
SPEC.loader.exec_module(runtime_archive)


HASH_A = "a" * 64
HASH_B = "b" * 64
HASH_C = "c" * 64
VERSION = "150.0.7871.186"
RELEASE_VERSION = f"{VERSION}-r5"
ARCHIVE_ROOT = f"Kwiken-runtime-{RELEASE_VERSION}"
CHROME_CONTENTS = b"fake kwiken executable\n"
CHROME_SHA256 = hashlib.sha256(CHROME_CONTENTS).hexdigest()
CHROMIUM_REVISION = "0fcdce5f4fdec8d442d7df760cb541f1ca6e446d"


def dependency_state() -> dict:
    entries = [
        {
            "path": "src",
            "revision": CHROMIUM_REVISION,
            "type": "git",
            "url": "https://chromium.googlesource.com/chromium/src",
            "workingTreeSha256": HASH_C,
        }
    ]
    return {
        "entries": entries,
        "limitations": runtime_archive.DEPENDENCY_STATE_LIMITATIONS,
        "schemaVersion": runtime_archive.DEPENDENCY_STATE_SCHEMA_VERSION,
        "summary": {
            "cipdPackages": 0,
            "gcsObjects": 0,
            "gitRepositories": 1,
            "gitSubmodules": 0,
        },
        "treeSha256": runtime_archive.dependency_state_tree_sha256(entries),
    }


def provenance(*, dirty: bool = False) -> dict:
    state = dependency_state()
    native_build = runtime_archive._with_native_build_receipt(
        {
            "buildInvocation": {
                "commandLine": "autoninja -C out/Kwiken chrome mini_installer -j 2",
                "completed": True,
                "jobs": 2,
                "targets": ["chrome", "mini_installer"],
            },
            "buildKind": runtime_archive.BUILD_KIND,
            "chrome7zSha256": HASH_A,
            "chromeExeSha256": CHROME_SHA256,
            "miniInstallerSha256": HASH_B,
            "outputDirectory": "out/Kwiken",
            "sourceBinding": {
                "appliedSourceTreeSha256": HASH_C,
                "chromiumRevision": CHROMIUM_REVISION,
                "depotToolsRevision": "5b785272f9c776789167b4a8e32eab34352e6f20",
                "dependencyStateTreeSha256": state["treeSha256"],
                "gnArgsSha256": HASH_B,
            },
            "toolchain": {
                "cipdClientSha256": HASH_A,
                "cipdClientVersion": "git_revision:2947bd98a9c59d4f552df3a043c5883651448e0a",
                "python": "Python 3.13.5",
                "pythonCipdInstance": "EfwGjXJshOrpv0PsG7VqQ1_r2tusJOaoCg2LjarBnVAC",
                "pythonCipdPackage": "infra/3pp/tools/cpython3/windows-amd64",
                "pythonCipdVersion": "2@3.11.8.chromium.35",
                "pythonPath": "bootstrap/python3/bin/python3.exe",
                "pythonRuntimeTreeSha256": HASH_B,
                "pythonSha256": HASH_C,
                "sevenZipPath": "third_party/lzma_sdk/bin/host_platform/7za.exe",
                "sevenZipSha256": HASH_A,
                "visualStudio": "18.8.1234.1",
                "windowsDebugger": "10.0.26100.7705",
                "windowsSdk": "10.0.26100.8249",
            },
        }
    )
    return {
        "nativeBuild": native_build,
        "product": {
            "name": "Kwiken",
            "packageRevision": "5",
            "releaseVersion": RELEASE_VERSION,
            "version": VERSION,
        },
        "source": {
            "appliedSourceTreeSha256": HASH_C,
            "chromium": {
                "repository": "https://chromium.googlesource.com/chromium/src",
                "revision": CHROMIUM_REVISION,
                "version": VERSION,
            },
            "depotToolsRevision": "5b785272f9c776789167b4a8e32eab34352e6f20",
            "dependencyState": state,
            "gnArgs": {
                "path": "chromium-fork/args.gn",
                "sha256": HASH_B,
            },
            "kwiken": {
                "dirty": dirty,
                "repository": "https://github.com/Mschmitt478/kwiken",
                "revision": "0975bf8c688086d390604471b25aa6ad90b6ea8d",
            },
            "patchSet": {
                "inputs": [
                    {
                        "path": "chromium-fork/patches/0001-kwiken-browser.patch",
                        "sha256": HASH_A,
                    }
                ]
            },
        },
        "target": {"arch": "x64", "os": "windows"},
    }


def trusted_expectations(archive: Path, *, dirty: bool = False) -> dict:
    return runtime_archive.trusted_expectations_for_provenance(
        provenance(dirty=dirty),
        artifact_sha256=runtime_archive.sha256_file(archive),
        artifact_size=archive.stat().st_size,
    )


def write_runtime(root: Path) -> None:
    files = {
        "chrome.exe": CHROME_CONTENTS,
        "chrome_proxy.exe": b"fake proxy\n",
        f"{VERSION}/chrome.dll": b"fake chrome dll\n",
        f"{VERSION}/resources.pak": b"fake resources\n",
        f"{VERSION}/Locales/en-US.pak": b"fake locale\n",
        f"{VERSION}/snapshot.bin": bytes(range(255)),
    }
    for relative, contents in files.items():
        path = root.joinpath(*relative.split("/"))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)


def write_json(path: Path, value: dict) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def write_zip_member(
    archive: zipfile.ZipFile,
    name: str,
    contents: bytes,
    *,
    symlink: bool = False,
) -> None:
    info = zipfile.ZipInfo(name, date_time=runtime_archive.FIXED_ZIP_TIMESTAMP)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_version = 45
    info.extract_version = 45
    if symlink:
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
    else:
        info.create_system = 0
        info.external_attr = 0o100644 << 16
    info._compresslevel = 9
    with archive.open(info, mode="w", force_zip64=True) as destination:
        destination.write(contents)


class RuntimeArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="kwiken-runtime-tests-")
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        write_runtime(self.source)
        self.archive = self.root / "runtime.zip"
        self.manifest = self.root / "runtime.provenance.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def pack(self, archive: Path | None = None, manifest: Path | None = None) -> dict:
        return runtime_archive.create_runtime_archive(
            self.source,
            archive or self.archive,
            manifest or self.manifest,
            ARCHIVE_ROOT,
            provenance(),
            required_files=(
                "chrome.exe",
                f"{VERSION}/chrome.dll",
                f"{VERSION}/Locales/en-US.pak",
            ),
        )

    def verify(self, *, extract_to: Path | None = None, expected: dict | None = None):
        return runtime_archive.verify_runtime_archive(
            self.archive,
            self.manifest,
            extract_to=extract_to,
            expectations=expected or trusted_expectations(self.archive),
        )

    def malicious_archive(self, members: list[tuple[str, bytes, bool]]) -> None:
        good_manifest = self.pack()
        with zipfile.ZipFile(
            self.archive,
            "w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        ) as archive:
            for name, contents, symlink in members:
                write_zip_member(archive, name, contents, symlink=symlink)
        good_manifest["artifact"] = {
            "fileName": self.archive.name,
            "format": "zip",
            "sha256": runtime_archive.sha256_file(self.archive),
            "size": self.archive.stat().st_size,
        }
        write_json(self.manifest, good_manifest)

    def trust_mutated_archive(self, manifest: dict) -> None:
        manifest["artifact"] = {
            "fileName": self.archive.name,
            "format": "zip",
            "sha256": runtime_archive.sha256_file(self.archive),
            "size": self.archive.stat().st_size,
        }
        write_json(self.manifest, manifest)

    def test_pack_is_deterministic_and_manifest_lists_every_file(self) -> None:
        first = self.pack()
        second_archive = self.root / "runtime-second.zip"
        second_manifest = self.root / "runtime-second.provenance.json"
        second = self.pack(second_archive, second_manifest)

        self.assertEqual(self.archive.read_bytes(), second_archive.read_bytes())
        self.assertEqual(first["artifact"]["sha256"], second["artifact"]["sha256"])
        expected_paths = sorted(
            path.relative_to(self.source).as_posix()
            for path in self.source.rglob("*")
            if path.is_file()
        )
        self.assertEqual(
            expected_paths,
            [record["path"] for record in first["runtime"]["files"]],
        )
        self.assertEqual(len(expected_paths), first["runtime"]["fileCount"])

    def test_pack_uses_compact_windows_transaction_paths(self) -> None:
        longest_runtime_path = (
            self.source
            / VERSION
            / "PrivacySandboxAttestationsPreloaded"
            / "privacy-sandbox-attestations.dat"
        )
        longest_runtime_path.parent.mkdir(parents=True, exist_ok=True)
        longest_runtime_path.write_bytes(b"attestations\n")

        output_parent = self.root / "release"
        while len(os.fspath(output_parent.absolute())) < 150:
            output_parent /= "nested-transaction-path"
        output_parent.mkdir(parents=True)
        archive = output_parent / f"{ARCHIVE_ROOT}-windows-x64.zip"
        manifest = output_parent / f"{ARCHIVE_ROOT}-windows-x64.provenance.json"

        transaction_directories: list[Path] = []
        atomic_paths: list[Path] = []
        real_mkdtemp = runtime_archive.tempfile.mkdtemp
        real_new_atomic_path = runtime_archive._new_atomic_path

        def capture_mkdtemp(*args, **kwargs) -> str:
            created = Path(real_mkdtemp(*args, **kwargs))
            transaction_directories.append(created)
            return os.fspath(created)

        def capture_atomic_path(destination: Path) -> Path:
            created = real_new_atomic_path(destination)
            atomic_paths.append(created)
            return created

        with mock.patch.object(
            runtime_archive.tempfile, "mkdtemp", side_effect=capture_mkdtemp
        ), mock.patch.object(
            runtime_archive, "_new_atomic_path", side_effect=capture_atomic_path
        ):
            packed_manifest = self.pack(archive, manifest)

        self.assertEqual(1, len(transaction_directories))
        self.assertEqual(1, len(atomic_paths))
        transaction_directory = transaction_directories[0]
        intermediate_paths = [
            transaction_directory,
            transaction_directory / archive.name,
            transaction_directory / manifest.name,
            *atomic_paths,
        ]
        self.assertLessEqual(
            max(len(os.fspath(path.absolute())) for path in intermediate_paths),
            259,
        )
        self.assertNotIn(archive.name, transaction_directory.name)
        self.assertNotIn(manifest.name, atomic_paths[0].name)

        extraction_parent = self.root / "verify"
        extraction_padding = (
            105 - len(os.fspath(extraction_parent.absolute())) - 1
        )
        if extraction_padding > 0:
            extraction_parent /= "x" * extraction_padding
        extraction_parent.mkdir(parents=True)
        extraction_destination = extraction_parent / "verified-extracted"
        extraction_paths: list[Path] = []
        real_new_extraction_path = runtime_archive._new_extraction_path

        def capture_extraction_path(destination: Path) -> Path:
            created = real_new_extraction_path(destination)
            extraction_paths.append(created)
            return created

        with mock.patch.object(
            runtime_archive,
            "_new_extraction_path",
            side_effect=capture_extraction_path,
        ):
            runtime_archive.verify_runtime_archive(
                archive,
                manifest,
                extract_to=extraction_destination,
                expectations=trusted_expectations(archive),
            )

        self.assertEqual(1, len(extraction_paths))
        longest_record = max(
            (record["path"] for record in packed_manifest["runtime"]["files"]),
            key=len,
        )
        deepest_target = extraction_paths[0].joinpath(
            ARCHIVE_ROOT, *longest_record.split("/")
        )
        self.assertLessEqual(len(os.fspath(deepest_target.absolute())), 259)
        self.assertNotIn(extraction_destination.name, extraction_paths[0].name)

    def test_cli_pack_and_verify_contract(self) -> None:
        state = dependency_state()
        state_manifest = self.root / "dependency-state.json"
        write_json(state_manifest, state)
        self.assertEqual(
            0,
            runtime_archive.main(
                [
                    "pack",
                    "--source",
                    str(self.source),
                    "--archive",
                    str(self.archive),
                    "--manifest",
                    str(self.manifest),
                    "--archive-root",
                    ARCHIVE_ROOT,
                    "--version",
                    VERSION,
                    "--package-revision",
                    "5",
                    "--release-version",
                    RELEASE_VERSION,
                    "--kwiken-revision",
                    "0975bf8c688086d390604471b25aa6ad90b6ea8d",
                    "--chromium-revision",
                    "0fcdce5f4fdec8d442d7df760cb541f1ca6e446d",
                    "--depot-tools-revision",
                    "5b785272f9c776789167b4a8e32eab34352e6f20",
                    "--source-delta-sha256",
                    HASH_C,
                    "--dependency-state-manifest",
                    str(state_manifest),
                    "--gn-args-sha256",
                    HASH_B,
                    "--chrome-7z-sha256",
                    HASH_A,
                    "--chrome-exe-sha256",
                    CHROME_SHA256,
                    "--mini-installer-sha256",
                    HASH_B,
                    "--build-command-line",
                    "autoninja -C out/Kwiken chrome mini_installer -j 2",
                    "--build-jobs",
                    "2",
                    "--visual-studio-version",
                    "18.8.1234.1",
                    "--windows-sdk-version",
                    "10.0.26100.8249",
                    "--windows-debugger-version",
                    "10.0.26100.7705",
                    "--python-version",
                    "Python 3.13.5",
                    "--python-cipd-package",
                    "infra/3pp/tools/cpython3/windows-amd64",
                    "--python-cipd-version",
                    "2@3.11.8.chromium.35",
                    "--python-cipd-instance",
                    "EfwGjXJshOrpv0PsG7VqQ1_r2tusJOaoCg2LjarBnVAC",
                    "--cipd-client-version",
                    "git_revision:2947bd98a9c59d4f552df3a043c5883651448e0a",
                    "--cipd-client-sha256",
                    HASH_A,
                    "--python-path",
                    "bootstrap/python3/bin/python3.exe",
                    "--python-runtime-tree-sha256",
                    HASH_B,
                    "--python-sha256",
                    HASH_C,
                    "--seven-zip-path",
                    "third_party/lzma_sdk/bin/host_platform/7za.exe",
                    "--seven-zip-sha256",
                    HASH_A,
                    "--output-directory",
                    "out/Kwiken",
                    "--source-input",
                    f"chromium-fork/patches/0001-kwiken-browser.patch={HASH_A}",
                ]
            ),
        )
        extracted = self.root / "cli-extracted"
        self.assertEqual(
            0,
            runtime_archive.main(
                [
                    "verify",
                    "--archive",
                    str(self.archive),
                    "--manifest",
                    str(self.manifest),
                    "--extract-to",
                    str(extracted),
                    "--expect-version",
                    VERSION,
                    "--expect-package-revision",
                    "5",
                    "--expect-release-version",
                    RELEASE_VERSION,
                    "--expect-kwiken-revision",
                    "0975bf8c688086d390604471b25aa6ad90b6ea8d",
                    "--expect-chromium-revision",
                    "0fcdce5f4fdec8d442d7df760cb541f1ca6e446d",
                    "--expect-depot-tools-revision",
                    "5b785272f9c776789167b4a8e32eab34352e6f20",
                    "--expect-source-delta-sha256",
                    HASH_C,
                    "--expect-dependency-state-tree-sha256",
                    state["treeSha256"],
                    "--expect-gn-args-sha256",
                    HASH_B,
                    "--expect-artifact-sha256",
                    runtime_archive.sha256_file(self.archive),
                    "--expect-artifact-size",
                    str(self.archive.stat().st_size),
                    "--expect-chrome-7z-sha256",
                    HASH_A,
                    "--expect-chrome-exe-sha256",
                    CHROME_SHA256,
                    "--expect-mini-installer-sha256",
                    HASH_B,
                    "--expect-build-command-line",
                    "autoninja -C out/Kwiken chrome mini_installer -j 2",
                    "--expect-build-jobs",
                    "2",
                    "--expect-output-directory",
                    "out/Kwiken",
                    "--expect-visual-studio-version",
                    "18.8.1234.1",
                    "--expect-windows-sdk-version",
                    "10.0.26100.8249",
                    "--expect-windows-debugger-version",
                    "10.0.26100.7705",
                    "--expect-python-version",
                    "Python 3.13.5",
                    "--expect-python-cipd-package",
                    "infra/3pp/tools/cpython3/windows-amd64",
                    "--expect-python-cipd-version",
                    "2@3.11.8.chromium.35",
                    "--expect-python-cipd-instance",
                    "EfwGjXJshOrpv0PsG7VqQ1_r2tusJOaoCg2LjarBnVAC",
                    "--expect-cipd-client-version",
                    "git_revision:2947bd98a9c59d4f552df3a043c5883651448e0a",
                    "--expect-cipd-client-sha256",
                    HASH_A,
                    "--expect-python-path",
                    "bootstrap/python3/bin/python3.exe",
                    "--expect-python-runtime-tree-sha256",
                    HASH_B,
                    "--expect-python-sha256",
                    HASH_C,
                    "--expect-seven-zip-path",
                    "third_party/lzma_sdk/bin/host_platform/7za.exe",
                    "--expect-seven-zip-sha256",
                    HASH_A,
                    "--expect-source-input",
                    f"chromium-fork/patches/0001-kwiken-browser.patch={HASH_A}",
                    "--require-clean-source",
                ]
            ),
        )
        self.assertTrue((extracted / ARCHIVE_ROOT / "chrome.exe").is_file())

    def test_verify_extracts_only_after_full_validation(self) -> None:
        self.pack()
        destination = self.root / "extracted"
        self.verify(extract_to=destination)
        self.assertEqual(
            (self.source / "chrome.exe").read_bytes(),
            (destination / ARCHIVE_ROOT / "chrome.exe").read_bytes(),
        )
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "must not already exist",
        ):
            self.verify(extract_to=destination)

    def test_archive_hash_tampering_is_rejected(self) -> None:
        self.pack()
        expected = trusted_expectations(self.archive)
        archive_bytes = bytearray(self.archive.read_bytes())
        archive_bytes[len(archive_bytes) // 2] ^= 0x01
        self.archive.write_bytes(archive_bytes)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError, "artifactSha256|checksum does not match"
        ):
            self.verify(expected=expected)

    def test_full_file_manifest_hash_tampering_is_rejected(self) -> None:
        manifest = self.pack()
        manifest["runtime"]["files"][0]["sha256"] = "d" * 64
        records = [
            runtime_archive.FileRecord(
                record["path"], record["size"], record["sha256"]
            )
            for record in manifest["runtime"]["files"]
        ]
        manifest["runtime"]["treeSha256"] = runtime_archive.tree_sha256(records)
        write_json(self.manifest, manifest)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError, "checksum mismatch"
        ):
            self.verify()

    def test_path_traversal_is_rejected_before_extraction(self) -> None:
        self.malicious_archive(
            [(f"{ARCHIVE_ROOT}/../escape.txt", b"escape", False)]
        )
        destination = self.root / "unsafe-extraction"
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError, "Unsafe runtime path component"
        ):
            self.verify(extract_to=destination)
        self.assertFalse(destination.exists())
        self.assertFalse((self.root / "escape.txt").exists())

    def test_case_insensitive_collision_is_rejected(self) -> None:
        self.malicious_archive(
            [
                (f"{ARCHIVE_ROOT}/Folder/value.txt", b"one", False),
                (f"{ARCHIVE_ROOT}/folder/VALUE.txt", b"two", False),
            ]
        )
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "Case-insensitive runtime path collision",
        ):
            self.verify()

    def test_windows_unsafe_path_forms_are_rejected(self) -> None:
        unsafe_paths = (
            "/absolute/file",
            "C:/absolute/file",
            "folder\\backslash.txt",
            "folder/file.txt:stream",
            "folder/CON.txt",
            "folder/COM¹.txt",
            "folder/LPT².log",
            "folder/CONIN$",
            "folder/CONOUT$.txt",
            'folder/bad"name',
            "folder/bad<name",
            "folder/bad>name",
            "folder/bad|name",
            "folder/bad?name",
            "folder/bad*name",
            "folder/trailing. ",
        )
        for path in unsafe_paths:
            with self.subTest(path=path), self.assertRaises(
                runtime_archive.RuntimeArchiveError
            ):
                runtime_archive._validate_relative_path(
                    path, archive_member=True
                )

    def test_unexpected_version_directory_is_rejected(self) -> None:
        unexpected_path = "149.0.0.0/old.dll"
        unexpected_file = self.source / "unexpected.dll"
        unexpected_file.write_bytes(b"old")
        # Repack with the unexpected directory represented honestly so the
        # provenance validator, not an archive/file-set mismatch, rejects it.
        version_path = self.source / unexpected_path
        version_path.parent.mkdir(parents=True)
        unexpected_file.replace(version_path)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "unexpected version directory",
        ):
            self.pack()

    def test_zip_symlink_is_rejected(self) -> None:
        self.malicious_archive(
            [(f"{ARCHIVE_ROOT}/link", b"chrome.exe", True)]
        )
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "Links and reparse points are not allowed",
        ):
            self.verify()

    def test_pack_rejects_source_symlink_when_supported(self) -> None:
        target = self.source / "real-file"
        target.write_bytes(b"real")
        link = self.source / "linked-file"
        try:
            os.symlink(target, link)
        except (OSError, NotImplementedError):
            self.skipTest("Creating symlinks is not permitted on this Windows host.")
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "Links and reparse points are not allowed",
        ):
            self.pack()

    def test_pack_rejects_outputs_inside_runtime_source(self) -> None:
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "cannot be placed inside",
        ):
            runtime_archive.create_runtime_archive(
                self.source,
                self.source / "bad.zip",
                self.root / "bad.json",
                ARCHIVE_ROOT,
                provenance(),
            )

    def test_pack_rejects_dirty_source(self) -> None:
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "dirty Kwiken source",
        ):
            runtime_archive.create_runtime_archive(
                self.source,
                self.archive,
                self.manifest,
                ARCHIVE_ROOT,
                provenance(dirty=True),
            )

    def test_patch_input_expectation_is_enforced(self) -> None:
        self.pack()
        expected = trusted_expectations(self.archive)
        expected["sourceInputs"] = [
            {
                "path": "chromium-fork/patches/0001-kwiken-browser.patch",
                "sha256": HASH_B,
            }
        ]
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "patch-set inputs do not match",
        ):
            self.verify(expected=expected)

    def test_verification_requires_complete_trusted_expectations(self) -> None:
        self.pack()
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "Trusted release expectations are required",
        ):
            runtime_archive.verify_runtime_archive(self.archive, self.manifest)
        incomplete = trusted_expectations(self.archive)
        incomplete.pop("windowsSdkVersion")
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "expectations are incomplete",
        ):
            self.verify(expected=incomplete)

    def test_every_native_build_field_is_externally_pinned(self) -> None:
        self.pack()
        expected = trusted_expectations(self.archive)
        expected["windowsSdkVersion"] = "10.0.99999.0"
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "provenance mismatch for windowsSdkVersion",
        ):
            self.verify(expected=expected)

    def test_dependency_state_tree_is_externally_pinned(self) -> None:
        self.pack()
        expected = trusted_expectations(self.archive)
        expected["dependencyStateTreeSha256"] = HASH_A
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "provenance mismatch for dependencyStateTreeSha256",
        ):
            self.verify(expected=expected)

    def test_dependency_state_validates_content_attestation_fields(self) -> None:
        entries = [
            {
                "declaredPackage": "infra/tools/fixture/${platform}",
                "instanceId": "A" * 44,
                "package": "infra/tools/fixture/windows-amd64",
                "packageFileTreeSha256": HASH_A,
                "packageManifestSha256": HASH_B,
                "path": "src/tools/fixture",
                "type": "cipd",
                "verificationLevel": (
                    "cipd-deployment-check-and-package-manifest-sha256"
                ),
                "version": "latest",
                "versionResolution": (
                    "declared-version-with-installed-instance-provenance"
                ),
            },
            {
                "artifactSha256": HASH_A,
                "contentNamesSha256": None,
                "expectedSha256": HASH_A,
                "expectedSizeBytes": 7,
                "installedTreeSha256": HASH_B,
                "object": "fixture.bin",
                "outputFile": "fixture.bin",
                "path": "src/test/data",
                "type": "gcs",
                "url": "gs://kwiken-test/fixture.bin",
                "verificationLevel": (
                    "expected-artifact-and-installed-content-sha256"
                ),
            },
            dependency_state()["entries"][0],
        ]
        state = {
            "entries": entries,
            "limitations": [
                runtime_archive.DEPENDENCY_STATE_MUTABLE_CIPD_LIMITATION,
                runtime_archive.DEPENDENCY_STATE_INACTIVE_PLATFORM_LIMITATION,
            ],
            "schemaVersion": runtime_archive.DEPENDENCY_STATE_SCHEMA_VERSION,
            "summary": {
                "cipdPackages": 1,
                "gcsObjects": 1,
                "gitRepositories": 1,
                "gitSubmodules": 0,
            },
            "treeSha256": runtime_archive.dependency_state_tree_sha256(entries),
        }
        self.assertEqual(state, runtime_archive._validate_dependency_state(state))
        state["limitations"] = runtime_archive.DEPENDENCY_STATE_LIMITATIONS
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError, "limitations must exactly match"
        ):
            runtime_archive._validate_dependency_state(state)

    def test_native_build_receipt_tampering_is_rejected(self) -> None:
        manifest = self.pack()
        manifest["nativeBuild"]["chromeExeSha256"] = "d" * 64
        write_json(self.manifest, manifest)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "buildReceiptSha256 does not bind",
        ):
            self.verify()

    def test_native_chrome_hash_must_match_runtime_chrome(self) -> None:
        bad_provenance = provenance()
        native_build = dict(bad_provenance["nativeBuild"])
        native_build["chromeExeSha256"] = "d" * 64
        native_build = runtime_archive._with_native_build_receipt(native_build)
        bad_provenance["nativeBuild"] = native_build
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "chromeExeSha256 does not match runtime chrome.exe",
        ):
            runtime_archive.create_runtime_archive(
                self.source,
                self.archive,
                self.manifest,
                ARCHIVE_ROOT,
                bad_provenance,
            )

    def test_raw_zip_member_name_is_validated_before_zipfile_sanitization(self) -> None:
        manifest = self.pack()
        safe_name = f"{ARCHIVE_ROOT}/chrome.exe".encode("ascii")
        raw_name = f"{ARCHIVE_ROOT}\\chrome.exe".encode("ascii")
        archive_bytes = self.archive.read_bytes()
        self.assertGreaterEqual(archive_bytes.count(safe_name), 2)
        self.archive.write_bytes(archive_bytes.replace(safe_name, raw_name))
        manifest["artifact"]["sha256"] = runtime_archive.sha256_file(self.archive)
        manifest["artifact"]["size"] = self.archive.stat().st_size
        write_json(self.manifest, manifest)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "forward slashes|raw member name",
        ):
            self.verify()

    def test_zip_member_order_is_canonical(self) -> None:
        manifest = self.pack()
        members = sorted(
            (
                f"{ARCHIVE_ROOT}/{path.relative_to(self.source).as_posix()}",
                path.read_bytes(),
            )
            for path in self.source.rglob("*")
            if path.is_file()
        )
        with zipfile.ZipFile(
            self.archive,
            "w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        ) as archive:
            for name, contents in reversed(members):
                write_zip_member(archive, name, contents)
        manifest["artifact"]["sha256"] = runtime_archive.sha256_file(self.archive)
        manifest["artifact"]["size"] = self.archive.stat().st_size
        write_json(self.manifest, manifest)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "canonical ordinal path order",
        ):
            self.verify()

    def test_size_mismatch_is_rejected_before_snapshot_copy(self) -> None:
        manifest = self.pack()
        expected = trusted_expectations(self.archive)
        oversized = self.archive.stat().st_size + 10 * 1024 * 1024 * 1024
        manifest["artifact"]["size"] = oversized
        expected["artifactSize"] = oversized
        write_json(self.manifest, manifest)
        with mock.patch.object(
            runtime_archive.tempfile,
            "TemporaryFile",
            side_effect=AssertionError("snapshot must not be created"),
        ), self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "size does not match",
        ):
            self.verify(expected=expected)

    def test_compressed_size_limit_is_enforced_before_snapshot_copy(self) -> None:
        self.pack()
        expected = trusted_expectations(self.archive)
        with mock.patch.object(
            runtime_archive.tempfile,
            "TemporaryFile",
            side_effect=AssertionError("snapshot must not be created"),
        ), self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "compressed-size limit",
        ):
            runtime_archive.verify_runtime_archive(
                self.archive,
                self.manifest,
                expectations=expected,
                max_archive_bytes=self.archive.stat().st_size - 1,
            )

    def test_many_entry_eocd_is_bounded_before_zipfile(self) -> None:
        manifest = self.pack()
        archive_bytes = bytearray(self.archive.read_bytes())
        eocd_offset = len(archive_bytes) - runtime_archive.ZIP_EOCD_SIZE
        excessive_count = runtime_archive.DEFAULT_MAX_FILES + 1
        struct.pack_into("<H", archive_bytes, eocd_offset + 8, excessive_count)
        struct.pack_into("<H", archive_bytes, eocd_offset + 10, excessive_count)
        self.archive.write_bytes(archive_bytes)
        self.trust_mutated_archive(manifest)
        with mock.patch.object(
            runtime_archive.zipfile,
            "ZipFile",
            side_effect=AssertionError("ZipFile must not be constructed"),
        ), self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "contains 10001 entries",
        ):
            self.verify()

    def test_zip_with_mz_prefix_is_rejected(self) -> None:
        manifest = self.pack()
        self.archive.write_bytes(b"MZ" + self.archive.read_bytes())
        self.trust_mutated_archive(manifest)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "prepended|gapped envelope",
        ):
            self.verify()

    def test_zip_with_trailing_bytes_is_rejected(self) -> None:
        manifest = self.pack()
        self.archive.write_bytes(self.archive.read_bytes() + b"hidden trailer")
        self.trust_mutated_archive(manifest)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "EOCD must end exactly",
        ):
            self.verify()

    def test_noncanonical_central_zip64_values_are_rejected(self) -> None:
        cases = (
            (runtime_archive.ZIP_UINT32_MAX, 1, 0, struct.pack("<HHQ", 1, 8, 1)),
            (1, runtime_archive.ZIP_UINT32_MAX, 0, struct.pack("<HHQ", 1, 8, 1)),
            (1, 1, runtime_archive.ZIP_UINT32_MAX, struct.pack("<HHQ", 1, 8, 1)),
        )
        for compressed, uncompressed, offset, extra in cases:
            with self.subTest(
                compressed=compressed,
                uncompressed=uncompressed,
                offset=offset,
            ):
                with self.assertRaisesRegex(
                    runtime_archive.RuntimeArchiveError, "ZIP64 data is unnecessary"
                ):
                    runtime_archive._resolve_central_zip64_values(
                        compressed_size=compressed,
                        uncompressed_size=uncompressed,
                        local_header_offset=offset,
                        disk_start=0,
                        extra=extra,
                        label="test entry",
                    )
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError, "disk-start data"
        ):
            runtime_archive._resolve_central_zip64_values(
                compressed_size=1,
                uncompressed_size=1,
                local_header_offset=0,
                disk_start=runtime_archive.ZIP_UINT16_MAX,
                extra=struct.pack("<HHI", 1, 4, 0),
                label="test entry",
            )

    def test_local_encryption_flag_mismatch_is_rejected(self) -> None:
        manifest = self.pack()
        archive_bytes = bytearray(self.archive.read_bytes())
        local_flags = struct.unpack_from("<H", archive_bytes, 6)[0]
        struct.pack_into("<H", archive_bytes, 6, local_flags | 0x1)
        self.archive.write_bytes(archive_bytes)
        self.trust_mutated_archive(manifest)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "Encrypted ZIP member",
        ):
            self.verify()

    def test_local_compression_method_mismatch_is_rejected(self) -> None:
        manifest = self.pack()
        archive_bytes = bytearray(self.archive.read_bytes())
        struct.pack_into("<H", archive_bytes, 8, zipfile.ZIP_STORED)
        self.archive.write_bytes(archive_bytes)
        self.trust_mutated_archive(manifest)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "compression methods disagree",
        ):
            self.verify()

    def test_local_filename_mismatch_is_rejected(self) -> None:
        manifest = self.pack()
        archive_bytes = bytearray(self.archive.read_bytes())
        name_size = struct.unpack_from("<H", archive_bytes, 26)[0]
        self.assertGreater(name_size, 0)
        archive_bytes[runtime_archive.ZIP_LOCAL_HEADER_SIZE] ^= 0x01
        self.archive.write_bytes(archive_bytes)
        self.trust_mutated_archive(manifest)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "filenames disagree",
        ):
            self.verify()

    def test_local_size_mismatch_is_rejected(self) -> None:
        manifest = self.pack()
        archive_bytes = bytearray(self.archive.read_bytes())
        struct.pack_into("<I", archive_bytes, 18, 0)
        self.archive.write_bytes(archive_bytes)
        self.trust_mutated_archive(manifest)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "sizes are not in canonical ZIP64 form",
        ):
            self.verify()

    def test_remaining_local_envelope_fields_are_bound(self) -> None:
        manifest = self.pack()
        original = self.archive.read_bytes()
        eocd_offset = len(original) - runtime_archive.ZIP_EOCD_SIZE
        central_offset = struct.unpack_from("<I", original, eocd_offset + 16)[0]
        name_size = struct.unpack_from("<H", original, 26)[0]
        zip64_size_offset = runtime_archive.ZIP_LOCAL_HEADER_SIZE + name_size + 4

        def flip_byte(data: bytearray, offset: int) -> None:
            data[offset] ^= 0x01

        def change_local_time(data: bytearray, _offset: int) -> None:
            struct.pack_into("<H", data, 10, 1)

        def change_central_local_offset(data: bytearray, offset: int) -> None:
            struct.pack_into("<I", data, offset, 1)

        probes = (
            ("signature", 0, flip_byte, "local-header signature"),
            ("timestamp", 10, change_local_time, "timestamps disagree"),
            ("crc", 14, flip_byte, "CRC values disagree"),
            ("zip64 extra", zip64_size_offset, flip_byte, "ZIP64 sizes disagree"),
            (
                "local offset",
                central_offset + 42,
                change_central_local_offset,
                "overlap|gaps|out of order",
            ),
        )
        for label, offset, mutate, message in probes:
            with self.subTest(field=label):
                archive_bytes = bytearray(original)
                mutate(archive_bytes, offset)
                self.archive.write_bytes(archive_bytes)
                self.trust_mutated_archive(manifest)
                with self.assertRaisesRegex(
                    runtime_archive.RuntimeArchiveError,
                    message,
                ):
                    self.verify()

    def test_verification_opens_archive_path_once(self) -> None:
        self.pack()
        expected = trusted_expectations(self.archive)
        archive_path = self.archive
        original_open = Path.open
        archive_open_count = 0

        def tracking_open(path: Path, *args, **kwargs):
            nonlocal archive_open_count
            mode = args[0] if args else kwargs.get("mode", "r")
            if path == archive_path and mode == "rb":
                archive_open_count += 1
            return original_open(path, *args, **kwargs)

        with mock.patch.object(Path, "open", tracking_open):
            self.verify(expected=expected)
        self.assertEqual(1, archive_open_count)

    def test_pack_refuses_to_overwrite_release_pair(self) -> None:
        self.pack()
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "Refusing to overwrite",
        ):
            self.pack()

    def test_manifest_size_and_record_count_are_bounded_before_zip_inspection(self) -> None:
        self.pack()
        expected = trusted_expectations(self.archive)
        with mock.patch.object(runtime_archive, "MAX_MANIFEST_BYTES", 64):
            with self.assertRaisesRegex(
                runtime_archive.RuntimeArchiveError,
                "manifest exceeds",
            ):
                self.verify(expected=expected)
        with self.assertRaisesRegex(
            runtime_archive.RuntimeArchiveError,
            "runtime.files contains",
        ):
            runtime_archive.verify_runtime_archive(
                self.archive,
                self.manifest,
                expectations=expected,
                max_files=1,
            )


if __name__ == "__main__":
    unittest.main()
