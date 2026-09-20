#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import shutil
import tempfile
from pathlib import Path
from urllib.parse import unquote, urlparse
from xml.etree import ElementTree


STAGES = ["internal", "beta", "10", "25", "50", "100"]
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def fail(message):
    raise SystemExit(f"update rollout: {message}")


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def artifact(path, state_directory, stored_name):
    resolved = path.resolve()
    if not resolved.is_file():
        fail(f"artifact does not exist: {resolved}")
    state_directory = state_directory.resolve()
    stored_path = Path("artifacts") / stored_name
    stored = state_directory / stored_path
    if resolved != stored:
        atomic_copy(resolved, stored)
    return {"path": stored_path.as_posix(), "sha256": digest(stored)}


def resolve_artifact(state_path, record):
    stored_path = record.get("path") if isinstance(record, dict) else None
    if not isinstance(stored_path, str) or not stored_path:
        fail("artifact path is invalid")
    path = Path(stored_path)
    if path.is_absolute():
        fail("artifact paths must be relative to the rollout state")
    state_directory = state_path.parent.resolve()
    resolved = (state_directory / path).resolve()
    try:
        resolved.relative_to(state_directory)
    except ValueError:
        fail("artifact path escapes the rollout state bundle")
    return resolved


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def atomic_copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        shutil.copyfile(source, temporary)
        temporary.chmod(0o644)
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()


def release(version, build, dmg, appcast, state_directory, artifact_prefix):
    if not version or not all(part.isdigit() for part in version.split(".")):
        fail(f"invalid version: {version!r}")
    if build <= 0:
        fail("build must be positive")
    return {
        "version": version,
        "build": build,
        "dmg": artifact(dmg, state_directory, f"{artifact_prefix}/{dmg.name}"),
        "appcast": artifact(appcast, state_directory, f"{artifact_prefix}/appcast.xml"),
    }


def load(state_path):
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"state does not exist: {state_path}")
    except (OSError, json.JSONDecodeError) as error:
        fail(f"could not read state: {error}")
    validate(state_path, state)
    return state


def validate_release(state_path, name, value):
    if not isinstance(value, dict):
        fail(f"{name} must be an object")
    if (
        not isinstance(value.get("version"), str)
        or not value["version"]
        or not all(part.isdigit() for part in value["version"].split("."))
    ):
        fail(f"{name}.version is invalid")
    if not isinstance(value.get("build"), int) or value["build"] <= 0:
        fail(f"{name}.build is invalid")
    for artifact_name in ("dmg", "appcast"):
        record = value.get(artifact_name)
        if not isinstance(record, dict):
            fail(f"{name}.{artifact_name} must be an object")
        expected = record.get("sha256")
        if (
            not isinstance(expected, str)
            or len(expected) != 64
            or any(character not in "0123456789abcdef" for character in expected)
        ):
            fail(f"{name}.{artifact_name}.sha256 is invalid")
        path = resolve_artifact(state_path, record)
        if not path.is_file():
            fail(f"{name}.{artifact_name} is missing: {path}")
        if digest(path) != expected:
            fail(f"{name}.{artifact_name} hash mismatch: {path}")
    validate_appcast(
        state_path,
        name,
        value["appcast"],
        value["dmg"],
        value["version"],
        value["build"],
    )


def validate_appcast(state_path, name, appcast_record, dmg_record, version, build):
    appcast = resolve_artifact(state_path, appcast_record)
    dmg = resolve_artifact(state_path, dmg_record)
    try:
        raw = appcast.read_bytes()
        if b"<!DOCTYPE" in raw or b"<!ENTITY" in raw:
            fail(f"{name}.appcast contains a DTD or entity declaration")
        root = ElementTree.fromstring(raw)
    except (OSError, ElementTree.ParseError) as error:
        fail(f"{name}.appcast is not valid XML: {error}")
    if root.tag != "rss" or root.get("version") != "2.0":
        fail(f"{name}.appcast must have an RSS 2.0 root")
    channels = root.findall("channel")
    if len(channels) != 1:
        fail(f"{name}.appcast must contain exactly one channel")
    items = channels[0].findall("item")
    expected_version = str(build)
    expected_short_version = version
    matching_items = []
    for item in items:
        sparkle_version = item.findall(f"{{{SPARKLE_NAMESPACE}}}version")
        short_version = item.findall(f"{{{SPARKLE_NAMESPACE}}}shortVersionString")
        if (
            len(sparkle_version) == 1
            and len(short_version) == 1
            and sparkle_version[0].text == expected_version
            and short_version[0].text == expected_short_version
        ):
            matching_items.append(item)
    if len(matching_items) != 1:
        fail(
            f"{name}.appcast must contain exactly one item for "
            f"version {version} build {build}"
        )
    enclosures = matching_items[0].findall("enclosure")
    if len(enclosures) != 1:
        fail(f"{name}.appcast release item must contain exactly one enclosure")
    enclosure = enclosures[0]
    url = enclosure.get("url")
    if not url:
        fail(f"{name}.appcast release enclosure is missing its URL")
    if Path(unquote(urlparse(url).path)).name != dmg.name:
        fail(f"{name}.appcast enclosure does not identify {dmg.name}")
    length = enclosure.get("length")
    if not length or not length.isdigit() or int(length) != dmg.stat().st_size:
        fail(f"{name}.appcast enclosure length does not match {dmg}")
    signature = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature")
    if not signature:
        fail(f"{name}.appcast release enclosure is missing its EdDSA signature")


def validate(state_path, state):
    if not isinstance(state, dict) or state.get("schema_version") != 1:
        fail("schema_version must be 1")
    if state.get("stages") != STAGES:
        fail("stages do not match the Perry rollout sequence")
    stage = state.get("stage")
    if stage not in STAGES:
        fail(f"invalid stage: {stage!r}")
    reached = state.get("reached_stages")
    expected_reached = STAGES[: STAGES.index(stage) + 1]
    if reached != expected_reached:
        fail("reached_stages are not a contiguous rollout prefix")
    if not isinstance(state.get("rolled_back"), bool):
        fail("rolled_back must be a boolean")
    validate_release(state_path, "current_release", state.get("current_release"))
    validate_release(state_path, "previous_release", state.get("previous_release"))
    current = state["current_release"]
    previous = state["previous_release"]
    if current["build"] <= previous["build"]:
        fail("current release must be newer than previous release")


def feed_path(state_path, stage):
    return state_path.parent / "feeds" / stage / "appcast.xml"


def initialize(args):
    if args.state.exists():
        fail(f"state already exists: {args.state}")
    state = {
        "schema_version": 1,
        "stages": STAGES,
        "stage": "internal",
        "reached_stages": ["internal"],
        "rolled_back": False,
        "current_release": release(
            args.version,
            args.build,
            args.dmg,
            args.appcast,
            args.state.parent,
            "current",
        ),
        "previous_release": release(
            args.previous_version,
            args.previous_build,
            args.previous_dmg,
            args.previous_appcast,
            args.state.parent,
            "previous",
        ),
    }
    validate(args.state, state)
    atomic_copy(
        resolve_artifact(args.state, state["current_release"]["appcast"]),
        feed_path(args.state, "internal"),
    )
    atomic_json(args.state, state)
    print(f"initialized {args.version} build {args.build} at internal")


def promote(args):
    state = load(args.state)
    if state["rolled_back"]:
        fail("a rolled-back release cannot be promoted")
    current_index = STAGES.index(state["stage"])
    if current_index == len(STAGES) - 1:
        fail("release is already at 100")
    expected = STAGES[current_index + 1]
    if args.stage != expected:
        fail(f"next legal stage is {expected}, not {args.stage}")
    appcast = resolve_artifact(args.state, state["current_release"]["appcast"])
    atomic_copy(appcast, feed_path(args.state, args.stage))
    state["stage"] = args.stage
    state["reached_stages"].append(args.stage)
    atomic_json(args.state, state)
    print(f"promoted {state['current_release']['version']} to {args.stage}")


def rollback(args):
    state = load(args.state)
    if state["rolled_back"]:
        fail("release is already rolled back")
    appcast = resolve_artifact(args.state, state["previous_release"]["appcast"])
    for stage in state["reached_stages"]:
        atomic_copy(appcast, feed_path(args.state, stage))
    state["rolled_back"] = True
    atomic_json(args.state, state)
    print(
        f"rolled back {state['current_release']['version']} to "
        f"{state['previous_release']['version']} through {state['stage']}"
    )


def verify(args):
    state = load(args.state)
    selected_release = state["previous_release"] if state["rolled_back"] else state["current_release"]
    selected_appcast = resolve_artifact(args.state, selected_release["appcast"])
    selected_digest = digest(selected_appcast)
    for stage in state["reached_stages"]:
        feed = feed_path(args.state, stage)
        if not feed.is_file():
            fail(f"feed is missing for reached stage {stage}: {feed}")
        if digest(feed) != selected_digest:
            fail(f"feed does not match the active release for stage {stage}: {feed}")
    for stage in STAGES[len(state["reached_stages"]) :]:
        if feed_path(args.state, stage).exists():
            fail(f"unreached stage already has a feed: {stage}")
    print(
        f"verified rollout for {selected_release['version']} through {state['stage']}"
        f"{' after rollback' if state['rolled_back'] else ''}"
    )


def parser():
    command = argparse.ArgumentParser(prog="manage-update-rollout.py")
    subcommands = command.add_subparsers(dest="command", required=True)

    initialize_parser = subcommands.add_parser("initialize")
    initialize_parser.add_argument("--state", type=Path, required=True)
    initialize_parser.add_argument("--version", required=True)
    initialize_parser.add_argument("--build", type=int, required=True)
    initialize_parser.add_argument("--dmg", type=Path, required=True)
    initialize_parser.add_argument("--appcast", type=Path, required=True)
    initialize_parser.add_argument("--previous-version", required=True)
    initialize_parser.add_argument("--previous-build", type=int, required=True)
    initialize_parser.add_argument("--previous-dmg", type=Path, required=True)
    initialize_parser.add_argument("--previous-appcast", type=Path, required=True)
    initialize_parser.set_defaults(run=initialize)

    promote_parser = subcommands.add_parser("promote")
    promote_parser.add_argument("--state", type=Path, required=True)
    promote_parser.add_argument("--stage", choices=STAGES, required=True)
    promote_parser.set_defaults(run=promote)

    rollback_parser = subcommands.add_parser("rollback")
    rollback_parser.add_argument("--state", type=Path, required=True)
    rollback_parser.set_defaults(run=rollback)

    verify_parser = subcommands.add_parser("verify")
    verify_parser.add_argument("--state", type=Path, required=True)
    verify_parser.set_defaults(run=verify)
    return command


def main():
    args = parser().parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
