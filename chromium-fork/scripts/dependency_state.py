#!/usr/bin/env python3
"""Validate and fingerprint the active Chromium gclient dependency state."""

from __future__ import annotations

import argparse
import ast
import base64
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tarfile
import time
import urllib.parse
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO, Iterable, Mapping, Sequence


SCHEMA_VERSION = 1
MAX_COMMAND_OUTPUT_BYTES = 32 * 1024 * 1024
MAX_GIT_TREE_OUTPUT_BYTES = 128 * 1024 * 1024
MAX_METADATA_BYTES = 32 * 1024 * 1024
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
REVISION_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
CIPD_INSTANCE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{40,64}$")
CIPD_SERVICE = "https://chrome-infra-packages.appspot.com"
GCS_PROBE_REVISION_PREFIX = "kwiken-gcs-v1:"
CIPD_PROBE_REVISION_PREFIX = "kwiken-cipd-v1:"
BASE_LIMITATIONS = [
    "inactive-non-windows-conditional-dependencies-are-not-materialized-or-validated",
]
MUTABLE_CIPD_LIMITATION = (
    "cipd-mutable-version-to-instance-resolution-is-not-independently-verifiable-offline"
)


class DependencyStateError(ValueError):
    """Raised when the gclient dependency state is incomplete or unsafe."""


def _json_no_duplicates(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise DependencyStateError(f"Duplicate JSON key is not allowed: {key!r}")
        value[key] = item
    return value


def _read_limited(path: Path, maximum_bytes: int = MAX_METADATA_BYTES) -> bytes:
    try:
        size = path.stat().st_size
    except OSError as error:
        raise DependencyStateError(f"Could not inspect metadata file {path}: {error}") from error
    if size > maximum_bytes:
        raise DependencyStateError(
            f"Metadata file exceeds the {maximum_bytes}-byte limit: {path}"
        )
    try:
        return path.read_bytes()
    except OSError as error:
        raise DependencyStateError(f"Could not read metadata file {path}: {error}") from error


def _load_json_bytes(data: bytes, label: str) -> Any:
    try:
        return json.loads(
            data.decode("utf-8"), object_pairs_hook=_json_no_duplicates
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise DependencyStateError(f"Could not parse {label}: {error}") from error


def _normalized_relative_path(value: str, label: str = "dependency path") -> str:
    if not isinstance(value, str) or not value:
        raise DependencyStateError(f"{label} must be a non-empty string.")
    if "\x00" in value or "\\" in value or value.startswith("/"):
        raise DependencyStateError(f"Unsafe {label}: {value!r}")
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise DependencyStateError(f"Unsafe {label}: {value!r}")
    normalized = PurePosixPath(*parts).as_posix()
    if normalized != value:
        raise DependencyStateError(f"Non-normalized {label}: {value!r}")
    return normalized


def _is_reparse_point(file_stat: os.stat_result) -> bool:
    attributes = getattr(file_stat, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(attributes & reparse_flag)


def _assert_plain_path(path: Path, *, directory: bool) -> None:
    try:
        file_stat = path.lstat()
    except OSError as error:
        raise DependencyStateError(f"Required dependency path is missing: {path}") from error
    if stat.S_ISLNK(file_stat.st_mode) or _is_reparse_point(file_stat):
        raise DependencyStateError(f"Dependency path cannot be a link or reparse point: {path}")
    if directory and not stat.S_ISDIR(file_stat.st_mode):
        raise DependencyStateError(f"Dependency path is not a directory: {path}")
    if not directory and not stat.S_ISREG(file_stat.st_mode):
        raise DependencyStateError(f"Dependency path is not a regular file: {path}")


def _sanitized_environment() -> dict[str, str]:
    environment = dict(os.environ)
    for name in list(environment):
        upper = name.upper()
        if upper in {
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_COMMON_DIR",
            "GIT_CONFIG_COUNT",
        } or upper.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")):
            environment.pop(name, None)
    environment.update(
        {
            "DEPOT_TOOLS_UPDATE": "0",
            "DEPOT_TOOLS_WIN_TOOLCHAIN": "0",
            "DEPOT_TOOLS_COLLECT_METRICS": "0",
            "DEPOT_TOOLS_METRICS": "0",
            "CIPD_CONFIG_FILE": "-",
            "CIPD_DISABLE_NETWORK": "1",
            "GCLIENT_PY3": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    return environment


def _run_process(
    command: Sequence[str],
    *,
    cwd: Path,
    timeout_seconds: int,
    label: str,
    maximum_stdout_bytes: int = MAX_COMMAND_OUTPUT_BYTES,
) -> bytes:
    if maximum_stdout_bytes < 1 or maximum_stdout_bytes > MAX_GIT_TREE_OUTPUT_BYTES:
        raise DependencyStateError(f"Invalid stdout limit for {label}.")
    try:
        process = subprocess.Popen(
            list(command),
            cwd=str(cwd),
            env=_sanitized_environment(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
        )
    except OSError as error:
        raise DependencyStateError(f"Could not start {label}: {error}") from error
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as error:
        if os.name == "nt":
            try:
                subprocess.run(
                    ["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=15,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                process.kill()
        else:
            process.kill()
        try:
            process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
        raise DependencyStateError(
            f"{label} timed out after {timeout_seconds} seconds."
        ) from error
    if len(stdout) > maximum_stdout_bytes or len(stderr) > MAX_COMMAND_OUTPUT_BYTES:
        raise DependencyStateError(f"{label} exceeded its bounded output limit.")
    if process.returncode != 0:
        detail = stderr.decode("utf-8", errors="replace").strip()
        raise DependencyStateError(
            f"{label} failed with exit code {process.returncode}: {detail}"
        )
    return stdout


def _run_git(
    repository: Path,
    arguments: Sequence[str],
    *,
    timeout_seconds: int,
    label: str,
    maximum_stdout_bytes: int = MAX_COMMAND_OUTPUT_BYTES,
) -> bytes:
    command = [
        "git",
        "-c",
        f"core.excludesFile={os.devnull}",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.untrackedCache=false",
        "-c",
        "status.showUntrackedFiles=all",
        "-C",
        str(repository),
        *arguments,
    ]
    return _run_process(
        command,
        cwd=repository,
        timeout_seconds=timeout_seconds,
        label=label,
        maximum_stdout_bytes=maximum_stdout_bytes,
    )


def _load_revinfo_output(data: bytes, label: str) -> dict[str, dict[str, Any]]:
    value = _load_json_bytes(data, label)
    if not isinstance(value, dict) or not value:
        raise DependencyStateError(f"{label} must be a non-empty JSON object.")
    result: dict[str, dict[str, Any]] = {}
    for path, record in value.items():
        path = _normalized_relative_path(path, "gclient dependency key")
        if not isinstance(record, dict) or set(record) != {"url", "rev"}:
            raise DependencyStateError(f"Malformed {label} record for {path!r}.")
        url = record["url"]
        revision = record["rev"]
        if url is not None and (not isinstance(url, str) or not url):
            raise DependencyStateError(f"Malformed gclient URL for {path!r}.")
        if revision is not None and (not isinstance(revision, str) or not revision):
            raise DependencyStateError(f"Malformed gclient revision for {path!r}.")
        result[path] = {"url": url, "rev": revision}
    return result


def _encode_cipd_probe_revision(version: str) -> str:
    if not version or any(character in version for character in "\x00\r\n"):
        raise DependencyStateError("CIPD declaration probe received an invalid version.")
    encoded = base64.urlsafe_b64encode(version.encode("utf-8")).decode("ascii")
    return CIPD_PROBE_REVISION_PREFIX + encoded.rstrip("=")


def _decode_cipd_probe_revision(revision: Any, path: str) -> str:
    if not isinstance(revision, str) or not revision.startswith(
        CIPD_PROBE_REVISION_PREFIX
    ):
        raise DependencyStateError(
            f"CIPD declaration probe did not preserve the complete version for {path}."
        )
    encoded = revision[len(CIPD_PROBE_REVISION_PREFIX) :]
    try:
        padding = "=" * (-len(encoded) % 4)
        version = base64.b64decode(
            (encoded + padding).encode("ascii"), altchars=b"-_", validate=True
        ).decode("utf-8")
    except (UnicodeError, ValueError) as error:
        raise DependencyStateError(
            f"CIPD declaration probe returned a malformed version for {path}."
        ) from error
    if not version or any(character in version for character in "\x00\r\n"):
        raise DependencyStateError(
            f"CIPD declaration probe returned an invalid version for {path}."
        )
    return version


def _pinned_vpython_command(
    depot_tools_root: Path, script: Path, arguments: Sequence[str]
) -> list[str]:
    specification = depot_tools_root / ".vpython3"
    _assert_plain_path(specification, directory=False)
    if os.name == "nt":
        executable = depot_tools_root / ".cipd_bin" / "vpython3.exe"
    else:
        executable = depot_tools_root / "vpython3"
    _assert_plain_path(executable, directory=False)
    return [
        str(executable),
        "-vpython-spec",
        str(specification),
        str(script),
        *arguments,
    ]


def _invoke_gclient_revinfo(
    checkout_root: Path,
    depot_tools_root: Path,
    *,
    actual: bool,
    jobs: int,
    timeout_seconds: int,
) -> dict[str, dict[str, Any]]:
    gclient_path = depot_tools_root / "gclient.py"
    _assert_plain_path(gclient_path, directory=False)
    command = _pinned_vpython_command(
        depot_tools_root,
        gclient_path,
        [
            "revinfo",
            "--deps=win",
            "--output-json=-",
            "-j",
            str(jobs),
            "--ignore-dep-type=cipd",
            "--ignore-dep-type=gcs",
        ],
    )
    if actual:
        command.append("--actual")
    output = _run_process(
        command,
        cwd=checkout_root,
        timeout_seconds=timeout_seconds,
        label="gclient revinfo --actual" if actual else "gclient revinfo",
    )
    return _load_revinfo_output(
        output, "actual gclient revinfo" if actual else "expected gclient revinfo"
    )


def _gclient_declarations_main(arguments: Sequence[str]) -> int:
    """Run pinned gclient with GCS cleanup disabled and enriched GCS revisions."""
    if len(arguments) != 2:
        raise DependencyStateError("Malformed internal gclient declaration probe invocation.")
    depot_tools_root = Path(arguments[0]).absolute()
    jobs = int(arguments[1])
    sys.path.insert(0, str(depot_tools_root))
    try:
        import gclient  # type: ignore[import-not-found]
    except ImportError as error:
        raise DependencyStateError(f"Could not import pinned gclient: {error}") from error

    original_gcs_init = gclient.GcsDependency.__init__
    original_cipd_run = gclient.CipdDependency.run

    def enriched_gcs_init(dependency: Any, *args: Any, **kwargs: Any) -> None:
        original_gcs_init(dependency, *args, **kwargs)
        payload = {
            "outputFile": dependency.output_file,
            "sha256": dependency.sha256sum,
            "sizeBytes": dependency.size_bytes,
        }
        encoded = base64.urlsafe_b64encode(
            json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
        ).decode("ascii").rstrip("=")
        dependency.set_url(f"{dependency.url}@{GCS_PROBE_REVISION_PREFIX}{encoded}")

    def enriched_cipd_run(dependency: Any, *args: Any, **kwargs: Any) -> Any:
        result = original_cipd_run(dependency, *args, **kwargs)
        package_url, separator, version = dependency.url.partition("@")
        if not separator or not version:
            raise DependencyStateError(
                f"Pinned gclient returned a malformed CIPD URL for {dependency.name}."
            )
        dependency.set_url(
            f"{package_url}@{_encode_cipd_probe_revision(version)}"
        )
        return result

    # ParseDepsFile otherwise calls IsDownloadNeeded and can remove an installed
    # GCS output directory even for revinfo. The exact depot_tools revision is
    # validated before this pinned private-API probe is launched.
    gclient.GcsDependency.__init__ = enriched_gcs_init
    gclient.GcsDependency.IsDownloadNeeded = lambda dependency: False
    # Pinned gclient's JSON revinfo splits URLs on every '@' and therefore
    # truncates CIPD versions such as "version:3@resolved-tag". Encode the
    # complete revision after gclient has processed the package and decode it
    # in the parent process before comparing it with .gclient_entries.
    gclient.CipdDependency.run = enriched_cipd_run
    return int(
        gclient.main(
            [
                "revinfo",
                "--deps=win",
                "--output-json=-",
                "-j",
                str(jobs),
            ]
        )
        or 0
    )


def _invoke_gclient_declarations(
    checkout_root: Path,
    depot_tools_root: Path,
    *,
    jobs: int,
    timeout_seconds: int,
) -> dict[str, dict[str, Any]]:
    output = _run_process(
        _pinned_vpython_command(
            depot_tools_root,
            Path(__file__).resolve(),
            [
                "__gclient-declarations",
                str(depot_tools_root),
                str(jobs),
            ],
        ),
        cwd=checkout_root,
        timeout_seconds=timeout_seconds,
        label="pinned gclient dependency declaration probe",
    )
    declarations = _load_revinfo_output(
        output, "gclient dependency declaration probe"
    )
    for path, record in declarations.items():
        if str(record.get("url", "")).startswith(f"{CIPD_SERVICE}/"):
            record["rev"] = _decode_cipd_probe_revision(record.get("rev"), path)
    return declarations


def _parse_gcs_declaration(
    record: Mapping[str, Any], path: str
) -> dict[str, Any]:
    url = record.get("url")
    revision = record.get("rev")
    if not isinstance(url, str) or not url.startswith("gs://"):
        raise DependencyStateError(f"GCS declaration URL is malformed for {path}.")
    if not isinstance(revision, str) or not revision.startswith(
        GCS_PROBE_REVISION_PREFIX
    ):
        raise DependencyStateError(f"GCS declaration metadata is missing for {path}.")
    encoded = revision[len(GCS_PROBE_REVISION_PREFIX) :]
    try:
        padding = "=" * (-len(encoded) % 4)
        payload = _load_json_bytes(
            base64.urlsafe_b64decode((encoded + padding).encode("ascii")),
            f"GCS declaration metadata for {path}",
        )
    except (UnicodeError, ValueError) as error:
        raise DependencyStateError(
            f"GCS declaration metadata is malformed for {path}: {error}"
        ) from error
    if not isinstance(payload, dict) or set(payload) != {
        "outputFile",
        "sha256",
        "sizeBytes",
    }:
        raise DependencyStateError(f"GCS declaration metadata is malformed for {path}.")
    output_file = payload["outputFile"]
    sha256 = payload["sha256"]
    size_bytes = payload["sizeBytes"]
    if output_file is not None and (
        not isinstance(output_file, str)
        or not output_file
        or "/" in output_file
        or "\\" in output_file
        or output_file in {".", ".."}
    ):
        raise DependencyStateError(f"GCS output filename is unsafe for {path}.")
    if not isinstance(sha256, str) or not SHA256_PATTERN.fullmatch(sha256):
        raise DependencyStateError(f"GCS SHA-256 is malformed for {path}.")
    if not isinstance(size_bytes, int) or isinstance(size_bytes, bool) or size_bytes < 0:
        raise DependencyStateError(f"GCS size is malformed for {path}.")
    return {
        "outputFile": output_file,
        "sha256": sha256,
        "sizeBytes": size_bytes,
        "url": url,
    }


def _dependency_type(record: Mapping[str, Any], path: str) -> str:
    url = record.get("url")
    revision = record.get("rev")
    if not isinstance(url, str) or not url:
        raise DependencyStateError(f"gclient dependency has no URL: {path}")
    if url.startswith("gs://"):
        if revision is not None:
            raise DependencyStateError(f"GCS dependency unexpectedly has a revision: {path}")
        return "gcs"
    if url.startswith(f"{CIPD_SERVICE}/"):
        if not isinstance(revision, str) or not revision:
            raise DependencyStateError(f"CIPD dependency has no declared version: {path}")
        return "cipd"
    if isinstance(revision, str) and REVISION_PATTERN.fullmatch(revision):
        return "git"
    raise DependencyStateError(
        f"Unsupported or unpinned gclient dependency declaration for {path}: {url}@{revision}"
    )


def _split_non_git_key(path: str) -> tuple[str, str]:
    dependency_path, separator, name = path.partition(":")
    if not separator or not name:
        raise DependencyStateError(f"Non-Git dependency key is malformed: {path!r}")
    return _normalized_relative_path(dependency_path), name


def _expected_spec(record: Mapping[str, Any]) -> str:
    url = record["url"]
    revision = record["rev"]
    return url if revision is None else f"{url}@{revision}"


def _load_gclient_entries(checkout_root: Path) -> dict[str, str]:
    path = checkout_root / ".gclient_entries"
    _assert_plain_path(path, directory=False)
    try:
        text = _read_limited(path).decode("utf-8")
    except UnicodeError as error:
        raise DependencyStateError(f"Could not decode {path}: {error}") from error
    prefix, separator, expression = text.partition("=")
    if not separator or prefix.strip() != "entries":
        raise DependencyStateError(f"Malformed gclient entries metadata: {path}")
    try:
        value = ast.literal_eval(expression.strip())
    except (SyntaxError, ValueError) as error:
        raise DependencyStateError(f"Could not parse {path}: {error}") from error
    if not isinstance(value, dict):
        raise DependencyStateError(f"gclient entries metadata is not a dictionary: {path}")
    entries: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not isinstance(item, str):
            raise DependencyStateError(f"gclient entries metadata contains non-string data: {path}")
        entries[key] = item
    return entries


def _validate_sync_entry(
    path: str, record: Mapping[str, Any], gclient_entries: Mapping[str, str]
) -> None:
    actual = gclient_entries.get(path)
    expected = record["url"] if str(record.get("url", "")).startswith("gs://") else _expected_spec(record)
    if path == "src" and actual == record["url"]:
        return
    if actual != expected:
        raise DependencyStateError(
            f".gclient_entries does not match the active DEPS declaration for {path}: "
            f"expected {expected!r}, found {actual!r}"
        )


def _source_delta_sha256(
    repository: Path, expected_revision: str, *, timeout_seconds: int
) -> str:
    names = _run_git(
        repository,
        [
            "-c",
            "color.ui=false",
            "diff",
            "--name-only",
            "-z",
            "--no-ext-diff",
            "--no-textconv",
            "--no-renames",
            "--ignore-submodules=all",
            expected_revision,
            "--",
            ".",
        ],
        timeout_seconds=timeout_seconds,
        label=f"source delta listing for {repository}",
    )
    raw_paths = [item for item in names.split(b"\0") if item]
    try:
        paths = sorted(item.decode("utf-8") for item in raw_paths)
    except UnicodeError as error:
        raise DependencyStateError(
            f"Git returned a non-UTF-8 path in {repository}: {error}"
        ) from error
    digest = hashlib.sha256()
    for relative in paths:
        relative = _normalized_relative_path(relative, "modified source path")
        file_path = repository.joinpath(*relative.split("/"))
        if os.path.lexists(file_path):
            _assert_plain_path(file_path, directory=False)
            file_digest = hashlib.sha256()
            size = 0
            with file_path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    file_digest.update(chunk)
                    size += len(chunk)
            record = f"{relative}\0{size}\0{file_digest.hexdigest()}\n"
        else:
            record = f"{relative}\0deleted\n"
        digest.update(record.encode("utf-8"))
    return digest.hexdigest()


def _parse_zero_paths(data: bytes, label: str) -> list[str]:
    try:
        return [
            _normalized_relative_path(item.decode("utf-8").rstrip("/"), label)
            for item in data.split(b"\0")
            if item
        ]
    except UnicodeError as error:
        raise DependencyStateError(f"Git returned a non-UTF-8 {label}: {error}") from error


def _allowed_nested_paths(repository_path: str, dependency_paths: Iterable[str]) -> list[str]:
    prefix = f"{repository_path}/"
    nested = []
    for candidate in dependency_paths:
        if candidate.startswith(prefix):
            nested.append(candidate[len(prefix) :])
    return sorted(nested)


def _is_declared_nested_path(path: str, nested_paths: Sequence[str]) -> bool:
    return any(path == nested or path.startswith(f"{nested}/") for nested in nested_paths)


def _gitlinks_from_index(
    repository: Path, *, timeout_seconds: int
) -> dict[str, str]:
    output = _run_git(
        repository,
        ["ls-files", "--stage", "-z"],
        timeout_seconds=timeout_seconds,
        label=f"Git index listing for {repository}",
        maximum_stdout_bytes=MAX_GIT_TREE_OUTPUT_BYTES,
    )
    result: dict[str, str] = {}
    for raw in output.split(b"\0"):
        if not raw:
            continue
        metadata, separator, raw_path = raw.partition(b"\t")
        fields = metadata.split()
        if not separator or len(fields) != 3:
            raise DependencyStateError(f"Malformed Git index record in {repository}.")
        mode, object_id, stage = fields
        if stage != b"0":
            raise DependencyStateError(f"Unmerged Git index entry in {repository}.")
        if mode == b"160000":
            try:
                path = _normalized_relative_path(raw_path.decode("utf-8"), "submodule path")
                revision = object_id.decode("ascii")
            except UnicodeError as error:
                raise DependencyStateError(f"Malformed submodule entry in {repository}.") from error
            if not REVISION_PATTERN.fullmatch(revision):
                raise DependencyStateError(f"Malformed submodule revision in {repository}: {revision}")
            result[path] = revision
    return result


def _gitlinks_from_head(
    repository: Path, *, timeout_seconds: int
) -> dict[str, str]:
    output = _run_git(
        repository,
        ["ls-tree", "-rz", "HEAD"],
        timeout_seconds=timeout_seconds,
        label=f"Git HEAD tree listing for {repository}",
        maximum_stdout_bytes=MAX_GIT_TREE_OUTPUT_BYTES,
    )
    result: dict[str, str] = {}
    for raw in output.split(b"\0"):
        if not raw:
            continue
        metadata, separator, raw_path = raw.partition(b"\t")
        fields = metadata.split()
        if not separator or len(fields) != 3:
            raise DependencyStateError(f"Malformed Git tree record in {repository}.")
        mode, object_type, object_id = fields
        if mode == b"160000":
            if object_type != b"commit":
                raise DependencyStateError(f"Malformed Gitlink in {repository}.")
            try:
                path = _normalized_relative_path(raw_path.decode("utf-8"), "submodule path")
                revision = object_id.decode("ascii")
            except UnicodeError as error:
                raise DependencyStateError(f"Malformed submodule entry in {repository}.") from error
            result[path] = revision
    return result


def _validate_clean_tool_checkout(
    repository: Path, expected_revision: str, *, timeout_seconds: int
) -> None:
    if not REVISION_PATTERN.fullmatch(expected_revision):
        raise DependencyStateError("The pinned depot_tools revision is malformed.")
    _assert_plain_path(repository, directory=True)
    head = _run_git(
        repository,
        ["rev-parse", "--verify", "HEAD^{commit}"],
        timeout_seconds=timeout_seconds,
        label="depot_tools HEAD validation",
    ).decode("ascii", errors="strict").strip()
    if head != expected_revision:
        raise DependencyStateError(
            f"depot_tools revision mismatch: expected {expected_revision}, found {head}"
        )
    tracked = _run_git(
        repository,
        ["status", "--porcelain=v1", "-z", "--untracked-files=no"],
        timeout_seconds=timeout_seconds,
        label="depot_tools tracked status",
    )
    untracked = _run_git(
        repository,
        ["ls-files", "--others", "-z", "--exclude-per-directory=.gitignore"],
        timeout_seconds=timeout_seconds,
        label="depot_tools untracked source listing",
    )
    if tracked or untracked:
        raise DependencyStateError(
            "The pinned depot_tools checkout contains tracked or relevant untracked changes."
        )


def _validate_submodules(
    checkout_root: Path,
    repository: Path,
    repository_path: str,
    *,
    declared_dependency_paths: Sequence[str],
    timeout_seconds: int,
) -> list[dict[str, Any]]:
    index_gitlinks = _gitlinks_from_index(repository, timeout_seconds=timeout_seconds)
    head_gitlinks = _gitlinks_from_head(repository, timeout_seconds=timeout_seconds)
    if index_gitlinks != head_gitlinks:
        raise DependencyStateError(f"Gitlink index differs from HEAD in {repository_path}.")

    entries: list[dict[str, Any]] = []
    for submodule_path, revision in sorted(head_gitlinks.items()):
        full_relative = f"{repository_path}/{submodule_path}"
        submodule = checkout_root.joinpath(*full_relative.split("/"))
        if full_relative not in declared_dependency_paths:
            if not os.path.lexists(submodule):
                continue
            _assert_plain_path(submodule, directory=True)
            try:
                next(submodule.iterdir())
            except StopIteration:
                continue
            raise DependencyStateError(
                f"Inactive Git submodule contains undeclared content: {full_relative}"
            )
        _assert_plain_path(submodule, directory=True)
        submodule_head = _run_git(
            submodule,
            ["rev-parse", "--verify", "HEAD^{commit}"],
            timeout_seconds=timeout_seconds,
            label=f"Git submodule HEAD for {full_relative}",
        ).decode("ascii", errors="strict").strip()
        if submodule_head != revision:
            raise DependencyStateError(
                f"Git submodule revision mismatch for {full_relative}: "
                f"expected {revision}, found {submodule_head}"
            )
        tracked_status = _run_git(
            submodule,
            [
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=no",
                "--ignore-submodules=none",
            ],
            timeout_seconds=timeout_seconds,
            label=f"Git submodule tracked status for {full_relative}",
        )
        if tracked_status:
            raise DependencyStateError(f"Git submodule has tracked changes: {full_relative}")
        untracked = _parse_zero_paths(
            _run_git(
                submodule,
                ["ls-files", "--others", "-z", "--exclude-per-directory=.gitignore"],
                timeout_seconds=timeout_seconds,
                label=f"Git submodule untracked listing for {full_relative}",
            ),
            "untracked submodule path",
        )
        nested_paths = _allowed_nested_paths(full_relative, declared_dependency_paths)
        unexpected_untracked = [
            path for path in untracked if not _is_declared_nested_path(path, nested_paths)
        ]
        if unexpected_untracked:
            raise DependencyStateError(
                f"Git submodule has relevant untracked files {full_relative}: "
                f"{unexpected_untracked[:20]}"
            )
        entries.append(
            {
                "parent": repository_path,
                "path": full_relative,
                "revision": revision,
                "type": "git-submodule",
                "workingTreeSha256": EMPTY_SHA256,
            }
        )
    return entries


def _validate_git_worktree(
    checkout_root: Path,
    repository_path: str,
    expected_revision: str,
    *,
    declared_dependency_paths: Sequence[str],
    allowed_source_delta_sha256: str | None,
    timeout_seconds: int,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    repository = checkout_root.joinpath(*repository_path.split("/"))
    _assert_plain_path(repository, directory=True)
    top_level = _run_git(
        repository,
        ["rev-parse", "--show-toplevel"],
        timeout_seconds=timeout_seconds,
        label=f"Git worktree root for {repository_path}",
    ).decode("utf-8", errors="strict").strip()
    if os.path.normcase(os.path.abspath(top_level)) != os.path.normcase(
        os.path.abspath(repository)
    ):
        raise DependencyStateError(
            f"gclient dependency does not own its declared worktree root: {repository_path}"
        )
    head = _run_git(
        repository,
        ["rev-parse", "--verify", "HEAD^{commit}"],
        timeout_seconds=timeout_seconds,
        label=f"Git HEAD for {repository_path}",
    ).decode("ascii", errors="strict").strip()
    if head != expected_revision:
        raise DependencyStateError(
            f"Git dependency revision mismatch for {repository_path}: "
            f"expected {expected_revision}, found {head}"
        )

    tracked_status = _run_git(
        repository,
        [
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=no",
            "--ignore-submodules=none",
        ],
        timeout_seconds=timeout_seconds,
        label=f"tracked Git status for {repository_path}",
    )
    if allowed_source_delta_sha256 is None:
        if tracked_status:
            raise DependencyStateError(
                f"Tracked modifications are not allowed in gclient dependency {repository_path}."
            )
        working_tree_hash = EMPTY_SHA256
    else:
        working_tree_hash = _source_delta_sha256(
            repository, expected_revision, timeout_seconds=timeout_seconds
        )
        if working_tree_hash != allowed_source_delta_sha256:
            raise DependencyStateError(
                f"Declared Chromium source delta mismatch for {repository_path}: "
                f"expected {allowed_source_delta_sha256}, found {working_tree_hash}"
            )

    untracked = _parse_zero_paths(
        _run_git(
            repository,
            ["ls-files", "--others", "-z", "--exclude-per-directory=.gitignore"],
            timeout_seconds=timeout_seconds,
            label=f"untracked source listing for {repository_path}",
        ),
        "untracked source path",
    )
    nested_paths = _allowed_nested_paths(repository_path, declared_dependency_paths)
    unexpected_untracked = [
        path for path in untracked if not _is_declared_nested_path(path, nested_paths)
    ]
    if unexpected_untracked:
        raise DependencyStateError(
            f"Relevant untracked source inputs are not allowed in {repository_path}: "
            f"{unexpected_untracked[:20]}"
        )

    git_entry = {
        "path": repository_path,
        "revision": expected_revision,
        "type": "git",
        "workingTreeSha256": working_tree_hash,
    }
    submodule_entries = _validate_submodules(
        checkout_root,
        repository,
        repository_path,
        declared_dependency_paths=declared_dependency_paths,
        timeout_seconds=timeout_seconds,
    )
    return git_entry, submodule_entries


def _validate_cipd_deployment(
    checkout_root: Path,
    depot_tools_root: Path,
    *,
    timeout_seconds: int,
) -> None:
    executable = depot_tools_root / (
        ".cipd_client.exe" if os.name == "nt" else ".cipd_client"
    )
    _assert_plain_path(executable, directory=False)
    _run_process(
        [
            str(executable),
            "deployment-check",
            "-disable-network",
            "-log-level",
            "error",
            "-root",
            str(checkout_root),
        ],
        cwd=checkout_root,
        timeout_seconds=timeout_seconds,
        label="offline CIPD deployment content check",
    )


def _cipd_manifest_tree_sha256(manifest: Mapping[str, Any], label: str) -> str:
    files = manifest.get("files")
    if not isinstance(files, list):
        raise DependencyStateError(f"CIPD manifest has no file list: {label}")
    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in files:
        if not isinstance(item, dict):
            raise DependencyStateError(f"Malformed CIPD file record: {label}")
        name = _normalized_relative_path(item.get("name"), "CIPD package file")
        size = item.get("size")
        digest = item.get("hash")
        if name in seen:
            raise DependencyStateError(f"Duplicate CIPD package file {name!r}: {label}")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise DependencyStateError(f"Malformed CIPD file size for {name!r}: {label}")
        if not isinstance(digest, str) or not CIPD_INSTANCE_PATTERN.fullmatch(digest):
            raise DependencyStateError(f"Malformed CIPD file hash for {name!r}: {label}")
        seen.add(name)
        records.append({"hash": digest, "path": name, "sizeBytes": size})
    records.sort(key=lambda record: record["path"])
    return hashlib.sha256(
        json.dumps(records, separators=(",", ":"), sort_keys=True).encode("utf-8")
        + b"\n"
    ).hexdigest()


def _load_cipd_installations(checkout_root: Path) -> list[dict[str, Any]]:
    packages_root = checkout_root / ".cipd" / "pkgs"
    _assert_plain_path(packages_root, directory=True)
    installations: list[dict[str, Any]] = []
    for slot in sorted(packages_root.iterdir(), key=lambda item: item.name):
        if not slot.is_dir() or not slot.name.isdigit():
            continue
        description_path = slot / "description.json"
        current_path = slot / "_current.txt"
        _assert_plain_path(description_path, directory=False)
        _assert_plain_path(current_path, directory=False)
        description = _load_json_bytes(
            _read_limited(description_path, 64 * 1024), str(description_path)
        )
        if not isinstance(description, dict):
            raise DependencyStateError(f"Malformed CIPD description: {description_path}")
        subdir = description.get("subdir")
        package = description.get("package_name")
        if not isinstance(subdir, str) or not isinstance(package, str):
            raise DependencyStateError(f"Malformed CIPD description: {description_path}")
        subdir = _normalized_relative_path(subdir, "CIPD installation path")
        try:
            instance_id = _read_limited(current_path, 256).decode("ascii").strip()
        except UnicodeError as error:
            raise DependencyStateError(f"Malformed CIPD current pin: {current_path}") from error
        if not CIPD_INSTANCE_PATTERN.fullmatch(instance_id):
            raise DependencyStateError(f"Malformed CIPD current pin: {current_path}")
        manifest_path = slot / instance_id / ".cipdpkg" / "manifest.json"
        _assert_plain_path(manifest_path, directory=False)
        manifest_bytes = _read_limited(manifest_path)
        manifest = _load_json_bytes(manifest_bytes, str(manifest_path))
        if not isinstance(manifest, dict) or manifest.get("package_name") != package:
            raise DependencyStateError(f"Malformed CIPD package manifest: {manifest_path}")
        installations.append(
            {
                "instanceId": instance_id,
                "package": package,
                "packageFileTreeSha256": _cipd_manifest_tree_sha256(
                    manifest, str(manifest_path)
                ),
                "packageManifestSha256": hashlib.sha256(manifest_bytes).hexdigest(),
                "path": subdir,
            }
        )
    return installations


def _cipd_package_matches(declared_package: str, installed_package: str) -> bool:
    pieces = re.split(r"(\$\{[A-Za-z0-9_]+\})", declared_package)
    pattern = "".join(
        r"[^/]+" if piece.startswith("${") else re.escape(piece)
        for piece in pieces
    )
    return re.fullmatch(pattern, installed_package) is not None


def _load_gcs_metadata(checkout_root: Path) -> set[tuple[str, str]]:
    path = checkout_root / ".gcs_entries"
    _assert_plain_path(path, directory=False)
    value = _load_json_bytes(_read_limited(path), str(path))
    if not isinstance(value, dict):
        raise DependencyStateError(f"Malformed GCS metadata: {path}")
    entries: set[tuple[str, str]] = set()
    for owner, paths in value.items():
        if not isinstance(owner, str) or not isinstance(paths, dict):
            raise DependencyStateError(f"Malformed GCS metadata: {path}")
        for dependency_path, objects in paths.items():
            dependency_path = _normalized_relative_path(
                dependency_path, "GCS dependency path"
            )
            if not isinstance(objects, list) or not all(
                isinstance(item, str) and item for item in objects
            ):
                raise DependencyStateError(f"Malformed GCS metadata: {path}")
            entries.update((dependency_path, item) for item in objects)
    return entries


def _check_deadline(deadline: float, label: str) -> None:
    if time.monotonic() > deadline:
        raise DependencyStateError(f"{label} exceeded the dependency content time limit.")


def _hash_stream(
    stream: BinaryIO,
    *,
    deadline: float,
    label: str,
) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    while True:
        _check_deadline(deadline, label)
        chunk = stream.read(1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        size += len(chunk)
    return digest.hexdigest(), size


def _hash_regular_file(
    path: Path,
    *,
    deadline: float,
    label: str,
    expected_size: int | None = None,
) -> tuple[str, int]:
    _assert_plain_path(path, directory=False)
    try:
        with path.open("rb") as stream:
            digest, size = _hash_stream(stream, deadline=deadline, label=label)
    except OSError as error:
        raise DependencyStateError(f"Could not hash {label} {path}: {error}") from error
    if expected_size is not None and size != expected_size:
        raise DependencyStateError(
            f"{label} has the wrong size: expected {expected_size}, found {size}: {path}"
        )
    return digest, size


def _archive_member_name(value: str, label: str) -> str | None:
    if (
        not isinstance(value, str)
        or not value
        or "\\" in value
        or "\x00" in value
        or value.startswith("/")
        or re.match(r"^[A-Za-z]:", value)
    ):
        raise DependencyStateError(f"Unsafe {label}: {value!r}")
    value = value.rstrip("/")
    normalized_parts: list[str] = []
    for part in value.split("/"):
        if part == ".":
            continue
        if part in {"", ".."}:
            raise DependencyStateError(f"Unsafe {label}: {value!r}")
        normalized_parts.append(part)
    if not normalized_parts:
        return None
    return _normalized_relative_path("/".join(normalized_parts), label)


def _installed_tree_sha256(records: Sequence[Mapping[str, Any]]) -> str:
    encoded = json.dumps(
        sorted(records, key=lambda record: (str(record["path"]), str(record["type"]))),
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded + b"\n").hexdigest()


def _verify_tar_installation(
    artifact: Path,
    output_directory: Path,
    content_names_path: Path,
    *,
    deadline: float,
    label: str,
) -> tuple[str, str]:
    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    try:
        with tarfile.open(artifact, "r:*") as archive:
            members = archive.getmembers()
            expected_names = archive.getnames()
            content_names_bytes = _read_limited(content_names_path)
            content_names = _load_json_bytes(content_names_bytes, str(content_names_path))
            if content_names != expected_names:
                raise DependencyStateError(
                    f"GCS extracted-content metadata differs from the retained artifact: {label}"
                )
            for member in members:
                _check_deadline(deadline, label)
                relative = _archive_member_name(member.name, "GCS tar member")
                if relative is None:
                    continue
                if relative in seen:
                    raise DependencyStateError(f"Duplicate GCS tar member {relative!r}: {label}")
                seen.add(relative)
                installed = output_directory.joinpath(*relative.split("/"))
                if member.isdir():
                    _assert_plain_path(installed, directory=True)
                    records.append({"path": relative, "type": "directory"})
                    continue
                if member.issym():
                    try:
                        file_stat = installed.lstat()
                    except OSError as error:
                        raise DependencyStateError(
                            f"GCS symlink is missing for {relative}: {error}"
                        ) from error
                    if not (stat.S_ISLNK(file_stat.st_mode) or _is_reparse_point(file_stat)):
                        raise DependencyStateError(f"GCS symlink was replaced: {relative}")
                    target = os.readlink(installed)
                    if target != member.linkname:
                        raise DependencyStateError(f"GCS symlink target differs: {relative}")
                    records.append(
                        {"path": relative, "target": target, "type": "symlink"}
                    )
                    continue
                if not (member.isfile() or member.islnk()):
                    raise DependencyStateError(
                        f"Unsupported GCS tar member type for {relative}: {label}"
                    )
                installed_hash, installed_size = _hash_regular_file(
                    installed,
                    deadline=deadline,
                    label=f"installed GCS member {relative}",
                    expected_size=member.size,
                )
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise DependencyStateError(f"Could not read GCS tar member {relative}.")
                with extracted:
                    archive_hash, archive_size = _hash_stream(
                        extracted, deadline=deadline, label=f"GCS tar member {relative}"
                    )
                if archive_size != installed_size or archive_hash != installed_hash:
                    raise DependencyStateError(
                        f"Installed GCS tar member differs from the retained artifact: {relative}"
                    )
                records.append(
                    {
                        "path": relative,
                        "sha256": installed_hash,
                        "sizeBytes": installed_size,
                        "type": "file",
                    }
                )
    except (tarfile.TarError, OSError) as error:
        raise DependencyStateError(f"Could not verify GCS tar artifact {label}: {error}") from error
    return _installed_tree_sha256(records), hashlib.sha256(content_names_bytes).hexdigest()


def _verify_zip_installation(
    artifact: Path,
    output_directory: Path,
    content_names_path: Path,
    *,
    deadline: float,
    label: str,
) -> tuple[str, str]:
    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    try:
        with zipfile.ZipFile(artifact) as archive:
            infos = archive.infolist()
            expected_names = archive.namelist()
            content_names_bytes = _read_limited(content_names_path)
            content_names = _load_json_bytes(content_names_bytes, str(content_names_path))
            if content_names != expected_names:
                raise DependencyStateError(
                    f"GCS extracted-content metadata differs from the retained artifact: {label}"
                )
            for info in infos:
                _check_deadline(deadline, label)
                relative = _archive_member_name(info.filename, "GCS zip member")
                if relative is None:
                    continue
                if relative in seen:
                    raise DependencyStateError(f"Duplicate GCS zip member {relative!r}: {label}")
                seen.add(relative)
                installed = output_directory.joinpath(*relative.split("/"))
                if info.is_dir():
                    _assert_plain_path(installed, directory=True)
                    records.append({"path": relative, "type": "directory"})
                    continue
                installed_hash, installed_size = _hash_regular_file(
                    installed,
                    deadline=deadline,
                    label=f"installed GCS member {relative}",
                    expected_size=info.file_size,
                )
                with archive.open(info, "r") as archived:
                    archive_hash, archive_size = _hash_stream(
                        archived, deadline=deadline, label=f"GCS zip member {relative}"
                    )
                if archive_size != installed_size or archive_hash != installed_hash:
                    raise DependencyStateError(
                        f"Installed GCS zip member differs from the retained artifact: {relative}"
                    )
                records.append(
                    {
                        "path": relative,
                        "sha256": installed_hash,
                        "sizeBytes": installed_size,
                        "type": "file",
                    }
                )
    except (zipfile.BadZipFile, OSError) as error:
        raise DependencyStateError(f"Could not verify GCS zip artifact {label}: {error}") from error
    return _installed_tree_sha256(records), hashlib.sha256(content_names_bytes).hexdigest()


def _verify_gcs_object(
    checkout_root: Path,
    dependency_path: str,
    object_name: str,
    declaration: Mapping[str, Any],
    *,
    deadline: float,
) -> dict[str, Any]:
    output_directory = checkout_root.joinpath(*dependency_path.split("/"))
    _assert_plain_path(output_directory, directory=True)
    gcs_file_name = object_name.replace("/", "_")
    prefix = gcs_file_name.replace(".", "_")
    output_file = declaration["outputFile"]
    artifact = output_directory / (output_file or f".{gcs_file_name}")
    label = f"{dependency_path}:{object_name}"
    artifact_hash, artifact_size = _hash_regular_file(
        artifact,
        deadline=deadline,
        label=f"GCS artifact {label}",
        expected_size=declaration["sizeBytes"],
    )
    if artifact_hash != declaration["sha256"]:
        raise DependencyStateError(
            f"GCS artifact SHA-256 differs from the active DEPS declaration: {label}"
        )

    hash_marker = output_directory / f".{prefix}_hash"
    migration_marker = output_directory / f".{prefix}_is_first_class_gcs"
    try:
        marker_hash = _read_limited(hash_marker, 256).decode("ascii").strip()
        migration_value = _read_limited(migration_marker, 64).decode("ascii").strip()
    except UnicodeError as error:
        raise DependencyStateError(f"Malformed GCS sync marker for {label}.") from error
    if marker_hash != declaration["sha256"] or migration_value != "1":
        raise DependencyStateError(f"GCS sync markers differ from DEPS for {label}.")

    content_names_sha256: str | None = None
    if tarfile.is_tarfile(artifact):
        installed_tree, content_names_sha256 = _verify_tar_installation(
            artifact,
            output_directory,
            output_directory / f".{prefix}_content_names",
            deadline=deadline,
            label=label,
        )
    elif zipfile.is_zipfile(artifact):
        installed_tree, content_names_sha256 = _verify_zip_installation(
            artifact,
            output_directory,
            output_directory / f".{prefix}_content_names",
            deadline=deadline,
            label=label,
        )
    else:
        installed_tree = _installed_tree_sha256(
            [
                {
                    "path": output_file or f".{gcs_file_name}",
                    "sha256": artifact_hash,
                    "sizeBytes": artifact_size,
                    "type": "file",
                }
            ]
        )
    return {
        "artifactSha256": artifact_hash,
        "contentNamesSha256": content_names_sha256,
        "installedTreeSha256": installed_tree,
    }


def _entry_sort_key(entry: Mapping[str, Any]) -> tuple[str, str, str, str]:
    return (
        str(entry.get("type", "")),
        str(entry.get("path", "")),
        str(entry.get("package", entry.get("object", ""))),
        str(entry.get("revision", entry.get("instanceId", ""))),
    )


def _duplicate_entry_identities(
    entries: Sequence[Mapping[str, Any]],
) -> list[tuple[str, str, str]]:
    seen: set[tuple[str, str, str]] = set()
    duplicates: set[tuple[str, str, str]] = set()
    for entry in entries:
        identity = (
            str(entry.get("type", "")),
            str(entry.get("path", "")),
            str(entry.get("package", entry.get("object", ""))),
        )
        if identity in seen:
            duplicates.add(identity)
        else:
            seen.add(identity)
    return sorted(duplicates)


def dependency_tree_sha256(entries: Sequence[Mapping[str, Any]]) -> str:
    encoded = json.dumps(
        list(entries), ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    return hashlib.sha256(encoded + b"\n").hexdigest()


def collect_dependency_state(
    checkout_root: Path,
    expected_revinfo: Mapping[str, Mapping[str, Any]],
    actual_revinfo: Mapping[str, Mapping[str, Any]],
    dependency_declarations: Mapping[str, Mapping[str, Any]],
    *,
    cipd_deployment_verified: bool,
    source_delta_sha256: str,
    command_timeout_seconds: int,
) -> dict[str, Any]:
    checkout_root = checkout_root.absolute()
    _assert_plain_path(checkout_root, directory=True)
    if not SHA256_PATTERN.fullmatch(source_delta_sha256):
        raise DependencyStateError("The expected Chromium source delta is malformed.")
    if "src" not in expected_revinfo:
        raise DependencyStateError("gclient dependency graph does not contain the src solution.")

    if any(_dependency_type(record, path) != "git" for path, record in expected_revinfo.items()):
        raise DependencyStateError("Git-only gclient revinfo contains a non-Git dependency.")
    if set(actual_revinfo) != set(expected_revinfo):
        missing = sorted(set(expected_revinfo) - set(actual_revinfo))
        unexpected = sorted(set(actual_revinfo) - set(expected_revinfo))
        raise DependencyStateError(
            f"Actual Git dependency graph differs from declarations "
            f"(missing={missing}, unexpected={unexpected})."
        )

    probe_git: dict[str, Mapping[str, Any]] = {}
    non_git: dict[str, Mapping[str, Any]] = {}
    non_git_kinds: dict[str, str] = {}
    for path, record in dependency_declarations.items():
        url = record.get("url")
        if isinstance(url, str) and url.startswith("gs://"):
            _parse_gcs_declaration(record, path)
            non_git[path] = record
            non_git_kinds[path] = "gcs"
        elif isinstance(url, str) and url.startswith(f"{CIPD_SERVICE}/"):
            if _dependency_type(record, path) != "cipd":
                raise DependencyStateError(f"Malformed CIPD declaration for {path}.")
            non_git[path] = record
            non_git_kinds[path] = "cipd"
        else:
            if _dependency_type(record, path) != "git":
                raise DependencyStateError(f"Unsupported dependency declaration for {path}.")
            probe_git[path] = record
    if probe_git != dict(expected_revinfo):
        raise DependencyStateError(
            "Pinned gclient declaration probe disagrees with Git-only revinfo."
        )

    gclient_entries = _load_gclient_entries(checkout_root)
    all_declarations = {**expected_revinfo, **non_git}
    if set(gclient_entries) != set(all_declarations):
        missing = sorted(set(all_declarations) - set(gclient_entries))
        unexpected = sorted(set(gclient_entries) - set(all_declarations))
        raise DependencyStateError(
            ".gclient_entries differs from the active dependency graph "
            f"(missing={missing}, unexpected={unexpected})."
        )
    for path, record in all_declarations.items():
        _validate_sync_entry(path, record, gclient_entries)

    declared_paths = sorted(
        {
            path for path in expected_revinfo
        }
        | {
            _split_non_git_key(path)[0]
            for path in non_git
        }
    )
    entries: list[dict[str, Any]] = []
    submodules: list[dict[str, Any]] = []
    for path in sorted(expected_revinfo):
        expected = expected_revinfo[path]
        actual = actual_revinfo[path]
        if actual.get("url") != expected.get("url") or actual.get("rev") != expected.get("rev"):
            raise DependencyStateError(
                f"Actual gclient Git pin differs from DEPS for {path}: {actual}"
            )
        git_entry, git_submodules = _validate_git_worktree(
            checkout_root,
            path,
            expected["rev"],
            declared_dependency_paths=declared_paths,
            allowed_source_delta_sha256=(source_delta_sha256 if path == "src" else None),
            timeout_seconds=command_timeout_seconds,
        )
        git_entry["url"] = expected["url"]
        entries.append(git_entry)
        submodules.extend(git_submodules)
    entries.extend(submodules)

    cipd_installations = _load_cipd_installations(checkout_root)
    cipd_paths = sorted(path for path, kind in non_git_kinds.items() if kind == "cipd")
    if cipd_paths and not cipd_deployment_verified:
        raise DependencyStateError("Offline CIPD deployment content verification was not run.")
    matched_cipd_slots: set[tuple[str, str, str]] = set()
    has_mutable_cipd_version = False
    for path in cipd_paths:
        install_path, declared_package = _split_non_git_key(path)
        expected_record = non_git[path]
        expected_url = expected_record["url"]
        url_package = urllib.parse.unquote(expected_url[len(CIPD_SERVICE) + 1 :])
        if url_package != declared_package:
            raise DependencyStateError(f"CIPD key and package URL disagree for {path}.")
        matches = [
            item
            for item in cipd_installations
            if item["path"] == install_path
            and _cipd_package_matches(declared_package, item["package"])
        ]
        if len(matches) != 1:
            raise DependencyStateError(
                f"Installed CIPD metadata does not match the active DEPS package for {path}."
            )
        installation = matches[0]
        instance_id = installation["instanceId"]
        version = expected_record["rev"]
        immutable_version = bool(CIPD_INSTANCE_PATTERN.fullmatch(version))
        if immutable_version and version != instance_id:
            raise DependencyStateError(
                f"Installed CIPD instance differs from immutable DEPS pin for {path}."
            )
        if not immutable_version:
            has_mutable_cipd_version = True
        identity = (installation["path"], installation["package"], instance_id)
        if identity in matched_cipd_slots:
            raise DependencyStateError(f"Multiple DEPS declarations matched CIPD slot {identity}.")
        matched_cipd_slots.add(identity)
        entries.append(
            {
                "declaredPackage": declared_package,
                "instanceId": instance_id,
                "package": installation["package"],
                "packageFileTreeSha256": installation["packageFileTreeSha256"],
                "packageManifestSha256": installation["packageManifestSha256"],
                "path": install_path,
                "type": "cipd",
                "verificationLevel": "cipd-deployment-check-and-package-manifest-sha256",
                "version": version,
                "versionResolution": (
                    "immutable-instance-id"
                    if immutable_version
                    else "declared-version-with-installed-instance-provenance"
                ),
            }
        )
    installed_identities = {
        (item["path"], item["package"], item["instanceId"])
        for item in cipd_installations
    }
    if matched_cipd_slots != installed_identities:
        unexpected = sorted(installed_identities - matched_cipd_slots)
        raise DependencyStateError(f"Unexpected active CIPD installations: {unexpected}")

    gcs_metadata = _load_gcs_metadata(checkout_root)
    gcs_paths = sorted(path for path, kind in non_git_kinds.items() if kind == "gcs")
    content_deadline = time.monotonic() + command_timeout_seconds
    for path in gcs_paths:
        dependency_path, object_name = _split_non_git_key(path)
        if (dependency_path, object_name) not in gcs_metadata:
            raise DependencyStateError(
                f"GCS sync metadata does not contain the active DEPS object {path}."
            )
        declaration = _parse_gcs_declaration(non_git[path], path)
        content = _verify_gcs_object(
            checkout_root,
            dependency_path,
            object_name,
            declaration,
            deadline=content_deadline,
        )
        entries.append(
            {
                "artifactSha256": content["artifactSha256"],
                "contentNamesSha256": content["contentNamesSha256"],
                "expectedSha256": declaration["sha256"],
                "expectedSizeBytes": declaration["sizeBytes"],
                "installedTreeSha256": content["installedTreeSha256"],
                "object": object_name,
                "outputFile": declaration["outputFile"],
                "path": dependency_path,
                "type": "gcs",
                "url": declaration["url"],
                "verificationLevel": "expected-artifact-and-installed-content-sha256",
            }
        )

    entries.sort(key=_entry_sort_key)
    duplicate_identities = _duplicate_entry_identities(entries)
    if duplicate_identities:
        raise DependencyStateError(
            f"Dependency-state entries contain duplicate identities: "
            f"{duplicate_identities}"
        )
    summary = {
        "cipdPackages": sum(entry["type"] == "cipd" for entry in entries),
        "gcsObjects": sum(entry["type"] == "gcs" for entry in entries),
        "gitRepositories": sum(entry["type"] == "git" for entry in entries),
        "gitSubmodules": sum(entry["type"] == "git-submodule" for entry in entries),
    }
    limitations = list(BASE_LIMITATIONS)
    if has_mutable_cipd_version:
        limitations.insert(0, MUTABLE_CIPD_LIMITATION)
    return {
        "entries": entries,
        "limitations": limitations,
        "schemaVersion": SCHEMA_VERSION,
        "summary": summary,
        "treeSha256": dependency_tree_sha256(entries),
    }


def _collect_command(arguments: argparse.Namespace) -> None:
    checkout_root = Path(arguments.checkout_root)
    depot_tools_root = Path(arguments.depot_tools_root)
    _assert_plain_path(depot_tools_root, directory=True)
    _validate_clean_tool_checkout(
        depot_tools_root,
        arguments.depot_tools_revision,
        timeout_seconds=arguments.command_timeout_seconds,
    )
    expected = _invoke_gclient_revinfo(
        checkout_root,
        depot_tools_root,
        actual=False,
        jobs=arguments.gclient_jobs,
        timeout_seconds=arguments.command_timeout_seconds,
    )
    actual = _invoke_gclient_revinfo(
        checkout_root,
        depot_tools_root,
        actual=True,
        jobs=arguments.gclient_jobs,
        timeout_seconds=arguments.command_timeout_seconds,
    )
    declarations = _invoke_gclient_declarations(
        checkout_root,
        depot_tools_root,
        jobs=arguments.gclient_jobs,
        timeout_seconds=arguments.command_timeout_seconds,
    )
    if any(
        str(record.get("url", "")).startswith(f"{CIPD_SERVICE}/")
        for record in declarations.values()
    ):
        _validate_cipd_deployment(
            checkout_root,
            depot_tools_root,
            timeout_seconds=arguments.command_timeout_seconds,
        )
    manifest = collect_dependency_state(
        checkout_root,
        expected,
        actual,
        declarations,
        cipd_deployment_verified=True,
        source_delta_sha256=arguments.source_delta_sha256,
        command_timeout_seconds=arguments.command_timeout_seconds,
    )
    json.dump(manifest, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout-root", required=True)
    parser.add_argument("--depot-tools-root", required=True)
    parser.add_argument("--depot-tools-revision", required=True)
    parser.add_argument("--source-delta-sha256", required=True)
    parser.add_argument("--gclient-jobs", type=int, default=8, choices=range(1, 33))
    parser.add_argument(
        "--command-timeout-seconds", type=int, default=300, choices=range(1, 1801)
    )
    parser.set_defaults(handler=_collect_command)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    effective_argv = list(sys.argv[1:] if argv is None else argv)
    if effective_argv[:1] == ["__gclient-declarations"]:
        try:
            return _gclient_declarations_main(effective_argv[1:])
        except (DependencyStateError, OSError, ValueError) as error:
            print(f"dependency_state.py: internal probe error: {error}", file=sys.stderr)
            return 1
    parser = build_argument_parser()
    arguments = parser.parse_args(effective_argv)
    try:
        arguments.handler(arguments)
    except (DependencyStateError, OSError) as error:
        parser.exit(1, f"dependency_state.py: error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
