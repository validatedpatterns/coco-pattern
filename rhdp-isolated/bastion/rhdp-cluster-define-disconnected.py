# SPDX-FileCopyrightText: 2024-present Red Hat Inc
#
# SPDX-License-Identifier: Apache-2.0
"""
Generate disconnected OpenShift install-config.yaml for CoCo pattern.
This is adapted from rhdp/rhdp-cluster-define.py with disconnected networking.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys

import typer
from jinja2 import Environment, FileSystemLoader, select_autoescape
from rich import print as rprint
from typing_extensions import Annotated


def cleanup(pattern_dir: pathlib.Path, use_upi: bool = False) -> None:
    """Cleanup directory"""
    # Use UPI directory if requested, otherwise IPI
    dir_name = "openshift-install-upi" if use_upi else "openshift-install-disconnected"
    install_dir = pattern_dir / dir_name
    azure_dir = pathlib.Path.home() / ".azure"

    if install_dir.exists() and install_dir.is_dir():
        shutil.rmtree(install_dir)
    install_dir.mkdir()
    
    # Don't remove azure dir as it should already exist from configure-bastion


def validate_dir():
    """Simple validation for directory"""
    assert pathlib.Path("values-global.yaml").exists()
    assert pathlib.Path("values-simple.yaml").exists()


def get_acr_certificate(acr_login_server: str) -> str:
    """
    Get the CA certificate for ACR.
    In disconnected environments, we need to trust the ACR certificate.
    """
    try:
        # Try to get certificate using openssl
        result = subprocess.run(
            ["openssl", "s_client", "-connect", f"{acr_login_server}:443", "-showcerts"],
            input=b"",
            capture_output=True,
            timeout=10
        )
        
        if result.returncode == 0:
            output = result.stdout.decode('utf-8')
            # Extract the certificate
            certs = []
            in_cert = False
            cert_lines = []
            
            for line in output.split('\n'):
                if '-----BEGIN CERTIFICATE-----' in line:
                    in_cert = True
                    cert_lines = [line]
                elif '-----END CERTIFICATE-----' in line:
                    cert_lines.append(line)
                    certs.append('\n'.join(cert_lines))
                    in_cert = False
                elif in_cert:
                    cert_lines.append(line)
            
            if certs:
                # Return the first certificate (should be the ACR cert)
                return certs[0]
        
        rprint("[yellow]Warning: Could not retrieve ACR certificate automatically[/yellow]")
        return ""
    except Exception as e:
        rprint(f"[yellow]Warning: Failed to get ACR certificate: {e}[/yellow]")
        return ""


def parse_idms_to_digest_sources(cluster_resources_dir: pathlib.Path) -> str:
    """
    Parse ImageDigestMirrorSet YAML files and convert to imageDigestSources format.
    Returns YAML string for imageDigestSources section.
    """
    import yaml
    
    digest_sources = []
    
    # Find all IDMS files
    idms_files = list(cluster_resources_dir.glob("idms-*.yaml"))
    
    if not idms_files:
        rprint("[yellow]Warning: No IDMS files found in cluster resources[/yellow]")
        return ""
    
    for idms_file in idms_files:
        try:
            with open(idms_file, 'r') as f:
                # Use safe_load_all to handle multi-document YAML files
                for idms_content in yaml.safe_load_all(f):
                    if idms_content and 'spec' in idms_content and 'imageDigestMirrors' in idms_content['spec']:
                        for mirror in idms_content['spec']['imageDigestMirrors']:
                            source_entry = {
                                'source': mirror.get('source', ''),
                                'mirrors': mirror.get('mirrors', [])
                            }
                            digest_sources.append(source_entry)
        except Exception as e:
            rprint(f"[yellow]Warning: Failed to parse {idms_file.name}: {e}[/yellow]")
    
    if not digest_sources:
        return ""
    
    # Convert to YAML string
    yaml_str = yaml.dump(digest_sources, default_flow_style=False, sort_keys=False)
    return yaml_str


def setup_install(
    pattern_dir: pathlib.Path,
    region: str,
    pull_secret_path: pathlib.Path,
    ssh_key_path: pathlib.Path,
    use_upi: bool = False,
):
    """Create the disconnected install config file"""
    try:
        GUID = os.environ["GUID"]
        RESOURCEGROUP = os.environ["RESOURCEGROUP"]
        ACR_LOGIN_SERVER = os.environ["ACR_LOGIN_SERVER"]
    except KeyError as e:
        rprint(f"[red]Unable to get required environment variable: {e}[/red]")
        raise e
    
    # Get network configuration from Terraform outputs or environment
    # These should be set by the wrapper script
    vnet_name = os.environ.get("VNET_NAME", f"vnet-coco-disconnected-{GUID}")
    master_subnet_name = os.environ.get("MASTER_SUBNET_NAME", "subnet-master")
    worker_subnet_name = os.environ.get("WORKER_SUBNET_NAME", "subnet-worker")
    
    # Read ssh_public_key
    ssh_key = ssh_key_path.expanduser().read_text().strip()
    pull_secret = pull_secret_path.expanduser().read_text().strip()
    
    # Get ACR certificate
    rprint("[info]Retrieving ACR certificate...[/info]")
    additional_trust_bundle = get_acr_certificate(ACR_LOGIN_SERVER)
    
    if not additional_trust_bundle:
        rprint("[yellow]Warning: No ACR certificate retrieved. You may need to add it manually.[/yellow]")
        additional_trust_bundle = "# No certificate retrieved automatically"
    
    # Parse IDMS files to imageDigestSources
    cluster_resources_dir = pattern_dir / "cluster-resources"
    if not cluster_resources_dir.exists():
        rprint("[red]Error: cluster-resources directory not found[/red]")
        rprint("[red]Please run mirror.sh first[/red]")
        sys.exit(1)
    
    rprint("[info]Parsing ImageDigestMirrorSet configurations...[/info]")
    image_digest_sources = parse_idms_to_digest_sources(cluster_resources_dir)
    
    if not image_digest_sources:
        rprint("[yellow]Warning: No image digest sources found. Install may fail.[/yellow]")
    
    # Setup Jinja environment
    bastion_dir = pattern_dir / "rhdp-isolated" / "bastion"
    jinja_env = Environment(
        loader=FileSystemLoader(searchpath=bastion_dir),
        autoescape=select_autoescape()
    )
    
    config_template = jinja_env.get_template("install-config.yaml.j2")
    output_text = config_template.render(
        GUID=GUID,
        RESOURCEGROUP=RESOURCEGROUP,
        ssh_key=ssh_key,
        pull_secret=pull_secret,
        region=region,
        vnet_name=vnet_name,
        master_subnet_name=master_subnet_name,
        worker_subnet_name=worker_subnet_name,
        additional_trust_bundle=additional_trust_bundle,
        image_digest_sources=image_digest_sources
    )
    
    # Use UPI directory if requested, otherwise IPI
    dir_name = "openshift-install-upi" if use_upi else "openshift-install-disconnected"
    install_config = pattern_dir / dir_name / "install-config.yaml"
    install_config.write_text(output_text)
    
    rprint(f"[green]Install config created at: {install_config}[/green]")


def write_azure_creds():
    """Write azure creds based on env vars (should already exist from configure-bastion)"""
    azure_dir = pathlib.Path.home() / ".azure"
    sp_path = azure_dir / "osServicePrincipal.json"
    
    if sp_path.exists():
        rprint("[info]Azure credentials already configured[/info]")
        return
    
    azure_dir.mkdir(exist_ok=True)
    
    keymap = {
        "subscriptionId": os.environ["SUBSCRIPTION"],
        "clientId": os.environ["CLIENT_ID"],
        "clientSecret": os.environ["PASSWORD"],
        "tenantId": os.environ["TENANT"],
    }
    
    with open(sp_path, "w", encoding="utf-8") as file:
        json.dump(keymap, file)
    
    rprint("[green]Azure credentials configured[/green]")


def run(
    region: Annotated[str, typer.Argument(help="Azure region code")],
    upi: Annotated[bool, typer.Option("--upi", help="Generate config for UPI deployment")] = False,
):
    """
    Generate disconnected install-config.yaml for CoCo pattern.
    Region flag requires an azure region key which can be (authoritatively)
    requested with: "az account list-locations -o table".
    """
    mode = "UPI" if upi else "IPI"
    rprint(f"[bold blue]CoCo Pattern - Disconnected Install Config Generator ({mode})[/bold blue]")
    
    validate_dir()
    cleanup(pathlib.Path.cwd(), use_upi=upi)
    setup_install(
        pathlib.Path.cwd(),
        region,
        pathlib.Path("~/pull-secret.json"),
        pathlib.Path("~/.ssh/id_rsa.pub"),
        use_upi=upi,
    )
    write_azure_creds()
    
    rprint("[bold green]Install config generation complete![/bold green]")


if __name__ == "__main__":
    typer.run(run)

