"""Shared fixtures for the CloudberryOS tool test suite.

tools/build.py and tools/cloudberryos-resource.py are not a Python
package (the latter's filename even has hyphens), so they are loaded
directly by file path with importlib rather than imported normally.
"""
import copy
import importlib.util
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = REPO_ROOT / "tools"


def _load_module(module_name, file_path):
    spec = importlib.util.spec_from_file_location(module_name, file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def build_module():
    return _load_module("cb_build", TOOLS_DIR / "build.py")


@pytest.fixture(scope="session")
def resource_module():
    return _load_module("cb_resource", TOOLS_DIR / "cloudberryos-resource.py")


@pytest.fixture
def sample_catalog():
    """A small, hand-built catalog exercising domain collapse, search,
    and a youtube video -- independent of the real config/resources.json
    so tests don't silently rot if the real catalog changes."""
    return {
        "brand": "TestBerry",
        "default_student": "Explorer",
        "theme": {"accent": "#2f6f73"},
        "resources": [
            {
                "title": "Example Site",
                "url": "https://www.example.com/",
                "category": "Explore",
                "summary": "An example site for testing.",
                "allow_domains": ["example.com", "sub.example.com"],
                "search": {
                    "label": "Search Example",
                    "action": "https://search.example.com/search",
                    "query_param": "q",
                    "placeholder": "search...",
                },
            },
            {
                "title": "Unrelated",
                "url": "https://unrelated.org/",
                "category": "Read",
                "summary": "An unrelated site.",
                "allow_domains": [],
            },
        ],
        "youtube": {
            "videos": [
                {
                    "title": "Sample Video",
                    "youtube_id": "dQw4w9WgXcQ",
                    "category": "Watch",
                    "summary": "A sample approved video.",
                }
            ],
            "channels": [],
        },
        "extra_allow_domains": ["ocsp.example.net"],
    }


@pytest.fixture
def sample_catalog_with_schema_version(sample_catalog):
    catalog = copy.deepcopy(sample_catalog)
    catalog["schema_version"] = 1
    return catalog


@pytest.fixture
def catalog_path(tmp_path, sample_catalog):
    path = tmp_path / "resources.json"
    import json

    path.write_text(json.dumps(sample_catalog), encoding="utf-8")
    return path
