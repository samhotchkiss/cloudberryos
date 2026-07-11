#!/usr/bin/env python3
import argparse
import html
import json
import pathlib
from urllib.parse import urlparse


FIREFOX_BLOCK_ALL = "<all_urls>"


def load_config(path):
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if "resources" not in data or not isinstance(data["resources"], list):
        raise SystemExit("config must contain a resources array")
    return data


def uniq(items):
    seen = set()
    output = []
    for item in items:
        if item and item not in seen:
            seen.add(item)
            output.append(item)
    return output


def domain_from_url(url):
    parsed = urlparse(url)
    return parsed.netloc.lower()


def normalize_domain(domain):
    domain = domain.strip().lower()
    if domain.startswith("*."):
        domain = domain[2:]
    return domain


def collect_domains(config):
    domains = []
    for resource in config["resources"]:
        url_domain = domain_from_url(resource["url"])
        if url_domain:
            domains.append(url_domain)
        domains.extend(resource.get("allow_domains", []))
        search = resource.get("search")
        if search:
            domains.append(domain_from_url(search["action"]))
    domains.extend(config.get("extra_allow_domains", []))
    if config.get("youtube", {}).get("videos"):
        domains.extend([
            "youtube-nocookie.com",
            "ytimg.com",
            "googlevideo.com",
        ])
    return uniq([normalize_domain(domain) for domain in domains])


def youtube_video_ids(config):
    videos = config.get("youtube", {}).get("videos", [])
    return uniq([video.get("youtube_id", "").strip() for video in videos])


def firefox_patterns_for_domain(domain):
    # WebExtension match patterns need both the bare domain and subdomains.
    return [
        f"https://{domain}/*",
        f"https://*.{domain}/*",
        f"http://{domain}/*",
        f"http://*.{domain}/*",
    ]


def chrome_patterns_for_domain(domain):
    # Chrome URLBlocklist/URLAllowlist bare hosts include subdomains.
    return [domain]


def homepage_url(target):
    return pathlib.Path(target, "home", "index.html").resolve().as_uri()


def squid_domain_lines(config):
    domains = collect_domains(config)
    minimal = []
    for domain in domains:
        covered = any(domain != other and domain.endswith(f".{other}") for other in domains)
        if not covered:
            minimal.append(domain)
    return [f".{domain}" for domain in uniq(minimal)]


def build_firefox_policy(config, target):
    exceptions = [
        f"{pathlib.Path(target, 'home').resolve().as_uri()}/*",
        "http://127.0.0.1/*",
        "http://localhost/*",
    ]
    for domain in collect_domains(config):
        exceptions.extend(firefox_patterns_for_domain(domain))
    for video_id in youtube_video_ids(config):
        exceptions.extend([
            f"https://www.youtube-nocookie.com/embed/{video_id}*",
            f"https://youtube-nocookie.com/embed/{video_id}*",
        ])
    exceptions = uniq(exceptions)

    return {
        "policies": {
            "Homepage": {
                "URL": homepage_url(target),
                "Locked": True,
                "StartPage": "homepage-locked",
            },
            "FirefoxHome": {
                "Search": False,
                "TopSites": False,
                "SponsoredTopSites": False,
                "Highlights": False,
                "Pocket": False,
                "Stories": False,
                "SponsoredPocket": False,
                "SponsoredStories": False,
                "Snippets": False,
                "Locked": True,
            },
            "FirefoxSuggest": {
                "WebSuggestions": False,
                "SponsoredSuggestions": False,
                "ImproveSuggest": False,
                "Locked": True,
            },
            "WebsiteFilter": {
                "Block": [FIREFOX_BLOCK_ALL],
                "Exceptions": exceptions,
            },
            "DisablePrivateBrowsing": True,
            "BlockAboutAddons": True,
            "BlockAboutConfig": True,
            "BlockAboutProfiles": True,
            "BlockAboutSupport": True,
            "DisableFirefoxAccounts": True,
            "DisablePocket": True,
            "DisableTelemetry": True,
            "DontCheckDefaultBrowser": True,
            "OfferToSaveLogins": False,
            "ExtensionSettings": {
                "*": {
                    "installation_mode": "blocked"
                }
            },
        }
    }


def build_chrome_policy(config, target):
    allowlist = [
        "about:*",
        "blob:*",
        "data:*",
        f"{pathlib.Path(target, 'home').resolve().as_uri()}/*",
        "http://127.0.0.1/*",
        "http://localhost/*",
    ]
    for domain in collect_domains(config):
        allowlist.extend(chrome_patterns_for_domain(domain))
    for video_id in youtube_video_ids(config):
        allowlist.extend([
            f"youtube-nocookie.com/embed/{video_id}",
            f"www.youtube-nocookie.com/embed/{video_id}",
        ])
    allowlist = uniq(allowlist)

    return {
        "URLBlocklist": ["*"],
        "URLAllowlist": allowlist,
        "HomepageLocation": homepage_url(target),
        "HomepageIsNewTabPage": False,
        "RestoreOnStartup": 4,
        "RestoreOnStartupURLs": [homepage_url(target)],
        "IncognitoModeAvailability": 1,
        "BrowserGuestModeEnabled": False,
        "DefaultSearchProviderEnabled": False,
        "ExtensionInstallBlocklist": ["*"],
        "PasswordManagerEnabled": False,
        "SafeBrowsingProtectionLevel": 1,
    }


def grouped_resources(resources):
    groups = {}
    for resource in resources:
        groups.setdefault(resource.get("category", "Explore"), []).append(resource)
    return groups


def category_tone(category):
    tones = {
        "Look Up": "#2f6f73",
        "Learn": "#4f86a8",
        "Explore": "#6f9d68",
        "Read": "#9b5d73",
        "Practice": "#d79436",
        "Watch": "#17343a",
    }
    return tones.get(category, "#2f6f73")


def render_search(resource):
    search = resource.get("search")
    if not search:
        return ""
    label = html.escape(search.get("label", "Search"))
    action = html.escape(search["action"], quote=True)
    query_param = html.escape(search.get("query_param", "q"), quote=True)
    placeholder = html.escape(search.get("placeholder", "Search..."), quote=True)
    return f"""
        <form class="search-panel" action="{action}" method="get">
          <label for="site-search">{label}</label>
          <div class="search-row">
            <input id="site-search" name="{query_param}" type="search" placeholder="{placeholder}" autocomplete="off" />
            <button type="submit">Search</button>
          </div>
        </form>
    """


def render_home(config, target, student):
    brand = html.escape(config.get("brand", "CloudberryOS"))
    student = html.escape(student or config.get("default_student", "Explorer"))
    accent = html.escape(config.get("theme", {}).get("accent", "#2f6f73"))
    groups = grouped_resources(config["resources"])
    videos = config.get("youtube", {}).get("videos", [])
    search_html = ""
    sections_html = []
    quick_links = []

    for category, resources in groups.items():
        category_cards = []
        for resource in resources:
            title = html.escape(resource["title"])
            url = html.escape(resource["url"], quote=True)
            summary = html.escape(resource.get("summary", ""))
            if not search_html and resource.get("search"):
                search_html = render_search(resource)
            if title in {"Khan Academy", "TypingClub", "NASA Space Place", "Wikipedia"}:
                quick_links.append((title, url))
            tone = html.escape(category_tone(category))
            category_cards.append(f"""
              <a class="resource-card" style="--tone: {tone}" href="{url}">
                <span class="resource-kicker">{html.escape(category)}</span>
                <span class="resource-title">{title}</span>
                <span class="resource-summary">{summary}</span>
              </a>
            """)
        sections_html.append(f"""
          <section class="section">
            <div class="section-head">
              <h2>{html.escape(category)}</h2>
            </div>
            <div class="resource-grid">
              {''.join(category_cards)}
            </div>
          </section>
        """)

    quick_html = ""
    if quick_links:
        quick_items = []
        for title, url in quick_links[:4]:
            quick_items.append(f'<a class="quick-link" href="{url}">{title}</a>')
        quick_html = f"""
          <nav class="quick-row" aria-label="Quick launch">
            {''.join(quick_items)}
          </nav>
        """

    hero_video_html = ""
    if videos:
        video_cards = []
        first_video = videos[0]
        first_title = html.escape(first_video["title"])
        first_video_id = html.escape(first_video["youtube_id"], quote=True)
        hero_video_html = f"""
          <section class="hero-video" aria-label="Approved video">
            <div class="hero-video-head">
              <span>Approved Video</span>
              <a href="#watch">More</a>
            </div>
            <iframe
                    src="https://www.youtube-nocookie.com/embed/{first_video_id}?rel=0&modestbranding=1&playsinline=1"
                    title="{first_title}"
                    referrerpolicy="strict-origin-when-cross-origin"
                    allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                    allowfullscreen></iframe>
          </section>
        """
        for video in videos:
            title = html.escape(video["title"])
            video_id = html.escape(video["youtube_id"], quote=True)
            summary = html.escape(video.get("summary", ""))
            video_cards.append(f"""
              <article class="video-card">
                <div class="video-frame">
                  <iframe
                    src="https://www.youtube-nocookie.com/embed/{video_id}?rel=0&modestbranding=1&playsinline=1"
                    title="{title}"
                    referrerpolicy="strict-origin-when-cross-origin"
                    allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                    allowfullscreen></iframe>
                </div>
                <div class="video-copy">
                  <h3>{title}</h3>
                  <p>{summary}</p>
                </div>
              </article>
            """)
        sections_html.append(f"""
          <section class="section watch-section" id="watch">
            <div class="section-head">
              <h2>Watch</h2>
            </div>
            <div class="video-grid">
              {''.join(video_cards)}
            </div>
          </section>
        """)

    missions = [
        ("Find", "Look up a machine, star, place, or animal and save one question for later."),
        ("Make", "Create a drawing, story, model, or tiny game from something you learned."),
        ("Explain", "Tell someone how one surprising thing works without using a video."),
    ]
    mission_cards = []
    for label, body in missions:
        mission_cards.append(f"""
          <article class="mission-card">
            <span>{html.escape(label)}</span>
            <p>{html.escape(body)}</p>
          </article>
        """)

    dock_tools = [
        ("Projects", "Stories, drawings, science notes, code, and questions."),
        ("Ask for a Shelf", "A request note for one more site, topic, or tool."),
        ("Offline Wikipedia", "Simple English Wikipedia with pictures, ready without the web."),
        ("Tux Paint", "Fast drawing and stamps."),
        ("GCompris", "Puzzles, logic, math, and discovery."),
        ("Krita", "Bigger art projects."),
    ]
    dock_cards = []
    for title, body in dock_tools:
        dock_cards.append(f"""
          <article class="tool-card">
            <span class="tool-dot"></span>
            <div>
              <h3>{html.escape(title)}</h3>
              <p>{html.escape(body)}</p>
            </div>
          </article>
        """)

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="referrer" content="strict-origin-when-cross-origin" />
  <title>{brand}</title>
  <style>
    :root {{
      --accent: {accent};
      --ink: #132024;
      --muted: #5c6b70;
      --line: rgba(216, 225, 223, 0.86);
      --paper: #f3f7f3;
      --panel: rgba(255, 255, 255, 0.94);
      --sun: #e9b44c;
      --leaf: #6f9d68;
      --sky: #4f86a8;
      --berry: #9b5d73;
      --night: #17343a;
    }}
    * {{ box-sizing: border-box; }}
    html {{ scroll-behavior: smooth; }}
    body {{
      margin: 0;
      min-height: 100vh;
      color: var(--ink);
      background:
        linear-gradient(180deg, rgba(23, 52, 58, 0.08), rgba(243, 247, 243, 0) 460px),
        var(--paper);
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    main {{
      width: min(1180px, calc(100% - 32px));
      margin: 0 auto;
      padding: 28px 0 56px;
    }}
    .hero {{
      display: grid;
      grid-template-columns: minmax(0, 1.1fr) minmax(320px, 0.9fr);
      min-height: 520px;
      overflow: hidden;
      border: 1px solid rgba(255, 255, 255, 0.36);
      border-radius: 10px;
      background:
        linear-gradient(90deg, rgba(10, 22, 26, 0.82) 0%, rgba(10, 22, 26, 0.58) 44%, rgba(10, 22, 26, 0.08) 100%),
        url("../assets/cloudberryos-wallpaper-3840.png") center / cover;
      box-shadow: 0 24px 70px rgba(23, 33, 36, 0.22);
    }}
    .hero-copy {{
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      gap: 28px;
      min-height: 520px;
      padding: 34px;
      color: #f8faf7;
    }}
    .mark {{
      width: 54px;
      height: 54px;
      border-radius: 15px;
      background:
        radial-gradient(circle at 37px 17px, var(--sun) 0 9px, transparent 10px),
        linear-gradient(135deg, var(--accent), var(--sky));
      box-shadow: inset 0 -10px 18px rgba(0, 0, 0, 0.12);
      flex: 0 0 auto;
    }}
    .brand-row {{
      display: flex;
      align-items: center;
      gap: 14px;
      color: rgba(248, 250, 247, 0.9);
      font-weight: 800;
    }}
    h1 {{
      max-width: 620px;
      margin: 18px 0 0;
      font-size: clamp(3rem, 8vw, 6.9rem);
      line-height: 0.9;
      letter-spacing: 0;
    }}
    .subtitle {{
      max-width: 560px;
      margin: 18px 0 0;
      color: rgba(248, 250, 247, 0.88);
      font-size: 1.18rem;
      line-height: 1.45;
    }}
    .hero-panel {{
      align-self: end;
      margin: 24px;
      padding: 18px;
      border: 1px solid rgba(248, 250, 247, 0.34);
      border-radius: 10px;
      background: rgba(248, 250, 247, 0.9);
      color: var(--ink);
      backdrop-filter: blur(18px);
      display: grid;
      gap: 16px;
    }}
    .hero-note {{
      width: fit-content;
      max-width: 100%;
      padding: 10px 14px;
      border: 1px solid rgba(248, 250, 247, 0.26);
      border-radius: 999px;
      color: rgba(248, 250, 247, 0.92);
      background: rgba(10, 22, 26, 0.38);
      font-weight: 800;
    }}
    .search-panel label {{
      display: block;
      font-weight: 700;
      margin-bottom: 10px;
    }}
    .search-row {{
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 10px;
    }}
    input[type="search"] {{
      min-width: 0;
      width: 100%;
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 13px 14px;
      font: inherit;
      background: #fbfcfb;
    }}
    button {{
      border: 0;
      border-radius: 6px;
      padding: 0 18px;
      min-height: 46px;
      color: #fff;
      background: var(--accent);
      font: inherit;
      font-weight: 700;
      cursor: pointer;
    }}
    .quick-row {{
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 14px;
    }}
    .quick-link {{
      display: inline-flex;
      align-items: center;
      min-height: 38px;
      padding: 0 12px;
      border: 1px solid rgba(47, 111, 115, 0.2);
      border-radius: 999px;
      color: var(--night);
      background: rgba(255, 255, 255, 0.75);
      text-decoration: none;
      font-weight: 800;
    }}
    .hero-video {{
      display: grid;
      gap: 10px;
    }}
    .hero-video-head {{
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      color: var(--muted);
      font-size: 0.78rem;
      font-weight: 900;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }}
    .hero-video-head a {{
      color: var(--accent);
      text-decoration: none;
      text-transform: none;
      letter-spacing: 0;
    }}
    .hero-video iframe {{
      display: block;
      width: 100%;
      aspect-ratio: 16 / 9;
      border: 0;
      border-radius: 8px;
      background: #0f1719;
    }}
    .mission-strip {{
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 14px;
      margin: 22px 0 34px;
    }}
    .mission-card {{
      min-height: 146px;
      padding: 18px;
      border: 1px solid var(--line);
      border-radius: 10px;
      background: var(--panel);
      box-shadow: 0 12px 30px rgba(23, 33, 36, 0.08);
    }}
    .mission-card span {{
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: 74px;
      min-height: 32px;
      padding: 0 12px;
      border-radius: 999px;
      color: #fff;
      background: var(--night);
      font-weight: 900;
    }}
    .mission-card:nth-child(2) span {{ background: var(--berry); }}
    .mission-card:nth-child(3) span {{ background: var(--leaf); color: #102022; }}
    .mission-card p {{
      margin: 14px 0 0;
      color: var(--muted);
      line-height: 1.45;
    }}
    .sections {{
      display: grid;
      gap: 32px;
      margin-top: 0;
    }}
    .section-head {{
      display: flex;
      align-items: end;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 12px;
    }}
    .section h2 {{
      margin: 0;
      font-size: 0.98rem;
      text-transform: uppercase;
      color: var(--muted);
      letter-spacing: 0.08em;
    }}
    .resource-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
      gap: 14px;
    }}
    .video-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 16px;
    }}
    .video-card {{
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
      overflow: hidden;
      box-shadow: 0 16px 36px rgba(23, 33, 36, 0.1);
    }}
    .video-frame {{
      aspect-ratio: 16 / 9;
      background: #0f1719;
    }}
    .video-frame iframe {{
      display: block;
      width: 100%;
      height: 100%;
      border: 0;
    }}
    .video-copy {{
      padding: 14px 16px 16px;
    }}
    .video-copy h3 {{
      margin: 0 0 6px;
      font-size: 1rem;
    }}
    .video-copy p {{
      margin: 0;
      color: var(--muted);
      line-height: 1.42;
    }}
    .resource-card {{
      position: relative;
      display: grid;
      gap: 10px;
      min-height: 156px;
      padding: 18px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
      color: inherit;
      text-decoration: none;
      overflow: hidden;
      transition: transform 160ms ease, border-color 160ms ease, box-shadow 160ms ease;
    }}
    .resource-card::before {{
      content: "";
      position: absolute;
      inset: 0 auto 0 0;
      width: 6px;
      background: var(--tone);
    }}
    .resource-card:hover,
    .resource-card:focus-visible {{
      transform: translateY(-2px);
      border-color: color-mix(in srgb, var(--tone), #ffffff 20%);
      box-shadow: 0 14px 30px rgba(23, 33, 36, 0.1);
      outline: none;
    }}
    .resource-kicker {{
      color: var(--tone);
      font-size: 0.74rem;
      font-weight: 900;
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }}
    .resource-title {{
      font-weight: 800;
      font-size: 1.14rem;
    }}
    .resource-summary {{
      color: var(--muted);
      line-height: 1.42;
    }}
    .tool-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
      gap: 12px;
    }}
    .tool-card {{
      display: flex;
      gap: 12px;
      min-height: 116px;
      padding: 16px;
      border: 1px solid rgba(216, 225, 223, 0.8);
      border-radius: 8px;
      background: rgba(255, 255, 255, 0.78);
    }}
    .tool-dot {{
      width: 14px;
      height: 14px;
      margin-top: 5px;
      border-radius: 50%;
      background: var(--sun);
      box-shadow: 0 0 0 5px rgba(233, 180, 76, 0.18);
      flex: 0 0 auto;
    }}
    .tool-card h3 {{
      margin: 0 0 7px;
      font-size: 1rem;
    }}
    .tool-card p {{
      margin: 0;
      color: var(--muted);
      line-height: 1.42;
    }}
    .request {{
      margin-top: 32px;
      padding: 18px;
      border-left: 4px solid var(--berry);
      background: rgba(155, 93, 115, 0.08);
      border-radius: 8px;
    }}
    .request h2 {{
      margin: 0 0 6px;
      font-size: 1.05rem;
    }}
    .request p {{
      margin: 0;
      color: var(--muted);
      line-height: 1.45;
    }}
    @media (max-width: 620px) {{
      main {{ width: min(100% - 22px, 1120px); padding-top: 20px; }}
      .hero {{ grid-template-columns: 1fr; min-height: auto; }}
      .hero-copy {{ min-height: 420px; padding: 22px; }}
      .hero-panel {{ margin: 0 14px 14px; }}
      .search-row {{ grid-template-columns: 1fr; }}
      button {{ width: 100%; }}
      .mission-strip {{ grid-template-columns: 1fr; }}
      .resource-card {{ min-height: 132px; }}
    }}
</style>
  <link rel="stylesheet" href="../assets/cloudberryos-home.css" />
</head>
<body>
  <main>
    <header class="hero" id="top">
      <nav class="topbar" aria-label="CloudberryOS navigation">
        <a class="topbar-brand" href="#top">
          <img src="../assets/icons/cloudberryos-browser.svg" alt="" />
          <span>{brand}</span>
        </a>
        <div class="topbar-links">
          <a href="#directions">Ideas</a>
          <a href="#resources">Explore</a>
          <a href="#watch">Watch</a>
          <a href="#local-shelf">Make</a>
        </div>
      </nav>
      <div class="hero-copy">
        <div>
          <div class="brand-row">
            <div class="mark" aria-hidden="true"></div>
            <span>{brand}</span>
          </div>
          <h1><span class="welcome">Welcome to</span>{student}'s workshop.</h1>
          <p class="subtitle">Look closely. Follow a question. Make something that did not exist this morning.</p>
        </div>
        <div class="hero-note">Offline Wikipedia with pictures is ready when the internet is not.</div>
      </div>
      <div class="hero-panel">
        {search_html}
        {quick_html}
        {hero_video_html}
      </div>
    </header>
    <section class="mission-strip" id="directions" aria-label="Ideas for today">
      <div class="mission-intro">
        <p>A few ways to begin</p>
        <h2>What will you follow today?</h2>
      </div>
      {''.join(mission_cards)}
    </section>
    <div class="sections" id="resources">
      {''.join(sections_html)}
      <section class="section" id="local-shelf">
        <div class="section-head">
          <h2>Make</h2>
        </div>
        <div class="tool-grid">
          {''.join(dock_cards)}
        </div>
      </section>
    </div>
    <section class="request">
      <h2>Need a new shelf?</h2>
      <p>Write down what you want to use, what you want to make or learn, and why it belongs here.</p>
    </section>
  </main>
</body>
</html>
"""


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")


def write_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def build_desktop_file(target):
    home = homepage_url(target)
    return f"""[Desktop Entry]
Type=Application
Name=CloudberryOS
Comment=Open the curated kids homepage
Exec=firefox {home}
Icon=cloudberryos-browser
Terminal=false
Categories=Education;
"""


def build_browser_desktop_file():
    return """[Desktop Entry]
Type=Application
Name=CloudberryOS Browser
Comment=Open the curated CloudberryOS browser
Exec=cloudberryos-browser %u
Icon=cloudberryos-browser
Terminal=false
Categories=Education;
StartupNotify=true
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;
"""


def build_browser_launcher(target):
    system_site_dir = pathlib.Path(target).resolve()
    return f"""#!/usr/bin/env bash
set -euo pipefail

SYSTEM_SITE_DIR="{system_site_dir}"
USER_HOME_FILE="${{HOME}}/CloudberryOS/site/home/index.html"
if [[ -f "$USER_HOME_FILE" ]]; then
  SITE_DIR="${{HOME}}/CloudberryOS/site"
else
  SITE_DIR="$SYSTEM_SITE_DIR"
fi
HOME_PORT="${{CLOUDBERRYOS_HOME_PORT:-8765}}"
HOME_URL="http://127.0.0.1:${{HOME_PORT}}/home/index.html"
TARGET_URL="${{1:-$HOME_URL}}"
STATE_DIR="${{HOME}}/.cloudberryos"
LOG_FILE="$STATE_DIR/browser.log"
mkdir -p "$STATE_DIR"

log() {{
  printf '[%s] %s\\n' "$(date --iso-8601=seconds)" "$*" >> "$LOG_FILE"
}}

start_home_server() {{
  if [[ ! -d "$SITE_DIR" ]]; then
    log "CloudberryOS site directory not found: $SITE_DIR"
    return 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    if python3 - "$HOME_URL" >/dev/null 2>&1 <<'PY'
import sys
import urllib.request

try:
    with urllib.request.urlopen(sys.argv[1], timeout=1.5) as response:
        raise SystemExit(0 if response.status < 500 else 1)
except Exception:
    raise SystemExit(1)
PY
    then
      return 0
    fi

    log "Starting CloudberryOS local homepage server on 127.0.0.1:$HOME_PORT from $SITE_DIR"
    (
      cd "$SITE_DIR"
      nohup python3 -m http.server "$HOME_PORT" --bind 127.0.0.1 >> "$LOG_FILE" 2>&1 &
      printf '%s\\n' "$!" > "$STATE_DIR/home-server.pid"
    )

    for _ in 1 2 3 4 5; do
      sleep 0.4
      if python3 - "$HOME_URL" >/dev/null 2>&1 <<'PY'
import sys
import urllib.request

try:
    with urllib.request.urlopen(sys.argv[1], timeout=1.5) as response:
        raise SystemExit(0 if response.status < 500 else 1)
except Exception:
    raise SystemExit(1)
PY
      then
        return 0
      fi
    done
  fi

  log "CloudberryOS local homepage server did not start"
  return 1
}}

write_userjs() {{
  local profile_dir="$1"
  [[ -d "$profile_dir" ]] || return 0
  cat > "$profile_dir/user.js" <<EOF
user_pref("browser.startup.homepage", "$HOME_URL");
user_pref("browser.startup.page", 1);
user_pref("browser.newtabpage.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.max_tabs_undo", 0);
user_pref("browser.sessionstore.max_windows_undo", 0);
user_pref("browser.urlbar.suggest.searches", false);
user_pref("browser.urlbar.suggest.quicksuggest.sponsored", false);
user_pref("extensions.getAddons.showPane", false);
user_pref("extensions.htmlaboutaddons.recommendations.enabled", false);
user_pref("network.proxy.type", 1);
user_pref("network.proxy.http", "127.0.0.1");
user_pref("network.proxy.http_port", 3128);
user_pref("network.proxy.ssl", "127.0.0.1");
user_pref("network.proxy.ssl_port", 3128);
user_pref("network.proxy.no_proxies_on", "localhost, 127.0.0.1");
user_pref("signon.rememberSignons", false);
EOF
}}

write_userjs "$STATE_DIR/firefox-profile"
for profile_root in "$HOME/snap/firefox/common/.mozilla/firefox" "$HOME/.mozilla/firefox"; do
  [[ -d "$profile_root" ]] || continue
  while IFS= read -r profile_dir; do
    [[ -f "$profile_dir/prefs.js" || -f "$profile_dir/times.json" ]] || continue
    write_userjs "$profile_dir"
    rm -f "$profile_dir/sessionstore.jsonlz4" "$profile_dir/sessionstore-backups"/*.jsonlz4 2>/dev/null || true
  done < <(find "$profile_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
done

if command -v firefox >/dev/null 2>&1; then
  FIREFOX_BIN="$(command -v firefox)"
elif [[ -x /snap/bin/firefox ]]; then
  FIREFOX_BIN="/snap/bin/firefox"
else
  log "Firefox executable not found"
  exit 127
fi

export http_proxy="http://127.0.0.1:3128"
export https_proxy="http://127.0.0.1:3128"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="$no_proxy"
export MOZ_ENABLE_WAYLAND=1

start_home_server || true
log "Launching $FIREFOX_BIN --new-window $TARGET_URL"
nohup "$FIREFOX_BIN" --new-window "$TARGET_URL" >> "$LOG_FILE" 2>&1 &
"""


def build_squid_config():
    return """# Managed by CloudberryOS.
http_port 127.0.0.1:3128

acl cloudberryos_allowed dstdomain "/etc/cloudberryos/allowed-domains.txt"
acl cloudberryos_local src 127.0.0.1/32 ::1
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow cloudberryos_local cloudberryos_allowed
http_access deny all

cache deny all
access_log stdio:/var/log/squid/cloudberryos-access.log
"""


def build_firewall_script():
    return """#!/usr/bin/env bash
set -euo pipefail

CHAIN="CLOUDBERRYOS_OUT"
USERS_FILE="/etc/cloudberryos/student-users"

while rule="$(iptables -w -S OUTPUT | grep -- "-j $CHAIN" | head -n 1)"; [[ -n "$rule" ]]; do
  read -r -a parts <<< "$rule"
  parts[0]="-D"
  iptables -w "${parts[@]}"
done
iptables -w -F "$CHAIN" 2>/dev/null || true
iptables -w -X "$CHAIN" 2>/dev/null || true
iptables -w -N "$CHAIN"

iptables -w -A "$CHAIN" -o lo -j RETURN
iptables -w -A "$CHAIN" -p udp --dport 443 -j REJECT
iptables -w -A "$CHAIN" -p tcp -m multiport --dports 80,443 -j REJECT
iptables -w -A "$CHAIN" -j RETURN

if [[ -f "$USERS_FILE" ]]; then
  while IFS= read -r user; do
    [[ -z "$user" ]] && continue
    if id "$user" >/dev/null 2>&1; then
      uid="$(id -u "$user")"
      iptables -w -A OUTPUT -m owner --uid-owner "$uid" -j "$CHAIN"
    fi
  done < "$USERS_FILE"
fi
"""


def build_firewall_service():
    return """[Unit]
Description=Apply CloudberryOS student web egress rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cloudberryos-firewall-apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--student", default="")
    args = parser.parse_args()

    config = load_config(args.config)
    target = pathlib.Path(args.target)
    student = args.student or config.get("default_student", "Explorer")

    write_text(target / "home" / "index.html", render_home(config, target, student))
    write_json(target / "generated" / "firefox-policies.json", build_firefox_policy(config, target))
    write_json(target / "generated" / "chrome-policies.json", build_chrome_policy(config, target))
    write_text(target / "generated" / "allowed-domains.txt", "\n".join(squid_domain_lines(config)) + "\n")
    write_text(target / "generated" / "squid-cloudberryos.conf", build_squid_config())
    write_text(target / "generated" / "cloudberryos-browser", build_browser_launcher(target))
    write_text(target / "generated" / "cloudberryos-browser.desktop", build_browser_desktop_file())
    write_text(target / "generated" / "cloudberryos-firewall-apply", build_firewall_script())
    write_text(target / "generated" / "cloudberryos-firewall.service", build_firewall_service())
    write_text(target / "generated" / "cloudberryos-home.desktop", build_desktop_file(target))


if __name__ == "__main__":
    main()
