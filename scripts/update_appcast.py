#!/usr/bin/env python3
"""Add (or replace) a release in Voilà's Sparkle appcast.

Usage:
  update_appcast.py <appcast.xml> --version 1.1 --build 2 --url <dmg url>
                    --signature 'sparkle:edSignature="…" length="…"'
                    [--notes-html <file>] [--min-os 26.0]

The newest release goes first. Re-publishing the same build replaces its entry; publishing a
build number that isn't higher than the newest one is refused, because Sparkle compares
CFBundleVersion and would never offer it.
"""
import argparse
import html
import re
import sys
from email.utils import formatdate

parser = argparse.ArgumentParser()
parser.add_argument("appcast")
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True)
parser.add_argument("--url", required=True)
parser.add_argument("--signature", required=True)
parser.add_argument("--notes-html")
parser.add_argument("--min-os", default="26.0")
args = parser.parse_args()

if not re.fullmatch(r'sparkle:edSignature="[^"]+" length="\d+"', args.signature.strip()):
    sys.exit(f"Unexpected sign_update output: {args.signature!r}")

with open(args.appcast, encoding="utf-8") as f:
    xml = f.read()

items = re.findall(r"\s*<item>.*?</item>", xml, flags=re.S)
builds = [int(b) for b in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", xml)]
same = [i for i in items if f"<sparkle:version>{args.build}</sparkle:version>" in i]
if not same and builds and int(args.build) <= max(builds):
    sys.exit(f"Build {args.build} must be higher than the newest published build {max(builds)} "
             "(bump CFBundleVersion in Resources/Info.plist).")
for item in same:
    xml = xml.replace(item, "")

notes = ""
if args.notes_html:
    with open(args.notes_html, encoding="utf-8") as f:
        body = f.read().strip().replace("]]>", "]]&gt;")
    notes = f"\n      <description><![CDATA[{body}]]></description>"

item = f"""
    <item>
      <title>Version {html.escape(args.version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(args.min_os)}</sparkle:minimumSystemVersion>{notes}
      <enclosure url="{html.escape(args.url)}" type="application/octet-stream" {args.signature.strip()}/>
    </item>"""

anchor = re.search(r"<language>.*?</language>", xml)
if not anchor:
    sys.exit("appcast.xml has no <language> element to insert after")
xml = xml[: anchor.end()] + item + xml[anchor.end():]

with open(args.appcast, "w", encoding="utf-8") as f:
    f.write(xml)
print(f"Appcast updated with Voilà {args.version} (build {args.build})")
