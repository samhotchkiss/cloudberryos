"""Tests for tools/cloudberryos-resource.py against its current, real
behavior. Scope: M0 only -- these assert existing behavior (including
known limitations noted in docs/packaging-goal.md, e.g. title-only
dedupe) rather than fixing anything (that belongs to M1)."""
import argparse
import json
import subprocess
import sys
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
RESOURCE_SCRIPT = REPO_ROOT / "tools" / "cloudberryos-resource.py"


def make_args(config, **overrides):
    defaults = dict(config=str(config))
    defaults.update(overrides)
    return argparse.Namespace(**defaults)


# ---------------------------------------------------------------------------
# add-site round trip
# ---------------------------------------------------------------------------

def test_add_site_round_trip(resource_module, catalog_path):
    args = make_args(
        catalog_path,
        title="New Kid Site",
        url="https://kidsite.example/",
        category="Explore",
        summary="A brand new site.",
        allow_domain=["kidsite.example", "cdn.kidsite.example"],
    )
    resource_module.add_site(args)

    reloaded = resource_module.load_config(catalog_path)
    titles = [r["title"] for r in reloaded["resources"]]
    assert "New Kid Site" in titles

    added = next(r for r in reloaded["resources"] if r["title"] == "New Kid Site")
    assert added["url"] == "https://kidsite.example/"
    assert added["category"] == "Explore"
    assert added["summary"] == "A brand new site."
    assert added["allow_domains"] == ["kidsite.example", "cdn.kidsite.example"]


def test_add_site_normalizes_wildcard_domains(resource_module, catalog_path):
    args = make_args(
        catalog_path,
        title="Wildcard Site",
        url="https://wild.example/",
        category="Explore",
        summary="x",
        allow_domain=["*.Wild.EXAMPLE"],
    )
    resource_module.add_site(args)
    reloaded = resource_module.load_config(catalog_path)
    added = next(r for r in reloaded["resources"] if r["title"] == "Wildcard Site")
    assert added["allow_domains"] == ["wild.example"]


def test_add_site_rejects_duplicate_title_case_insensitive(resource_module, catalog_path):
    args = make_args(
        catalog_path,
        title="example site",  # matches existing "Example Site" case-insensitively
        url="https://dup.example/",
        category="Explore",
        summary="dup",
        allow_domain=[],
    )
    with pytest.raises(SystemExit):
        resource_module.add_site(args)


# ---------------------------------------------------------------------------
# add-video round trip
# ---------------------------------------------------------------------------

def test_add_video_round_trip(resource_module, catalog_path):
    args = make_args(
        catalog_path,
        title="Second Video",
        video="https://www.youtube.com/watch?v=jNQXAC9IVRw",
        summary="A second approved video.",
    )
    resource_module.add_video(args)

    reloaded = resource_module.load_config(catalog_path)
    videos = reloaded["youtube"]["videos"]
    titles = [v["title"] for v in videos]
    assert "Second Video" in titles

    added = next(v for v in videos if v["title"] == "Second Video")
    assert added["youtube_id"] == "jNQXAC9IVRw"
    assert added["category"] == "Watch"
    assert added["summary"] == "A second approved video."
    # original video from the sample catalog must still be present
    assert any(v["youtube_id"] == "dQw4w9WgXcQ" for v in videos)


def test_add_video_rejects_duplicate_id(resource_module, catalog_path):
    args = make_args(
        catalog_path,
        title="Duplicate",
        video="dQw4w9WgXcQ",  # already present in sample_catalog fixture
        summary="dup",
    )
    with pytest.raises(SystemExit):
        resource_module.add_video(args)


# ---------------------------------------------------------------------------
# video ID extraction
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "value,expected",
    [
        ("dQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ("https://youtu.be/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ("https://youtu.be/dQw4w9WgXcQ?t=30", "dQw4w9WgXcQ"),
        ("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?rel=0", "dQw4w9WgXcQ"),
        ("  dQw4w9WgXcQ  ", "dQw4w9WgXcQ"),
    ],
)
def test_video_id_from_recognized_forms(resource_module, value, expected):
    assert resource_module.video_id_from(value) == expected


def test_video_id_from_raises_on_unrecognized_value(resource_module):
    with pytest.raises(SystemExit):
        resource_module.video_id_from("https://example.com/not-a-video")


# ---------------------------------------------------------------------------
# list command (smoke test -- must not raise)
# ---------------------------------------------------------------------------

def test_list_items_runs_without_error(resource_module, catalog_path, capsys):
    args = make_args(catalog_path)
    resource_module.list_items(args)
    out = capsys.readouterr().out
    assert "Example Site" in out
    assert "Approved videos" in out


# ---------------------------------------------------------------------------
# schema_version tolerance / preservation
# ---------------------------------------------------------------------------

def test_add_site_preserves_schema_version(resource_module, tmp_path, sample_catalog_with_schema_version):
    path = tmp_path / "resources.json"
    path.write_text(json.dumps(sample_catalog_with_schema_version), encoding="utf-8")

    args = make_args(
        path,
        title="Schema Test Site",
        url="https://schema.example/",
        category="Explore",
        summary="x",
        allow_domain=[],
    )
    resource_module.add_site(args)

    reloaded = resource_module.load_config(path)
    assert reloaded.get("schema_version") == 1
    assert any(r["title"] == "Schema Test Site" for r in reloaded["resources"])


def test_add_video_preserves_schema_version(resource_module, tmp_path, sample_catalog_with_schema_version):
    path = tmp_path / "resources.json"
    path.write_text(json.dumps(sample_catalog_with_schema_version), encoding="utf-8")

    args = make_args(
        path,
        title="Schema Test Video",
        video="jNQXAC9IVRw",
        summary="x",
    )
    resource_module.add_video(args)

    reloaded = resource_module.load_config(path)
    assert reloaded.get("schema_version") == 1
    assert any(v["youtube_id"] == "jNQXAC9IVRw" for v in reloaded["youtube"]["videos"])


# ---------------------------------------------------------------------------
# CLI-level round trip (exercises argparse wiring via subprocess, matching
# real invocation as `cloudberryos-resource add-site ...`)
# ---------------------------------------------------------------------------

def test_cli_add_site_round_trip(tmp_path, sample_catalog):
    config_path = tmp_path / "resources.json"
    config_path.write_text(json.dumps(sample_catalog), encoding="utf-8")

    result = subprocess.run(
        [
            sys.executable,
            str(RESOURCE_SCRIPT),
            "--config",
            str(config_path),
            "add-site",
            "--title",
            "CLI Site",
            "--url",
            "https://cli.example/",
            "--summary",
            "Added via CLI",
            "--allow-domain",
            "cli.example",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    assert "Added site: CLI Site" in result.stdout

    reloaded = json.loads(config_path.read_text(encoding="utf-8"))
    assert any(r["title"] == "CLI Site" for r in reloaded["resources"])


def test_cli_add_video_round_trip(tmp_path, sample_catalog):
    config_path = tmp_path / "resources.json"
    config_path.write_text(json.dumps(sample_catalog), encoding="utf-8")

    result = subprocess.run(
        [
            sys.executable,
            str(RESOURCE_SCRIPT),
            "--config",
            str(config_path),
            "add-video",
            "--title",
            "CLI Video",
            "--video",
            "https://youtu.be/jNQXAC9IVRw",
            "--summary",
            "Added via CLI",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    assert "Added video: CLI Video (jNQXAC9IVRw)" in result.stdout

    reloaded = json.loads(config_path.read_text(encoding="utf-8"))
    assert any(v["youtube_id"] == "jNQXAC9IVRw" for v in reloaded["youtube"]["videos"])
