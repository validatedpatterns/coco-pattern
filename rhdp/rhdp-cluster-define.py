# SPDX-FileCopyrightText: 2024-present Red Hat Inc
#
# SPDX-License-Identifier: Apache-2.0
import json
import os
import pathlib
import shutil
from typing import Dict, List, Optional

import typer
from jinja2 import Environment, FileSystemLoader, select_autoescape
from rich import print as rprint
from typing_extensions import Annotated


def get_default_cluster_configs(prefix: str = "") -> List[Dict]:
    """Get default cluster configurations

    Args:
        prefix: Optional prefix to add to cluster name and directory
    """
    if prefix:
        return [
            {
                "name": f"coco-{prefix}",
                "directory": f"openshift-install-{prefix}",
                "cluster_network_cidr": "10.128.0.0/14",
                "machine_network_cidr": "10.0.0.0/16",
                "service_network_cidr": "172.30.0.0/16",
            }
        ]
    return [
        {
            "name": "coco",
            "directory": "openshift-install",
            "cluster_network_cidr": "10.128.0.0/14",
            "machine_network_cidr": "10.0.0.0/16",
            "service_network_cidr": "172.30.0.0/16",
        }
    ]


def get_multicluster_configs() -> List[Dict]:
    """Get multicluster configurations for hub and spoke"""
    return [
        {
            "name": "coco-hub",
            "directory": "openshift-install-hub",
            "cluster_network_cidr": "10.128.0.0/14",
            "machine_network_cidr": "10.0.0.0/16",
            "service_network_cidr": "172.30.0.0/16",
        },
        {
            "name": "coco-spoke",
            "directory": "openshift-install-spoke",
            "cluster_network_cidr": "10.132.0.0/14",
            "machine_network_cidr": "10.4.0.0/16",
            "service_network_cidr": "172.34.0.0/16",
        },
    ]


# Files openshift-install writes early in "create cluster" that indicate an
# install directory already holds state for a (possibly still-live) cluster.
STATE_MARKER_FILES = ("metadata.json",)


def _existing_state_dirs(
    pattern_dir: pathlib.Path, cluster_configs: List[Dict]
) -> List[Dict]:
    """Return the cluster configs whose install directory already holds
    cluster state (i.e. a previous `create cluster` was run there)."""
    existing = []
    for config in cluster_configs:
        install_dir = pattern_dir / config["directory"]
        if install_dir.exists() and any(
            (install_dir / marker).exists() for marker in STATE_MARKER_FILES
        ):
            existing.append(config)
    return existing


def cleanup(
    pattern_dir: pathlib.Path,
    cluster_configs: List[Dict],
    recreate: bool = False,
) -> None:
    """Cleanup directories for all clusters.

    Refuses to touch an install directory that already holds cluster state
    unless `recreate` is explicitly set. Wiping that directory destroys the
    only local record `openshift-install` has of any cloud resources it
    previously provisioned there, which is what silently turns a re-run into
    an unintentional "recreate" of the cluster (and can orphan the old cloud
    resources). This function does NOT run `openshift-install destroy
    cluster` on your behalf — see the warning printed below.
    """
    azure_dir = pathlib.Path.home() / ".azure"

    existing = _existing_state_dirs(pattern_dir, cluster_configs)

    if existing and not recreate:
        rprint("[red]ERROR: Existing cluster install state detected:[/red]")
        for config in existing:
            rprint(f"  - {config['name']}: {pattern_dir / config['directory']}")
        rprint(
            "\n[yellow]Refusing to overwrite without --recreate.[/yellow]\n"
            "This tool does NOT run 'openshift-install destroy cluster' for you.\n"
            "Before re-running with --recreate, either:\n"
            "  1. Destroy the existing cluster's cloud resources yourself:\n"
            "     openshift-install destroy cluster --dir=<install_dir>\n"
            "  2. Or confirm the cloud resources are already gone / were never "
            "created.\n"
            "Re-running with --recreate will DELETE the local install state above\n"
            "WITHOUT destroying any associated cloud resources, which can orphan them."
        )
        raise typer.Exit(code=1)

    if existing:
        rprint("[yellow]--recreate specified: wiping local install state for:[/yellow]")
        for config in existing:
            rprint(f"  - {config['name']}: {pattern_dir / config['directory']}")
        rprint(
            "[yellow]NOTE: this does NOT call 'openshift-install destroy cluster'. "
            "If cloud resources still exist from the previous install, they will "
            "be orphaned. Destroy them manually first if needed.[/yellow]"
        )

    for config in cluster_configs:
        install_dir = pattern_dir / config["directory"]
        if install_dir.exists() and install_dir.is_dir():
            shutil.rmtree(install_dir)
        install_dir.mkdir()

    if azure_dir.exists() and azure_dir.is_dir():
        shutil.rmtree(azure_dir)


def validate_dir():
    """Simple validation for directory"""
    assert pathlib.Path("values-global.yaml").exists()
    assert pathlib.Path("values-azure.yaml").exists()


# Default SSH public key candidates to auto-detect, in preference order.
# Ed25519 first (current best practice), falling back through ECDSA to RSA
# for backwards compatibility with existing keys.
DEFAULT_SSH_KEY_CANDIDATES = ("id_ed25519", "id_ecdsa", "id_rsa")


def resolve_pull_secret(override: Optional[str]) -> pathlib.Path:
    """Resolve the OpenShift pull secret path.

    Honors an explicit override (--pull-secret / PULL_SECRET env var), else
    falls back to the historical default of ~/pull-secret.json.
    """
    path = (
        pathlib.Path(override).expanduser()
        if override
        else pathlib.Path("~/pull-secret.json").expanduser()
    )
    if not path.exists():
        rprint(f"[red]ERROR: OpenShift pull secret not found at {path}[/red]")
        rprint(
            "Download it from https://console.redhat.com/openshift/downloads "
            "and save it there, or point to it with --pull-secret / the "
            "PULL_SECRET environment variable."
        )
        raise typer.Exit(code=1)
    return path


def resolve_ssh_public_key(override: Optional[str]) -> pathlib.Path:
    """Resolve the SSH public key to embed in install-config.yaml.

    Honors an explicit override (--ssh-public-key / SSH_PUBLIC_KEY env var).
    Otherwise auto-detects the user's default key, preferring Ed25519, then
    ECDSA, then RSA (first match wins) -- current best practice while
    remaining backwards compatible with existing RSA-only setups.
    """
    if override:
        path = pathlib.Path(override).expanduser()
        if not path.exists():
            rprint(f"[red]ERROR: SSH public key not found at {path}[/red]")
            raise typer.Exit(code=1)
        return path

    ssh_dir = pathlib.Path.home() / ".ssh"
    for candidate in DEFAULT_SSH_KEY_CANDIDATES:
        candidate_path = ssh_dir / f"{candidate}.pub"
        if candidate_path.exists():
            return candidate_path

    checked = ", ".join(str(ssh_dir / f"{c}.pub") for c in DEFAULT_SSH_KEY_CANDIDATES)
    rprint("[red]ERROR: No SSH public key found.[/red]")
    rprint(
        f"Checked (in order): {checked}\n"
        "Generate a modern key with: ssh-keygen -t ed25519\n"
        "Or point to an existing one with --ssh-public-key / the "
        "SSH_PUBLIC_KEY environment variable."
    )
    raise typer.Exit(code=1)


def setup_install(
    pattern_dir: pathlib.Path,
    region: str,
    pull_secret_path: pathlib.Path,
    ssh_key_path: pathlib.Path,
    cluster_configs: List[Dict],
):
    """create the install config files for all clusters"""
    try:
        GUID = os.environ["GUID"]
        RESOURCEGROUP = os.environ["RESOURCEGROUP"]
    except KeyError as e:
        rprint("Unable to get azure environment details")
        raise e

    # Read ssh_public_key and pull_secret
    ssh_key = ssh_key_path.expanduser().read_text()
    pull_secret = pull_secret_path.expanduser().read_text()
    rhdp_dir = pattern_dir / "rhdp"
    jinja_env = Environment(
        loader=FileSystemLoader(searchpath=rhdp_dir), autoescape=select_autoescape()
    )
    config_template = jinja_env.get_template("install-config.yaml.j2")

    # Create install config for each cluster
    for config in cluster_configs:
        rprint(f"Creating install config for cluster: {config['name']}")
        output_text = config_template.render(
            GUID=GUID,
            RESOURCEGROUP=RESOURCEGROUP,
            ssh_key=ssh_key,
            pull_secret=pull_secret,
            region=region,
            cluster_name=config["name"],
            cluster_network_cidr=config["cluster_network_cidr"],
            machine_network_cidr=config["machine_network_cidr"],
            service_network_cidr=config["service_network_cidr"],
        )
        install_config = pattern_dir / config["directory"] / "install-config.yaml"
        install_config.write_text(output_text)


def write_azure_creds():
    """write azure creds based on env vars"""
    azure_dir = azure_dir = pathlib.Path.home() / ".azure"
    azure_dir.mkdir(exist_ok=True)
    sp_path = azure_dir / "osServicePrincipal.json"

    keymap = {
        "subscriptionId": os.environ["SUBSCRIPTION"],
        "clientId": os.environ["CLIENT_ID"],
        "clientSecret": os.environ["PASSWORD"],
        "tenantId": os.environ["TENANT"],
    }

    with open(sp_path, "w", encoding="utf-8") as file:
        json.dump(keymap, file)


def print():
    rprint("Run openshift install .")


def run(
    region: Annotated[str, typer.Argument(help="Azure region code")],
    multicluster: Annotated[
        bool, typer.Option("--multicluster", help="Deploy hub and spoke clusters")
    ] = False,
    prefix: Annotated[
        str, typer.Option("--prefix", help="Prefix for cluster name and directory")
    ] = "",
    recreate: Annotated[
        bool,
        typer.Option(
            "--recreate",
            help=(
                "Required if the install directory already has cluster state. "
                "Wipes the local install state so a new cluster can be created. "
                "Does NOT destroy cloud resources from a previous install -- "
                "destroy those yourself first if they still exist."
            ),
        ),
    ] = False,
    pull_secret: Annotated[
        Optional[str],
        typer.Option(
            "--pull-secret",
            envvar="PULL_SECRET",
            help="Path to the OpenShift pull secret (default: ~/pull-secret.json).",
        ),
    ] = None,
    ssh_public_key: Annotated[
        Optional[str],
        typer.Option(
            "--ssh-public-key",
            envvar="SSH_PUBLIC_KEY",
            help=(
                "Path to an SSH public key to embed in install-config.yaml. "
                "Defaults to auto-detecting ~/.ssh/id_ed25519.pub, then "
                "id_ecdsa.pub, then id_rsa.pub (first match wins)."
            ),
        ),
    ] = None,
):
    """
    Region flag requires an azure region key which can be (authoritatively)
    requested with: "az account list-locations -o table".

    Use --multicluster flag to deploy both hub (coco-hub) and spoke (coco-spoke)
    clusters.

    Use --prefix to add a prefix to cluster name and install directory, enabling
    multiple cluster deployments (e.g., --prefix cluster1 creates coco-cluster1
    in openshift-install-cluster1).

    Use --recreate to allow wiping an install directory that already has
    cluster state. Without it, the command refuses to touch a directory that
    looks like it belongs to a previous (possibly still-live) cluster. This
    does NOT run "openshift-install destroy cluster" for you.

    Use --pull-secret (or the PULL_SECRET environment variable) to override
    the OpenShift pull secret location (default: ~/pull-secret.json).

    Use --ssh-public-key (or the SSH_PUBLIC_KEY environment variable) to
    override the SSH public key embedded in install-config.yaml. Without an
    override, the key is auto-detected, preferring ~/.ssh/id_ed25519.pub,
    then id_ecdsa.pub, then id_rsa.pub.
    """
    validate_dir()

    # Resolve and validate secrets/keys before touching any install
    # directory, so a missing pull secret or SSH key can't trigger a
    # destructive cleanup() only to fail afterwards.
    pull_secret_path = resolve_pull_secret(pull_secret)
    ssh_public_key_path = resolve_ssh_public_key(ssh_public_key)

    # Choose cluster configurations based on multicluster flag
    if multicluster:
        if prefix:
            rprint("WARNING: --prefix is ignored when using --multicluster")
        cluster_configs = get_multicluster_configs()
        rprint("Setting up multicluster deployment (hub and spoke)")
    else:
        cluster_configs = get_default_cluster_configs(prefix)
        if prefix:
            rprint(f"Setting up single cluster deployment with prefix: {prefix}")
        else:
            rprint("Setting up single cluster deployment")

    cleanup(pathlib.Path.cwd(), cluster_configs, recreate=recreate)
    setup_install(
        pathlib.Path.cwd(),
        region,
        pull_secret_path,
        ssh_public_key_path,
        cluster_configs,
    )
    write_azure_creds()


if __name__ == "__main__":
    typer.run(run)
