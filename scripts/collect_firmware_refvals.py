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
  pip install "osc-veritas[snp]==0.1.3rc1"
  PyYAML (pip install pyyaml)
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
  --ocp-version (repeatable) wins if given. Otherwise this script
  auto-detects from a live cluster (`oc version`). Unlike OSC, there is no
  values-file pin for the exact OCP patch version -- it's genuine live
  cluster state, not something coco-pattern declares.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - checked explicitly in main()
    yaml = None  # type: ignore[assignment]

VERITAS_PIP_SPEC = "osc-veritas[snp]==0.1.3rc1"
RVPS_FILENAME = "rvps-reference-values.yaml"


class CollectionError(Exception):
    """Raised for any unrecoverable error; caught in main() for a clean exit."""


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--platform",
        required=True,
        choices=["baremetal", "azure"],
        help="Platform to collect reference values for",
    )
    parser.add_argument(
        "-o",
        "--output",
        help="Override output path",
    )
    parser.add_argument(
        "-p",
        "--pull-secret",
        default=None,
        help="Pull secret file (default: ~/pull-secret.json, override via "
        "the PULL_SECRET environment variable)",
    )
    parser.add_argument(
        "-v",
        "--ocp-version",
        action="append",
        dest="ocp_versions",
        metavar="VER",
        help="OCP version (bare metal; repeatable; default: auto-detect "
        "from a live cluster)",
    )
    parser.add_argument(
        "--osc-version",
        action="append",
        dest="osc_versions",
        metavar="VER",
        help="OSC operator version (repeatable; default: read from "
        "--values-file's pinned subscription CSV)",
    )
    parser.add_argument(
        "--values-file",
        help="Values file to read the pinned OSC operator version from "
        "(default: values-azure.yaml or values-baremetal.yaml, "
        "matching --platform)",
    )
    parser.add_argument(
        "-t",
        "--tee",
        default="both",
        choices=["tdx", "snp", "both"],
        help="TEE type (default: both -- collects and merges both)",
    )
    parser.add_argument(
        "--verify-tlog",
        action="store_true",
        help="Azure only: verify against the Rekor transparency log "
        "instead of the default --skip-tlog. Only the signature check "
        "is skipped by default, not overall image verification.",
    )
    return parser.parse_args(argv)


# --------------------------------------------------------------------------
# Prerequisite checks
# --------------------------------------------------------------------------


def check_veritas():
    if shutil.which("veritas") is None:
        raise CollectionError(
            "veritas is required but not installed.\n"
            f'  Install with: pip install "{VERITAS_PIP_SPEC}"'
        )


def check_pyyaml():
    if yaml is None:
        raise CollectionError(
            "python3 with PyYAML module is required. "
            "Install with: pip3 install pyyaml"
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
        print(
            "WARNING: could not determine cosign version; veritas requires "
            "cosign >= 2.0",
            file=sys.stderr,
        )
        return
    major = int(match.group(1))
    if major < 2:
        raise CollectionError(
            f"cosign >= 2.0 is required (found: {match.group(1)}.{match.group(2)})"
        )


def resolve_pull_secret(cli_value):
    import os

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
    """Resolve OCP version(s) for bare metal: CLI override, else live-cluster.

    Unlike OSC, there is no values-file pin for the exact OCP patch version.
    """
    if args.ocp_versions:
        return list(dict.fromkeys(args.ocp_versions)), "--ocp-version"

    if shutil.which("oc") is not None:
        whoami = subprocess.run(
            ["oc", "whoami"], capture_output=True, text=True, check=False
        )
        if whoami.returncode == 0:
            print("Detecting OCP version from cluster...")
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
                    print(f"Detected OCP version: {version}")
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
        print(
            f"WARNING: OSC versions {osc_versions} straddle the 1.13 "
            "bot-version boundary; using the newer format (1.2)",
            file=sys.stderr,
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

    print(f"Running veritas (tee={tee})...")
    print("(This may take 2-3 minutes to download and process artifacts)")
    result = subprocess.run(args, check=False)
    print()
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
                print(
                    f"WARNING: key '{key}' differs between TEE runs; "
                    "keeping the first value seen",
                    file=sys.stderr,
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
        import os

        os.environ["REGISTRY_AUTH_FILE"] = str(pull_secret)
        if (Path.home() / ".docker" / "config.json").is_file():
            print(
                "WARNING: ~/.docker/config.json exists and takes precedence "
                "over REGISTRY_AUTH_FILE for cosign's registry auth. If it "
                "lacks registry.redhat.io credentials, cosign verification "
                "will still fail with UNAUTHORIZED regardless of "
                "--pull-secret/PULL_SECRET.",
                file=sys.stderr,
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

    print("==========================================")
    print("Firmware Reference Value Collection")
    print("==========================================")
    print(f"Platform:       {args.platform}")
    print(f"Version:        {version_display} (source: {version_source})")
    print(f"OSC version:    {', '.join(osc_versions)} (source: {osc_source})")
    print(f"Bot version:    {bot_version}")
    print(f"TEE Type(s):    {' '.join(tees_to_run)}")
    print(f"Output file:    {output_file}")
    print()

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

    print(f"Merging reference values from: {' '.join(tees_to_run)}...")
    merged = merge_reference_values(per_tee_values)

    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(json.dumps(merged, indent=2) + "\n")

    print()
    print("Collected firmware reference values:")
    print(json.dumps(merged, indent=2))
    print()
    print(f"Saved to: {output_file}")
    print()

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
        print(f"Created empty placeholder for the other platform: {sibling}")
        print()

    print("Next steps:")
    print(f"1. Review the collected values: cat {output_file}")
    print(f"2. Ensure '{vault_key}' is configured in ~/values-secret-coco-pattern.yaml")
    print("3. Run: make load-secrets")
    print()


def main(argv=None):
    args = parse_args(argv)
    try:
        run(args)
    except CollectionError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
