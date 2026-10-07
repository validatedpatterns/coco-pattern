#!/usr/bin/env python3
"""Collect firmware/PCR reference values using the veritas CLI.

Runs locally (no cluster pods required):

  1. Runs veritas (installed on the host) to compute firmware measurements.
  2. Extracts reference values from OCP release artifacts (bare metal) or the
     dm-verity image (Azure).
  3. By default collects for BOTH TDX and SNP and merges the results, so a
     single output supports heterogeneous (mixed-TEE) deployments.
  4. Saves to ~/.coco-pattern/ for loading into Vault via 'make load-secrets'.

veritas is installed on the host via pip (see Prerequisites below) rather
than run in a container. The container image this script used to run
(quay.io/openshift_sandboxed_containers/coco-tools) is pinned to an older
veritas release that lacks --skip-tlog, which is needed to avoid repeated
failures against Red Hat's private Rekor instance for Azure image signature
verification. See the tracking issue for moving back to the container once
a coco-tools release ships with a newer veritas.

Prerequisites:
  python3 -m pip install -r requirements.txt
  cosign >= 2.0 (Azure only;
    https://docs.sigstore.dev/cosign/system_config/installation/)
  tdx-measure (bare metal TDX only; cargo install --git
    https://github.com/virtee/tdx-measure tdx-measure-cli)

Version resolution (OSC operator version, both platforms):
  --osc-version (repeatable) wins if given. Otherwise this script reads
  clusterGroup.subscriptions.sandbox.csv from --values-file (default:
  values-azure.yaml / values-baremetal.yaml, matching --platform) and uses
  that pinned version. There is no live-cluster auto-detect and no silent
  "latest" fallback for OSC version -- if it can't be resolved, the script
  exits with an error asking for an explicit --osc-version. This keeps
  collected reference values aligned with what the pattern's own values
  files declare, rather than whatever happens to be installed on whichever
  cluster you ran the collector against.

  The resolved OSC version also determines veritas's --bot-version (Red Hat
  build of Trustee wire format: "1.2" for OSC >= 1.13, "1.1" for OSC <=
  1.12). This is a structural format switch, not just a version stamp, and
  previously was never passed to veritas at all (always silently used the
  "1.2" default).

Version resolution (OCP version, bare metal only):
  --ocp-version (repeatable) wins if given, followed by the OCP_VERSION
  environment variable. Otherwise this script auto-detects from a live
  cluster (`oc version`). Unlike OSC, there is no values-file pin for the
  exact OCP patch version -- it's genuine live cluster state, not something
  coco-pattern declares.
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from types import SimpleNamespace
from typing import Annotated, Literal, Optional

import typer
from rich.console import Console

try:
    import yaml
except ImportError:  # pragma: no cover - checked explicitly in main()
    yaml = None  # type: ignore[assignment]

RVPS_FILENAME = "rvps-reference-values.yaml"
console = Console()
error_console = Console(stderr=True)


class CollectionError(Exception):
    """Raised for any unrecoverable error; caught in main() for a clean exit."""


# --------------------------------------------------------------------------
# Prerequisite checks
# --------------------------------------------------------------------------


def check_veritas():
    if shutil.which("veritas") is None:
        raise CollectionError(
            "veritas is required but not installed.\n"
            "  Install shared dependencies with: python3 -m pip install -r "
            "requirements.txt"
        )


def check_pyyaml():
    if yaml is None:
        raise CollectionError(
            "python3 with PyYAML module is required. Install shared "
            "dependencies with: python3 -m pip install -r requirements.txt"
        )


def check_cosign():
    """cosign is only used by veritas for Azure image signature verification.

    Bare metal verifies via 'oc adm release info --verify' instead.
    """
    if shutil.which("cosign") is None:
        raise CollectionError(
            "cosign is required for Azure signature verification but was "
            "not found.\n"
            "  Install cosign >= 2.0: "
            "https://docs.sigstore.dev/cosign/system_config/installation/"
        )
    result = subprocess.run(
        ["cosign", "version"], capture_output=True, text=True, check=False
    )
    match = re.search(r"GitVersion:\s*v?(\d+)\.(\d+)", result.stdout)
    if not match:
        error_console.print(
            "WARNING: could not determine cosign version; veritas requires "
            "cosign >= 2.0",
        )
        return
    major = int(match.group(1))
    if major < 2:
        raise CollectionError(
            f"cosign >= 2.0 is required (found: {match.group(1)}.{match.group(2)})"
        )


def resolve_pull_secret(cli_value):
    path = Path(
        cli_value or os.environ.get("PULL_SECRET") or Path.home() / "pull-secret.json"
    )
    if not path.is_file():
        raise CollectionError(
            f"Pull secret not found at {path}\n"
            "  Provide path via --pull-secret, the PULL_SECRET environment "
            "variable, or create ~/pull-secret.json"
        )
    return path


# --------------------------------------------------------------------------
# Version resolution
# --------------------------------------------------------------------------


def default_values_file(platform):
    repo_root = Path(__file__).resolve().parent.parent
    return repo_root / f"values-{platform}.yaml"


def resolve_osc_versions(args):
    """Resolve OSC operator version(s): CLI override, else the values-file pin.

    No live-cluster auto-detect and no "latest" fallback -- raises
    CollectionError if neither source yields a version.
    """
    if args.osc_versions:
        return list(dict.fromkeys(args.osc_versions)), "--osc-version"

    values_file = (
        Path(args.values_file)
        if args.values_file
        else default_values_file(args.platform)
    )
    if not values_file.is_file():
        raise CollectionError(
            "Could not resolve OSC version: no --osc-version given and "
            f"values file not found at {values_file}\n"
            "  Pass --osc-version explicitly, or point --values-file at a "
            "values-<topology>.yaml that sets "
            "clusterGroup.subscriptions.sandbox.csv."
        )

    with open(values_file) as f:
        doc = yaml.safe_load(f) or {}

    csv = (
        doc.get("clusterGroup", {})
        .get("subscriptions", {})
        .get("sandbox", {})
        .get("csv")
    )
    if not csv:
        raise CollectionError(
            "Could not resolve OSC version: "
            "clusterGroup.subscriptions.sandbox.csv not set in "
            f"{values_file}\n"
            "  Pass --osc-version explicitly instead."
        )

    # CSV format: sandboxed-containers-operator.v1.13.0 -> 1.13.0
    osc_version = csv.rsplit(".v", 1)[-1]
    return [osc_version], f"values file ({values_file})"


def resolve_ocp_versions(args):
    """Resolve OCP version(s): CLI override, environment override, then cluster.

    Unlike OSC, there is no values-file pin for the exact OCP patch version.
    """
    if args.ocp_versions:
        return list(dict.fromkeys(args.ocp_versions)), "--ocp-version"

    if ocp_version := os.environ.get("OCP_VERSION"):
        return [ocp_version], "OCP_VERSION environment variable"

    if shutil.which("oc") is not None:
        whoami = subprocess.run(
            ["oc", "whoami"], capture_output=True, text=True, check=False
        )
        if whoami.returncode == 0:
            console.print("Detecting OCP version from cluster...")
            result = subprocess.run(
                ["oc", "version", "-o", "json"],
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode == 0:
                try:
                    version = json.loads(result.stdout).get("openshiftVersion")
                except json.JSONDecodeError:
                    version = None
                if version:
                    console.print(f"Detected OCP version: {version}")
                    return [version], "live cluster"

    raise CollectionError(
        "Could not auto-detect OCP version. Specify with --ocp-version"
    )


def compute_bot_version(osc_versions):
    """Map OSC version(s) to veritas's --bot-version ("1.2" for >=1.13, else "1.1").

    This is a structural format switch in the Trustee RVPS ConfigMap, not
    just a version stamp -- see veritas's models.format_trustee().
    """

    def bucket(version):
        parts = version.split(".")
        try:
            major, minor = int(parts[0]), int(parts[1])
        except (IndexError, ValueError):
            return "1.2"  # unparsable (e.g. "latest", a git hash) -> current default
        return "1.2" if (major, minor) >= (1, 13) else "1.1"

    buckets = {bucket(v) for v in osc_versions}
    if len(buckets) > 1:
        error_console.print(
            f"WARNING: OSC versions {osc_versions} straddle the 1.13 "
            "bot-version boundary; using the newer format (1.2)",
        )
        return "1.2"
    return buckets.pop()


# --------------------------------------------------------------------------
# veritas invocation + output extraction
# --------------------------------------------------------------------------


def run_veritas(
    platform, tee, versions, pull_secret, skip_tlog, bot_version, output_dir
):
    args = [
        "veritas",
        "--platform",
        platform,
        "--tee",
        tee,
        "--authfile",
        str(pull_secret),
        "--bot-version",
        bot_version,
    ]

    version_flag = "--image-tag" if platform == "azure" else "--ocp-version"
    for version in versions:
        args.extend([version_flag, version])

    # XFAM CPU features only matter for TDX; only add for the tdx run to
    # avoid veritas's harmless-but-noisy "only relevant for TDX" warning.
    if platform == "baremetal" and tee == "tdx":
        args.extend(
            [
                "--hw-xfam-allow",
                "x87",
                "--hw-xfam-allow",
                "sse",
                "--hw-xfam-allow",
                "avx",
            ]
        )

    # cosign/Rekor verification only applies to the Azure branch. Default to
    # --skip-tlog: Red Hat signs and logs these images against its own
    # private Rekor instance, which has been unreliable. --skip-tlog still
    # verifies the cosign signature against Red Hat's public key -- it only
    # skips the transparency-log lookup, which cannot succeed against a
    # different Rekor server anyway (the log entry only exists on Red Hat's
    # instance). Pass --verify-tlog to opt back into full verification.
    if platform == "azure" and skip_tlog:
        args.append("--skip-tlog")

    args.extend(["-o", str(output_dir)])

    console.print(f"Running veritas (tee={tee})...")
    console.print("(This may take 2-3 minutes to download and process artifacts)")
    result = subprocess.run(args, check=False)
    console.print()
    if result.returncode != 0:
        raise CollectionError(
            f"veritas failed (tee={tee}), exit code {result.returncode}"
        )


def extract_reference_values(yaml_path):
    """Extract reference values from a veritas-produced ConfigMap YAML.

    Returns a plain dict of claim-name -> value. Supports both the old
    (Trustee 1.1) and new (Trustee 1.2) veritas RVPS formats.
    """
    import base64

    with open(yaml_path) as f:
        doc = yaml.safe_load(f)

    data = doc.get("data", {})
    result = {}

    if "reference_value" in data:
        # New format (veritas 0.1.x / Trustee 1.2): JSON object with
        # base64-encoded RVPS entries.
        raw = data["reference_value"]
        entries = json.loads(raw) if isinstance(raw, str) else raw
        for claim_name, b64_value in entries.items():
            padded = b64_value + "=" * (-len(b64_value) % 4)
            decoded = json.loads(base64.urlsafe_b64decode(padded))
            result[claim_name] = decoded.get("value", decoded)
    elif "reference-values.json" in data:
        # Old format: JSON array of {name, hash-value} entries.
        raw = data["reference-values.json"]
        entries = json.loads(raw) if isinstance(raw, str) else raw
        for entry in entries:
            name = entry.get("name", "")
            value = entry.get("value", entry.get("hash-value", []))
            result[name] = value
    else:
        raise CollectionError(
            "ConfigMap has neither reference_value nor " "reference-values.json key"
        )

    return result


def merge_reference_values(dicts):
    """Union reference-value dicts by key; warn (keep first) on conflicts."""
    result = {}
    for data in dicts:
        for key, value in data.items():
            if key in result and result[key] != value:
                error_console.print(
                    f"WARNING: key '{key}' differs between TEE runs; "
                    "keeping the first value seen",
                )
                continue
            result[key] = value
    return result


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def default_output_file(platform):
    if platform == "azure":
        return Path.home() / ".coco-pattern" / "measurements.json"
    return Path.home() / ".coco-pattern" / "firmware-reference-values.json"


def sibling_output_file(platform):
    """The *other* platform's placeholder path (see comment in main())."""
    if platform == "azure":
        return Path.home() / ".coco-pattern" / "firmware-reference-values.json"
    return Path.home() / ".coco-pattern" / "measurements.json"


def run(args):
    check_veritas()
    check_pyyaml()
    if args.platform == "azure":
        check_cosign()

    pull_secret = resolve_pull_secret(args.pull_secret)

    if args.platform == "azure":
        # veritas passes --authfile to skopeo for pulling/inspecting the
        # dm-verity image, but its cosign-based signature verification step
        # invokes `cosign verify` directly with no auth args at all. cosign
        # (via go-containerregistry's DefaultKeychain) only picks up
        # credentials from ~/.docker/config.json, $DOCKER_CONFIG/config.json,
        # or -- if neither of those exists -- $REGISTRY_AUTH_FILE. Export the
        # latter so the pull secret authenticates the registry.redhat.io pull
        # cosign does internally; otherwise it silently falls back to
        # anonymous auth and fails with a confusing UNAUTHORIZED error.
        os.environ["REGISTRY_AUTH_FILE"] = str(pull_secret)
        if (Path.home() / ".docker" / "config.json").is_file():
            error_console.print(
                "WARNING: ~/.docker/config.json exists and takes precedence "
                "over REGISTRY_AUTH_FILE for cosign's registry auth. If it "
                "lacks registry.redhat.io credentials, cosign verification "
                "will still fail with UNAUTHORIZED regardless of "
                "--pull-secret/PULL_SECRET.",
            )

    osc_versions, osc_source = resolve_osc_versions(args)
    bot_version = compute_bot_version(osc_versions)

    if args.platform == "azure":
        versions, version_source = osc_versions, osc_source
        version_display = f"OSC {', '.join(osc_versions)}"
    else:
        versions, version_source = resolve_ocp_versions(args)
        version_display = f"OCP {', '.join(versions)}"

    output_file = (
        Path(args.output) if args.output else default_output_file(args.platform)
    )
    tees_to_run = ["tdx", "snp"] if args.tee == "both" else [args.tee]
    skip_tlog = not args.verify_tlog

    console.print("==========================================")
    console.print("Firmware Reference Value Collection")
    console.print("==========================================")
    console.print(f"Platform:       {args.platform}")
    console.print(f"Version:        {version_display} (source: {version_source})")
    console.print(f"OSC version:    {', '.join(osc_versions)} (source: {osc_source})")
    console.print(f"Bot version:    {bot_version}")
    console.print(f"TEE Type(s):    {' '.join(tees_to_run)}")
    console.print(f"Output file:    {output_file}")
    console.print()

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        per_tee_values = []
        for tee in tees_to_run:
            out_dir = tmpdir / tee
            out_dir.mkdir(parents=True, exist_ok=True)
            run_veritas(
                args.platform,
                tee,
                versions,
                pull_secret,
                skip_tlog,
                bot_version,
                out_dir,
            )
            per_tee_values.append(extract_reference_values(out_dir / RVPS_FILENAME))

    console.print(f"Merging reference values from: {' '.join(tees_to_run)}...")
    merged = merge_reference_values(per_tee_values)

    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(json.dumps(merged, indent=2) + "\n")

    console.print()
    console.print("Collected firmware reference values:")
    console.print(json.dumps(merged, indent=2))
    console.print()
    console.print(f"Saved to: {output_file}")
    console.print()

    vault_key = "pcrStash" if args.platform == "azure" else "firmwareReferenceValues"

    # The values-secret template enables pcrStash (Azure) and
    # firmwareReferenceValues (bare metal) unconditionally so the same file
    # works on either topology. Ensure the *other* platform's file also
    # exists (as an empty '{}' placeholder) so 'make load-secrets' doesn't
    # fail on a topology that only ever collects reference values for one
    # platform. This never overwrites real, previously-collected data.
    sibling = sibling_output_file(args.platform)
    if not sibling.is_file():
        sibling.parent.mkdir(parents=True, exist_ok=True)
        sibling.write_text("{}\n")
        console.print(f"Created empty placeholder for the other platform: {sibling}")
        console.print()

    console.print("Next steps:")
    console.print(f"1. Review the collected values: cat {output_file}")
    console.print(
        f"2. Ensure '{vault_key}' is configured in ~/values-secret-coco-pattern.yaml"
    )
    console.print("3. Run: make load-secrets")
    console.print()


def main(
    platform: Annotated[
        Literal["baremetal", "azure"],
        typer.Option("--platform", help="Platform to collect reference values for"),
    ],
    output: Annotated[
        Optional[Path], typer.Option("-o", "--output", help="Override output path")
    ] = None,
    pull_secret: Annotated[
        Optional[Path],
        typer.Option(
            "-p",
            "--pull-secret",
            help="Pull secret file (default: ~/pull-secret.json; PULL_SECRET overrides it)",
        ),
    ] = None,
    ocp_versions: Annotated[
        Optional[list[str]],
        typer.Option(
            "-v",
            "--ocp-version",
            help="OCP version (bare metal; repeatable; overrides OCP_VERSION)",
        ),
    ] = None,
    osc_versions: Annotated[
        Optional[list[str]],
        typer.Option("--osc-version", help="OSC operator version (repeatable)"),
    ] = None,
    values_file: Annotated[
        Optional[Path],
        typer.Option(
            "--values-file", help="Values file containing the pinned OSC version"
        ),
    ] = None,
    tee: Annotated[
        Literal["tdx", "snp", "both"],
        typer.Option("-t", "--tee", help="TEE type (default: both)"),
    ] = "both",
    verify_tlog: Annotated[
        bool,
        typer.Option(
            "--verify-tlog",
            help="Azure only: verify against the Rekor transparency log",
        ),
    ] = False,
):
    args = SimpleNamespace(
        platform=platform,
        output=output,
        pull_secret=pull_secret,
        ocp_versions=ocp_versions,
        osc_versions=osc_versions,
        values_file=values_file,
        tee=tee,
        verify_tlog=verify_tlog,
    )
    try:
        run(args)
    except CollectionError as e:
        error_console.print(f"Error: {e}")
        raise typer.Exit(code=1)


if __name__ == "__main__":
    typer.run(main)
