"""Unit tests for the local DCAP PCK bundle contract."""

import importlib.util
import json
import struct
from pathlib import Path

import pytest

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("dcap_pck", REPOSITORY_ROOT / "scripts/dcap-pck.py")
assert SPEC and SPEC.loader
dcap_pck = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dcap_pck)


def platform(qe_id: str = "a" * 32, pce_id: str = "0000") -> dict[str, str]:
    return {
        "enc_ppid": "",
        "pce_id": pce_id,
        "cpu_svn": "b" * 32,
        "pce_svn": "0000",
        "qe_id": qe_id,
        "platform_manifest": "c0ffee",
    }


def test_platform_validation_rejects_duplicate_qe_pce_pairs():
    with pytest.raises(ValueError, match="duplicate"):
        dcap_pck.validate_platforms([platform(), platform()])


def test_platform_validation_rejects_duplicate_qe_ids():
    with pytest.raises(ValueError, match="duplicate QE IDs"):
        dcap_pck.validate_platforms([platform(), platform(pce_id="0001")])


def test_request_bundle_detects_tampered_platform_list(tmp_path: Path):
    bundle = tmp_path / "request"
    bundle.mkdir()
    platforms = bundle / "platform-list.json"
    dcap_pck.write_json(platforms, [platform()])
    dcap_pck.write_json(
        bundle / "manifest.json",
        dcap_pck.create_manifest(dcap_pck.REQUEST_TYPE, {"platform-list.json": platforms}),
    )
    platforms.write_text("[]\n", encoding="utf-8")

    with pytest.raises(ValueError, match="checksum mismatch"):
        dcap_pck.request_platforms(bundle)


def test_response_bundle_rejects_expired_cache(tmp_path: Path):
    bundle = tmp_path / "response"
    cache_dir = bundle / "pck"
    cache_dir.mkdir(parents=True)
    cache = cache_dir / ("a" * 32 + "_0000")
    cache.write_bytes(struct.pack("<HIQ", 1, 4, 1))
    dcap_pck.write_json(
        bundle / "manifest.json",
        dcap_pck.create_manifest(
            dcap_pck.RESPONSE_TYPE,
            {f"pck/{cache.name}": cache},
            platforms=[platform()],
        ),
    )

    with pytest.raises(ValueError, match="expired"):
        dcap_pck.response_cache(bundle)


def test_read_api_key_removes_environment_value(monkeypatch):
    monkeypatch.setenv("INTEL_PCS_API_KEY", "test-canary")

    assert dcap_pck.read_api_key() == "test-canary"
    assert "INTEL_PCS_API_KEY" not in dcap_pck.os.environ


def test_platform_data_decoding_uses_exact_required_fields(monkeypatch):
    encoded = {key: dcap_pck.base64.b64encode(value.encode()).decode() for key, value in platform().items()}
    monkeypatch.setattr(dcap_pck, "run_oc", lambda _: json.dumps({"items": [{"data": encoded}]}))

    assert dcap_pck.cluster_platforms("intel-dcap-operator-system") == [platform()]


def test_response_bundle_rejects_cache_larger_than_secret_limit(tmp_path: Path):
    cache = tmp_path / "oversized"
    cache.write_bytes(b"x" * (dcap_pck.MAX_CACHE_BYTES + 1))

    with pytest.raises(ValueError, match="exceeds"):
        dcap_pck.cache_metadata(cache)


def test_import_refuses_changed_platform_data(monkeypatch, tmp_path: Path):
    response = tmp_path / "response"
    cache_dir = response / "pck"
    cache_dir.mkdir(parents=True)
    cache = cache_dir / ("a" * 32 + "_0000")
    cache.write_bytes(struct.pack("<HIQ", 1, 4, 4_000_000_000))
    dcap_pck.write_json(
        response / "manifest.json",
        dcap_pck.create_manifest(dcap_pck.RESPONSE_TYPE, {f"pck/{cache.name}": cache}, platforms=[platform()]),
    )
    changed = platform()
    changed["cpu_svn"] = "d" * 32
    monkeypatch.setattr(dcap_pck, "cluster_platforms", lambda _: [changed])

    with pytest.raises(ValueError, match="platform data does not match"):
        dcap_pck.command_import(type("Arguments", (), {"input": str(response), "namespace": "test", "qgs_selector": "app=test", "timeout": "1m"})())
