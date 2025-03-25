# SPDX-FileCopyrightText: 2024-present Red Hat Inc
#
# SPDX-License-Identifier: Apache-2.0
import json
import os
import pathlib
import shutil

import typer
from jinja2 import Environment, FileSystemLoader, select_autoescape
from rich import print as rprint
from typing_extensions import Annotated


def cleanup(pattern_dir: pathlib.Path) -> None:
    """Cleanup directory"""

    install_dir = pattern_dir / "openshift-install"
    azure_dir = pathlib.Path.home() / ".azure"

    if install_dir.exists() and install_dir.is_dir():
        shutil.rmtree(install_dir)
    install_dir.mkdir()
    if azure_dir.exists() and azure_dir.is_dir():
        shutil.rmtree(azure_dir)


def validate_dir():
    """Simple validation for directory"""
    assert pathlib.Path("values-global.yaml").exists()
    assert pathlib.Path("values-simple.yaml").exists()


def setup_install(
    pattern_dir: pathlib.Path,
    region: str,
    pull_secret_path: pathlib.Path,
    ssh_key_path: pathlib.Path,
):
    """create the install config file"""
    try:
        GUID = os.environ["GUID"]
        RESOURCEGROUP = os.environ["RESOURCEGROUP"]
    except KeyError as e:
        rprint("Unable to get azure environment details")
        raise e
    # Read ssh_public_key
    ssh_key = ssh_key_path.expanduser().read_text()
    pull_secret = pull_secret_path.expanduser().read_text()
    rhdp_dir = pattern_dir / "rhdp"
    jinja_env = Environment(
        loader=FileSystemLoader(searchpath= rhdp_dir), autoescape=select_autoescape()
    )
    config_template = jinja_env.get_template("install-config.yaml.j2")
    output_text = config_template.render(
        GUID=GUID,
        RESOURCEGROUP=RESOURCEGROUP,
        ssh_key=ssh_key,
        pull_secret=pull_secret,
        region=region,
    )
    install_config = pattern_dir / "openshift-install/install-config.yaml"
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


def run(region: Annotated[str, typer.Argument()] = "eastasia"):
    """warpper function for cli parsing as required"""
    validate_dir()
    cleanup(pathlib.Path.cwd())
    setup_install(
        pathlib.Path.cwd(),
        region,
        pathlib.Path("~/pull-secret.json"),
        pathlib.Path("~/.ssh/id_rsa.pub"),
    )
    write_azure_creds()


if __name__ == "__main__":
    typer.run(run)
