"""Tests for tools/build.py against its current, real behavior.

Scope: M0 only. These tests assert what build.py actually does today;
they do not fix or work around known prototype defects (see
docs/packaging-goal.md "Known prototype defects").
"""
import json

import pytest


# ---------------------------------------------------------------------------
# Homepage HTML generation
# ---------------------------------------------------------------------------

def test_render_home_contains_brand_and_student(build_module, sample_catalog, tmp_path):
    html = build_module.render_home(sample_catalog, tmp_path, "Arlo")
    assert "<!doctype html>" in html
    assert "<title>TestBerry</title>" in html
    assert "Arlo" in html


def test_render_home_contains_resource_cards(build_module, sample_catalog, tmp_path):
    html = build_module.render_home(sample_catalog, tmp_path, "Arlo")
    assert "Example Site" in html
    assert 'href="https://www.example.com/"' in html
    assert "Unrelated" in html
    assert 'href="https://unrelated.org/"' in html


def test_render_home_contains_search_panel(build_module, sample_catalog, tmp_path):
    html = build_module.render_home(sample_catalog, tmp_path, "Arlo")
    assert 'action="https://search.example.com/search"' in html
    assert "Search Example" in html


def test_render_home_contains_approved_video_embed(build_module, sample_catalog, tmp_path):
    html = build_module.render_home(sample_catalog, tmp_path, "Arlo")
    assert "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ" in html
    assert "Sample Video" in html


def test_render_home_escapes_html_in_titles(build_module, sample_catalog, tmp_path):
    catalog = sample_catalog
    catalog["resources"][0]["title"] = "<script>alert(1)</script>"
    html = build_module.render_home(catalog, tmp_path, "Arlo")
    assert "<script>alert(1)</script>" not in html
    assert "&lt;script&gt;" in html


def test_render_home_defaults_student_when_blank(build_module, sample_catalog, tmp_path):
    html = build_module.render_home(sample_catalog, tmp_path, "")
    assert "Explorer" in html


# ---------------------------------------------------------------------------
# Domain collection / collapse (Security Model rests on this)
# ---------------------------------------------------------------------------

def test_collect_domains_includes_url_allow_search_extra_and_youtube(build_module, sample_catalog):
    domains = build_module.collect_domains(sample_catalog)
    # url netloc
    assert "www.example.com" in domains
    assert "unrelated.org" in domains
    # allow_domains
    assert "example.com" in domains
    assert "sub.example.com" in domains
    # search action domain
    assert "search.example.com" in domains
    # extra_allow_domains
    assert "ocsp.example.net" in domains
    # youtube CDN domains, added because youtube.videos is non-empty
    assert "youtube-nocookie.com" in domains
    assert "ytimg.com" in domains
    assert "googlevideo.com" in domains


def test_collect_domains_deduplicates(build_module, sample_catalog):
    domains = build_module.collect_domains(sample_catalog)
    assert len(domains) == len(set(domains))


def test_collect_domains_no_youtube_domains_without_videos(build_module, sample_catalog):
    sample_catalog["youtube"]["videos"] = []
    domains = build_module.collect_domains(sample_catalog)
    assert "youtube-nocookie.com" not in domains
    assert "ytimg.com" not in domains
    assert "googlevideo.com" not in domains


def test_squid_domain_lines_collapses_subdomains_to_leading_dot(build_module, sample_catalog):
    """Explicit assertion the Security Model's whole-domain claim rests on:
    a sample catalog with a base domain plus subdomains of it must collapse
    to a single leading-dot dstdomain entry for the base domain, and unrelated
    domains must each get their own leading-dot entry, unmodified.
    """
    lines = build_module.squid_domain_lines(sample_catalog)

    # www.example.com and sub.example.com are subdomains of example.com and
    # must NOT appear as separate entries -- they are covered by the
    # leading-dot ".example.com" entry (dstdomain semantics: leading dot
    # matches the domain and all its subdomains).
    assert ".example.com" in lines
    assert ".www.example.com" not in lines
    assert ".sub.example.com" not in lines

    # unrelated.org has no relationship to example.com and must survive
    # as its own entry.
    assert ".unrelated.org" in lines

    # search.example.com is itself a subdomain of example.com and search
    # was written as a bare form.example.com domain, so it too must collapse.
    assert ".search.example.com" not in lines

    # extra_allow_domains entry, and youtube CDN domains, are independent
    # base domains and must appear as their own leading-dot entries.
    assert ".ocsp.example.net" in lines
    assert ".youtube-nocookie.com" in lines
    assert ".ytimg.com" in lines
    assert ".googlevideo.com" in lines

    # Every generated line must be a leading-dot dstdomain entry.
    assert all(line.startswith(".") for line in lines)

    # Exact expected set for this sample catalog (order-independent).
    assert set(lines) == {
        ".example.com",
        ".unrelated.org",
        ".ocsp.example.net",
        ".youtube-nocookie.com",
        ".ytimg.com",
        ".googlevideo.com",
    }


def test_squid_domain_lines_keeps_unrelated_sibling_domains_separate(build_module):
    """Two domains that share a suffix only coincidentally as substrings
    (not as a dot-separated subdomain relationship) must both be kept."""
    config = {
        "resources": [
            {
                "title": "A",
                "url": "https://notexample.com/",
                "category": "Explore",
                "summary": "x",
                "allow_domains": ["example.com"],
            }
        ],
    }
    lines = build_module.squid_domain_lines(config)
    # "notexample.com" does NOT end with ".example.com", so it is not
    # covered by example.com and both must be present.
    assert set(lines) == {".notexample.com", ".example.com"}


# ---------------------------------------------------------------------------
# schema_version tolerance
# ---------------------------------------------------------------------------

def test_build_accepts_catalog_with_schema_version(build_module, sample_catalog_with_schema_version):
    assert build_module.load_config.__call__  # sanity: attribute exists

    # collect_domains / render_home / squid_domain_lines must not choke on
    # an unknown top-level "schema_version" key.
    domains = build_module.collect_domains(sample_catalog_with_schema_version)
    assert "example.com" in domains
    lines = build_module.squid_domain_lines(sample_catalog_with_schema_version)
    assert ".example.com" in lines
    html = build_module.render_home(sample_catalog_with_schema_version, "/tmp/whatever", "Arlo")
    assert "TestBerry" in html


def test_build_main_end_to_end_with_schema_version(build_module, sample_catalog_with_schema_version, tmp_path, monkeypatch):
    """Full pipeline (argparse -> load_config -> generators -> write files)
    tolerates a schema_version field and still produces all expected
    artifacts."""
    config_path = tmp_path / "resources.json"
    config_path.write_text(json.dumps(sample_catalog_with_schema_version), encoding="utf-8")
    target = tmp_path / "target"

    monkeypatch.setattr(
        "sys.argv",
        ["build.py", "--config", str(config_path), "--target", str(target), "--student", "Arlo"],
    )
    build_module.main()

    assert (target / "home" / "index.html").exists()
    assert (target / "generated" / "firefox-policies.json").exists()
    assert (target / "generated" / "chrome-policies.json").exists()
    assert (target / "generated" / "allowed-domains.txt").exists()
    assert (target / "generated" / "squid-cloudberryos.conf").exists()

    allowed = (target / "generated" / "allowed-domains.txt").read_text(encoding="utf-8")
    assert ".example.com" in allowed.splitlines()
    assert ".unrelated.org" in allowed.splitlines()

    # Policy JSON must still be well-formed JSON.
    firefox_policy = json.loads((target / "generated" / "firefox-policies.json").read_text(encoding="utf-8"))
    assert "policies" in firefox_policy
    chrome_policy = json.loads((target / "generated" / "chrome-policies.json").read_text(encoding="utf-8"))
    assert "URLAllowlist" in chrome_policy


# ---------------------------------------------------------------------------
# load_config
# ---------------------------------------------------------------------------

def test_load_config_requires_resources_list(build_module, tmp_path):
    bad_path = tmp_path / "bad.json"
    bad_path.write_text(json.dumps({"brand": "X"}), encoding="utf-8")
    with pytest.raises(SystemExit):
        build_module.load_config(bad_path)


def test_load_config_reads_valid_catalog(build_module, catalog_path):
    config = build_module.load_config(catalog_path)
    assert isinstance(config["resources"], list)
    assert config["brand"] == "TestBerry"


# ---------------------------------------------------------------------------
# normalize_domain / uniq helpers
# ---------------------------------------------------------------------------

def test_normalize_domain_strips_wildcard_and_lowers(build_module):
    assert build_module.normalize_domain("*.Example.COM") == "example.com"
    assert build_module.normalize_domain("  Example.com  ") == "example.com"


def test_uniq_preserves_order_and_drops_falsy(build_module):
    assert build_module.uniq(["a", "", "b", "a", None, "c"]) == ["a", "b", "c"]
