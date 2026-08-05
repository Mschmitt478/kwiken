from __future__ import annotations

import re
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "export-runtime.ps1"


class ExportRuntimeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = SCRIPT_PATH.read_text(encoding="utf-8")

    def test_release_has_no_tool_or_safety_bypass_parameters(self) -> None:
        parameter_block = self.script[: self.script.index(
            '. (Join-Path $PSScriptRoot "common.ps1")'
        )]
        for forbidden in (
            "PythonPath",
            "SevenZipPath",
            "SkipSmokeTest",
            "AllowDirtyRepository",
        ):
            self.assertNotIn(forbidden, parameter_block)
        self.assertNotIn("python3.bat", self.script)
        self.assertIn('"python3.exe"', self.script)
        self.assertIn('"export",', self.script)
        self.assertIn("Assert-InstalledPythonMatchesAuthenticatedRuntime", self.script)
        self.assertIn(
            "$relativePath -notmatch '(?:^|/)__pycache__/[^/]+\\.pyc$'",
            self.script,
        )
        self.assertIn(
            "$verifiedPaths.Count -ne $authenticatedFiles.Count", self.script
        )
        self.assertIn('@("-I", "-S", "-B", $ToolPath)', self.script)
        self.assertIn("ExpectedRuntimeTreeSha256", self.script)
        self.assertNotIn(
            "Get-PythonVersionText -PythonPath $python.Path", self.script
        )
        self.assertIn("-IsolatedPython", self.script)

    def test_repository_cleanliness_command_is_explicit(self) -> None:
        self.assertRegex(
            self.script,
            r"status --porcelain=v1\s+`?\s*--untracked-files=all "
            r"--ignore-submodules=none",
        )

    def test_incremental_build_precedes_immutable_snapshots(self) -> None:
        build = self.script.index('"autoninja.bat"')
        archive_snapshot = self.script.index(
            "Copy-FileSnapshot -Source $rawArchive"
        )
        installer_snapshot = self.script.index(
            "Copy-FileSnapshot -Source $miniInstaller"
        )
        extraction = self.script.index(
            "Invoke-HardenedSevenZipExtraction -SevenZipPath"
        )
        self.assertLess(build, archive_snapshot)
        self.assertLess(build, installer_snapshot)
        self.assertLess(archive_snapshot, extraction)

    def test_raw_seven_zip_is_tested_listed_then_extracted_without_prompt(self) -> None:
        integrity = self.script.index('@("t", "-bd", "-p-", "--", $ArchivePath)')
        listing = self.script.index(
            '@("l", "-slt", "-sccUTF-8", "-p-", "--", $ArchivePath)'
        )
        extraction = self.script.index(
            '@("x", "-bd", "-y", "-p-", "-o$Destination", "--", $ArchivePath)'
        )
        self.assertLess(integrity, listing)
        self.assertLess(listing, extraction)
        self.assertIn("Assert-SafeSevenZipListing", self.script)

    def test_tool_hashes_and_amd64_checks_are_release_inputs(self) -> None:
        for required in (
            '"--python-path"',
            '"--python-sha256"',
            '"--seven-zip-path"',
            '"--seven-zip-sha256"',
            "Assert-Amd64Pe -Path $nativeChromePath",
            "Assert-Amd64Pe -Path $nativeProxyPath",
            "Assert-Amd64Pe -Path $nativeDllPath",
            "Assert-Amd64Pe -Path $snapshotInstaller",
        ):
            self.assertIn(required, self.script)

    def test_publication_is_ready_marked_and_directory_atomic(self) -> None:
        ready_write = self.script.index("[IO.File]::WriteAllText(\n    $readyPath")
        publish = self.script.index(
            "[IO.Directory]::Move($publicationRoot, $finalDirectory)"
        )
        self.assertLess(ready_write, publish)
        self.assertIn("Refusing to overwrite existing runtime release", self.script)
        self.assertIn("New-PrivateDirectory -Path $stagingRoot", self.script)
        self.assertIn("ConvertStringSecurityDescriptorToSecurityDescriptor", self.script)
        self.assertIn("D:P(A;OICI;FA", self.script)
        self.assertIn("S-1-5-12", self.script)
        self.assertNotIn('"--no-sandbox"', self.script)

    def test_all_manifest_native_fields_are_repeated_as_verify_expectations(self) -> None:
        pairs = (
            ("--chrome-7z-sha256", "--expect-chrome-7z-sha256"),
            ("--chrome-exe-sha256", "--expect-chrome-exe-sha256"),
            ("--mini-installer-sha256", "--expect-mini-installer-sha256"),
            ("--build-command-line", "--expect-build-command-line"),
            ("--build-jobs", "--expect-build-jobs"),
            ("--visual-studio-version", "--expect-visual-studio-version"),
            ("--windows-sdk-version", "--expect-windows-sdk-version"),
            ("--windows-debugger-version", "--expect-windows-debugger-version"),
            ("--python-version", "--expect-python-version"),
            ("--python-cipd-package", "--expect-python-cipd-package"),
            ("--python-cipd-version", "--expect-python-cipd-version"),
            ("--python-cipd-instance", "--expect-python-cipd-instance"),
            ("--cipd-client-version", "--expect-cipd-client-version"),
            ("--cipd-client-sha256", "--expect-cipd-client-sha256"),
            ("--python-path", "--expect-python-path"),
            (
                "--python-runtime-tree-sha256",
                "--expect-python-runtime-tree-sha256",
            ),
            ("--python-sha256", "--expect-python-sha256"),
            ("--seven-zip-path", "--expect-seven-zip-path"),
            ("--seven-zip-sha256", "--expect-seven-zip-sha256"),
            ("--output-directory", "--expect-output-directory"),
            (
                "--dependency-state-manifest",
                "--expect-dependency-state-tree-sha256",
            ),
        )
        for packed, verified in pairs:
            with self.subTest(field=packed):
                self.assertIn(f'"{packed}"', self.script)
                self.assertIn(f'"{verified}"', self.script)
        self.assertIn('"--expect-artifact-sha256"', self.script)
        self.assertIn('"--expect-artifact-size"', self.script)
        self.assertIn('"--max-archive-bytes"', self.script)
        self.assertIn('"--require-clean-source"', self.script)

    def test_dependency_state_is_snapshotted_and_rechecked_before_publish(self) -> None:
        self.assertIn("function Invoke-DependencyStateCapture", self.script)
        self.assertIn("$snapshotDependencyStateTool", self.script)
        self.assertIn("$dependencyState.ManifestSha256", self.script)
        self.assertIn("$finalDependencyState.ManifestSha256", self.script)
        final_check = self.script.index(
            'throw "The Chromium dependency state changed during release staging."'
        )
        publish = self.script.index(
            "[IO.Directory]::Move($publicationRoot, $finalDirectory)"
        )
        self.assertLess(final_check, publish)

    def test_process_tree_cleanup_is_checked_and_confirmed(self) -> None:
        self.assertIn("Stop-ProcessTreeChecked", self.script)
        self.assertIn("$taskkillExitCode -ne 0", self.script)
        self.assertIn("Stop-ProfileProcessesChecked", self.script)
        self.assertIn("Smoke-test process cleanup was incomplete", self.script)

    def test_cleanup_races_preserve_primary_outcomes(self) -> None:
        stop_tree = self.script[
            self.script.index("function Stop-ProcessTreeChecked") :
            self.script.index("function Invoke-DirectProcess")
        ]
        self.assertIn("if (-not $Process.HasExited)", stop_tree)
        self.assertNotIn(
            "$taskkillExitCode -ne 0 -or -not $Process.HasExited",
            stop_tree,
        )
        self.assertIn("-WarningAction Continue", self.script)
        self.assertIn("function Test-SameProfileProcess", self.script)
        self.assertIn("$Current.CreationDate -eq $Candidate.CreationDate", self.script)


if __name__ == "__main__":
    unittest.main()
