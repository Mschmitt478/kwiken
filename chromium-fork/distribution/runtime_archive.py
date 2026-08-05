#!/usr/bin/env python3
"""Create and verify deterministic, provenance-bound Kwiken runtime archives."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import sys
import tempfile
import unicodedata
import uuid
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO, Iterable, Mapping, Sequence


SCHEMA_VERSION = 3
DEPENDENCY_STATE_SCHEMA_VERSION = 1
BUILD_KIND = "patched-chromium-source"
FIXED_ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
DEFAULT_MAX_FILES = 10_000
DEFAULT_MAX_UNCOMPRESSED_BYTES = 4 * 1024 * 1024 * 1024
DEFAULT_MAX_ARCHIVE_BYTES = 5 * 1024 * 1024 * 1024
MAX_MANIFEST_BYTES = 16 * 1024 * 1024
MAX_CENTRAL_DIRECTORY_BYTES = 64 * 1024 * 1024
COPY_BUFFER_BYTES = 1024 * 1024
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
ZIP_EOCD_SIZE = 22
ZIP64_LOCATOR_SIZE = 20
ZIP64_EOCD_SIZE = 56
ZIP_CENTRAL_HEADER_SIZE = 46
ZIP_LOCAL_HEADER_SIZE = 30
ZIP_UINT16_MAX = 0xFFFF
ZIP_UINT32_MAX = 0xFFFFFFFF
ZIP64_CANONICAL_LIMIT = (1 << 31) - 1
ZIP_EOCD_SIGNATURE = b"PK\x05\x06"
ZIP64_LOCATOR_SIGNATURE = b"PK\x06\x07"
ZIP64_EOCD_SIGNATURE = b"PK\x06\x06"
ZIP_CENTRAL_HEADER_SIGNATURE = b"PK\x01\x02"
ZIP_LOCAL_HEADER_SIGNATURE = b"PK\x03\x04"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
REVISION_PATTERN = re.compile(r"^[0-9a-f]{40}$")
VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+\.\d+$")
DRIVE_PATH_PATTERN = re.compile(r"^[A-Za-z]:")
WINDOWS_RESERVED_NAMES = {
    "CON",
    "PRN",
    "AUX",
    "NUL",
    "CONIN$",
    "CONOUT$",
    *(f"COM{index}" for index in range(1, 10)),
    *(f"LPT{index}" for index in range(1, 10)),
    *(f"COM{index}" for index in "¹²³"),
    *(f"LPT{index}" for index in "¹²³"),
}
WINDOWS_FORBIDDEN_CHARACTERS = frozenset('<>:"/\\|?*') | frozenset(
    chr(value) for value in range(32)
)
DEPENDENCY_STATE_MUTABLE_CIPD_LIMITATION = (
    "cipd-mutable-version-to-instance-resolution-is-not-independently-verifiable-offline"
)
DEPENDENCY_STATE_INACTIVE_PLATFORM_LIMITATION = (
    "inactive-non-windows-conditional-dependencies-are-not-materialized-or-validated"
)
DEPENDENCY_STATE_LIMITATIONS = [DEPENDENCY_STATE_INACTIVE_PLATFORM_LIMITATION]
TRUSTED_EXPECTATION_KEYS = frozenset(
    {
        "appliedSourceTreeSha256",
        "artifactSha256",
        "artifactSize",
        "buildCommandLine",
        "buildJobs",
        "buildReceiptSha256",
        "cipdClientSha256",
        "cipdClientVersion",
        "chrome7zSha256",
        "chromeExeSha256",
        "chromiumRevision",
        "cleanSource",
        "depotToolsRevision",
        "dependencyStateTreeSha256",
        "gnArgsSha256",
        "kwikenRevision",
        "miniInstallerSha256",
        "outputDirectory",
        "packageRevision",
        "pythonPath",
        "pythonCipdInstance",
        "pythonCipdPackage",
        "pythonCipdVersion",
        "pythonRuntimeTreeSha256",
        "pythonSha256",
        "pythonVersion",
        "releaseVersion",
        "sevenZipPath",
        "sevenZipSha256",
        "sourceInputs",
        "version",
        "visualStudioVersion",
        "windowsDebuggerVersion",
        "windowsSdkVersion",
    }
)


class RuntimeArchiveError(ValueError):
    """Raised when an archive, source tree, or manifest is unsafe or invalid."""


@dataclass(frozen=True)
class FileRecord:
    path: str
    size: int
    sha256: str

    def as_json(self) -> dict[str, Any]:
        return {"path": self.path, "sha256": self.sha256, "size": self.size}


@dataclass(frozen=True)
class ZipEnvelopeRecord:
    """A bounded, independently parsed central-directory record."""

    name: str
    raw_name: bytes
    version_made_by: int
    version_needed: int
    flags: int
    compression_method: int
    dos_time: int
    dos_date: int
    crc32: int
    compressed_size: int
    uncompressed_size: int
    disk_start: int
    internal_attributes: int
    external_attributes: int
    local_header_offset: int
    central_extra: bytes
    comment: bytes


def _sha256_stream(stream: BinaryIO) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = stream.read(COPY_BUFFER_BYTES)
        if not chunk:
            break
        digest.update(chunk)
        size += len(chunk)
    return digest.hexdigest(), size


def sha256_file(path: Path) -> str:
    with path.open("rb") as stream:
        return _sha256_stream(stream)[0]


def _canonical_json_sha256(value: Mapping[str, Any]) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _native_build_receipt_sha256(native_build: Mapping[str, Any]) -> str:
    receipt_input = dict(native_build)
    receipt_input.pop("buildReceiptSha256", None)
    return _canonical_json_sha256(receipt_input)


def _with_native_build_receipt(native_build: Mapping[str, Any]) -> dict[str, Any]:
    result = dict(native_build)
    result["buildReceiptSha256"] = _native_build_receipt_sha256(result)
    return result


def _canonical_case_key(path: str) -> str:
    return unicodedata.normalize("NFC", path).casefold()


def _validate_relative_path(path: str, *, archive_member: bool = False) -> tuple[str, ...]:
    if not isinstance(path, str) or not path:
        raise RuntimeArchiveError("Runtime paths must be non-empty strings.")
    if "\x00" in path:
        raise RuntimeArchiveError(f"Runtime path contains a null character: {path!r}")
    if "\\" in path:
        if archive_member:
            raise RuntimeArchiveError(
                f"ZIP member paths must use forward slashes: {path!r}"
            )
        path = path.replace("\\", "/")
    if path.startswith("/") or path.startswith("//") or DRIVE_PATH_PATTERN.match(path):
        raise RuntimeArchiveError(f"Absolute runtime path is not allowed: {path!r}")

    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise RuntimeArchiveError(f"Unsafe runtime path component in {path!r}")

    for part in parts:
        if part.endswith((" ", ".")):
            raise RuntimeArchiveError(
                f"Windows-ambiguous trailing space or period in {path!r}"
            )
        forbidden = WINDOWS_FORBIDDEN_CHARACTERS.intersection(part)
        if forbidden:
            raise RuntimeArchiveError(
                f"Windows-forbidden character is not allowed in {path!r}"
            )
        reserved_candidate = part.split(".", 1)[0].upper()
        if reserved_candidate in WINDOWS_RESERVED_NAMES:
            raise RuntimeArchiveError(
                f"Windows device-name component is not allowed in {path!r}"
            )

    normalized = PurePosixPath(*parts).as_posix()
    if normalized != path:
        raise RuntimeArchiveError(f"Runtime path is not normalized: {path!r}")
    return tuple(parts)


def _validate_archive_root(root: str) -> None:
    parts = _validate_relative_path(root)
    if len(parts) != 1:
        raise RuntimeArchiveError("The runtime archive root must be one directory name.")


def _validate_case_and_parent_collisions(paths: Iterable[str]) -> None:
    files: dict[str, str] = {}
    directories: dict[str, str] = {}
    for path in sorted(paths):
        parts = _validate_relative_path(path)
        for index in range(1, len(parts)):
            parent = "/".join(parts[:index])
            parent_key = _canonical_case_key(parent)
            if parent_key in files:
                raise RuntimeArchiveError(
                    f"Runtime path treats file {files[parent_key]!r} as a directory: {path!r}"
                )
            directories.setdefault(parent_key, parent)

        key = _canonical_case_key(path)
        if key in files:
            raise RuntimeArchiveError(
                f"Case-insensitive runtime path collision: {files[key]!r} and {path!r}"
            )
        if key in directories:
            raise RuntimeArchiveError(
                f"Runtime file collides with directory {directories[key]!r}: {path!r}"
            )
        files[key] = path


def _is_reparse_point(file_stat: os.stat_result) -> bool:
    attributes = getattr(file_stat, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(attributes & reparse_flag)


def _assert_regular_file(path: Path) -> os.stat_result:
    file_stat = path.lstat()
    if stat.S_ISLNK(file_stat.st_mode) or _is_reparse_point(file_stat):
        raise RuntimeArchiveError(f"Links and reparse points are not allowed: {path}")
    if not stat.S_ISREG(file_stat.st_mode):
        raise RuntimeArchiveError(f"Only regular runtime files are supported: {path}")
    return file_stat


def _collect_source_files(source_root: Path) -> list[tuple[Path, FileRecord]]:
    source_root = source_root.absolute()
    _ensure_no_reparse_ancestors(source_root)
    if not source_root.exists():
        raise RuntimeArchiveError(f"Runtime source does not exist: {source_root}")
    root_stat = source_root.lstat()
    if stat.S_ISLNK(root_stat.st_mode) or _is_reparse_point(root_stat):
        raise RuntimeArchiveError(
            f"The runtime source root cannot be a link or reparse point: {source_root}"
        )
    if not source_root.is_dir():
        raise RuntimeArchiveError(f"Runtime source is not a directory: {source_root}")

    files: list[tuple[Path, FileRecord]] = []

    def walk(directory: Path) -> None:
        entries = sorted(os.scandir(directory), key=lambda item: item.name)
        for entry in entries:
            entry_path = Path(entry.path)
            entry_stat = entry.stat(follow_symlinks=False)
            if stat.S_ISLNK(entry_stat.st_mode) or _is_reparse_point(entry_stat):
                raise RuntimeArchiveError(
                    f"Links and reparse points are not allowed: {entry_path}"
                )
            if stat.S_ISDIR(entry_stat.st_mode):
                walk(entry_path)
                continue
            if not stat.S_ISREG(entry_stat.st_mode):
                raise RuntimeArchiveError(
                    f"Only regular runtime files are supported: {entry_path}"
                )

            relative = entry_path.relative_to(source_root).as_posix()
            _validate_relative_path(relative)
            with entry_path.open("rb") as stream:
                file_hash, size = _sha256_stream(stream)
            if size != entry_stat.st_size:
                raise RuntimeArchiveError(
                    f"Runtime file changed while it was being hashed: {entry_path}"
                )
            files.append((entry_path, FileRecord(relative, size, file_hash)))

    walk(source_root)
    if not files:
        raise RuntimeArchiveError("The runtime source directory is empty.")
    files.sort(key=lambda item: item[1].path)
    _validate_case_and_parent_collisions(record.path for _, record in files)
    return files


def tree_sha256(records: Sequence[FileRecord]) -> str:
    digest = hashlib.sha256()
    for record in sorted(records, key=lambda item: item.path):
        _validate_relative_path(record.path)
        digest.update(record.path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(record.size).encode("ascii"))
        digest.update(b"\0")
        digest.update(record.sha256.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def _path_is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _new_atomic_path(destination: Path) -> Path:
    return destination.with_name(
        f".kwiken-tmp-{os.getpid()}-{uuid.uuid4().hex}.tmp"
    )


def _new_extraction_path(destination: Path) -> Path:
    return destination.with_name(f".kwiken-extract-{uuid.uuid4().hex[:12]}")


def _write_zip_member(
    archive: zipfile.ZipFile,
    archive_name: str,
    source_path: Path,
    expected: FileRecord,
) -> None:
    _assert_regular_file(source_path)
    info = zipfile.ZipInfo(archive_name, date_time=FIXED_ZIP_TIMESTAMP)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 0
    info.external_attr = 0o100644 << 16
    info._compresslevel = 9  # zipfile has no public per-ZipInfo setter before 3.13.

    digest = hashlib.sha256()
    size = 0
    with source_path.open("rb") as source, archive.open(
        info, mode="w", force_zip64=True
    ) as destination:
        while True:
            chunk = source.read(COPY_BUFFER_BYTES)
            if not chunk:
                break
            destination.write(chunk)
            digest.update(chunk)
            size += len(chunk)

    if size != expected.size or digest.hexdigest() != expected.sha256:
        raise RuntimeArchiveError(
            f"Runtime file changed while it was being archived: {source_path}"
        )


def _write_json_atomic(path: Path, value: Mapping[str, Any]) -> None:
    temporary = _new_atomic_path(path)
    try:
        with temporary.open("w", encoding="utf-8", newline="\n") as output:
            json.dump(value, output, indent=2, sort_keys=True, ensure_ascii=False)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _publish_file_no_replace(source: Path, destination: Path) -> None:
    """Publish a same-volume staged file without replacing an existing path."""

    try:
        os.link(source, destination)
    except FileExistsError as error:
        raise RuntimeArchiveError(
            f"Refusing to overwrite an existing release artifact: {destination}"
        ) from error
    except OSError as error:
        raise RuntimeArchiveError(
            f"Could not publish staged release artifact {destination}: {error}"
        ) from error
    source.unlink()


def _require_sha256(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise RuntimeArchiveError(f"{label} must be a lowercase SHA-256 string.")
    normalized = value.lower()
    if value != normalized or not SHA256_PATTERN.fullmatch(normalized):
        raise RuntimeArchiveError(f"{label} must be a lowercase SHA-256 string.")
    return normalized


def _required_mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise RuntimeArchiveError(f"{label} must be a JSON object.")
    return value


def _required_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise RuntimeArchiveError(f"{label} must be a non-empty string.")
    return value


def _require_revision(value: Any, label: str) -> str:
    value = _required_string(value, label)
    if not REVISION_PATTERN.fullmatch(value):
        raise RuntimeArchiveError(f"{label} must be a lowercase 40-character revision.")
    return value


def _dependency_entry_sort_key(
    entry: Mapping[str, Any],
) -> tuple[str, str, str, str]:
    return (
        str(entry.get("type", "")),
        str(entry.get("path", "")),
        str(entry.get("package", entry.get("object", ""))),
        str(entry.get("revision", entry.get("instanceId", ""))),
    )


def dependency_state_tree_sha256(entries: Sequence[Mapping[str, Any]]) -> str:
    encoded = json.dumps(
        list(entries), ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    return hashlib.sha256(encoded + b"\n").hexdigest()


def _validate_dependency_state(value: Any) -> Mapping[str, Any]:
    state = _required_mapping(value, "source.dependencyState")
    expected_keys = {
        "entries",
        "limitations",
        "schemaVersion",
        "summary",
        "treeSha256",
    }
    if set(state) != expected_keys:
        raise RuntimeArchiveError(
            "source.dependencyState must contain exactly the normalized fields."
        )
    if state.get("schemaVersion") != DEPENDENCY_STATE_SCHEMA_VERSION:
        raise RuntimeArchiveError("Unsupported dependency-state schema version.")
    raw_entries = state.get("entries")
    if not isinstance(raw_entries, list) or not raw_entries:
        raise RuntimeArchiveError("source.dependencyState.entries must be non-empty.")
    if len(raw_entries) > 10_000:
        raise RuntimeArchiveError("source.dependencyState.entries exceeds its limit.")

    entries: list[Mapping[str, Any]] = []
    identities: list[tuple[str, str, str]] = []
    counts = {
        "cipdPackages": 0,
        "gcsObjects": 0,
        "gitRepositories": 0,
        "gitSubmodules": 0,
    }
    for index, raw_entry in enumerate(raw_entries):
        label = f"source.dependencyState.entries[{index}]"
        entry = _required_mapping(raw_entry, label)
        entry_type = _required_string(entry.get("type"), f"{label}.type")
        path = _required_string(entry.get("path"), f"{label}.path")
        _validate_relative_path(path)
        identity_name = ""
        if entry_type == "git":
            if set(entry) != {
                "path",
                "revision",
                "type",
                "url",
                "workingTreeSha256",
            }:
                raise RuntimeArchiveError(f"{label} has non-canonical Git fields.")
            _require_revision(entry.get("revision"), f"{label}.revision")
            _required_string(entry.get("url"), f"{label}.url")
            _require_sha256(
                entry.get("workingTreeSha256"), f"{label}.workingTreeSha256"
            )
            counts["gitRepositories"] += 1
        elif entry_type == "git-submodule":
            if set(entry) != {
                "parent",
                "path",
                "revision",
                "type",
                "workingTreeSha256",
            }:
                raise RuntimeArchiveError(
                    f"{label} has non-canonical Git submodule fields."
                )
            parent = _required_string(entry.get("parent"), f"{label}.parent")
            _validate_relative_path(parent)
            if not path.startswith(f"{parent}/"):
                raise RuntimeArchiveError(f"{label}.path is outside its parent.")
            _require_revision(entry.get("revision"), f"{label}.revision")
            if entry.get("workingTreeSha256") != EMPTY_SHA256:
                raise RuntimeArchiveError(f"{label} must report a clean worktree.")
            counts["gitSubmodules"] += 1
        elif entry_type == "cipd":
            if set(entry) != {
                "declaredPackage",
                "instanceId",
                "package",
                "packageFileTreeSha256",
                "packageManifestSha256",
                "path",
                "type",
                "verificationLevel",
                "version",
                "versionResolution",
            }:
                raise RuntimeArchiveError(f"{label} has non-canonical CIPD fields.")
            _required_string(entry.get("declaredPackage"), f"{label}.declaredPackage")
            identity_name = _required_string(entry.get("package"), f"{label}.package")
            instance_id = _required_string(entry.get("instanceId"), f"{label}.instanceId")
            if not re.fullmatch(r"[A-Za-z0-9_-]{40,64}", instance_id):
                raise RuntimeArchiveError(f"{label}.instanceId is malformed.")
            _require_sha256(
                entry.get("packageFileTreeSha256"),
                f"{label}.packageFileTreeSha256",
            )
            _require_sha256(
                entry.get("packageManifestSha256"),
                f"{label}.packageManifestSha256",
            )
            _required_string(entry.get("version"), f"{label}.version")
            if entry.get("verificationLevel") != (
                "cipd-deployment-check-and-package-manifest-sha256"
            ):
                raise RuntimeArchiveError(
                    f"{label}.verificationLevel is unsupported."
                )
            if entry.get("versionResolution") not in {
                "immutable-instance-id",
                "declared-version-with-installed-instance-provenance",
            }:
                raise RuntimeArchiveError(
                    f"{label}.versionResolution is unsupported."
                )
            counts["cipdPackages"] += 1
        elif entry_type == "gcs":
            if set(entry) != {
                "artifactSha256",
                "contentNamesSha256",
                "expectedSha256",
                "expectedSizeBytes",
                "installedTreeSha256",
                "object",
                "outputFile",
                "path",
                "type",
                "url",
                "verificationLevel",
            }:
                raise RuntimeArchiveError(f"{label} has non-canonical GCS fields.")
            identity_name = _required_string(entry.get("object"), f"{label}.object")
            url = _required_string(entry.get("url"), f"{label}.url")
            if not url.startswith("gs://"):
                raise RuntimeArchiveError(f"{label}.url must use gs://.")
            artifact_hash = _require_sha256(
                entry.get("artifactSha256"), f"{label}.artifactSha256"
            )
            expected_hash = _require_sha256(
                entry.get("expectedSha256"), f"{label}.expectedSha256"
            )
            if artifact_hash != expected_hash:
                raise RuntimeArchiveError(
                    f"{label}.artifactSha256 must match its expected digest."
                )
            _require_sha256(
                entry.get("installedTreeSha256"),
                f"{label}.installedTreeSha256",
            )
            content_names_hash = entry.get("contentNamesSha256")
            if content_names_hash is not None:
                _require_sha256(content_names_hash, f"{label}.contentNamesSha256")
            expected_size = entry.get("expectedSizeBytes")
            if (
                not isinstance(expected_size, int)
                or isinstance(expected_size, bool)
                or expected_size < 0
            ):
                raise RuntimeArchiveError(
                    f"{label}.expectedSizeBytes must be non-negative."
                )
            output_file = entry.get("outputFile")
            if output_file is not None:
                output_file = _required_string(output_file, f"{label}.outputFile")
                _validate_relative_path(output_file)
                if "/" in output_file:
                    raise RuntimeArchiveError(
                        f"{label}.outputFile must be a single safe basename."
                    )
            if entry.get("verificationLevel") != (
                "expected-artifact-and-installed-content-sha256"
            ):
                raise RuntimeArchiveError(
                    f"{label}.verificationLevel is unsupported."
                )
            counts["gcsObjects"] += 1
        else:
            raise RuntimeArchiveError(f"Unsupported dependency-state type: {entry_type}")
        identities.append((entry_type, path, identity_name))
        entries.append(entry)

    if len(identities) != len(set(identities)):
        raise RuntimeArchiveError("source.dependencyState contains duplicate entries.")
    if list(entries) != sorted(entries, key=_dependency_entry_sort_key):
        raise RuntimeArchiveError("source.dependencyState.entries is not sorted.")
    has_mutable_cipd = any(
        entry.get("type") == "cipd"
        and entry.get("versionResolution")
        == "declared-version-with-installed-instance-provenance"
        for entry in entries
    )
    expected_limitations = (
        [DEPENDENCY_STATE_MUTABLE_CIPD_LIMITATION]
        if has_mutable_cipd
        else []
    ) + [DEPENDENCY_STATE_INACTIVE_PLATFORM_LIMITATION]
    if state.get("limitations") != expected_limitations:
        raise RuntimeArchiveError(
            "source.dependencyState.limitations must exactly match its dependency checks."
        )
    summary = _required_mapping(state.get("summary"), "source.dependencyState.summary")
    if dict(summary) != counts:
        raise RuntimeArchiveError("source.dependencyState.summary does not match entries.")
    expected_tree_hash = _require_sha256(
        state.get("treeSha256"), "source.dependencyState.treeSha256"
    )
    if dependency_state_tree_sha256(entries) != expected_tree_hash:
        raise RuntimeArchiveError(
            "source.dependencyState.treeSha256 does not match its entries."
        )
    return state


def _load_dependency_state_manifest(path: Path) -> Mapping[str, Any]:
    try:
        with path.open("rb") as source:
            size = os.fstat(source.fileno()).st_size
            if size > MAX_MANIFEST_BYTES:
                raise RuntimeArchiveError(
                    f"Dependency-state manifest exceeds {MAX_MANIFEST_BYTES} bytes."
                )
            encoded = source.read(MAX_MANIFEST_BYTES + 1)
        value = json.loads(encoded.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise RuntimeArchiveError(
            f"Could not read dependency-state manifest {path}: {error}"
        ) from error
    return _validate_dependency_state(value)


def _validate_provenance(provenance: Mapping[str, Any]) -> None:
    product = _required_mapping(provenance.get("product"), "product")
    for name in ("name", "version", "packageRevision", "releaseVersion"):
        _required_string(product.get(name), f"product.{name}")
    if product["name"] != "Kwiken":
        raise RuntimeArchiveError("product.name must be Kwiken.")
    if not VERSION_PATTERN.fullmatch(product["version"]):
        raise RuntimeArchiveError("product.version must be a four-part numeric version.")
    if not product["packageRevision"].isdigit():
        raise RuntimeArchiveError("product.packageRevision must be numeric.")
    if product["releaseVersion"] != (
        f"{product['version']}-r{product['packageRevision']}"
    ):
        raise RuntimeArchiveError(
            "product.releaseVersion must combine product.version and packageRevision."
        )

    target = _required_mapping(provenance.get("target"), "target")
    if target.get("os") != "windows" or target.get("arch") != "x64":
        raise RuntimeArchiveError("Only the windows/x64 Kwiken runtime is supported.")

    source = _required_mapping(provenance.get("source"), "source")
    kwiken = _required_mapping(source.get("kwiken"), "source.kwiken")
    if kwiken.get("repository") != "https://github.com/Mschmitt478/kwiken":
        raise RuntimeArchiveError("source.kwiken.repository is not the canonical repository.")
    _require_revision(kwiken.get("revision"), "source.kwiken.revision")
    if not isinstance(kwiken.get("dirty"), bool):
        raise RuntimeArchiveError("source.kwiken.dirty must be a boolean.")
    if kwiken["dirty"]:
        raise RuntimeArchiveError("Release provenance cannot report a dirty Kwiken source.")

    chromium = _required_mapping(source.get("chromium"), "source.chromium")
    if chromium.get("repository") != "https://chromium.googlesource.com/chromium/src":
        raise RuntimeArchiveError("source.chromium.repository is not canonical.")
    if chromium.get("version") != product["version"]:
        raise RuntimeArchiveError("source.chromium.version must equal product.version.")
    _require_revision(chromium.get("revision"), "source.chromium.revision")
    _require_revision(source.get("depotToolsRevision"), "source.depotToolsRevision")
    _require_sha256(source.get("appliedSourceTreeSha256"), "source.appliedSourceTreeSha256")
    dependency_state = _validate_dependency_state(source.get("dependencyState"))
    dependency_entries = dependency_state["entries"]
    source_entries = [
        entry
        for entry in dependency_entries
        if entry.get("type") == "git" and entry.get("path") == "src"
    ]
    if len(source_entries) != 1:
        raise RuntimeArchiveError(
            "source.dependencyState must contain exactly one src Git repository."
        )
    if source_entries[0].get("revision") != chromium["revision"]:
        raise RuntimeArchiveError(
            "source.dependencyState src revision must match source.chromium.revision."
        )
    if source_entries[0].get("workingTreeSha256") != source["appliedSourceTreeSha256"]:
        raise RuntimeArchiveError(
            "source.dependencyState src worktree must match the applied source delta."
        )
    for dependency_entry in dependency_entries:
        if (
            dependency_entry.get("type") == "git"
            and dependency_entry.get("path") != "src"
            and dependency_entry.get("workingTreeSha256") != EMPTY_SHA256
        ):
            raise RuntimeArchiveError(
                "Non-solution Git dependencies must report clean worktrees."
            )

    gn_args = _required_mapping(source.get("gnArgs"), "source.gnArgs")
    if gn_args.get("path") != "chromium-fork/args.gn":
        raise RuntimeArchiveError("source.gnArgs.path must be chromium-fork/args.gn.")
    _require_sha256(gn_args.get("sha256"), "source.gnArgs.sha256")

    patch_set = _required_mapping(source.get("patchSet"), "source.patchSet")
    inputs = patch_set.get("inputs")
    if not isinstance(inputs, list) or not inputs:
        raise RuntimeArchiveError("source.patchSet.inputs must be a non-empty array.")
    input_paths: list[str] = []
    for index, source_input in enumerate(inputs):
        source_input = _required_mapping(
            source_input, f"source.patchSet.inputs[{index}]"
        )
        input_path = _required_string(
            source_input.get("path"), f"source.patchSet.inputs[{index}].path"
        )
        _validate_relative_path(input_path)
        _require_sha256(
            source_input.get("sha256"),
            f"source.patchSet.inputs[{index}].sha256",
        )
        input_paths.append(input_path)
    _validate_case_and_parent_collisions(input_paths)
    if _canonical_case_key(
        "chromium-fork/patches/0001-kwiken-browser.patch"
    ) not in {_canonical_case_key(path) for path in input_paths}:
        raise RuntimeArchiveError("source.patchSet.inputs is missing the Kwiken patch.")

    native_build = _required_mapping(provenance.get("nativeBuild"), "nativeBuild")
    if native_build.get("buildKind") != BUILD_KIND:
        raise RuntimeArchiveError(f"nativeBuild.buildKind must be {BUILD_KIND}.")
    if native_build.get("outputDirectory") != "out/Kwiken":
        raise RuntimeArchiveError("nativeBuild.outputDirectory must be out/Kwiken.")
    _require_sha256(native_build.get("chrome7zSha256"), "nativeBuild.chrome7zSha256")
    _require_sha256(
        native_build.get("miniInstallerSha256"),
        "nativeBuild.miniInstallerSha256",
    )
    _require_sha256(native_build.get("chromeExeSha256"), "nativeBuild.chromeExeSha256")
    receipt_hash = _require_sha256(
        native_build.get("buildReceiptSha256"),
        "nativeBuild.buildReceiptSha256",
    )

    source_binding = _required_mapping(
        native_build.get("sourceBinding"), "nativeBuild.sourceBinding"
    )
    expected_source_binding = {
        "appliedSourceTreeSha256": source["appliedSourceTreeSha256"],
        "chromiumRevision": chromium["revision"],
        "depotToolsRevision": source["depotToolsRevision"],
        "dependencyStateTreeSha256": dependency_state["treeSha256"],
        "gnArgsSha256": gn_args["sha256"],
    }
    if dict(source_binding) != expected_source_binding:
        raise RuntimeArchiveError(
            "nativeBuild.sourceBinding must exactly match the declared source provenance."
        )

    invocation = _required_mapping(
        native_build.get("buildInvocation"), "nativeBuild.buildInvocation"
    )
    _required_string(
        invocation.get("commandLine"), "nativeBuild.buildInvocation.commandLine"
    )
    jobs = invocation.get("jobs")
    if not isinstance(jobs, int) or isinstance(jobs, bool) or jobs < 1:
        raise RuntimeArchiveError("nativeBuild.buildInvocation.jobs must be positive.")
    if invocation.get("completed") is not True:
        raise RuntimeArchiveError("nativeBuild.buildInvocation.completed must be true.")
    if invocation.get("targets") != ["chrome", "mini_installer"]:
        raise RuntimeArchiveError(
            "nativeBuild.buildInvocation.targets must be chrome and mini_installer."
        )

    toolchain = _required_mapping(native_build.get("toolchain"), "nativeBuild.toolchain")
    for name in ("visualStudio", "windowsSdk", "windowsDebugger", "python"):
        _required_string(toolchain.get(name), f"nativeBuild.toolchain.{name}")
    python_path = _required_string(
        toolchain.get("pythonPath"), "nativeBuild.toolchain.pythonPath"
    )
    _validate_relative_path(python_path)
    if not python_path.lower().endswith("/python3.exe"):
        raise RuntimeArchiveError(
            "nativeBuild.toolchain.pythonPath must identify a direct python3.exe."
        )
    _require_sha256(
        toolchain.get("pythonSha256"), "nativeBuild.toolchain.pythonSha256"
    )
    _require_sha256(
        toolchain.get("pythonRuntimeTreeSha256"),
        "nativeBuild.toolchain.pythonRuntimeTreeSha256",
    )
    if toolchain.get("pythonCipdPackage") != (
        "infra/3pp/tools/cpython3/windows-amd64"
    ):
        raise RuntimeArchiveError(
            "nativeBuild.toolchain.pythonCipdPackage is not the pinned Windows package."
        )
    _required_string(
        toolchain.get("pythonCipdVersion"),
        "nativeBuild.toolchain.pythonCipdVersion",
    )
    python_cipd_instance = _required_string(
        toolchain.get("pythonCipdInstance"),
        "nativeBuild.toolchain.pythonCipdInstance",
    )
    if not re.fullmatch(r"[A-Za-z0-9_-]{40,64}", python_cipd_instance):
        raise RuntimeArchiveError(
            "nativeBuild.toolchain.pythonCipdInstance is malformed."
        )
    cipd_client_version = _required_string(
        toolchain.get("cipdClientVersion"),
        "nativeBuild.toolchain.cipdClientVersion",
    )
    if not re.fullmatch(r"git_revision:[0-9a-f]{40}", cipd_client_version):
        raise RuntimeArchiveError(
            "nativeBuild.toolchain.cipdClientVersion is malformed."
        )
    _require_sha256(
        toolchain.get("cipdClientSha256"),
        "nativeBuild.toolchain.cipdClientSha256",
    )
    if toolchain.get("sevenZipPath") != (
        "third_party/lzma_sdk/bin/host_platform/7za.exe"
    ):
        raise RuntimeArchiveError(
            "nativeBuild.toolchain.sevenZipPath must identify Chromium's pinned extractor."
        )
    _require_sha256(
        toolchain.get("sevenZipSha256"), "nativeBuild.toolchain.sevenZipSha256"
    )
    if receipt_hash != _native_build_receipt_sha256(native_build):
        raise RuntimeArchiveError(
            "nativeBuild.buildReceiptSha256 does not bind the native build fields."
        )


def trusted_expectations_for_provenance(
    provenance: Mapping[str, Any],
    *,
    artifact_sha256: str,
    artifact_size: int,
) -> dict[str, Any]:
    """Return the complete, externally supplied verification contract."""

    _validate_provenance(provenance)
    product = _required_mapping(provenance["product"], "product")
    source = _required_mapping(provenance["source"], "source")
    kwiken = _required_mapping(source["kwiken"], "source.kwiken")
    chromium = _required_mapping(source["chromium"], "source.chromium")
    dependency_state = _validate_dependency_state(source["dependencyState"])
    gn_args = _required_mapping(source["gnArgs"], "source.gnArgs")
    patch_set = _required_mapping(source["patchSet"], "source.patchSet")
    native_build = _required_mapping(provenance["nativeBuild"], "nativeBuild")
    invocation = _required_mapping(
        native_build["buildInvocation"], "nativeBuild.buildInvocation"
    )
    toolchain = _required_mapping(native_build["toolchain"], "nativeBuild.toolchain")
    if not isinstance(artifact_size, int) or isinstance(artifact_size, bool) or artifact_size < 0:
        raise RuntimeArchiveError("Trusted artifact size must be non-negative.")
    return {
        "appliedSourceTreeSha256": source["appliedSourceTreeSha256"],
        "artifactSha256": _require_sha256(
            artifact_sha256, "trusted artifact SHA-256"
        ),
        "artifactSize": artifact_size,
        "buildCommandLine": invocation["commandLine"],
        "buildJobs": invocation["jobs"],
        "buildReceiptSha256": native_build["buildReceiptSha256"],
        "cipdClientSha256": toolchain["cipdClientSha256"],
        "cipdClientVersion": toolchain["cipdClientVersion"],
        "chrome7zSha256": native_build["chrome7zSha256"],
        "chromeExeSha256": native_build["chromeExeSha256"],
        "chromiumRevision": chromium["revision"],
        "cleanSource": not kwiken["dirty"],
        "depotToolsRevision": source["depotToolsRevision"],
        "dependencyStateTreeSha256": dependency_state["treeSha256"],
        "gnArgsSha256": gn_args["sha256"],
        "kwikenRevision": kwiken["revision"],
        "miniInstallerSha256": native_build["miniInstallerSha256"],
        "outputDirectory": native_build["outputDirectory"],
        "packageRevision": product["packageRevision"],
        "pythonPath": toolchain["pythonPath"],
        "pythonCipdInstance": toolchain["pythonCipdInstance"],
        "pythonCipdPackage": toolchain["pythonCipdPackage"],
        "pythonCipdVersion": toolchain["pythonCipdVersion"],
        "pythonRuntimeTreeSha256": toolchain["pythonRuntimeTreeSha256"],
        "pythonSha256": toolchain["pythonSha256"],
        "pythonVersion": toolchain["python"],
        "releaseVersion": product["releaseVersion"],
        "sevenZipPath": toolchain["sevenZipPath"],
        "sevenZipSha256": toolchain["sevenZipSha256"],
        "sourceInputs": list(patch_set["inputs"]),
        "version": product["version"],
        "visualStudioVersion": toolchain["visualStudio"],
        "windowsDebuggerVersion": toolchain["windowsDebugger"],
        "windowsSdkVersion": toolchain["windowsSdk"],
    }


def create_runtime_archive(
    source_root: Path,
    archive_path: Path,
    manifest_path: Path,
    archive_root: str,
    provenance: Mapping[str, Any],
    required_files: Sequence[str] = (),
) -> dict[str, Any]:
    """Create a deterministic ZIP and full-file provenance sidecar."""

    source_root = source_root.absolute()
    archive_path = archive_path.absolute()
    manifest_path = manifest_path.absolute()
    if archive_path == manifest_path:
        raise RuntimeArchiveError("Archive and manifest paths must be different.")
    if _path_is_within(archive_path, source_root) or _path_is_within(
        manifest_path, source_root
    ):
        raise RuntimeArchiveError("Archive outputs cannot be placed inside the runtime source.")
    if archive_path.parent != manifest_path.parent:
        raise RuntimeArchiveError(
            "Archive and manifest must be published in the same directory."
        )

    _validate_provenance(provenance)
    _validate_archive_root(archive_root)
    expected_archive_root = (
        f"Kwiken-runtime-{provenance['product']['releaseVersion']}"
    )
    if archive_root != expected_archive_root:
        raise RuntimeArchiveError(
            f"runtime.archiveRoot must be {expected_archive_root}."
        )
    _ensure_no_reparse_ancestors(archive_path.parent)
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    _ensure_no_reparse_ancestors(archive_path.parent)
    if os.path.lexists(archive_path) or os.path.lexists(manifest_path):
        raise RuntimeArchiveError(
            "Refusing to overwrite an existing runtime archive or manifest."
        )

    files = _collect_source_files(source_root)
    records = [record for _, record in files]
    record_keys = {_canonical_case_key(record.path) for record in records}
    for required_file in required_files:
        _validate_relative_path(required_file)
        if _canonical_case_key(required_file) not in record_keys:
            raise RuntimeArchiveError(
                f"Required runtime file is missing: {required_file}"
            )

    staging_directory = Path(
        tempfile.mkdtemp(
            prefix=f".kwiken-pack-{os.getpid()}.",
            dir=archive_path.parent,
        )
    )
    os.chmod(staging_directory, 0o700)
    staged_archive = staging_directory / archive_path.name
    staged_manifest = staging_directory / manifest_path.name
    try:
        with zipfile.ZipFile(
            staged_archive,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
            allowZip64=True,
        ) as archive:
            for source_path, record in files:
                archive_name = f"{archive_root}/{record.path}"
                _write_zip_member(archive, archive_name, source_path, record)

        manifest: dict[str, Any] = {
            "artifact": {
                "fileName": archive_path.name,
                "format": "zip",
                "sha256": sha256_file(staged_archive),
                "size": staged_archive.stat().st_size,
            },
            "nativeBuild": dict(provenance["nativeBuild"]),
            "product": dict(provenance["product"]),
            "runtime": {
                "archiveRoot": archive_root,
                "fileCount": len(records),
                "files": [record.as_json() for record in records],
                "treeSha256": tree_sha256(records),
            },
            "schemaVersion": SCHEMA_VERSION,
            "source": dict(provenance["source"]),
            "target": dict(provenance["target"]),
        }
        _write_json_atomic(staged_manifest, manifest)
        verify_runtime_archive(
            staged_archive,
            staged_manifest,
            expectations=trusted_expectations_for_provenance(
                provenance,
                artifact_sha256=manifest["artifact"]["sha256"],
                artifact_size=manifest["artifact"]["size"],
            ),
        )

        archive_published = False
        try:
            _publish_file_no_replace(staged_archive, archive_path)
            archive_published = True
            _publish_file_no_replace(staged_manifest, manifest_path)
        except BaseException:
            if archive_published and archive_path.exists():
                archive_path.unlink()
            raise
        return manifest
    finally:
        if staging_directory.exists():
            shutil.rmtree(staging_directory)


def _load_manifest(path: Path) -> Mapping[str, Any]:
    try:
        with path.open("rb") as source:
            size = os.fstat(source.fileno()).st_size
            if size > MAX_MANIFEST_BYTES:
                raise RuntimeArchiveError(
                    f"Runtime manifest exceeds {MAX_MANIFEST_BYTES} bytes."
                )
            encoded = source.read(MAX_MANIFEST_BYTES + 1)
            if len(encoded) > MAX_MANIFEST_BYTES:
                raise RuntimeArchiveError(
                    f"Runtime manifest exceeds {MAX_MANIFEST_BYTES} bytes."
                )
            manifest = json.loads(encoded.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise RuntimeArchiveError(f"Could not read runtime manifest {path}: {error}") from error
    return _required_mapping(manifest, "manifest")


def _manifest_records(
    runtime: Mapping[str, Any], *, max_files: int
) -> list[FileRecord]:
    raw_files = runtime.get("files")
    if not isinstance(raw_files, list) or not raw_files:
        raise RuntimeArchiveError("runtime.files must be a non-empty array.")
    if len(raw_files) > max_files:
        raise RuntimeArchiveError(
            f"runtime.files contains {len(raw_files)} entries; limit is {max_files}."
        )
    records: list[FileRecord] = []
    for index, raw_record in enumerate(raw_files):
        raw_record = _required_mapping(raw_record, f"runtime.files[{index}]")
        path = _required_string(raw_record.get("path"), f"runtime.files[{index}].path")
        _validate_relative_path(path)
        size = raw_record.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise RuntimeArchiveError(f"runtime.files[{index}].size must be non-negative.")
        file_hash = _require_sha256(
            raw_record.get("sha256"), f"runtime.files[{index}].sha256"
        )
        records.append(FileRecord(path, size, file_hash))
    records.sort(key=lambda record: record.path)
    _validate_case_and_parent_collisions(record.path for record in records)
    return records


def _zip_info_is_link(info: zipfile.ZipInfo) -> bool:
    if info.create_system == 3:
        unix_mode = (info.external_attr >> 16) & 0xFFFF
        if stat.S_ISLNK(unix_mode):
            return True
    dos_attributes = info.external_attr & 0xFFFF
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(dos_attributes & reparse_flag)


def _read_exact(stream: BinaryIO, size: int, label: str) -> bytes:
    data = stream.read(size)
    if len(data) != size:
        raise RuntimeArchiveError(f"Runtime ZIP ended inside {label}.")
    return data


def _parse_extra_fields(extra: bytes, label: str) -> list[tuple[int, bytes]]:
    fields: list[tuple[int, bytes]] = []
    cursor = 0
    while cursor < len(extra):
        if len(extra) - cursor < 4:
            raise RuntimeArchiveError(f"Malformed ZIP extra-field header in {label}.")
        field_id, field_size = struct.unpack_from("<HH", extra, cursor)
        cursor += 4
        field_end = cursor + field_size
        if field_end > len(extra):
            raise RuntimeArchiveError(f"Malformed ZIP extra-field length in {label}.")
        fields.append((field_id, extra[cursor:field_end]))
        cursor = field_end
    return fields


def _resolve_central_zip64_values(
    *,
    compressed_size: int,
    uncompressed_size: int,
    local_header_offset: int,
    disk_start: int,
    extra: bytes,
    label: str,
) -> tuple[int, int, int, int]:
    needs_uncompressed = uncompressed_size == ZIP_UINT32_MAX
    needs_compressed = compressed_size == ZIP_UINT32_MAX
    needs_offset = local_header_offset == ZIP_UINT32_MAX
    needs_disk = disk_start == ZIP_UINT16_MAX
    if needs_disk:
        raise RuntimeArchiveError(
            f"ZIP64 disk-start data is not canonical for a single-disk archive: {label}."
        )
    needs_zip64 = needs_uncompressed or needs_compressed or needs_offset
    fields = _parse_extra_fields(extra, label)
    if not needs_zip64:
        if fields:
            raise RuntimeArchiveError(
                f"Unexpected central-directory extra field in {label}."
            )
        return compressed_size, uncompressed_size, local_header_offset, disk_start
    if len(fields) != 1 or fields[0][0] != 0x0001:
        raise RuntimeArchiveError(
            f"Canonical ZIP64 central-directory data is missing in {label}."
        )

    zip64_data = fields[0][1]
    expected_size = (
        (8 if needs_uncompressed else 0)
        + (8 if needs_compressed else 0)
        + (8 if needs_offset else 0)
    )
    if len(zip64_data) != expected_size:
        raise RuntimeArchiveError(
            f"ZIP64 central-directory data has the wrong size in {label}."
        )
    cursor = 0

    def take_uint64() -> int:
        nonlocal cursor
        value = struct.unpack_from("<Q", zip64_data, cursor)[0]
        cursor += 8
        return value

    if needs_uncompressed:
        uncompressed_size = take_uint64()
    if needs_compressed:
        compressed_size = take_uint64()
    if needs_offset:
        local_header_offset = take_uint64()
    if (
        (needs_uncompressed and uncompressed_size <= ZIP64_CANONICAL_LIMIT)
        or (needs_compressed and compressed_size <= ZIP64_CANONICAL_LIMIT)
        or (needs_offset and local_header_offset <= ZIP64_CANONICAL_LIMIT)
    ):
        raise RuntimeArchiveError(
            f"Central-directory ZIP64 data is unnecessary in {label}."
        )
    return compressed_size, uncompressed_size, local_header_offset, disk_start


def _parse_zip_directory_bounds(
    stream: BinaryIO,
    artifact_size: int,
    *,
    max_files: int,
) -> tuple[int, int, int]:
    if artifact_size < ZIP_EOCD_SIZE:
        raise RuntimeArchiveError("Runtime ZIP is too small to contain an EOCD record.")

    eocd_offset = artifact_size - ZIP_EOCD_SIZE
    stream.seek(eocd_offset)
    (
        signature,
        disk_number,
        central_disk_number,
        disk_entry_count,
        total_entry_count,
        central_size_32,
        central_offset_32,
        comment_size,
    ) = struct.unpack("<4s4H2IH", _read_exact(stream, ZIP_EOCD_SIZE, "EOCD"))
    if signature != ZIP_EOCD_SIGNATURE:
        raise RuntimeArchiveError(
            "Runtime ZIP EOCD must end exactly at the end of the artifact."
        )
    if comment_size != 0:
        raise RuntimeArchiveError("Normalized runtime ZIPs cannot have an EOCD comment.")
    if disk_number != 0 or central_disk_number != 0:
        raise RuntimeArchiveError("Multi-disk runtime ZIPs are not supported.")

    # A classic count of exactly 0xffff is valid and therefore ambiguous, but
    # Python's canonical writer always emits ZIP64 once a directory bound is
    # over its conservative 2 GiB limit. Detect the locator independently and
    # require it only where the canonical writer would.
    requires_zip64_locator = (
        central_size_32 > ZIP64_CANONICAL_LIMIT
        or central_offset_32 > ZIP64_CANONICAL_LIMIT
    )
    locator_offset = eocd_offset - ZIP64_LOCATOR_SIZE
    has_zip64_locator = False
    if locator_offset >= 0:
        stream.seek(locator_offset)
        has_zip64_locator = (
            _read_exact(stream, 4, "possible ZIP64 locator")
            == ZIP64_LOCATOR_SIGNATURE
        )
    if requires_zip64_locator and not has_zip64_locator:
        raise RuntimeArchiveError("Runtime ZIP is missing its ZIP64 locator.")
    if has_zip64_locator:
        if locator_offset < ZIP64_EOCD_SIZE:
            raise RuntimeArchiveError("Runtime ZIP is missing its ZIP64 envelope.")
        stream.seek(locator_offset)
        (
            locator_signature,
            zip64_disk_number,
            zip64_eocd_offset,
            total_disks,
        ) = struct.unpack(
            "<4sIQI", _read_exact(stream, ZIP64_LOCATOR_SIZE, "ZIP64 locator")
        )
        if locator_signature != ZIP64_LOCATOR_SIGNATURE:
            raise RuntimeArchiveError("Runtime ZIP is missing its ZIP64 locator.")
        if zip64_disk_number != 0 or total_disks != 1:
            raise RuntimeArchiveError("Multi-disk ZIP64 runtime archives are not supported.")
        if zip64_eocd_offset + ZIP64_EOCD_SIZE != locator_offset:
            raise RuntimeArchiveError(
                "ZIP64 EOCD and locator must be contiguous and canonical."
            )
        stream.seek(zip64_eocd_offset)
        (
            zip64_signature,
            zip64_record_size,
            zip64_version_made_by,
            zip64_version_needed,
            zip64_disk,
            zip64_central_disk,
            zip64_disk_entries,
            zip64_total_entries,
            central_size,
            central_offset,
        ) = struct.unpack(
            "<4sQ2H2I4Q", _read_exact(stream, ZIP64_EOCD_SIZE, "ZIP64 EOCD")
        )
        if zip64_signature != ZIP64_EOCD_SIGNATURE or zip64_record_size != 44:
            raise RuntimeArchiveError("Runtime ZIP has a noncanonical ZIP64 EOCD.")
        if zip64_version_made_by != 45 or zip64_version_needed != 45:
            raise RuntimeArchiveError("Runtime ZIP has noncanonical ZIP64 versions.")
        if zip64_disk != 0 or zip64_central_disk != 0:
            raise RuntimeArchiveError("Multi-disk ZIP64 runtime archives are not supported.")
        if zip64_disk_entries != zip64_total_entries:
            raise RuntimeArchiveError("ZIP64 entry counts disagree across disks.")
        if disk_entry_count != min(zip64_disk_entries, ZIP_UINT16_MAX) or (
            total_entry_count != min(zip64_total_entries, ZIP_UINT16_MAX)
        ):
            raise RuntimeArchiveError("Classic and ZIP64 entry counts disagree.")
        if central_size_32 != min(central_size, ZIP_UINT32_MAX) or (
            central_offset_32 != min(central_offset, ZIP_UINT32_MAX)
        ):
            raise RuntimeArchiveError("Classic and ZIP64 directory bounds disagree.")
        entry_count = zip64_total_entries
        central_end = zip64_eocd_offset
        if not (
            entry_count > ZIP_UINT16_MAX
            or central_size > ZIP64_CANONICAL_LIMIT
            or central_offset > ZIP64_CANONICAL_LIMIT
        ):
            raise RuntimeArchiveError("Runtime ZIP has an unnecessary ZIP64 envelope.")
    else:
        if disk_entry_count != total_entry_count:
            raise RuntimeArchiveError("ZIP entry counts disagree across disks.")
        entry_count = total_entry_count
        central_size = central_size_32
        central_offset = central_offset_32
        central_end = eocd_offset

    if entry_count < 1 or entry_count > max_files:
        raise RuntimeArchiveError(
            f"The runtime ZIP contains {entry_count} entries; limit is {max_files}."
        )
    if central_size > MAX_CENTRAL_DIRECTORY_BYTES:
        raise RuntimeArchiveError(
            "The runtime ZIP central directory exceeds its byte limit."
        )
    if central_size < entry_count * ZIP_CENTRAL_HEADER_SIZE:
        raise RuntimeArchiveError("Runtime ZIP central-directory size is inconsistent.")
    if central_offset > artifact_size or central_size > artifact_size - central_offset:
        raise RuntimeArchiveError("Runtime ZIP central directory is outside the artifact.")
    if central_offset + central_size != central_end:
        raise RuntimeArchiveError(
            "Runtime ZIP has prepended, trailing, or gapped envelope content."
        )
    return int(entry_count), int(central_offset), int(central_size)


def _parse_central_directory(
    stream: BinaryIO,
    entry_count: int,
    central_offset: int,
    central_size: int,
    *,
    max_uncompressed_bytes: int,
) -> list[ZipEnvelopeRecord]:
    central_end = central_offset + central_size
    records: list[ZipEnvelopeRecord] = []
    total_uncompressed = 0
    stream.seek(central_offset)
    for index in range(entry_count):
        if stream.tell() + ZIP_CENTRAL_HEADER_SIZE > central_end:
            raise RuntimeArchiveError("Runtime ZIP central directory ended early.")
        (
            signature,
            version_made_by,
            version_needed,
            flags,
            compression_method,
            dos_time,
            dos_date,
            crc32,
            compressed_size_32,
            uncompressed_size_32,
            name_size,
            extra_size,
            comment_size,
            disk_start_16,
            internal_attributes,
            external_attributes,
            local_header_offset_32,
        ) = struct.unpack(
            "<4s6H3I5H2I",
            _read_exact(stream, ZIP_CENTRAL_HEADER_SIZE, "central header"),
        )
        if signature != ZIP_CENTRAL_HEADER_SIGNATURE:
            raise RuntimeArchiveError(
                f"Invalid central-directory signature at entry {index}."
            )
        variable_size = name_size + extra_size + comment_size
        if stream.tell() + variable_size > central_end:
            raise RuntimeArchiveError("Runtime ZIP central entry exceeds its directory.")
        raw_name = _read_exact(stream, name_size, "central filename")
        central_extra = _read_exact(stream, extra_size, "central extra field")
        comment = _read_exact(stream, comment_size, "central comment")
        label = f"central entry {index}"
        (
            compressed_size,
            uncompressed_size,
            local_header_offset,
            disk_start,
        ) = _resolve_central_zip64_values(
            compressed_size=compressed_size_32,
            uncompressed_size=uncompressed_size_32,
            local_header_offset=local_header_offset_32,
            disk_start=disk_start_16,
            extra=central_extra,
            label=label,
        )
        if disk_start != 0:
            raise RuntimeArchiveError("Multi-disk ZIP members are not supported.")
        encoding = "utf-8" if flags & 0x800 else "cp437"
        try:
            name = raw_name.decode(encoding, errors="strict")
        except UnicodeDecodeError as error:
            raise RuntimeArchiveError(
                f"ZIP member name is not valid {encoding}: entry {index}."
            ) from error
        total_uncompressed += uncompressed_size
        if total_uncompressed > max_uncompressed_bytes:
            raise RuntimeArchiveError(
                "The runtime ZIP exceeds the configured uncompressed-size limit."
            )
        records.append(
            ZipEnvelopeRecord(
                name=name,
                raw_name=raw_name,
                version_made_by=version_made_by,
                version_needed=version_needed,
                flags=flags,
                compression_method=compression_method,
                dos_time=dos_time,
                dos_date=dos_date,
                crc32=crc32,
                compressed_size=compressed_size,
                uncompressed_size=uncompressed_size,
                disk_start=disk_start,
                internal_attributes=internal_attributes,
                external_attributes=external_attributes,
                local_header_offset=local_header_offset,
                central_extra=central_extra,
                comment=comment,
            )
        )
    if stream.tell() != central_end:
        raise RuntimeArchiveError(
            "Runtime ZIP central directory has unparsed or trailing records."
        )
    return records


def _validate_local_headers(
    stream: BinaryIO,
    records: Sequence[ZipEnvelopeRecord],
    central_offset: int,
) -> None:
    expected_offset = 0
    for index, record in enumerate(records):
        if record.local_header_offset != expected_offset:
            raise RuntimeArchiveError(
                "Runtime ZIP local records overlap, contain gaps, or are out of order."
            )
        stream.seek(record.local_header_offset)
        (
            signature,
            version_needed,
            flags,
            compression_method,
            dos_time,
            dos_date,
            crc32,
            compressed_size_32,
            uncompressed_size_32,
            name_size,
            extra_size,
        ) = struct.unpack(
            "<4s5H3I2H",
            _read_exact(stream, ZIP_LOCAL_HEADER_SIZE, "local header"),
        )
        if signature != ZIP_LOCAL_HEADER_SIGNATURE:
            raise RuntimeArchiveError(f"Invalid local-header signature at entry {index}.")
        variable_size = name_size + extra_size
        if stream.tell() + variable_size > central_offset:
            raise RuntimeArchiveError("Runtime ZIP local header exceeds the data region.")
        raw_name = _read_exact(stream, name_size, "local filename")
        local_extra = _read_exact(stream, extra_size, "local extra field")
        if raw_name != record.raw_name:
            raise RuntimeArchiveError(
                f"Local and central ZIP filenames disagree for {record.name!r}."
            )
        if version_needed != record.version_needed:
            raise RuntimeArchiveError(
                f"Local and central ZIP versions disagree for {record.name!r}."
            )
        if flags & 0x1:
            raise RuntimeArchiveError(f"Encrypted ZIP member is not allowed: {record.name!r}.")
        if flags & 0x8:
            raise RuntimeArchiveError(
                f"ZIP data descriptors are not canonical for {record.name!r}."
            )
        if flags != record.flags:
            raise RuntimeArchiveError(
                f"Local and central ZIP flags disagree for {record.name!r}."
            )
        if compression_method != record.compression_method:
            raise RuntimeArchiveError(
                f"Local and central compression methods disagree for {record.name!r}."
            )
        if dos_time != record.dos_time or dos_date != record.dos_date:
            raise RuntimeArchiveError(
                f"Local and central ZIP timestamps disagree for {record.name!r}."
            )
        if crc32 != record.crc32:
            raise RuntimeArchiveError(
                f"Local and central ZIP CRC values disagree for {record.name!r}."
            )
        if (
            compressed_size_32 != ZIP_UINT32_MAX
            or uncompressed_size_32 != ZIP_UINT32_MAX
        ):
            raise RuntimeArchiveError(
                f"Local ZIP sizes are not in canonical ZIP64 form for {record.name!r}."
            )
        fields = _parse_extra_fields(local_extra, f"local entry {record.name!r}")
        expected_zip64 = struct.pack(
            "<QQ", record.uncompressed_size, record.compressed_size
        )
        if len(fields) != 1 or fields[0] != (0x0001, expected_zip64):
            raise RuntimeArchiveError(
                f"Local ZIP64 sizes disagree for {record.name!r}."
            )
        data_end = stream.tell() + record.compressed_size
        if data_end > central_offset:
            raise RuntimeArchiveError(
                f"Compressed ZIP data exceeds the local data region: {record.name!r}."
            )
        expected_offset = data_end
    if expected_offset != central_offset:
        raise RuntimeArchiveError(
            "Runtime ZIP has a gap or trailing content before its central directory."
        )


def _validate_zip_envelope(
    stream: BinaryIO,
    artifact_size: int,
    *,
    max_files: int,
    max_uncompressed_bytes: int,
) -> list[ZipEnvelopeRecord]:
    entry_count, central_offset, central_size = _parse_zip_directory_bounds(
        stream, artifact_size, max_files=max_files
    )
    records = _parse_central_directory(
        stream,
        entry_count,
        central_offset,
        central_size,
        max_uncompressed_bytes=max_uncompressed_bytes,
    )
    _validate_local_headers(stream, records, central_offset)
    stream.seek(0)
    return records


def _inspect_archive(
    archive: zipfile.ZipFile,
    envelope_records: Sequence[ZipEnvelopeRecord],
    archive_root: str,
    manifest_records: Sequence[FileRecord],
    *,
    max_files: int,
    max_uncompressed_bytes: int,
) -> list[tuple[zipfile.ZipInfo, FileRecord]]:
    infos = archive.infolist()
    if not infos:
        raise RuntimeArchiveError("The runtime ZIP is empty.")
    if archive.comment:
        raise RuntimeArchiveError("Normalized runtime ZIPs must not have a comment.")
    if len(infos) > max_files:
        raise RuntimeArchiveError(
            f"The runtime ZIP contains {len(infos)} entries; limit is {max_files}."
        )
    if len(infos) != len(envelope_records):
        raise RuntimeArchiveError(
            "ZIP parser entry count disagrees with the bounded central directory."
        )

    archive_records: list[tuple[zipfile.ZipInfo, FileRecord]] = []
    archive_paths: list[str] = []
    total_size = 0
    root_prefix = f"{archive_root}/"
    member_names: list[str] = []
    for info, envelope in zip(infos, envelope_records):
        raw_name = info.orig_filename
        if not isinstance(raw_name, str):
            raise RuntimeArchiveError("ZIP member names must be text.")
        _validate_relative_path(raw_name, archive_member=True)
        name = info.filename
        if raw_name != name:
            raise RuntimeArchiveError(
                f"ZIP parser changed an unsafe raw member name: {raw_name!r}."
            )
        parser_fields = (
            name,
            info.create_version | (info.create_system << 8),
            info.extract_version,
            info.flag_bits,
            info.compress_type,
            info.CRC,
            info.compress_size,
            info.file_size,
            info.volume,
            info.internal_attr,
            info.external_attr,
            info.header_offset,
            info.extra,
            info.comment,
        )
        envelope_fields = (
            envelope.name,
            envelope.version_made_by,
            envelope.version_needed,
            envelope.flags,
            envelope.compression_method,
            envelope.crc32,
            envelope.compressed_size,
            envelope.uncompressed_size,
            envelope.disk_start,
            envelope.internal_attributes,
            envelope.external_attributes,
            envelope.local_header_offset,
            envelope.central_extra,
            envelope.comment,
        )
        if parser_fields != envelope_fields:
            raise RuntimeArchiveError(
                f"ZIP parser interpretation disagrees with the bounded envelope for {name!r}."
            )
        _validate_relative_path(name, archive_member=True)
        member_names.append(name)
        if info.is_dir() or name.endswith("/"):
            raise RuntimeArchiveError(
                f"Normalized runtime ZIPs must not contain directory entries: {name!r}"
            )
        expected_flags = 0x800 if not name.isascii() else 0
        if info.flag_bits != expected_flags:
            raise RuntimeArchiveError(
                f"ZIP member flags are not normalized for {name!r}: {info.flag_bits:#x}"
            )
        if info.compress_type != zipfile.ZIP_DEFLATED:
            raise RuntimeArchiveError(
                f"Unexpected ZIP compression method for {name!r}: {info.compress_type}"
            )
        if info.date_time != FIXED_ZIP_TIMESTAMP:
            raise RuntimeArchiveError(
                f"ZIP member timestamp is not normalized for {name!r}."
            )
        if _zip_info_is_link(info):
            raise RuntimeArchiveError(
                f"Links and reparse points are not allowed in the runtime ZIP: {name!r}"
            )
        if info.create_system != 0 or info.external_attr != (0o100644 << 16):
            raise RuntimeArchiveError(
                f"ZIP member platform attributes are not normalized for {name!r}."
            )
        if (
            info.create_version != 45
            or info.extract_version != 45
            or info.internal_attr != 0
        ):
            raise RuntimeArchiveError(
                f"ZIP member metadata is not normalized for {name!r}."
            )
        if info.comment:
            raise RuntimeArchiveError(
                f"Normalized ZIP members must not have comments: {name!r}"
            )
        if not name.startswith(root_prefix):
            raise RuntimeArchiveError(
                f"ZIP member is outside the declared archive root {archive_root!r}: {name!r}"
            )
        relative = name[len(root_prefix) :]
        _validate_relative_path(relative, archive_member=True)
        archive_paths.append(relative)
        total_size += info.file_size
        if total_size > max_uncompressed_bytes:
            raise RuntimeArchiveError(
                "The runtime ZIP exceeds the configured uncompressed-size limit."
            )
        archive_records.append(
            (info, FileRecord(relative, info.file_size, ""))
        )

    if member_names != sorted(member_names):
        raise RuntimeArchiveError(
            "Runtime ZIP members must be stored in canonical ordinal path order."
        )

    _validate_case_and_parent_collisions(archive_paths)
    archive_records.sort(key=lambda item: item[1].path)
    expected_by_path = {record.path: record for record in manifest_records}
    if set(archive_paths) != set(expected_by_path):
        missing = sorted(set(expected_by_path) - set(archive_paths))
        unexpected = sorted(set(archive_paths) - set(expected_by_path))
        raise RuntimeArchiveError(
            "Runtime ZIP file set does not match the manifest "
            f"(missing={missing}, unexpected={unexpected})."
        )

    verified: list[tuple[zipfile.ZipInfo, FileRecord]] = []
    for info, archive_record in archive_records:
        expected = expected_by_path[archive_record.path]
        if info.file_size != expected.size:
            raise RuntimeArchiveError(
                f"Runtime file size mismatch for {expected.path}: "
                f"expected {expected.size}, found {info.file_size}."
            )
        with archive.open(info, mode="r") as stream:
            actual_hash, actual_size = _sha256_stream(stream)
        if actual_size != expected.size or actual_hash != expected.sha256:
            raise RuntimeArchiveError(
                f"Runtime file checksum mismatch for {expected.path}."
            )
        verified.append((info, expected))
    return verified


def _ensure_no_reparse_ancestors(path: Path) -> None:
    existing = path.absolute()
    while True:
        if os.path.lexists(existing):
            file_stat = existing.lstat()
            if stat.S_ISLNK(file_stat.st_mode) or _is_reparse_point(file_stat):
                raise RuntimeArchiveError(
                    f"Extraction path cannot traverse a link or reparse point: {existing}"
                )
        parent = existing.parent
        if parent == existing:
            break
        existing = parent


def _extract_verified(
    archive: zipfile.ZipFile,
    verified: Sequence[tuple[zipfile.ZipInfo, FileRecord]],
    archive_root: str,
    destination: Path,
) -> None:
    # abspath is deliberately lexical. resolve() would follow an existing
    # junction or symlink before the no-reparse validation below could reject
    # it.
    destination = Path(os.path.abspath(os.fspath(destination)))
    _ensure_no_reparse_ancestors(destination)
    if os.path.lexists(destination):
        raise RuntimeArchiveError(
            f"Extraction destination must not already exist: {destination}"
        )
    _ensure_no_reparse_ancestors(destination.parent)
    destination.parent.mkdir(parents=True, exist_ok=True)
    _ensure_no_reparse_ancestors(destination.parent)
    temporary = _new_extraction_path(destination)
    if os.path.lexists(temporary):
        raise RuntimeArchiveError(f"Temporary extraction path already exists: {temporary}")
    temporary.mkdir()
    try:
        for info, record in verified:
            relative_parts = _validate_relative_path(record.path)
            target = temporary.joinpath(archive_root, *relative_parts)
            if not _path_is_within(target.absolute(), temporary.absolute()):
                raise RuntimeArchiveError(
                    f"Runtime member escapes the extraction directory: {record.path}"
                )
            target.parent.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256()
            size = 0
            with archive.open(info, mode="r") as source, target.open("xb") as output:
                while True:
                    chunk = source.read(COPY_BUFFER_BYTES)
                    if not chunk:
                        break
                    output.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
            if size != record.size or digest.hexdigest() != record.sha256:
                raise RuntimeArchiveError(
                    f"Extracted runtime file did not retain its checksum: {record.path}"
                )
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def _validate_trusted_expectations(
    manifest: Mapping[str, Any], expectations: Mapping[str, Any] | None
) -> None:
    if expectations is None:
        raise RuntimeArchiveError(
            "Trusted release expectations are required for runtime verification."
        )
    missing = sorted(TRUSTED_EXPECTATION_KEYS - set(expectations))
    unexpected = sorted(set(expectations) - TRUSTED_EXPECTATION_KEYS)
    if missing or unexpected:
        raise RuntimeArchiveError(
            "Trusted release expectations are incomplete "
            f"(missing={missing}, unexpected={unexpected})."
        )
    if expectations["cleanSource"] is not True:
        raise RuntimeArchiveError("Trusted expectations must require a clean source.")

    product = _required_mapping(manifest["product"], "product")
    artifact = _required_mapping(manifest["artifact"], "artifact")
    source = _required_mapping(manifest["source"], "source")
    kwiken = _required_mapping(source["kwiken"], "source.kwiken")
    chromium = _required_mapping(source["chromium"], "source.chromium")
    dependency_state = _validate_dependency_state(source["dependencyState"])
    gn_args = _required_mapping(source["gnArgs"], "source.gnArgs")
    native_build = _required_mapping(manifest["nativeBuild"], "nativeBuild")
    invocation = _required_mapping(
        native_build["buildInvocation"], "nativeBuild.buildInvocation"
    )
    toolchain = _required_mapping(native_build["toolchain"], "nativeBuild.toolchain")
    actual_fields = {
        "appliedSourceTreeSha256": source["appliedSourceTreeSha256"],
        "artifactSha256": artifact["sha256"],
        "artifactSize": artifact["size"],
        "buildCommandLine": invocation["commandLine"],
        "buildJobs": invocation["jobs"],
        "buildReceiptSha256": native_build["buildReceiptSha256"],
        "cipdClientSha256": toolchain["cipdClientSha256"],
        "cipdClientVersion": toolchain["cipdClientVersion"],
        "chrome7zSha256": native_build["chrome7zSha256"],
        "chromeExeSha256": native_build["chromeExeSha256"],
        "chromiumRevision": chromium["revision"],
        "cleanSource": not kwiken["dirty"],
        "depotToolsRevision": source["depotToolsRevision"],
        "dependencyStateTreeSha256": dependency_state["treeSha256"],
        "gnArgsSha256": gn_args["sha256"],
        "kwikenRevision": kwiken["revision"],
        "miniInstallerSha256": native_build["miniInstallerSha256"],
        "outputDirectory": native_build["outputDirectory"],
        "packageRevision": product["packageRevision"],
        "pythonPath": toolchain["pythonPath"],
        "pythonCipdInstance": toolchain["pythonCipdInstance"],
        "pythonCipdPackage": toolchain["pythonCipdPackage"],
        "pythonCipdVersion": toolchain["pythonCipdVersion"],
        "pythonRuntimeTreeSha256": toolchain["pythonRuntimeTreeSha256"],
        "pythonSha256": toolchain["pythonSha256"],
        "pythonVersion": toolchain["python"],
        "releaseVersion": product["releaseVersion"],
        "sevenZipPath": toolchain["sevenZipPath"],
        "sevenZipSha256": toolchain["sevenZipSha256"],
        "version": product["version"],
        "visualStudioVersion": toolchain["visualStudio"],
        "windowsDebuggerVersion": toolchain["windowsDebugger"],
        "windowsSdkVersion": toolchain["windowsSdk"],
    }
    for key, expected in expectations.items():
        if key in ("cleanSource", "sourceInputs"):
            continue
        if actual_fields[key] != expected:
            raise RuntimeArchiveError(
                f"Runtime provenance mismatch for {key}: "
                f"expected {expected!r}, found {actual_fields[key]!r}."
            )
    if actual_fields["cleanSource"] is not True:
        raise RuntimeArchiveError("Runtime provenance reports a dirty Kwiken source.")

    expected_inputs = expectations["sourceInputs"]
    if not isinstance(expected_inputs, list) or not expected_inputs:
        raise RuntimeArchiveError(
            "Trusted sourceInputs must be a non-empty array."
        )
    actual_inputs = _required_mapping(source["patchSet"], "source.patchSet")["inputs"]
    expected_pairs: list[tuple[str, str]] = []
    for index, item in enumerate(expected_inputs):
        item = _required_mapping(item, f"expectations.sourceInputs[{index}]")
        path = _required_string(item.get("path"), f"expectations.sourceInputs[{index}].path")
        _validate_relative_path(path)
        file_hash = _require_sha256(
            item.get("sha256"), f"expectations.sourceInputs[{index}].sha256"
        )
        expected_pairs.append((path, file_hash))
    actual_pairs = sorted((item["path"], item["sha256"]) for item in actual_inputs)
    if sorted(expected_pairs) != actual_pairs:
        raise RuntimeArchiveError(
            "Runtime provenance patch-set inputs do not match the expected inputs."
        )


def verify_runtime_archive(
    archive_path: Path,
    manifest_path: Path,
    *,
    extract_to: Path | None = None,
    expectations: Mapping[str, Any] | None = None,
    max_files: int = DEFAULT_MAX_FILES,
    max_uncompressed_bytes: int = DEFAULT_MAX_UNCOMPRESSED_BYTES,
    max_archive_bytes: int = DEFAULT_MAX_ARCHIVE_BYTES,
) -> Mapping[str, Any]:
    """Verify archive layout, every file, provenance, and optionally extract it."""

    if max_files < 1 or max_uncompressed_bytes < 1 or max_archive_bytes < 1:
        raise RuntimeArchiveError("Verification resource limits must be positive.")

    archive_path = archive_path.absolute()
    manifest_path = manifest_path.absolute()
    _ensure_no_reparse_ancestors(archive_path.parent)
    _ensure_no_reparse_ancestors(manifest_path.parent)
    _assert_regular_file(archive_path)
    _assert_regular_file(manifest_path)
    manifest = _load_manifest(manifest_path)
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise RuntimeArchiveError(
            f"Unsupported runtime manifest schema: {manifest.get('schemaVersion')!r}"
        )

    provenance = {
        "nativeBuild": manifest.get("nativeBuild"),
        "product": manifest.get("product"),
        "source": manifest.get("source"),
        "target": manifest.get("target"),
    }
    _validate_provenance(provenance)

    artifact = _required_mapping(manifest.get("artifact"), "artifact")
    if artifact.get("format") != "zip":
        raise RuntimeArchiveError("artifact.format must be zip.")
    if artifact.get("fileName") != archive_path.name:
        raise RuntimeArchiveError(
            "Runtime archive filename does not match artifact.fileName."
        )
    artifact_size = artifact.get("size")
    if (
        not isinstance(artifact_size, int)
        or isinstance(artifact_size, bool)
        or artifact_size < 0
    ):
        raise RuntimeArchiveError("artifact.size must be a non-negative integer.")
    expected_archive_hash = _require_sha256(artifact.get("sha256"), "artifact.sha256")

    product = _required_mapping(manifest["product"], "product")
    source = _required_mapping(manifest["source"], "source")
    runtime = _required_mapping(manifest.get("runtime"), "runtime")
    archive_root = _required_string(runtime.get("archiveRoot"), "runtime.archiveRoot")
    _validate_archive_root(archive_root)
    expected_archive_root = f"Kwiken-runtime-{product['releaseVersion']}"
    if archive_root != expected_archive_root:
        raise RuntimeArchiveError(
            f"runtime.archiveRoot must be {expected_archive_root}."
        )
    records = _manifest_records(runtime, max_files=max_files)
    if runtime.get("fileCount") != len(records):
        raise RuntimeArchiveError("runtime.fileCount does not match runtime.files.")
    expected_tree_hash = _require_sha256(runtime.get("treeSha256"), "runtime.treeSha256")
    if tree_sha256(records) != expected_tree_hash:
        raise RuntimeArchiveError("runtime.treeSha256 does not match runtime.files.")

    required_keys = {
        _canonical_case_key("chrome.exe"),
        _canonical_case_key("chrome_proxy.exe"),
        _canonical_case_key(f"{product['version']}/chrome.dll"),
        _canonical_case_key(f"{product['version']}/resources.pak"),
        _canonical_case_key(f"{product['version']}/Locales/en-US.pak"),
    }
    manifest_keys = {_canonical_case_key(record.path) for record in records}
    missing_required = sorted(required_keys - manifest_keys)
    if missing_required:
        raise RuntimeArchiveError(
            f"Runtime manifest is missing critical Chromium files: {missing_required}"
        )
    chrome_record = next(
        record
        for record in records
        if _canonical_case_key(record.path) == _canonical_case_key("chrome.exe")
    )
    native_build = _required_mapping(manifest["nativeBuild"], "nativeBuild")
    if chrome_record.sha256 != native_build["chromeExeSha256"]:
        raise RuntimeArchiveError(
            "nativeBuild.chromeExeSha256 does not match runtime chrome.exe."
        )
    for record in records:
        first_component = record.path.split("/", 1)[0]
        if VERSION_PATTERN.fullmatch(first_component) and first_component != product["version"]:
            raise RuntimeArchiveError(
                f"Runtime contains an unexpected version directory: {first_component}"
            )

    _validate_trusted_expectations(manifest, expectations)

    try:
        with archive_path.open("rb") as archive_source:
            initial_stat = os.fstat(archive_source.fileno())
            if not stat.S_ISREG(initial_stat.st_mode):
                raise RuntimeArchiveError(
                    f"Runtime archive is not a regular file: {archive_path}"
                )
            if initial_stat.st_size != artifact_size:
                raise RuntimeArchiveError(
                    "Runtime archive size does not match the manifest."
                )
            if artifact_size > max_archive_bytes:
                raise RuntimeArchiveError(
                    "Runtime archive exceeds the configured compressed-size limit."
                )
            with tempfile.TemporaryFile(
                mode="w+b", dir=archive_path.parent, prefix=".kwiken-verify-"
            ) as archive_stream:
                digest = hashlib.sha256()
                remaining = artifact_size
                while remaining:
                    chunk = archive_source.read(min(COPY_BUFFER_BYTES, remaining))
                    if not chunk:
                        raise RuntimeArchiveError(
                            "Runtime archive ended while it was being snapshotted."
                        )
                    archive_stream.write(chunk)
                    digest.update(chunk)
                    remaining -= len(chunk)
                actual_archive_hash = digest.hexdigest()
                final_stat = os.fstat(archive_source.fileno())
                initial_identity = (
                    initial_stat.st_dev,
                    initial_stat.st_ino,
                    initial_stat.st_size,
                    initial_stat.st_mtime_ns,
                )
                final_identity = (
                    final_stat.st_dev,
                    final_stat.st_ino,
                    final_stat.st_size,
                    final_stat.st_mtime_ns,
                )
                if final_identity != initial_identity:
                    raise RuntimeArchiveError(
                        "Runtime archive changed while it was being snapshotted."
                    )
                if actual_archive_hash != expected_archive_hash:
                    raise RuntimeArchiveError(
                        "Runtime archive checksum does not match the manifest."
                    )
                archive_stream.seek(0)
                envelope_records = _validate_zip_envelope(
                    archive_stream,
                    artifact_size,
                    max_files=max_files,
                    max_uncompressed_bytes=max_uncompressed_bytes,
                )
                with zipfile.ZipFile(archive_stream, mode="r") as archive:
                    verified = _inspect_archive(
                        archive,
                        envelope_records,
                        archive_root,
                        records,
                        max_files=max_files,
                        max_uncompressed_bytes=max_uncompressed_bytes,
                    )
                    if extract_to is not None:
                        _extract_verified(archive, verified, archive_root, extract_to)
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        if isinstance(error, RuntimeArchiveError):
            raise
        raise RuntimeArchiveError(f"Could not verify runtime ZIP: {error}") from error
    return manifest


def _parse_source_input(value: str) -> dict[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("source inputs must use PATH=SHA256")
    path, file_hash = value.rsplit("=", 1)
    try:
        _validate_relative_path(path)
        _require_sha256(file_hash, "source input hash")
    except RuntimeArchiveError as error:
        raise argparse.ArgumentTypeError(str(error)) from error
    return {"path": path, "sha256": file_hash}


def _pack_command(arguments: argparse.Namespace) -> None:
    dependency_state = _load_dependency_state_manifest(
        Path(arguments.dependency_state_manifest)
    )
    native_build = _with_native_build_receipt(
        {
            "buildInvocation": {
                "commandLine": arguments.build_command_line,
                "completed": True,
                "jobs": arguments.build_jobs,
                "targets": ["chrome", "mini_installer"],
            },
            "buildKind": BUILD_KIND,
            "chrome7zSha256": arguments.chrome_7z_sha256,
            "chromeExeSha256": arguments.chrome_exe_sha256,
            "miniInstallerSha256": arguments.mini_installer_sha256,
            "outputDirectory": arguments.output_directory,
            "sourceBinding": {
                "appliedSourceTreeSha256": arguments.source_delta_sha256,
                "chromiumRevision": arguments.chromium_revision,
                "depotToolsRevision": arguments.depot_tools_revision,
                "dependencyStateTreeSha256": dependency_state["treeSha256"],
                "gnArgsSha256": arguments.gn_args_sha256,
            },
            "toolchain": {
                "cipdClientSha256": arguments.cipd_client_sha256,
                "cipdClientVersion": arguments.cipd_client_version,
                "python": arguments.python_version,
                "pythonCipdInstance": arguments.python_cipd_instance,
                "pythonCipdPackage": arguments.python_cipd_package,
                "pythonCipdVersion": arguments.python_cipd_version,
                "pythonPath": arguments.python_path,
                "pythonRuntimeTreeSha256": arguments.python_runtime_tree_sha256,
                "pythonSha256": arguments.python_sha256,
                "sevenZipPath": arguments.seven_zip_path,
                "sevenZipSha256": arguments.seven_zip_sha256,
                "visualStudio": arguments.visual_studio_version,
                "windowsDebugger": arguments.windows_debugger_version,
                "windowsSdk": arguments.windows_sdk_version,
            },
        }
    )
    provenance = {
        "nativeBuild": native_build,
        "product": {
            "name": "Kwiken",
            "packageRevision": arguments.package_revision,
            "releaseVersion": arguments.release_version,
            "version": arguments.version,
        },
        "source": {
            "appliedSourceTreeSha256": arguments.source_delta_sha256,
            "chromium": {
                "repository": "https://chromium.googlesource.com/chromium/src",
                "revision": arguments.chromium_revision,
                "version": arguments.version,
            },
            "depotToolsRevision": arguments.depot_tools_revision,
            "dependencyState": dependency_state,
            "gnArgs": {
                "path": "chromium-fork/args.gn",
                "sha256": arguments.gn_args_sha256,
            },
            "kwiken": {
                "dirty": False,
                "repository": "https://github.com/Mschmitt478/kwiken",
                "revision": arguments.kwiken_revision,
            },
            "patchSet": {"inputs": arguments.source_input},
        },
        "target": {"arch": "x64", "os": "windows"},
    }
    create_runtime_archive(
        Path(arguments.source),
        Path(arguments.archive),
        Path(arguments.manifest),
        arguments.archive_root,
        provenance,
        arguments.require,
    )


def _verify_command(arguments: argparse.Namespace) -> None:
    expected_native_build = _with_native_build_receipt(
        {
            "buildInvocation": {
                "commandLine": arguments.expect_build_command_line,
                "completed": True,
                "jobs": arguments.expect_build_jobs,
                "targets": ["chrome", "mini_installer"],
            },
            "buildKind": BUILD_KIND,
            "chrome7zSha256": arguments.expect_chrome_7z_sha256,
            "chromeExeSha256": arguments.expect_chrome_exe_sha256,
            "miniInstallerSha256": arguments.expect_mini_installer_sha256,
            "outputDirectory": arguments.expect_output_directory,
            "sourceBinding": {
                "appliedSourceTreeSha256": arguments.expect_source_delta_sha256,
                "chromiumRevision": arguments.expect_chromium_revision,
                "depotToolsRevision": arguments.expect_depot_tools_revision,
                "dependencyStateTreeSha256": (
                    arguments.expect_dependency_state_tree_sha256
                ),
                "gnArgsSha256": arguments.expect_gn_args_sha256,
            },
            "toolchain": {
                "cipdClientSha256": arguments.expect_cipd_client_sha256,
                "cipdClientVersion": arguments.expect_cipd_client_version,
                "python": arguments.expect_python_version,
                "pythonCipdInstance": arguments.expect_python_cipd_instance,
                "pythonCipdPackage": arguments.expect_python_cipd_package,
                "pythonCipdVersion": arguments.expect_python_cipd_version,
                "pythonPath": arguments.expect_python_path,
                "pythonRuntimeTreeSha256": arguments.expect_python_runtime_tree_sha256,
                "pythonSha256": arguments.expect_python_sha256,
                "sevenZipPath": arguments.expect_seven_zip_path,
                "sevenZipSha256": arguments.expect_seven_zip_sha256,
                "visualStudio": arguments.expect_visual_studio_version,
                "windowsDebugger": arguments.expect_windows_debugger_version,
                "windowsSdk": arguments.expect_windows_sdk_version,
            },
        }
    )
    expectations = {
        "appliedSourceTreeSha256": arguments.expect_source_delta_sha256,
        "artifactSha256": arguments.expect_artifact_sha256,
        "artifactSize": arguments.expect_artifact_size,
        "buildCommandLine": arguments.expect_build_command_line,
        "buildJobs": arguments.expect_build_jobs,
        "buildReceiptSha256": expected_native_build["buildReceiptSha256"],
        "cipdClientSha256": arguments.expect_cipd_client_sha256,
        "cipdClientVersion": arguments.expect_cipd_client_version,
        "chrome7zSha256": arguments.expect_chrome_7z_sha256,
        "chromeExeSha256": arguments.expect_chrome_exe_sha256,
        "chromiumRevision": arguments.expect_chromium_revision,
        "cleanSource": True,
        "depotToolsRevision": arguments.expect_depot_tools_revision,
        "dependencyStateTreeSha256": (
            arguments.expect_dependency_state_tree_sha256
        ),
        "gnArgsSha256": arguments.expect_gn_args_sha256,
        "kwikenRevision": arguments.expect_kwiken_revision,
        "miniInstallerSha256": arguments.expect_mini_installer_sha256,
        "outputDirectory": arguments.expect_output_directory,
        "packageRevision": arguments.expect_package_revision,
        "pythonPath": arguments.expect_python_path,
        "pythonCipdInstance": arguments.expect_python_cipd_instance,
        "pythonCipdPackage": arguments.expect_python_cipd_package,
        "pythonCipdVersion": arguments.expect_python_cipd_version,
        "pythonRuntimeTreeSha256": arguments.expect_python_runtime_tree_sha256,
        "pythonSha256": arguments.expect_python_sha256,
        "pythonVersion": arguments.expect_python_version,
        "releaseVersion": arguments.expect_release_version,
        "sevenZipPath": arguments.expect_seven_zip_path,
        "sevenZipSha256": arguments.expect_seven_zip_sha256,
        "sourceInputs": arguments.expect_source_input,
        "version": arguments.expect_version,
        "visualStudioVersion": arguments.expect_visual_studio_version,
        "windowsDebuggerVersion": arguments.expect_windows_debugger_version,
        "windowsSdkVersion": arguments.expect_windows_sdk_version,
    }
    verify_runtime_archive(
        Path(arguments.archive),
        Path(arguments.manifest),
        extract_to=Path(arguments.extract_to) if arguments.extract_to else None,
        expectations=expectations,
        max_files=arguments.max_files,
        max_uncompressed_bytes=arguments.max_uncompressed_bytes,
        max_archive_bytes=arguments.max_archive_bytes,
    )


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    pack = subparsers.add_parser("pack", help="Create a normalized runtime ZIP.")
    pack.add_argument("--source", required=True)
    pack.add_argument("--archive", required=True)
    pack.add_argument("--manifest", required=True)
    pack.add_argument("--archive-root", required=True)
    pack.add_argument("--version", required=True)
    pack.add_argument("--package-revision", required=True)
    pack.add_argument("--release-version", required=True)
    pack.add_argument("--kwiken-revision", required=True)
    pack.add_argument("--chromium-revision", required=True)
    pack.add_argument("--depot-tools-revision", required=True)
    pack.add_argument("--source-delta-sha256", required=True)
    pack.add_argument("--dependency-state-manifest", required=True)
    pack.add_argument("--gn-args-sha256", required=True)
    pack.add_argument("--chrome-7z-sha256", required=True)
    pack.add_argument("--chrome-exe-sha256", required=True)
    pack.add_argument("--mini-installer-sha256", required=True)
    pack.add_argument("--build-command-line", required=True)
    pack.add_argument("--build-jobs", required=True, type=int)
    pack.add_argument("--visual-studio-version", required=True)
    pack.add_argument("--windows-sdk-version", required=True)
    pack.add_argument("--windows-debugger-version", required=True)
    pack.add_argument("--python-version", required=True)
    pack.add_argument("--python-cipd-package", required=True)
    pack.add_argument("--python-cipd-version", required=True)
    pack.add_argument("--python-cipd-instance", required=True)
    pack.add_argument("--cipd-client-version", required=True)
    pack.add_argument("--cipd-client-sha256", required=True)
    pack.add_argument("--python-path", required=True)
    pack.add_argument("--python-runtime-tree-sha256", required=True)
    pack.add_argument("--python-sha256", required=True)
    pack.add_argument("--seven-zip-path", required=True)
    pack.add_argument("--seven-zip-sha256", required=True)
    pack.add_argument("--output-directory", required=True)
    pack.add_argument(
        "--source-input", action="append", type=_parse_source_input, required=True
    )
    pack.add_argument("--require", action="append", default=[])
    pack.set_defaults(handler=_pack_command)

    verify = subparsers.add_parser(
        "verify", help="Verify provenance, contents, and optionally extract."
    )
    verify.add_argument("--archive", required=True)
    verify.add_argument("--manifest", required=True)
    verify.add_argument("--extract-to")
    verify.add_argument("--expect-version", required=True)
    verify.add_argument("--expect-package-revision", required=True)
    verify.add_argument("--expect-release-version", required=True)
    verify.add_argument("--expect-kwiken-revision", required=True)
    verify.add_argument("--expect-chromium-revision", required=True)
    verify.add_argument("--expect-depot-tools-revision", required=True)
    verify.add_argument("--expect-source-delta-sha256", required=True)
    verify.add_argument("--expect-dependency-state-tree-sha256", required=True)
    verify.add_argument("--expect-gn-args-sha256", required=True)
    verify.add_argument("--expect-artifact-sha256", required=True)
    verify.add_argument("--expect-artifact-size", required=True, type=int)
    verify.add_argument("--expect-chrome-7z-sha256", required=True)
    verify.add_argument("--expect-chrome-exe-sha256", required=True)
    verify.add_argument("--expect-mini-installer-sha256", required=True)
    verify.add_argument("--expect-build-command-line", required=True)
    verify.add_argument("--expect-build-jobs", required=True, type=int)
    verify.add_argument("--expect-output-directory", required=True)
    verify.add_argument("--expect-visual-studio-version", required=True)
    verify.add_argument("--expect-windows-sdk-version", required=True)
    verify.add_argument("--expect-windows-debugger-version", required=True)
    verify.add_argument("--expect-python-version", required=True)
    verify.add_argument("--expect-python-cipd-package", required=True)
    verify.add_argument("--expect-python-cipd-version", required=True)
    verify.add_argument("--expect-python-cipd-instance", required=True)
    verify.add_argument("--expect-cipd-client-version", required=True)
    verify.add_argument("--expect-cipd-client-sha256", required=True)
    verify.add_argument("--expect-python-path", required=True)
    verify.add_argument("--expect-python-runtime-tree-sha256", required=True)
    verify.add_argument("--expect-python-sha256", required=True)
    verify.add_argument("--expect-seven-zip-path", required=True)
    verify.add_argument("--expect-seven-zip-sha256", required=True)
    verify.add_argument(
        "--expect-source-input",
        action="append",
        type=_parse_source_input,
        required=True,
    )
    verify.add_argument("--require-clean-source", action="store_true", required=True)
    verify.add_argument("--max-files", type=int, default=DEFAULT_MAX_FILES)
    verify.add_argument(
        "--max-archive-bytes",
        type=int,
        default=DEFAULT_MAX_ARCHIVE_BYTES,
    )
    verify.add_argument(
        "--max-uncompressed-bytes",
        type=int,
        default=DEFAULT_MAX_UNCOMPRESSED_BYTES,
    )
    verify.set_defaults(handler=_verify_command)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_argument_parser()
    arguments = parser.parse_args(argv)
    try:
        arguments.handler(arguments)
    except RuntimeArchiveError as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
