#!/usr/bin/env python3
"""Add (or replace) one release item in a Sparkle appcast.xml, keeping the older items.

`releases/latest/download/appcast.xml` only ever serves the newest release's asset, so every release must carry the
full history; this merges the new item into the previous appcast. Called by Scripts/release.sh.
"""
import argparse
import email.utils
import html
import re
import os
import sys
import xml.etree.ElementTree as ET

SP = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SP)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def q(tag):
    return f"{{{SP}}}{tag}"


def inline(text):
    """Escaped text with **bold** and `code` (the only inline markup release notes use)."""
    text = html.escape(text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", text)


def notes_html(path):
    """Release-notes markdown -> minimal HTML (bullets and paragraphs; escaped)."""
    out, in_list = [], False
    for line in open(path, encoding="utf-8").read().splitlines():
        line = line.rstrip()
        if line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(line[2:])}</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if line and not line.startswith("#"):
            out.append(f"<p>{inline(line)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--existing")
    a.add_argument("--out", required=True)
    a.add_argument("--version", required=True)  # sparkle:shortVersionString
    a.add_argument("--build", required=True)  # sparkle:version (CFBundleVersion, must increase)
    a.add_argument("--url", required=True)
    a.add_argument("--length", required=True)
    a.add_argument("--ed-signature", default="")
    a.add_argument("--min-system", default="26.0")
    a.add_argument("--notes")
    args = a.parse_args()

    if args.existing and os.path.exists(args.existing):
        tree = ET.parse(args.existing)
        channel = tree.getroot().find("channel")
    else:
        rss = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "MacDown2.0"
        tree = ET.ElementTree(rss)

    for item in channel.findall("item"):  # re-running a version replaces it
        if item.findtext(q("shortVersionString")) == args.version:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {args.version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(localtime=False, usegmt=True)
    ET.SubElement(item, q("version")).text = args.build
    ET.SubElement(item, q("shortVersionString")).text = args.version
    ET.SubElement(item, q("minimumSystemVersion")).text = args.min_system
    if args.notes:
        desc = ET.SubElement(item, "description")
        desc.text = notes_html(args.notes)
    enc = {"url": args.url, "length": args.length, "type": "application/octet-stream"}
    if args.ed_signature:
        enc[q("edSignature")] = args.ed_signature
    ET.SubElement(item, "enclosure", enc)

    # Newest first; position among <title> and other channel children does not matter to Sparkle.
    first = next((i for i, c in enumerate(channel) if c.tag == "item"), len(channel))
    channel.insert(first, item)

    ET.indent(tree, space="  ")
    tree.write(args.out, encoding="utf-8", xml_declaration=True)
    if not args.ed_signature:
        print("update-appcast: item written WITHOUT sparkle:edSignature", file=sys.stderr)


main()
