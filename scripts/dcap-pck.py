#!/usr/bin/env python3
"""Create and import Intel DCAP PCK cache bundles for offline QGS mode."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from getpass import getpass
from pathlib import Path
from types import SimpleNamespace
from typing import Any

SCHEMA_VERSION = 1
REQUEST_TYPE = "dcap-platform-request"
RESPONSE_TYPE = "dcap-pck-response"
PLATFORM_FIELDS = ("enc_ppid", "pce_id", "cpu_svn", "pce_svn", "qe_id", "platform_manifest")
HEX_LENGTHS = {"pce_id": 4, "cpu_svn": 32, "pce_svn": 4, "qe_id": 32}
MAX_CACHE_BYTES = 750 * 1024


def fail(message: str) -> None:
    raise ValueError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read JSON file {path}: {error}")


def validate_platform(platform: dict[str, Any]) -> dict[str, str]:
    if set(platform) != set(PLATFORM_FIELDS):
        fail("platform data must contain exactly: " + ", ".join(PLATFORM_FIELDS))
    normalized: dict[str, str] = {}
    for field in PLATFORM_FIELDS:
        value = platform[field]
        if not isinstance(value, str):
            fail(f"platform {field} must be a string")
        normalized[field] = value.lower()

    for field, length in HEX_LENGTHS.items():
        if not re.fullmatch(rf"[0-9a-f]{{{length}}}", normalized[field]):
            fail(f"platform {field} must be {length} hexadecimal characters")
    if not re.fullmatch(r"[0-9a-f]+", normalized["platform_manifest"]):
        fail("platform_manifest must be non-empty hexadecimal data")
    if normalized["enc_ppid"] and not re.fullmatch(r"[0-9a-f]+", normalized["enc_ppid"]):
        fail("enc_ppid must be empty or hexadecimal data")
    return normalized


def platform_key(platform: dict[str, str]) -> tuple[str, str]:
    return platform["qe_id"], platform["pce_id"]


def validate_platforms(platforms: Any) -> list[dict[str, str]]:
    if not isinstance(platforms, list) or not platforms:
        fail("platform list must contain at least one platform")
    normalized = [validate_platform(platform) for platform in platforms if isinstance(platform, dict)]
    if len(normalized) != len(platforms):
        fail("platform list entries must be objects")
    keys = [platform_key(platform) for platform in normalized]
    if len(set(keys)) != len(keys):
        fail("platform list contains duplicate QE ID/PCE ID pairs")
    qe_ids = [platform["qe_id"] for platform in normalized]
    if len(set(qe_ids)) != len(qe_ids):
        fail("platform list contains duplicate QE IDs")
    return sorted(normalized, key=platform_key)


def create_manifest(bundle_type: str, files: dict[str, Path], **extra: Any) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "type": bundle_type,
        "createdAt": datetime.now(UTC).isoformat(),
        "files": {name: {"sha256": sha256(path), "size": path.stat().st_size} for name, path in files.items()},
        **extra,
    }


def validate_manifest(bundle: Path, expected_type: str) -> dict[str, Any]:
    manifest = load_json(bundle / "manifest.json")
    if not isinstance(manifest, dict):
        fail("bundle manifest must be an object")
    if manifest.get("schemaVersion") != SCHEMA_VERSION or manifest.get("type") != expected_type:
        fail(f"unsupported bundle type or schema in {bundle / 'manifest.json'}")
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        fail("bundle manifest has no files")
    for relative, metadata in files.items():
        path = bundle / relative
        if not isinstance(relative, str) or path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(bundle.resolve()):
            fail(f"invalid bundle file: {relative}")
        if not isinstance(metadata, dict) or metadata.get("size") != path.stat().st_size or metadata.get("sha256") != sha256(path):
            fail(f"checksum mismatch for {relative}")
    return manifest


def request_platforms(bundle: Path) -> tuple[dict[str, Any], list[dict[str, str]]]:
    manifest = validate_manifest(bundle, REQUEST_TYPE)
    if "platform-list.json" not in manifest["files"]:
        fail("request bundle is missing platform-list.json")
    return manifest, validate_platforms(load_json(bundle / "platform-list.json"))


def run_oc(arguments: list[str], input_text: str | None = None) -> str:
    result = subprocess.run(["oc", *arguments], input=input_text, text=True, capture_output=True, check=False)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"oc {' '.join(arguments[:3])} failed: {detail}")
    return result.stdout


def cluster_platforms(namespace: str) -> list[dict[str, str]]:
    data = json.loads(run_oc(["get", "secrets", "-n", namespace, "-l", "type=platform-data", "-o", "json"]))
    platforms = []
    for secret in data.get("items", []):
        encoded = secret.get("data", {})
        try:
            decoded = {field: base64.b64decode(encoded[field]).decode("ascii") for field in PLATFORM_FIELDS}
        except (KeyError, UnicodeDecodeError, ValueError) as error:
            fail(f"invalid platform-data Secret {secret.get('metadata', {}).get('name', '<unknown>')}: {error}")
        platforms.append(decoded)
    return validate_platforms(platforms)


def command_export(arguments: argparse.Namespace) -> None:
    output = Path(arguments.output).expanduser()
    if output.exists():
        fail(f"output bundle already exists: {output}")
    platforms = cluster_platforms(arguments.namespace)
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    output.mkdir(mode=0o700, parents=True)
    platform_list = output / "platform-list.json"
    write_json(platform_list, platforms)
    write_json(output / "manifest.json", create_manifest(REQUEST_TYPE, {"platform-list.json": platform_list}, namespace=arguments.namespace, platforms=[{"qe_id": item["qe_id"], "pce_id": item["pce_id"]} for item in platforms]))
    print(f"Created platform request bundle: {output}")


def read_api_key() -> str:
    api_key = os.environ.pop("INTEL_PCS_API_KEY", "")
    if not api_key:
        if not sys.stdin.isatty():
            fail("INTEL_PCS_API_KEY is not set and no interactive terminal is available")
        api_key = getpass("Intel PCS API key: ")
    if not api_key.strip():
        fail("Intel PCS API key is empty")
    return api_key


def generate_cache(tool_dir: Path, platforms_file: Path, output: Path, expire_hours: int, api_key: str) -> None:
    if not (tool_dir / "pcsclient.py").is_file():
        fail(f"pcsclient.py not found in {tool_dir}; run make dcap-tools first")
    sys.path.insert(0, str(tool_dir))
    try:
        from pcsclient import CacheCreator  # type: ignore[import-not-found]
    except ImportError as error:
        fail(f"cannot import Intel PcsClientTool from {tool_dir}: {error}")

    class Credentials:
        def get_pcs_api_key(self) -> str:
            return api_key

    cache_args = SimpleNamespace(
        url=None,
        input_file=str(platforms_file),
        output_dir=str(output),
        expire=expire_hours,
        tcb_update_type="early",
        sub_dir=False,
    )
    previous = Path.cwd()
    try:
        os.chdir(platforms_file.parent)
        CacheCreator(Credentials(), cache_args).generate_cache()
    finally:
        os.chdir(previous)


def cache_metadata(path: Path) -> dict[str, int]:
    if path.stat().st_size > MAX_CACHE_BYTES:
        fail(f"cache file exceeds {MAX_CACHE_BYTES} bytes: {path.name}")
    with path.open("rb") as cache:
        data = cache.read(14)
    if len(data) != 14:
        fail(f"cache file is too small: {path.name}")
    version, flags, expires_at = struct.unpack("<HIQ", data[:14])
    if version != 1 or flags != 4:
        fail(f"unsupported PCK cache header in {path.name}")
    if expires_at <= int(datetime.now(UTC).timestamp()):
        fail(f"PCK cache is expired: {path.name}")
    return {"expiresAt": expires_at}


def expire_hours(value: str) -> int:
    try:
        hours = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer between 1 and 8760") from error
    if not 1 <= hours <= 8760:
        raise argparse.ArgumentTypeError("must be between 1 and 8760")
    return hours


def command_generate(arguments: argparse.Namespace) -> None:
    request = Path(arguments.input).expanduser()
    request_manifest, platforms = request_platforms(request)
    output = Path(arguments.output).expanduser()
    if output.exists():
        fail(f"output bundle already exists: {output}")
    api_key = read_api_key()
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="dcap-pck-", dir=output.parent))
    try:
        cache_dir = temporary / "pck"
        generate_cache(Path(arguments.pcsclient_dir).expanduser(), request / "platform-list.json", cache_dir, arguments.expire_hours, api_key)
        if not cache_dir.is_dir():
            fail("Intel PcsClientTool did not create a PCK cache directory")
        expected = {f"{item['qe_id']}_{item['pce_id']}" for item in platforms}
        generated = {path.name for path in cache_dir.iterdir() if path.is_file()}
        if generated != expected:
            fail(f"generated PCK cache does not match request; expected {sorted(expected)}, got {sorted(generated)}")
        files = {f"pck/{path.name}": path for path in sorted(cache_dir.iterdir())}
        metadata = {path.name: cache_metadata(path) for path in cache_dir.iterdir()}
        write_json(temporary / "manifest.json", create_manifest(RESPONSE_TYPE, files, requestSha256=sha256(request / "manifest.json"), platforms=platforms, cache=metadata))
        temporary.rename(output)
    finally:
        api_key = ""
        if temporary.exists():
            shutil.rmtree(temporary)
    print(f"Created PCK response bundle: {output}")


def response_cache(bundle: Path) -> tuple[dict[str, Any], list[dict[str, str]], dict[tuple[str, str], Path]]:
    manifest = validate_manifest(bundle, RESPONSE_TYPE)
    platforms = validate_platforms(manifest.get("platforms"))
    cache: dict[tuple[str, str], Path] = {}
    for platform in platforms:
        name = f"{platform['qe_id']}_{platform['pce_id']}"
        path = bundle / "pck" / name
        if f"pck/{name}" not in manifest["files"] or not path.is_file():
            fail(f"response bundle is missing cache file {name}")
        cache[platform_key(platform)] = path
        cache_metadata(path)
    if set(manifest["files"]) != {f"pck/{path.name}" for path in cache.values()}:
        fail("response bundle contains unexpected files")
    return manifest, platforms, cache


def qgs_daemonset(namespace: str, configured_name: str) -> str:
    if configured_name:
        run_oc(["get", "daemonset", configured_name, "-n", namespace])
        return configured_name

    pods = json.loads(run_oc(["get", "pods", "-n", namespace, "-o", "json"])).get("items", [])
    names = set()
    for pod in pods:
        init_containers = pod.get("spec", {}).get("initContainers", [])
        if not any(container.get("name") == "pck-certs-watcher" for container in init_containers):
            continue
        for owner in pod.get("metadata", {}).get("ownerReferences", []):
            if owner.get("kind") == "DaemonSet" and owner.get("name"):
                names.add(owner["name"])
    if len(names) != 1:
        fail("expected exactly one QGS DaemonSet from pck-certs-watcher pod owners; set DCAP_QGS_DAEMONSET to override")
    return names.pop()


def command_import(arguments: argparse.Namespace) -> None:
    bundle = Path(arguments.input).expanduser()
    manifest, expected, cache = response_cache(bundle)
    current = cluster_platforms(arguments.namespace)
    if current != expected:
        fail("response bundle platform data does not match current platform-data Secrets")
    daemonset = qgs_daemonset(arguments.namespace, arguments.qgs_daemonset)
    resources = []
    for platform in expected:
        key = platform_key(platform)
        secret_name = f"{platform['qe_id']}-pck"
        source = cache[key]
        resources.append(run_oc(["create", "secret", "generic", secret_name, "-n", arguments.namespace, f"--from-file=certificate={source}", "--dry-run=client", "-o", "yaml"]))
    run_oc(["apply", "-f", "-"], input_text="---\n".join(resources))
    run_oc(["rollout", "restart", f"daemonset/{daemonset}", "-n", arguments.namespace])
    run_oc(["rollout", "status", f"daemonset/{daemonset}", "-n", arguments.namespace, f"--timeout={arguments.timeout}"])
    print(f"Imported {len(cache)} PCK cache Secrets from {bundle} (bundle SHA-256: {sha256(bundle / 'manifest.json')})")


def command_provision(arguments: argparse.Namespace) -> None:
    request = Path(arguments.request_bundle).expanduser()
    response = Path(arguments.response_bundle).expanduser()
    current = cluster_platforms(arguments.namespace)

    if request.exists():
        _, exported = request_platforms(request)
        if exported == current:
            print(f"Reusing matching platform request bundle: {request}")
        else:
            shutil.rmtree(request)
            if response.exists():
                shutil.rmtree(response)
            command_export(SimpleNamespace(namespace=arguments.namespace, output=str(request)))
    else:
        command_export(SimpleNamespace(namespace=arguments.namespace, output=str(request)))

    request_digest = sha256(request / "manifest.json")
    if response.exists():
        response_manifest, response_platforms, _ = response_cache(response)
        if response_manifest.get("requestSha256") == request_digest and response_platforms == current:
            print(f"Reusing matching PCK response bundle: {response}")
        else:
            shutil.rmtree(response)
            command_generate(
                SimpleNamespace(
                    input=str(request),
                    output=str(response),
                    pcsclient_dir=arguments.pcsclient_dir,
                    expire_hours=arguments.expire_hours,
                )
            )
    else:
        command_generate(
            SimpleNamespace(
                input=str(request),
                output=str(response),
                pcsclient_dir=arguments.pcsclient_dir,
                expire_hours=arguments.expire_hours,
            )
        )

    command_import(
        SimpleNamespace(
            input=str(response),
            namespace=arguments.namespace,
            qgs_daemonset=arguments.qgs_daemonset,
            timeout=arguments.timeout,
        )
    )


def command_tools(arguments: argparse.Namespace) -> None:
    repository = Path(arguments.repository).expanduser()
    tool_dir = Path(arguments.pcsclient_dir).expanduser()
    repository.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not (repository / ".git").is_dir():
        result = subprocess.run(["git", "clone", "https://github.com/intel/confidential-computing.tee.dcap", str(repository)], check=False)
        if result.returncode:
            fail("could not clone Intel PcsClientTool repository")
    for command in (
        ["git", "-C", str(repository), "fetch", "--depth", "1", "origin", arguments.ref],
        ["git", "-C", str(repository), "checkout", "--detach", arguments.ref],
        [sys.executable, "-m", "pip", "install", "-r", str(tool_dir / "requirements.txt")],
    ):
        result = subprocess.run(command, check=False)
        if result.returncode:
            fail("failed to prepare the pinned Intel PcsClientTool")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    tools = commands.add_parser("tools", help="clone the pinned Intel PcsClientTool")
    tools.add_argument("--repository", default=os.environ.get("DCAP_PCSCLIENT_REPO", "~/.coco-pattern/intel-dcap"))
    tools.add_argument("--pcsclient-dir", default=os.environ.get("DCAP_PCSCLIENT_DIR", "~/.coco-pattern/intel-dcap/tools/PcsClientTool"))
    tools.add_argument("--ref", default=os.environ.get("DCAP_PCSCLIENT_REF", "64b78f3766e7196d3d2c60e401540f0f853b2deb"))
    tools.set_defaults(func=command_tools)
    export = commands.add_parser("export", help="export QGS platform data from the disconnected cluster")
    export.add_argument("--namespace", default=os.environ.get("DCAP_NAMESPACE", "intel-dcap-operator-system"))
    export.add_argument("--output", default=os.environ.get("DCAP_REQUEST_BUNDLE", "~/.coco-pattern/dcap-pck/platform-request"))
    export.set_defaults(func=command_export)
    generate = commands.add_parser("generate", help="generate a PCK response bundle on the connected low side")
    generate.add_argument("--input", default=os.environ.get("DCAP_REQUEST_BUNDLE", "~/.coco-pattern/dcap-pck/platform-request"))
    generate.add_argument("--output", default=os.environ.get("DCAP_RESPONSE_BUNDLE", "~/.coco-pattern/dcap-pck/pck-response"))
    generate.add_argument("--pcsclient-dir", default=os.environ.get("DCAP_PCSCLIENT_DIR", "~/.coco-pattern/intel-dcap/tools/PcsClientTool"))
    generate.add_argument("--expire-hours", type=expire_hours, default=os.environ.get("DCAP_PCK_EXPIRE_HOURS", "8760"), metavar="HOURS")
    generate.set_defaults(func=command_generate)
    importer = commands.add_parser("import", help="import a PCK response bundle into the disconnected cluster")
    importer.add_argument("--namespace", default=os.environ.get("DCAP_NAMESPACE", "intel-dcap-operator-system"))
    importer.add_argument("--qgs-daemonset", default=os.environ.get("DCAP_QGS_DAEMONSET", ""))
    importer.add_argument("--timeout", default=os.environ.get("DCAP_QGS_TIMEOUT", "10m"))
    importer.add_argument("--input", default=os.environ.get("DCAP_RESPONSE_BUNDLE", "~/.coco-pattern/dcap-pck/pck-response"))
    importer.set_defaults(func=command_import)
    provision = commands.add_parser("provision", help="resume the connected-bastion PCK lifecycle")
    provision.add_argument("--namespace", default=os.environ.get("DCAP_NAMESPACE", "intel-dcap-operator-system"))
    provision.add_argument("--qgs-daemonset", default=os.environ.get("DCAP_QGS_DAEMONSET", ""))
    provision.add_argument("--timeout", default=os.environ.get("DCAP_QGS_TIMEOUT", "10m"))
    provision.add_argument("--request-bundle", default=os.environ.get("DCAP_REQUEST_BUNDLE", "~/.coco-pattern/dcap-pck/platform-request"))
    provision.add_argument("--response-bundle", default=os.environ.get("DCAP_RESPONSE_BUNDLE", "~/.coco-pattern/dcap-pck/pck-response"))
    provision.add_argument("--pcsclient-dir", default=os.environ.get("DCAP_PCSCLIENT_DIR", "~/.coco-pattern/intel-dcap/tools/PcsClientTool"))
    provision.add_argument("--expire-hours", type=expire_hours, default=os.environ.get("DCAP_PCK_EXPIRE_HOURS", "8760"), metavar="HOURS")
    provision.set_defaults(func=command_provision)
    return parser


def main() -> int:
    try:
        arguments = build_parser().parse_args()
        arguments.func(arguments)
        return 0
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
