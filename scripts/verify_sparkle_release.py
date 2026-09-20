import argparse
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlparse
from xml.etree import ElementTree


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def fail(message: str) -> None:
    raise SystemExit(f"Sparkle release verification: {message}")


def signature(appcast: Path, dmg: Path, version: str, build: int) -> str:
    try:
        raw = appcast.read_bytes()
        if b"<!DOCTYPE" in raw or b"<!ENTITY" in raw:
            fail("appcast contains a DTD or entity declaration")
        root = ElementTree.fromstring(raw)
    except (OSError, ElementTree.ParseError) as error:
        fail(f"could not parse appcast: {error}")
    matches = []
    for item in root.findall("./channel/item"):
        item_build = item.find(f"{{{SPARKLE_NAMESPACE}}}version")
        item_version = item.find(f"{{{SPARKLE_NAMESPACE}}}shortVersionString")
        if (
            item_build is not None
            and item_version is not None
            and item_build.text == str(build)
            and item_version.text == version
        ):
            matches.append(item)
    if len(matches) != 1:
        fail(f"appcast must contain exactly one item for version {version} build {build}")
    enclosures = matches[0].findall("enclosure")
    if len(enclosures) != 1:
        fail("release item must contain exactly one enclosure")
    enclosure = enclosures[0]
    url = enclosure.get("url", "")
    if Path(unquote(urlparse(url).path)).name != dmg.name:
        fail(f"release enclosure does not identify {dmg.name}")
    length = enclosure.get("length", "")
    if not length.isdigit() or int(length) != dmg.stat().st_size:
        fail("release enclosure length does not match the DMG")
    value = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature", "")
    if not value:
        fail("release enclosure has no EdDSA signature")
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--sign-update", type=Path, required=True)
    parser.add_argument("--key-file", type=Path, required=True)
    args = parser.parse_args()
    if (
        not args.dmg.is_file()
        or not args.sign_update.is_file()
        or not args.key_file.is_file()
    ):
        fail("DMG, sign_update, and key file must exist")
    value = signature(args.appcast, args.dmg, args.version, args.build)
    try:
        result = subprocess.run(
            [
                str(args.sign_update),
                "--verify",
                "--ed-key-file",
                str(args.key_file),
                str(args.dmg),
                value,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        fail("could not run Sparkle signature verification")
    if result.returncode != 0:
        fail("EdDSA signature verification failed")


if __name__ == "__main__":
    main()
