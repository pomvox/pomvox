#!/usr/bin/env python3
"""Emit, splice, and validate Sparkle appcast items for Pomvox releases.

Used by scripts/publish-release.sh. Signing itself happens with Sparkle's
sign_update (Keychain); this script only assembles and checks XML, so the
Linux CI spec suite can cover it. sparkle:version is the monotonic build
number (CURRENT_PROJECT_VERSION); sparkle:shortVersionString is the
marketing version (MARKETING_VERSION).
"""
from __future__ import annotations

import argparse
import base64
import re
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from xml.etree import ElementTree
from xml.sax.saxutils import escape, quoteattr

SPARKLE_NS = "http://www.sparkle-project.org/xml/rss/1.0/modules/sparkle"
REPO = "pomvox/pomvox"


def enclosure_url(tag: str, asset: str = "Pomvox.zip") -> str:
    return f"https://github.com/{REPO}/releases/download/{tag}/{asset}"


def appcast_item(short_version: str, build: int, tag: str, length: int,
                 ed_signature: str, pub_date: datetime | None = None,
                 min_system: str = "14.0") -> str:
    # Finding 6: every interpolated value that isn't a script-controlled
    # constant (short_version, tag, min_system all ultimately come from CLI
    # args a release script passes through) is escaped before it lands in the
    # XML — `escape()` for element text, `quoteattr()` for attribute values
    # (it supplies its own quote characters, switching quote style rather than
    # letting an embedded quote break out of the attribute). For clean inputs
    # this produces byte-identical output to the old bare interpolation.
    pub = format_datetime(pub_date or datetime.now(timezone.utc))
    notes_link = escape(f"https://github.com/{REPO}/releases/tag/{tag}")
    return f"""    <item>
      <title>Version {escape(short_version)}</title>
      <pubDate>{pub}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{escape(short_version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(min_system)}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{notes_link}</sparkle:releaseNotesLink>
      <enclosure url={quoteattr(enclosure_url(tag))} length="{length}"
                 type="application/octet-stream" sparkle:edSignature={quoteattr(ed_signature)}/>
    </item>"""


def _builds(appcast_text: str) -> list[int]:
    return [int(b) for b in re.findall(r"<sparkle:version>(\d+)</sparkle:version>",
                                       appcast_text)]


def insert_item(appcast_text: str, item_text: str) -> str:
    """Splice the item in newest-first (as the first <item>). Text surgery on
    purpose: ElementTree would rewrite namespace prefixes across the whole
    committed file; validate() re-parses the result for real."""
    new_builds = _builds(item_text)
    if len(new_builds) != 1:
        raise ValueError("item must carry exactly one sparkle:version")
    existing = _builds(appcast_text)
    if existing and new_builds[0] <= max(existing):
        raise ValueError(
            f"build {new_builds[0]} must be newer than the newest shipped build "
            f"({max(existing)}) — duplicates and downgrades are refused")
    if "<item>" in appcast_text:
        return appcast_text.replace("    <item>", item_text + "\n    <item>", 1)
    return appcast_text.replace("  </channel>", item_text + "\n  </channel>", 1)


def validate(appcast_text: str) -> list[str]:
    """Return a list of problems; [] means the feed is publishable."""
    problems: list[str] = []
    try:
        root = ElementTree.fromstring(appcast_text)
    except ElementTree.ParseError as e:
        return [f"malformed XML: {e}"]
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        return ["not an rss feed with a channel"]
    ns = {"sparkle": SPARKLE_NS}
    builds: list[int] = []
    for item in channel.findall("item"):
        version = item.find("sparkle:version", ns)
        if version is None or not (version.text or "").isdigit():
            problems.append("item missing integer sparkle:version")
            continue
        builds.append(int(version.text))
        enclosure = item.find("enclosure")
        if enclosure is None:
            problems.append(f"build {version.text}: missing enclosure")
            continue
        url = enclosure.get("url", "")
        if not url.startswith(f"https://github.com/{REPO}/releases/download/"):
            problems.append(f"build {version.text}: enclosure url {url!r} is not a release asset")
        if not enclosure.get("length", "").isdigit():
            problems.append(f"build {version.text}: enclosure length missing")
        if not enclosure.get(f"{{{SPARKLE_NS}}}edSignature"):
            problems.append(f"build {version.text}: enclosure missing sparkle:edSignature")
    if builds != sorted(builds, reverse=True):
        problems.append(f"items are not newest-first by sparkle:version: {builds}")
    if len(set(builds)) != len(builds):
        problems.append(f"duplicate sparkle:version values: {builds}")
    return problems


def verify_signature(path: str, ed_signature_b64: str, public_key_b64: str) -> bool:
    """EdDSA-verify a release archive against SUPublicEDKey (pre-commit gate)."""
    from nacl.exceptions import BadSignatureError
    from nacl.signing import VerifyKey
    try:
        VerifyKey(base64.b64decode(public_key_b64)).verify(
            open(path, "rb").read(), base64.b64decode(ed_signature_b64))
        return True
    except (BadSignatureError, ValueError):
        return False


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--appcast", default="appcast.xml")
    p.add_argument("--zip", required=True, help="release archive (for its byte length)")
    p.add_argument("--tag", required=True)
    p.add_argument("--short-version", required=True)
    p.add_argument("--build", type=int, required=True)
    p.add_argument("--signature", required=True, help="base64 EdDSA signature from sign_update")
    p.add_argument("--write", action="store_true", help="update --appcast in place")
    args = p.parse_args()

    from pathlib import Path
    length = Path(args.zip).stat().st_size
    item = appcast_item(args.short_version, args.build, args.tag, length, args.signature)
    try:
        updated = insert_item(Path(args.appcast).read_text(), item)
    except ValueError as e:
        print(f"appcast INVALID: {e}", file=sys.stderr)
        return 1
    problems = validate(updated)
    if problems:
        for problem in problems:
            print(f"appcast INVALID: {problem}", file=sys.stderr)
        return 1
    if args.write:
        Path(args.appcast).write_text(updated)
    else:
        print(updated)
    return 0


if __name__ == "__main__":
    sys.exit(main())
