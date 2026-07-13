"""Golden + determinism tests for the renderer.

The golden fixture comes from the FOP core team's alignment doc (2026-07-13)
and is verified identical to the daemon's Go rbac.PayloadSHA256. If this test
fails, DO NOT ship a render — the daemon will reject every manifest.

Run:  .venv/bin/python -m pytest render/test_render.py   (or plain python)
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render import payload_sha256  # noqa: E402

GOLDEN_BREWFILE = 'tap "farmer1st/fop"\nbrew "htop"\ncask "visual-studio-code"\n'
GOLDEN_SHA = "f81b15bfd39fdb77603b1146971e3f805afb4e016cc4d0ab7922d3b68cb74484"


def test_golden_fixture():
    assert payload_sha256(GOLDEN_BREWFILE, [], ["docker"]) == GOLDEN_SHA


def test_defaults_are_empty_arrays_not_null():
    # None must hash identically to [] — the daemon canonicalizes to [].
    assert payload_sha256("x\n", None, None) == payload_sha256("x\n", [], [])


def test_render_is_deterministic():
    root = Path(__file__).resolve().parent.parent
    py = sys.executable
    with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
        for d in (d1, d2):
            subprocess.run([py, str(root / "render/render.py"), "--out", d],
                           check=True, capture_output=True)
        f1 = sorted(Path(d1).rglob("*.json"))
        f2 = sorted(Path(d2).rglob("*.json"))
        assert [p.relative_to(d1) for p in f1] == [p.relative_to(d2) for p in f2]
        for a, b in zip(f1, f2):
            assert a.read_bytes() == b.read_bytes(), f"nondeterministic: {a.name}"


def test_index_matches_manifests():
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory() as d:
        subprocess.run([sys.executable, str(root / "render/render.py"), "--out", d],
                       check=True, capture_output=True)
        index = json.loads((Path(d) / "manifests/index.json").read_text())
        assert index["devices"], "devices map must not be empty"
        for login, entry in index["users"].items():
            m = json.loads((Path(d) / entry["path"]).read_text())
            assert m["user"] == login
            assert m["payload_sha256"] == entry["payload_sha256"]
            # recompute: the file's declared sha must be honest
            assert payload_sha256(m["brewfile"], m["system"], m["whitelist"]) \
                == entry["payload_sha256"]


if __name__ == "__main__":
    test_golden_fixture()
    test_defaults_are_empty_arrays_not_null()
    test_render_is_deterministic()
    test_index_matches_manifests()
    print("all renderer tests passed (golden sha verified)")
