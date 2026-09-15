#!/usr/bin/env python3
"""Safely extract and validate a full OpenClaw backup in fresh staging."""

from __future__ import annotations

import argparse
import copy
import itertools
import json
import os
import posixpath
import shutil
import sqlite3
import stat
import subprocess
import sys
import tarfile
from contextlib import contextmanager
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO

MAX_MANIFEST_BYTES = 1024 * 1024


class ValidationError(Exception):
    """Raised when a backup cannot be accepted as a staged restore."""


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Validate and extract a full OpenClaw backup outside live state."
    )
    parser.add_argument("archive", type=Path, help="OpenClaw .tar.gz backup archive")
    parser.add_argument(
        "--staging-dir",
        required=True,
        type=Path,
        help="Fresh directory to create for the staged restore",
    )
    parser.add_argument(
        "--openclaw-bin",
        default="openclaw",
        help="OpenClaw executable used for vendor archive verification",
    )
    parser.add_argument(
        "--system-package-root",
        default="/usr/lib/node_modules/openclaw",
        type=Path,
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--live-state-root",
        default="/home/openclaw/.openclaw",
        type=Path,
        help=argparse.SUPPRESS,
    )
    return parser.parse_args()


def run_vendor_verification(archive_fd: int, openclaw_bin: str) -> None:
    """Require OpenClaw's manifest and archive-layout verification to pass."""
    try:
        result = subprocess.run(
            [openclaw_bin, "backup", "verify", f"/proc/self/fd/{archive_fd}"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            pass_fds=(archive_fd,),
        )
    except OSError as exc:
        raise ValidationError("OpenClaw backup verifier could not be executed") from exc
    if result.returncode != 0:
        raise ValidationError("OpenClaw backup verification failed")


@contextmanager
def open_archive_stream(archive_fd: int) -> BinaryIO:
    """Open an independent stream for the inode pinned by archive_fd."""
    stream_fd = os.open(f"/proc/self/fd/{archive_fd}", os.O_RDONLY)
    with os.fdopen(stream_fd, "rb") as stream:
        yield stream


def read_manifest(archive_fd: int) -> dict[str, Any]:
    """Read the bounded root manifest without retaining the archive index."""
    manifest = None
    with open_archive_stream(archive_fd) as stream:
        with tarfile.open(fileobj=stream, mode="r|gz") as bundle:
            for member in bundle:
                member_path = PurePosixPath(member.name)
                if member_path.name == "manifest.json" and len(member_path.parts) == 2:
                    if member.size > MAX_MANIFEST_BYTES:
                        raise ValidationError("backup manifest exceeds the size limit")
                    manifest_file = bundle.extractfile(member)
                    if manifest_file is None:
                        raise ValidationError("backup manifest is not a regular file")
                    try:
                        manifest = json.load(manifest_file)
                    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                        raise ValidationError(
                            "backup manifest is not valid JSON"
                        ) from exc
                    break
                bundle.members.clear()
    if not isinstance(manifest, dict):
        raise ValidationError("archive is missing a valid root manifest")
    return manifest


def normalized_source_path(value: Any, label: str) -> Path:
    """Require a normalized absolute source path from the manifest."""
    if not isinstance(value, str) or not value.startswith("/"):
        raise ValidationError(f"manifest {label} must be an absolute path")
    if ".." in PurePosixPath(value).parts or os.path.normpath(value) != value:
        raise ValidationError(f"manifest {label} is not normalized")
    return Path(value)


def normalized_archive_path(value: Any, archive_root: str, label: str) -> PurePosixPath:
    """Require a traversal-free payload path under the declared archive root."""
    if not isinstance(value, str) or value.startswith("/") or "\\" in value:
        raise ValidationError(f"manifest {label} must be a relative archive path")
    path = PurePosixPath(value)
    if "." in path.parts or ".." in path.parts or str(path) != value:
        raise ValidationError(f"manifest {label} is not normalized")
    payload_root = PurePosixPath(archive_root) / "payload"
    if not path.is_relative_to(payload_root):
        raise ValidationError(f"manifest {label} is outside the payload root")
    return path


def require_full_backup(
    manifest: dict[str, Any], live_state_root: Path
) -> dict[str, str]:
    """Require a full state backup and return its state asset."""
    archive_root = manifest.get("archiveRoot")
    if (
        not isinstance(archive_root, str)
        or len(PurePosixPath(archive_root).parts) != 1
        or str(PurePosixPath(archive_root)) != archive_root
    ):
        raise ValidationError("manifest archive root is invalid")
    options = manifest.get("options")
    if (
        not isinstance(options, dict)
        or options.get("onlyConfig") is not False
        or options.get("includeWorkspace") is not True
    ):
        raise ValidationError("restore rehearsal requires a full backup")

    assets = manifest.get("assets")
    if not isinstance(assets, list) or not all(
        isinstance(asset, dict) for asset in assets
    ):
        raise ValidationError("backup manifest assets are invalid")
    for asset in assets:
        normalized_source_path(asset.get("sourcePath"), "asset source path")
        normalized_archive_path(asset.get("archivePath"), archive_root, "asset path")
    state_assets = [
        asset
        for asset in assets
        if isinstance(asset, dict) and asset.get("kind") == "state"
    ]
    if len(state_assets) != 1:
        raise ValidationError("full backup must contain exactly one state asset")
    state_asset = state_assets[0]
    source_path = state_asset.get("sourcePath")
    archive_path = state_asset.get("archivePath")
    trusted_state_root = live_state_root.resolve(strict=True)
    if Path(source_path).resolve(strict=False) != trusted_state_root:
        raise ValidationError("manifest state asset does not match live state root")

    paths = manifest.get("paths")
    if not isinstance(paths, dict):
        raise ValidationError("backup manifest paths are invalid")
    for label in ("configPath", "oauthDir"):
        normalized_source_path(paths.get(label), label)
    workspace_dirs = paths.get("workspaceDirs")
    if not isinstance(workspace_dirs, list) or not workspace_dirs:
        raise ValidationError("full backup declares no workspaces")
    for workspace in workspace_dirs:
        normalized_source_path(workspace, "workspace path")

    skipped = manifest.get("skipped", [])
    if not isinstance(skipped, list) or any(
        isinstance(item, dict) and item.get("reason") == "missing" for item in skipped
    ):
        raise ValidationError("full backup has missing planned assets")
    return {"sourcePath": source_path, "archivePath": archive_path}


def paths_overlap(left: Path, right: Path) -> bool:
    """Return whether either resolved path contains the other."""
    return left == right or left.is_relative_to(right) or right.is_relative_to(left)


def validate_staging_path(staging: Path, live_state_root: Path) -> Path:
    """Require a new absolute staging path isolated from live state."""
    if not staging.is_absolute():
        raise ValidationError("staging directory must be an absolute path")
    resolved_staging = staging.resolve(strict=False)
    if staging.exists():
        raise ValidationError("staging directory must not already exist")
    resolved_source = live_state_root.resolve(strict=True)
    if paths_overlap(resolved_staging, resolved_source):
        raise ValidationError("staging directory must not overlap live state")
    return resolved_staging


def map_source_to_archive(
    source_path: str, assets: list[dict[str, Any]]
) -> PurePosixPath | None:
    """Map an absolute source path into the most specific declared asset."""
    source = Path(source_path)
    candidates = []
    for asset in assets:
        asset_source_raw = asset.get("sourcePath")
        archive_path = asset.get("archivePath")
        if not isinstance(asset_source_raw, str) or not isinstance(archive_path, str):
            continue
        asset_source = Path(asset_source_raw)
        if source == asset_source or source.is_relative_to(asset_source):
            candidates.append(
                (
                    len(asset_source.parts),
                    PurePosixPath(archive_path) / source.relative_to(asset_source),
                )
            )
    if not candidates:
        return None
    return max(candidates, key=lambda candidate: candidate[0])[1]


def remap_internal_link(
    member: tarfile.TarInfo, manifest: dict[str, Any], staging: Path
) -> tarfile.TarInfo | None:
    """Rewrite an absolute link to a declared asset as a contained relative link."""
    assets = manifest.get("assets")
    if not member.issym() or not isinstance(assets, list):
        return None
    mapped_target = map_source_to_archive(member.linkname, assets)
    if mapped_target is None:
        return None
    remapped = copy.copy(member)
    remapped.linkname = posixpath.relpath(
        str(mapped_target), posixpath.dirname(member.name)
    )
    try:
        return tarfile.data_filter(remapped, str(staging))
    except (OSError, tarfile.TarError) as exc:
        raise ValidationError("internal archive link could not be contained") from exc


def is_reconstructable_package_link(
    member: tarfile.TarInfo, system_package_root: Path
) -> bool:
    """Return whether an absolute link resolves inside the installed core package."""
    if not member.issym() or not Path(member.linkname).is_absolute():
        return False
    try:
        package_root = system_package_root.resolve(strict=True)
        target = Path(member.linkname).resolve(strict=True)
    except OSError:
        return False
    return target == package_root or target.is_relative_to(package_root)


def extract_archive(
    archive_fd: int,
    staging: Path,
    manifest: dict[str, Any],
    system_package_root: Path,
) -> tuple[int, int]:
    """Extract one member at a time while enforcing link containment."""
    if not hasattr(tarfile, "data_filter"):
        raise ValidationError("Python runtime lacks safe tar extraction support")
    internal_links = 0
    package_links = 0
    with open_archive_stream(archive_fd) as stream:
        with tarfile.open(fileobj=stream, mode="r|gz") as bundle:
            for member in bundle:
                try:
                    filtered = tarfile.data_filter(member, str(staging))
                except tarfile.AbsoluteLinkError:
                    filtered = remap_internal_link(member, manifest, staging)
                    if filtered is not None:
                        internal_links += 1
                    elif is_reconstructable_package_link(member, system_package_root):
                        package_links += 1
                        bundle.members.clear()
                        continue
                    else:
                        raise ValidationError("unsafe external archive link rejected")
                except (OSError, tarfile.TarError) as exc:
                    raise ValidationError("unsafe archive member rejected") from exc
                if filtered is not None:
                    if filtered.isdir():
                        filtered = copy.copy(filtered)
                        filtered.mode = 0o700
                    bundle.extract(filtered, staging, filter="fully_trusted")
                bundle.members.clear()
    return internal_links, package_links


def validate_ownership_and_modes(staging: Path) -> None:
    """Require staged entries to remain owned by the invoking account.

    Also reject special filesystem entries.
    """
    expected_uid = os.geteuid()
    expected_gid = os.getegid()
    for path in itertools.chain((staging,), staging.rglob("*")):
        metadata = path.lstat()
        if metadata.st_uid != expected_uid or metadata.st_gid != expected_gid:
            raise ValidationError("staged restore has unexpected ownership")
        mode = stat.S_IMODE(metadata.st_mode)
        if not path.is_symlink() and mode & (
            stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX | stat.S_IWOTH
        ):
            raise ValidationError("staged restore has an unsafe file mode")


def resolve_staged_source(
    staging: Path, source_path: str, assets: list[dict[str, Any]]
) -> Path | None:
    """Map a manifest source path to its location under the staging root."""
    archive_path = map_source_to_archive(source_path, assets)
    return None if archive_path is None else staging / archive_path


def validate_required_payloads(staging: Path, manifest: dict[str, Any]) -> None:
    """Require the config, credentials, and declared workspaces in staging."""
    paths = manifest.get("paths")
    assets = manifest.get("assets")
    if not isinstance(paths, dict) or not isinstance(assets, list):
        raise ValidationError("backup manifest paths are invalid")

    required = [
        ("config", paths.get("configPath"), "file"),
        ("credentials", paths.get("oauthDir"), "directory"),
    ]
    workspace_dirs = paths.get("workspaceDirs")
    if not isinstance(workspace_dirs, list) or not workspace_dirs:
        raise ValidationError("full backup declares no workspaces")
    required.extend(("workspace", path, "directory") for path in workspace_dirs)

    for label, source_path, expected_type in required:
        if not isinstance(source_path, str):
            raise ValidationError(f"required {label} path is invalid")
        restored_path = resolve_staged_source(staging, source_path, assets)
        if restored_path is None:
            raise ValidationError(f"required {label} payload is not mapped")
        exists = (
            restored_path.is_file()
            if expected_type == "file"
            else restored_path.is_dir()
        )
        if not exists:
            raise ValidationError(f"staged restore is missing required {label} payload")


def validate_sqlite(staging: Path, state_archive_path: str) -> int:
    """Run SQLite integrity checks against every restored state database."""
    state_root = staging / PurePosixPath(state_archive_path)
    if not state_root.is_dir():
        raise ValidationError("staged restore is missing the state payload")
    databases = sorted(path for path in state_root.rglob("*.sqlite") if path.is_file())
    if not databases:
        raise ValidationError("staged restore contains no SQLite databases")
    for database in databases:
        try:
            connection = sqlite3.connect(
                f"{database.resolve().as_uri()}?mode=ro", uri=True
            )
            try:
                rows = connection.execute("PRAGMA integrity_check").fetchall()
            finally:
                connection.close()
        except sqlite3.DatabaseError as exc:
            raise ValidationError("SQLite integrity check failed") from exc
        if rows != [("ok",)]:
            raise ValidationError("SQLite integrity check failed")
    return len(databases)


def validate_restore(
    archive: Path,
    staging: Path,
    openclaw_bin: str,
    system_package_root: Path,
    live_state_root: Path,
) -> tuple[int, int, int, int]:
    """Verify, safely extract, and validate an OpenClaw backup."""
    archive = archive.resolve(strict=True)
    if not archive.is_file():
        raise ValidationError("archive must be a regular file")
    created_staging = False
    archive_fd = os.open(archive, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        initial_stat = os.fstat(archive_fd)
        if not stat.S_ISREG(initial_stat.st_mode):
            raise ValidationError("archive must be a regular file")
        run_vendor_verification(archive_fd, openclaw_bin)
        manifest = read_manifest(archive_fd)
        state_asset = require_full_backup(manifest, live_state_root)
        staging = validate_staging_path(staging, live_state_root)
        staging.mkdir(mode=0o700)
        created_staging = True
        internal_links, package_links = extract_archive(
            archive_fd, staging, manifest, system_package_root
        )
        final_stat = os.fstat(archive_fd)
        identity_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(
            getattr(initial_stat, field) != getattr(final_stat, field)
            for field in identity_fields
        ):
            raise ValidationError("archive changed during validation")
        staging.chmod(0o700)
        validate_ownership_and_modes(staging)
        validate_required_payloads(staging, manifest)
        database_count = validate_sqlite(staging, state_asset["archivePath"])
        return len(manifest["assets"]), database_count, internal_links, package_links
    except BaseException:
        if created_staging:
            make_tree_owner_accessible(staging)
            shutil.rmtree(staging)
        raise
    finally:
        os.close(archive_fd)


def make_tree_owner_accessible(staging: Path) -> None:
    """Restore owner directory access so failed staging can be removed."""
    if not staging.exists():
        return
    staging.chmod(0o700)
    for root, directories, _files in os.walk(staging, topdown=True, followlinks=False):
        Path(root).chmod(0o700)
        for directory in directories:
            path = Path(root) / directory
            if not path.is_symlink():
                path.chmod(0o700)


def main() -> int:
    """Run the staged restore validation command."""
    args = parse_args()
    try:
        asset_count, database_count, internal_links, package_links = validate_restore(
            args.archive,
            args.staging_dir,
            args.openclaw_bin,
            args.system_package_root,
            args.live_state_root,
        )
    except (OSError, tarfile.TarError, ValidationError) as exc:
        print(f"FAIL staged restore: {exc}", file=sys.stderr)
        return 1
    print(
        "PASS staged restore: "
        f"assets={asset_count} sqlite={database_count} "
        f"internal-links={internal_links} package-links={package_links} "
        "ownership=ok mode=0700"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
