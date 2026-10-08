#!/usr/bin/env python3
"""Writes the AltStore / SideStore source for one release, to stdout.

    scripts/make-source.py build/export/MiniWatts-unsigned.ipa v1.1.0 > build/export/apps.json

CI runs this on every `v*` tag and publishes the result as an asset of the release,
next to the ipa. That gives the source an address that never changes —

    https://github.com/ResistanceTo/MiniWatts/releases/latest/download/apps.json

— because `releases/latest` follows the newest release that is not a pre-release. A
beta tag therefore never reaches people who added the source, and nothing has to be
committed back to the repository after a release.

Everything a source app store checks is read from the ipa itself rather than typed
here, because a mismatch is not cosmetic: AltStore compares the version, build number,
entitlements and privacy keys it downloads against what the source claims, and refuses
to install on any difference.
"""

import datetime
import json
import os
import plistlib
import sys
import zipfile

REPO = os.environ.get("GITHUB_REPOSITORY", "ResistanceTo/MiniWatts")
BUNDLE_ID = "org.zhaohe.MiniWatts"
# Images come from master, not from the tag: they are presentation, and a release tagged
# before an image existed would otherwise point at a file that is not there.
RAW = f"https://raw.githubusercontent.com/{REPO}/master"
SCREENSHOT_SIZE = (1260, 2736)

DESCRIPTION = """\
MiniWatts reads the iPhone's own power management sensors and shows what is actually \
flowing: charger input in watts, what reaches the battery, rail voltages and currents, \
every temperature sensor placed on a map of the phone, the USB-PD profiles the charger \
offers, and a history of each charge.

It reads private system frameworks, so it is sideload-only and can never be on the App \
Store. It was built and verified on an iPhone Air; sensor names and scaling differ \
between models, so some readings may be wrong on yours.

Includes a Home Screen and Lock Screen widget, a charging Live Activity and a floating \
Picture in Picture meter. The widget and the Live Activity live in an app extension: \
signing it takes one more App ID, and LiveContainer cannot run extensions, so installed \
there MiniWatts has neither.

Free and open source: https://github.com/ResistanceTo/MiniWatts"""


def fail(message):
    print(f"make-source: {message}", file=sys.stderr)
    sys.exit(1)


def read_app(ipa):
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        # The app's own Info.plist sits at Payload/X.app/Info.plist; the widget's is
        # deeper, under PlugIns, and is not what a store checks.
        plists = [n for n in names if n.startswith("Payload/") and n.count("/") == 2
                  and n.endswith(".app/Info.plist")]
        if len(plists) != 1:
            fail(f"expected one app in {ipa}, found {len(plists)}")
        app_dir = plists[0].rsplit("/", 1)[0]
        # The distributed ipa is unsigned by design, and an unsigned binary carries no
        # entitlements — which is exactly what the source then declares. A signed ipa
        # would have some, and describing it as having none would make AltStore refuse
        # it, so say so instead of publishing a source that cannot install.
        if any(n.startswith(f"{app_dir}/_CodeSignature/") for n in names):
            fail("the ipa is signed; the source describes the unsigned build only")
        info = plistlib.loads(archive.read(plists[0]))
    return info


def main():
    if len(sys.argv) != 3:
        fail("usage: make-source.py <unsigned ipa> <tag>")
    ipa, tag = sys.argv[1], sys.argv[2]
    info = read_app(ipa)

    version = info["CFBundleShortVersionString"]
    if info["CFBundleIdentifier"] != BUNDLE_ID:
        fail(f"bundle identifier is {info['CFBundleIdentifier']}, expected {BUNDLE_ID}")
    if tag != f"v{version}":
        fail(f"the ipa reports version {version} but the tag is {tag}")

    release = f"https://github.com/{REPO}/releases/tag/{tag}"
    date = os.environ.get("RELEASE_DATE") or datetime.datetime.now(datetime.timezone.utc) \
        .replace(microsecond=0).isoformat().replace("+00:00", "Z")

    source = {
        "name": "MiniWatts",
        # Not in AltStore's current format, but older AltStore and SideStore builds
        # identify a source by it. Harmless where it is ignored.
        "identifier": f"{BUNDLE_ID}.source",
        "sourceURL": f"https://github.com/{REPO}/releases/latest/download/apps.json",
        "subtitle": "Live charge power, battery and thermal sensors.",
        "description": "The MiniWatts app, straight from its GitHub releases.",
        "iconURL": f"{RAW}/docs/icon.png",
        "website": f"https://github.com/{REPO}",
        "tintColor": "#0086B3",
        # No `marketplaceID` anywhere: SideStore takes its presence to mean a notarized
        # AltStore PAL source and refuses to add it.
        "apps": [{
            "name": "MiniWatts",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": "ResistanceTo",
            "subtitle": "Live charge power, battery and thermal sensors.",
            "localizedDescription": DESCRIPTION,
            "iconURL": f"{RAW}/docs/icon.png",
            "tintColor": "#0086B3",
            "category": "utilities",
            "screenshots": [
                {"imageURL": f"{RAW}/docs/screenshots/{name}.jpg",
                 "width": SCREENSHOT_SIZE[0], "height": SCREENSHOT_SIZE[1]}
                for name in ("power", "thermal", "adapter", "history")
            ],
            "versions": [{
                "version": version,
                "buildVersion": info["CFBundleVersion"],
                "date": date,
                "localizedDescription": f"Release notes: {release}",
                "downloadURL": f"https://github.com/{REPO}/releases/download/{tag}/{os.path.basename(ipa)}",
                "size": os.path.getsize(ipa),
                "minOSVersion": info.get("MinimumOSVersion", "17.0"),
            }],
            "appPermissions": {
                "entitlements": [],
                "privacy": {key: value for key, value in info.items()
                            if key.startswith("NS") and key.endswith("UsageDescription")},
            },
        }],
        "news": [],
    }
    json.dump(source, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
