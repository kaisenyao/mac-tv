#!/usr/bin/env python3
"""Download Apple's Apple TV 4K User Guide (tvOS 27) for reference while matching Mac TV to it.

    python3 scripts/tvos-guide.py [folder]        (default: work/tvos27-guide, which git ignores)

Writes toc.json (sections and pages), text/<page>.txt (each page's text, with its pictures marked
"[FIGURE <id> <width>x<height>: <caption>]"), img/fig/<id>.png (screenshots: about 1144x644, a 1920x1080 screen at
0.596) and img/icon/<id>.png (inline glyphs), and images.json (which pages each picture is on). Apple's pictures are
Apple's: keep them out of the repository. Measure them with scripts/px.swift; what has been measured is in
docs/custom/tvos27-reference.md.
"""
import concurrent.futures, html, json, os, re, subprocess, sys

BASE = "https://support.apple.com/en-bw/guide/tv"
AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"


def fetch(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 200:
        return True
    done = subprocess.run(["curl", "-sL", "--max-time", "60", "-A", AGENT, "-o", path, "-w", "%{http_code}", url],
                          capture_output=True, text=True)
    return done.stdout == "200"


def slug(url):
    return url.split("/guide/tv/")[1].split("/")[0]


def contents(page):
    """The table of contents: every page with the sections it is under."""
    body = page[page.find('<ul class="toc">'):]
    token = re.compile(r"(<ul[^>]*>)|(</ul>)|<button\s+class='section'.*?<span class='name'>(.*?)</span>"
                       r"|<a\s[^>]*?class='toc-item'.*?href='([^']+)'.*?<span class='name'>(.*?)</span>", re.S)
    depth, stack, items = 0, [], []
    for match in token.finditer(body):
        if match.group(1):
            depth += 1
        elif match.group(2):
            depth -= 1
            while stack and stack[-1][0] >= depth:
                stack.pop()
            if depth <= 0:
                break
        elif match.group(3) is not None:
            while stack and stack[-1][0] >= depth:
                stack.pop()
            stack.append((depth, html.unescape(match.group(3)).strip()))
        else:
            items.append({"section": " > ".join(name for _, name in stack),
                          "title": html.unescape(match.group(5)).strip(), "url": match.group(4)})
    return items


def text(page, name, images):
    """A page's article as plain text, noting every picture in `images`."""
    start = page.find("id='article-section'")
    end = page.find('id="helpful-rating-wrapper"', start)
    body = re.sub(r"<script.*?</script>|<style.*?</style>", "", page[start:end if end > 0 else None], flags=re.S)

    def picture(tag, figure):
        source = re.search(r'src="([^"]+)"', tag)
        if not source:
            return ""
        caption = re.search(r'alt="([^"]*)"', tag)
        width, height = re.search(r'width="(\d+)"', tag), re.search(r'height="(\d+)"', tag)
        key = source.group(1).rsplit("/", 1)[-1]
        entry = images.setdefault(key, {"url": source.group(1), "alt": html.unescape(caption.group(1)) if caption else "",
                                        "w": int(width.group(1)) if width else 0, "h": int(height.group(1)) if height else 0,
                                        "figure": False, "pages": []})
        entry["figure"] = entry["figure"] or figure
        if name not in entry["pages"]:
            entry["pages"].append(name)
        if figure:
            return "\n[FIGURE %s %sx%s: %s]\n" % (key[:8], entry["w"], entry["h"], entry["alt"])
        return "[icon %s: %s]" % (key[:8], entry["alt"])

    body = re.sub(r"<figure[^>]*>(.*?)</figure>",
                  lambda m: re.sub(r"<img [^>]*>", lambda i: picture(i.group(0), True), m.group(1)), body, flags=re.S)
    body = re.sub(r"<img [^>]*>", lambda i: picture(i.group(0), False), body)
    body = re.sub(r"<h1[^>]*>", "\n# ", body)
    body = re.sub(r"<h2[^>]*>", "\n\n## ", body)
    body = re.sub(r"<h3[^>]*>", "\n\n### ", body)
    body = re.sub(r"<li[^>]*>", "\n- ", body)
    body = re.sub(r"</(p|h1|h2|h3|div|tr|table)>", "\n", body)
    body = re.sub(r"<(td|th)[^>]*>", " | ", body)
    body = html.unescape(re.sub(r"<[^>]+>", "", body))
    body = re.sub(r"[ \t ]+", " ", body)
    body = re.sub(r"\n\s*\n+", "\n", body).replace("\n- \n", "\n- ")
    body = body.split("\n", 1)[1] if "\n" in body else body   # the first line is what is left of the opening tag
    return body.split("Helpful?")[0].strip()


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "work/tvos27-guide"
    folders = {name: os.path.join(out, name) for name in ("html", "text", "img/fig", "img/icon")}
    for folder in folders.values():
        os.makedirs(folder, exist_ok=True)

    toc = os.path.join(folders["html"], "toc.html")
    if not fetch(BASE + "/toc", toc):
        sys.exit("Cannot fetch the table of contents")
    items = contents(open(toc, encoding="utf-8", errors="replace").read())
    json.dump(items, open(os.path.join(out, "toc.json"), "w"), ensure_ascii=False, indent=1)

    with concurrent.futures.ThreadPoolExecutor(6) as pool:
        got = list(pool.map(lambda item: fetch(item["url"], os.path.join(folders["html"], slug(item["url"]) + ".html")), items))
    images = {}
    for item in items:
        name = slug(item["url"])
        page = open(os.path.join(folders["html"], name + ".html"), encoding="utf-8", errors="replace").read()
        with open(os.path.join(folders["text"], name + ".txt"), "w") as file:
            file.write("SECTION: %s\nTITLE: %s\nPAGE: %s\n\n%s\n" % (item["section"], item["title"], name, text(page, name, images)))
    json.dump(images, open(os.path.join(out, "images.json"), "w"), ensure_ascii=False, indent=1)

    def picture(pair):
        key, entry = pair
        return fetch(entry["url"], os.path.join(folders["img/fig" if entry["figure"] else "img/icon"], key[:8] + ".png"))
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        fetched = list(pool.map(picture, images.items()))
    print("%d pages (%d fetched), %d pictures (%d fetched, %d screenshots and figures) in %s"
          % (len(items), sum(got), len(images), sum(fetched), sum(1 for e in images.values() if e["figure"]), out))


if __name__ == "__main__":
    main()
