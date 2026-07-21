"""Golden + determinism tests for the renderer.

The golden fixture comes from the FOP core team's alignment doc (2026-07-13)
and is verified identical to the daemon's Go rbac.PayloadSHA256. If this test
fails, DO NOT ship a render — the daemon will reject every manifest.

Run:  .venv/bin/python -m pytest render/test_render.py   (or plain python)
"""
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render import payload_sha256, render_brewfile, resolve_apps  # noqa: E402

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


def test_manifest_shape_is_frozen():
    """The daemon's contract is FROZEN: rendered manifests carry exactly these
    keys and nothing else. New profile features (appRoles, registries, ...)
    must never leak into what Abra consumes.
    Contract change log:
      2026-07-20  + local_account (abra findings #3) — additive: outside the
                  hashed payload, ignored by daemons that predate it."""
    FROZEN_KEYS = {"schema", "user", "local_account", "brewfile", "system",
                   "whitelist", "payload_sha256"}
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory() as d:
        subprocess.run([sys.executable, str(root / "render/render.py"), "--out", d],
                       check=True, capture_output=True)
        for f in (Path(d) / "manifests/users").glob("*.json"):
            keys = set(json.loads(f.read_text()).keys())
            assert keys == FROZEN_KEYS, f"{f.name}: manifest keys drifted: {keys ^ FROZEN_KEYS}"


def test_canonical_form_is_utf8_not_escaped():
    """The recipe is raw UTF-8, no \\uXXXX escaping, no trailing newline —
    freezes the Python-side canonical form against serializer drift."""
    expected = hashlib.sha256(
        b'{"brewfile":"caf\xc3\xa9\\n","system":[],"whitelist":[]}').hexdigest()
    assert payload_sha256("café\n", [], []) == expected


def test_brewfile_ordering_id_not_key():
    """Brewfile ordering is load-bearing for byte-identity: formulae first,
    then casks, each sorted by brew ID (not by catalog key, not input order)."""
    catalog = {"apps": {
        "zz-formula": {"source": "formula", "id": "aaa"},
        "aa-cask":    {"source": "cask",    "id": "zzz"},
        "wrangler":   {"source": "formula", "id": "cloudflare-wrangler"},
        "terraform":  {"source": "formula", "id": "hashicorp/tap/terraform"},
    }}
    out = render_brewfile(catalog, ["aa-cask", "terraform", "zz-formula", "wrangler"])
    assert out == ('brew "aaa"\nbrew "cloudflare-wrangler"\n'
                   'brew "hashicorp/tap/terraform"\ncask "zzz"\n')
    assert render_brewfile(catalog, []) == ""  # empty set renders "" (not "\n")


def test_resolve_apps_override_semantics():
    """Union dedupes; add-then-remove means remove wins; removes of ungranted
    apps are no-ops; adds never duplicate."""
    roles = {"r1": {"apps": ["a", "b"]}, "r2": {"apps": ["b", "c"]}}
    u = lambda **kw: {"roles": ["r1", "r2"], **kw}
    assert resolve_apps({}, roles, u()) == ["a", "b", "c"]
    got = resolve_apps({}, roles, u(overrides={"add": ["d"], "remove": ["b"]}))
    assert set(got) == {"a", "c", "d"} and len(got) == len(set(got))
    assert "b" not in resolve_apps({}, roles, u(overrides={"add": ["b"], "remove": ["b"]}))
    assert resolve_apps({}, roles, u(overrides={"remove": ["nope"]})) == ["a", "b", "c"]
    got = resolve_apps({}, roles, u(overrides={"add": ["a"]}))
    assert len(got) == len(set(got))


def test_full_manifest_bytes_are_frozen():
    """One whole manifest pinned byte-for-byte (smallest user: yuthneak).
    Freezes the serializer (indent-2, sorted keys, trailing newline, raw UTF-8),
    the empty-brewfile form (""), and the local_account login-default. This
    golden changes ONLY on a deliberate contract change — serializer drift
    breaks byte-identity with every previously published manifest."""
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory() as d:
        subprocess.run([sys.executable, str(root / "render/render.py"), "--out", d],
                       check=True, capture_output=True)
        got = (Path(d) / "manifests/users/yuthneak.json").read_bytes()
    assert got == (b'{\n'
                   b'  "brewfile": "",\n'
                   b'  "local_account": "yuthneak",\n'
                   b'  "payload_sha256": "ea02dea45d14a3a7d314ea48f1310d49db6869126932660ccbac34a3fe61cba7",\n'
                   b'  "schema": "fop.rendered-manifest/v1",\n'
                   b'  "system": [],\n'
                   b'  "user": "yuthneak",\n'
                   b'  "whitelist": []\n'
                   b'}\n')


def test_prev_index_version_carry_forward():
    """--prev-index is the only runtime input that shapes output: same sha
    carries the version forward, changed sha bumps it, absent users seed at 1 —
    and NOTHING but index versions may differ from a fresh render."""
    root = Path(__file__).resolve().parent.parent
    py = sys.executable
    with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
        subprocess.run([py, str(root / "render/render.py"), "--out", d1],
                       check=True, capture_output=True)
        idx1 = json.loads((Path(d1) / "manifests/index.json").read_text())
        assert all(e["version"] == 1 for e in idx1["users"].values()), \
            "fresh render must seed every version at 1"
        logins = sorted(idx1["users"])
        keep, bump, absent = logins[0], logins[1], logins[2]
        prev = {"users": {
            keep: {**idx1["users"][keep], "version": 3},                      # same sha
            bump: {**idx1["users"][bump], "payload_sha256": "0" * 64,         # changed sha
                   "version": 7},
        }}
        prev_path = Path(d2) / "prev-index.json"
        prev_path.write_text(json.dumps(prev))
        subprocess.run([py, str(root / "render/render.py"), "--out", d2,
                        "--prev-index", str(prev_path)],
                       check=True, capture_output=True)
        idx2 = json.loads((Path(d2) / "manifests/index.json").read_text())
        assert idx2["users"][keep]["version"] == 3, "matching sha must carry forward"
        assert idx2["users"][bump]["version"] == 8, "changed sha must bump"
        assert idx2["users"][absent]["version"] == 1, "new user must seed at 1"
        # nothing else may differ: per-user manifests byte-identical, index
        # identical after normalizing versions
        for f in sorted((Path(d1) / "manifests/users").glob("*.json")):
            assert f.read_bytes() == (Path(d2) / "manifests/users" / f.name).read_bytes()
        for e in (idx1, idx2):
            for u in e["users"].values():
                u["version"] = 0
        assert idx1 == idx2


def test_local_account_defaults_and_stays_out_of_payload():
    """local_account defaults to the login; setting it must change NOTHING in
    the hashed payload (revocation/change detection stays purely app-driven)."""
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory() as d:
        subprocess.run([sys.executable, str(root / "render/render.py"), "--out", d],
                       check=True, capture_output=True)
        docs = {f.stem: json.loads(f.read_text())
                for f in (Path(d) / "manifests/users").glob("*.json")}
        # company users declare macOS accounts (email local-part convention);
        # yuthneak (personal-gmail test user, no company Mac) rides the default
        assert docs["vireakyuth"]["local_account"] == "vireakyuth.neak"
        assert docs["damon-hase"]["local_account"] == "damon.hase"
        assert docs["yuthneak"]["local_account"] == "yuthneak"
        for m in docs.values():  # never part of the hash
            assert payload_sha256(m["brewfile"], m["system"], m["whitelist"]) \
                == m["payload_sha256"]


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
        # bijection: no orphan files, no missing files; every enrolled device
        # resolves to a rendered manifest; devices map is rendered verbatim
        import yaml
        root = Path(__file__).resolve().parent.parent
        stems = {f.stem for f in (Path(d) / "manifests/users").glob("*.json")}
        assert stems == set(index["users"])
        assert set(index["devices"].values()) <= set(index["users"])
        assert index["devices"] == yaml.safe_load(
            (root / "profiles/devices.yml").read_text())["devices"]


if __name__ == "__main__":
    test_golden_fixture()
    test_defaults_are_empty_arrays_not_null()
    test_canonical_form_is_utf8_not_escaped()
    test_brewfile_ordering_id_not_key()
    test_resolve_apps_override_semantics()
    test_render_is_deterministic()
    test_manifest_shape_is_frozen()
    test_full_manifest_bytes_are_frozen()
    test_prev_index_version_carry_forward()
    test_local_account_defaults_and_stays_out_of_payload()
    test_index_matches_manifests()
    print("all renderer tests passed (golden sha verified)")
