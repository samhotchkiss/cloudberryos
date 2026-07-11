#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path
from urllib.parse import parse_qs, urlparse


DEFAULT_CONFIG = Path("/usr/share/cloudberryos/config/resources.json")


def load_config(path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def save_config(path, config):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")


def video_id_from(value):
    value = value.strip()
    if re.fullmatch(r"[A-Za-z0-9_-]{11}", value):
        return value
    parsed = urlparse(value)
    if parsed.hostname and "youtu.be" in parsed.hostname:
        candidate = parsed.path.strip("/").split("/")[0]
        if re.fullmatch(r"[A-Za-z0-9_-]{11}", candidate):
            return candidate
    query_id = parse_qs(parsed.query).get("v", [""])[0]
    if re.fullmatch(r"[A-Za-z0-9_-]{11}", query_id):
        return query_id
    match = re.search(r"/embed/([A-Za-z0-9_-]{11})", parsed.path)
    if match:
        return match.group(1)
    raise SystemExit(f"Could not find a YouTube video ID in: {value}")


def normalize_domain(domain):
    domain = domain.strip().lower()
    if domain.startswith("*."):
        domain = domain[2:]
    return domain


def add_site(args):
    path = Path(args.config)
    config = load_config(path)
    titles = {resource["title"].lower() for resource in config.get("resources", [])}
    if args.title.lower() in titles:
        raise SystemExit(f"Resource already exists: {args.title}")
    resource = {
        "title": args.title,
        "url": args.url,
        "category": args.category,
        "summary": args.summary,
        "allow_domains": [normalize_domain(domain) for domain in args.allow_domain],
    }
    config.setdefault("resources", []).append(resource)
    save_config(path, config)
    print(f"Added site: {args.title}")
    print(f"Run: sudo cloudberryos-apply")


def add_video(args):
    path = Path(args.config)
    config = load_config(path)
    youtube_id = video_id_from(args.video)
    videos = config.setdefault("youtube", {}).setdefault("videos", [])
    if any(video.get("youtube_id") == youtube_id for video in videos):
        raise SystemExit(f"Video already exists: {youtube_id}")
    videos.append({
        "title": args.title,
        "youtube_id": youtube_id,
        "category": "Watch",
        "summary": args.summary,
    })
    save_config(path, config)
    print(f"Added video: {args.title} ({youtube_id})")
    print(f"Run: sudo cloudberryos-apply")


def list_items(args):
    config = load_config(Path(args.config))
    print("Resources:")
    for resource in config.get("resources", []):
        domains = ", ".join(resource.get("allow_domains", []))
        print(f"- {resource['title']} [{resource.get('category', 'Explore')}] {resource['url']}")
        if domains:
            print(f"  allow: {domains}")
    videos = config.get("youtube", {}).get("videos", [])
    if videos:
        print("\nApproved videos:")
        for video in videos:
            print(f"- {video['title']} ({video['youtube_id']})")


def main():
    parser = argparse.ArgumentParser(description="Edit the CloudberryOS resource catalog.")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="Path to resources.json")
    subparsers = parser.add_subparsers(dest="command", required=True)

    site = subparsers.add_parser("add-site", help="Add a curated website")
    site.add_argument("--title", required=True)
    site.add_argument("--url", required=True)
    site.add_argument("--category", default="Explore")
    site.add_argument("--summary", required=True)
    site.add_argument("--allow-domain", action="append", required=True)
    site.set_defaults(func=add_site)

    video = subparsers.add_parser("add-video", help="Add an approved YouTube video")
    video.add_argument("--title", required=True)
    video.add_argument("--video", required=True, help="YouTube URL or 11-character video ID")
    video.add_argument("--summary", required=True)
    video.set_defaults(func=add_video)

    listed = subparsers.add_parser("list", help="List configured resources and videos")
    listed.set_defaults(func=list_items)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
