import argparse
import json
import re
from pathlib import Path


LOCK_FIELDS = {
    "CODEX_RUNTIME_VERSION",
    "CODEX_RUNTIME_TARGET",
    "CODEX_RUNTIME_ARCHIVE_SHA256",
    "CODEX_RUNTIME_BINARY_SHA256",
    "CODEX_RUNTIME_LICENSE",
    "CODEX_RUNTIME_SOURCE",
    "CODEX_RUNTIME_LICENSE_URL",
}
CUA_DRIVER_LOCK_FIELDS = {
    "CUA_DRIVER_VERSION",
    "CUA_DRIVER_TARGET",
    "CUA_DRIVER_RELEASE_TAG",
    "CUA_DRIVER_ASSET",
    "CUA_DRIVER_ASSET_URL",
    "CUA_DRIVER_ARCHIVE_SHA256",
    "CUA_DRIVER_BINARY_SHA256",
    "CUA_DRIVER_DISTRIBUTION_BINARY_SHA256",
    "CUA_DRIVER_ARCHIVE_BINARY",
    "CUA_DRIVER_SIGNING_IDENTIFIER",
    "CUA_DRIVER_SIGNING_TEAM",
    "CUA_DRIVER_SOURCE",
    "CUA_DRIVER_SOURCE_REVISION",
}
AGENT_DESKTOP_LOCK_FIELDS = {
    "AGENT_DESKTOP_VERSION",
    "AGENT_DESKTOP_TARGET",
    "AGENT_DESKTOP_RELEASE_TAG",
    "AGENT_DESKTOP_ASSET",
    "AGENT_DESKTOP_ASSET_URL",
    "AGENT_DESKTOP_ARCHIVE_SHA256",
    "AGENT_DESKTOP_BINARY_SHA256",
    "AGENT_DESKTOP_HELPER_SHA256",
    "AGENT_DESKTOP_SOURCE",
    "AGENT_DESKTOP_SOURCE_REVISION",
}
SPARKLE_LOCK_FIELDS = {
    "SPARKLE_VERSION",
    "SPARKLE_REVISION",
    "SPARKLE_ARTIFACT_SHA256",
}
XCODEGEN_LOCK_FIELDS = {
    "XCODEGEN_VERSION",
    "XCODEGEN_ARCHIVE_URL",
    "XCODEGEN_ARCHIVE_SHA256",
    "XCODEGEN_BINARY_SHA256",
}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SOURCE_REVISION_PATTERN = re.compile(r"^[0-9a-f]{40}$")
VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
CUA_DRIVER_LICENSE = "MIT"
AGENT_DESKTOP_LICENSE = "Apache-2.0"
SPARKLE_LICENSE = "MIT"
XCODEGEN_SOURCE = "https://github.com/yonaskolb/XcodeGen"
XCODEGEN_LICENSE = "MIT"


def fail(message):
    raise SystemExit(f"release metadata: {message}")


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"file not found: {path}")
    except OSError as error:
        fail(f"could not read {path}: {error}")
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {path} at line {error.lineno}, column {error.colno}")


def load_runtime_lock(path):
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        fail(f"runtime lock not found: {path}")
    except OSError as error:
        fail(f"could not read runtime lock {path}: {error}")

    for line_number, line in enumerate(lines, start=1):
        if not line:
            continue
        if "=" not in line:
            fail(f"runtime lock line {line_number} is not a key/value pair")
        key, value = line.split("=", 1)
        if key not in LOCK_FIELDS:
            fail(f"runtime lock has an unknown field: {key}")
        if key in values:
            fail(f"runtime lock repeats field: {key}")
        if not value:
            fail(f"runtime lock field is empty: {key}")
        values[key] = value

    missing = sorted(LOCK_FIELDS - values.keys())
    if missing:
        fail(f"runtime lock is missing fields: {', '.join(missing)}")

    version = values["CODEX_RUNTIME_VERSION"]
    if not VERSION_PATTERN.fullmatch(version):
        fail(f"runtime version is not pinned semver: {version}")
    if values["CODEX_RUNTIME_TARGET"] != "aarch64-apple-darwin":
        fail("runtime target must be aarch64-apple-darwin")
    for field in ("CODEX_RUNTIME_ARCHIVE_SHA256", "CODEX_RUNTIME_BINARY_SHA256"):
        if not SHA256_PATTERN.fullmatch(values[field]):
            fail(f"runtime lock field is not a lowercase SHA-256 digest: {field}")
    if not re.fullmatch(r"[A-Za-z0-9.+-]+", values["CODEX_RUNTIME_LICENSE"]):
        fail("runtime license is not an SPDX identifier")
    if values["CODEX_RUNTIME_LICENSE"] == "NOASSERTION":
        fail("runtime license must be identified")
    if values["CODEX_RUNTIME_SOURCE"] != "https://github.com/openai/codex":
        fail("runtime source must be the pinned Codex repository")
    license_prefix = f"https://github.com/openai/codex/blob/rust-v{version}/"
    if not values["CODEX_RUNTIME_LICENSE_URL"].startswith(license_prefix):
        fail("runtime license URL must name the pinned runtime tag")
    return values


def load_cua_driver_lock(path):
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        fail(f"Cua driver lock not found: {path}")
    except OSError as error:
        fail(f"could not read Cua driver lock {path}: {error}")

    for line_number, line in enumerate(lines, start=1):
        if not line:
            continue
        if line.count("=") != 1:
            fail(f"Cua driver lock line {line_number} is not a key/value pair")
        key, value = line.split("=", 1)
        if key not in CUA_DRIVER_LOCK_FIELDS:
            fail(f"Cua driver lock has an unknown field: {key}")
        if key in values:
            fail(f"Cua driver lock repeats field: {key}")
        if not value:
            fail(f"Cua driver lock field is empty: {key}")
        values[key] = value

    missing = sorted(CUA_DRIVER_LOCK_FIELDS - values.keys())
    if missing:
        fail(f"Cua driver lock is missing fields: {', '.join(missing)}")

    version = values["CUA_DRIVER_VERSION"]
    if not VERSION_PATTERN.fullmatch(version):
        fail(f"Cua driver version is not pinned semver: {version}")
    if values["CUA_DRIVER_TARGET"] != "aarch64-apple-darwin":
        fail("Cua driver target must be aarch64-apple-darwin")
    release_tag = values["CUA_DRIVER_RELEASE_TAG"]
    if release_tag != f"cua-driver-rs-v{version}":
        fail(f"Cua driver release tag must match version: {release_tag}")
    asset = values["CUA_DRIVER_ASSET"]
    if asset != f"cua-driver-rs-{version}-darwin-arm64.tar.gz":
        fail(f"Cua driver asset must be the Apple Silicon release archive: {asset}")
    expected_asset_url = f"https://github.com/trycua/cua/releases/download/{release_tag}/{asset}"
    if values["CUA_DRIVER_ASSET_URL"] != expected_asset_url:
        fail("Cua driver asset URL must be the exact pinned GitHub release asset")
    expected_archive_binary = f"cua-driver-rs-{version}-darwin-arm64/cua-driver"
    if values["CUA_DRIVER_ARCHIVE_BINARY"] != expected_archive_binary:
        fail("Cua driver archive binary path must name the pinned cua-driver member")
    if values["CUA_DRIVER_SOURCE"] != "https://github.com/trycua/cua":
        fail("Cua driver source must be the pinned Cua repository")
    for field in (
        "CUA_DRIVER_ARCHIVE_SHA256",
        "CUA_DRIVER_BINARY_SHA256",
        "CUA_DRIVER_DISTRIBUTION_BINARY_SHA256",
    ):
        if not SHA256_PATTERN.fullmatch(values[field]):
            fail(f"Cua driver lock field is not a lowercase SHA-256 digest: {field}")
    if values["CUA_DRIVER_SIGNING_IDENTIFIER"] != "cua-driver":
        fail("Cua driver signing identifier must be cua-driver")
    if not re.fullmatch(r"[A-Z0-9]{10}", values["CUA_DRIVER_SIGNING_TEAM"]):
        fail("Cua driver signing team must be a ten-character Apple team identifier")
    if not SOURCE_REVISION_PATTERN.fullmatch(values["CUA_DRIVER_SOURCE_REVISION"]):
        fail("Cua driver source revision is not a lowercase 40-character commit")
    return values


def load_agent_desktop_lock(path):
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        fail(f"agent-desktop lock not found: {path}")
    except OSError as error:
        fail(f"could not read agent-desktop lock {path}: {error}")

    for line_number, line in enumerate(lines, start=1):
        if not line:
            continue
        if line.count("=") != 1:
            fail(f"agent-desktop lock line {line_number} is not a key/value pair")
        key, value = line.split("=", 1)
        if key not in AGENT_DESKTOP_LOCK_FIELDS:
            fail(f"agent-desktop lock has an unknown field: {key}")
        if key in values:
            fail(f"agent-desktop lock repeats field: {key}")
        if not value:
            fail(f"agent-desktop lock field is empty: {key}")
        values[key] = value

    missing = sorted(AGENT_DESKTOP_LOCK_FIELDS - values.keys())
    if missing:
        fail(f"agent-desktop lock is missing fields: {', '.join(missing)}")

    version = values["AGENT_DESKTOP_VERSION"]
    if not VERSION_PATTERN.fullmatch(version):
        fail(f"agent-desktop version is not pinned semver: {version}")
    if values["AGENT_DESKTOP_TARGET"] != "aarch64-apple-darwin":
        fail("agent-desktop target must be aarch64-apple-darwin")
    release_tag = values["AGENT_DESKTOP_RELEASE_TAG"]
    if release_tag != f"v{version}":
        fail(f"agent-desktop release tag must match version: {release_tag}")
    asset = values["AGENT_DESKTOP_ASSET"]
    if asset != f"agent-desktop-v{version}-aarch64-apple-darwin.tar.gz":
        fail(f"agent-desktop asset must be the Apple Silicon release archive: {asset}")
    expected_asset_url = f"https://github.com/vercel-labs/agent-desktop/releases/download/{release_tag}/{asset}"
    if values["AGENT_DESKTOP_ASSET_URL"] != expected_asset_url:
        fail("agent-desktop asset URL must be the exact pinned GitHub release asset")
    if values["AGENT_DESKTOP_SOURCE"] != "https://github.com/vercel-labs/agent-desktop":
        fail("agent-desktop source must be the pinned agent-desktop repository")
    for field in (
        "AGENT_DESKTOP_ARCHIVE_SHA256",
        "AGENT_DESKTOP_BINARY_SHA256",
        "AGENT_DESKTOP_HELPER_SHA256",
    ):
        if not SHA256_PATTERN.fullmatch(values[field]):
            fail(f"agent-desktop lock field is not a lowercase SHA-256 digest: {field}")
    if not SOURCE_REVISION_PATTERN.fullmatch(values["AGENT_DESKTOP_SOURCE_REVISION"]):
        fail("agent-desktop source revision is not a lowercase 40-character commit")
    return values


def load_sparkle_lock(path):
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        fail(f"Sparkle lock not found: {path}")
    except OSError as error:
        fail(f"could not read Sparkle lock {path}: {error}")

    for line_number, line in enumerate(lines, start=1):
        if not line:
            continue
        if line.count("=") != 1:
            fail(f"Sparkle lock line {line_number} is not a key/value pair")
        key, value = line.split("=", 1)
        if key not in SPARKLE_LOCK_FIELDS:
            fail(f"Sparkle lock has an unknown field: {key}")
        if key in values:
            fail(f"Sparkle lock repeats field: {key}")
        if not value:
            fail(f"Sparkle lock field is empty: {key}")
        values[key] = value

    missing = sorted(SPARKLE_LOCK_FIELDS - values.keys())
    if missing:
        fail(f"Sparkle lock is missing fields: {', '.join(missing)}")
    if not VERSION_PATTERN.fullmatch(values["SPARKLE_VERSION"]):
        fail("Sparkle version is not pinned semver")
    if not SOURCE_REVISION_PATTERN.fullmatch(values["SPARKLE_REVISION"]):
        fail("Sparkle revision is not a lowercase 40-character commit")
    if not SHA256_PATTERN.fullmatch(values["SPARKLE_ARTIFACT_SHA256"]):
        fail("Sparkle artifact checksum is not a lowercase SHA-256 digest")
    return values


def load_xcodegen_lock(path):
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        fail(f"XcodeGen lock not found: {path}")
    except OSError as error:
        fail(f"could not read XcodeGen lock {path}: {error}")

    for line_number, line in enumerate(lines, start=1):
        if not line:
            continue
        if line.count("=") != 1:
            fail(f"XcodeGen lock line {line_number} is not a key/value pair")
        key, value = line.split("=", 1)
        if key not in XCODEGEN_LOCK_FIELDS:
            fail(f"XcodeGen lock has an unknown field: {key}")
        if key in values:
            fail(f"XcodeGen lock repeats field: {key}")
        if not value:
            fail(f"XcodeGen lock field is empty: {key}")
        values[key] = value

    missing = sorted(XCODEGEN_LOCK_FIELDS - values.keys())
    if missing:
        fail(f"XcodeGen lock is missing fields: {', '.join(missing)}")
    version = values["XCODEGEN_VERSION"]
    if not VERSION_PATTERN.fullmatch(version):
        fail(f"XcodeGen version is not pinned semver: {version}")
    expected_archive_url = f"{XCODEGEN_SOURCE}/releases/download/{version}/xcodegen.zip"
    if values["XCODEGEN_ARCHIVE_URL"] != expected_archive_url:
        fail("XcodeGen archive URL must be the exact pinned GitHub release asset")
    for field in ("XCODEGEN_ARCHIVE_SHA256", "XCODEGEN_BINARY_SHA256"):
        if not SHA256_PATTERN.fullmatch(values[field]):
            fail(f"XcodeGen lock field is not a lowercase SHA-256 digest: {field}")
    return values


def relative_path(raw_path, repo_root):
    if not raw_path:
        return None
    candidate = Path(raw_path)
    if not candidate.is_absolute():
        candidate = repo_root / candidate
    try:
        return candidate.resolve().relative_to(repo_root.resolve()).as_posix()
    except ValueError:
        return None


def package_location(node, repo_root):
    location = relative_path(node.get("path"), repo_root)
    if location:
        return location
    raw_url = node.get("url")
    if isinstance(raw_url, str) and raw_url:
        if raw_url.startswith("/"):
            identity = str(node.get("identity", "package")).lower()
            return f"external-path:{identity}"
        return raw_url
    fail(f"package {node.get('identity', '<unknown>')} has no stable location")


def package_ref(identity, version):
    return f"swift:{identity}@{version}"


def collect_graph(graph_paths, repo_root):
    nodes = {}
    edges = {}
    root_refs = set()

    def visit(node):
        if not isinstance(node, dict):
            fail("Swift package graph contains a non-object node")
        identity = node.get("identity")
        name = node.get("name")
        if not isinstance(identity, str) or not identity:
            fail("Swift package graph node has no identity")
        if not isinstance(name, str) or not name:
            fail(f"Swift package graph node has no name: {identity}")
        identity = identity.lower()
        version = node.get("version") or "unspecified"
        if not isinstance(version, str) or not version:
            fail(f"Swift package graph node has invalid version: {identity}")
        location = package_location(node, repo_root)
        ref = package_ref(identity, version)
        is_first_party = location == "Packages" or location.startswith("Packages/")
        if not is_first_party and version == "unspecified":
            fail(f"third-party package is not pinned: {identity}")
        existing = nodes.get(ref)
        record = {
            "identity": identity,
            "name": name,
            "version": version,
            "location": location,
            "is_first_party": is_first_party,
            "path": node.get("path") if isinstance(node.get("path"), str) else None,
            "url": node.get("url") if isinstance(node.get("url"), str) else None,
            "license": node.get("license") if isinstance(node.get("license"), str) else None,
        }
        if existing and existing != record:
            fail(f"Swift package graph has conflicting records for {ref}")
        nodes[ref] = record
        edges.setdefault(ref, set())
        for dependency in node.get("dependencies", []):
            dependency_ref = visit(dependency)
            edges[ref].add(dependency_ref)
        return ref

    for graph_path in graph_paths:
        graph = load_json(graph_path)
        root_refs.add(visit(graph))

    return nodes, edges, root_refs


def license_from_file(package_path):
    if not package_path:
        return None
    path = Path(package_path)
    if not path.is_dir():
        return None
    names = {"LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "NOTICE"}
    candidates = [candidate for candidate in path.iterdir() if candidate.name in names and candidate.is_file()]
    for candidate in sorted(candidates, key=lambda item: item.name):
        try:
            text = candidate.read_text(encoding="utf-8", errors="ignore")[:8192].lower()
        except OSError:
            continue
        if "mit license" in text:
            identifier = "MIT"
        elif "apache license" in text and "version 2.0" in text:
            identifier = "Apache-2.0"
        elif "gnu general public license" in text and "version 3" in text:
            identifier = "GPL-3.0-or-later"
        else:
            identifier = "NOASSERTION"
        return identifier, candidate.name
    return None


def third_party_components(nodes, runtime, cua_driver, agent_desktop, sparkle, xcodegen):
    components = [
        {
            "id": "runtime.codex",
            "name": "Codex",
            "version": runtime["CODEX_RUNTIME_VERSION"],
            "source": runtime["CODEX_RUNTIME_SOURCE"],
            "license": runtime["CODEX_RUNTIME_LICENSE"],
            "license_url": runtime["CODEX_RUNTIME_LICENSE_URL"],
            "target": runtime["CODEX_RUNTIME_TARGET"],
            "archive_sha256": runtime["CODEX_RUNTIME_ARCHIVE_SHA256"],
            "binary_sha256": runtime["CODEX_RUNTIME_BINARY_SHA256"],
        },
        {
            "id": "runtime.cua-driver",
            "name": "Cua Driver",
            "version": cua_driver["CUA_DRIVER_VERSION"],
            "source": cua_driver["CUA_DRIVER_SOURCE"],
            "source_revision": cua_driver["CUA_DRIVER_SOURCE_REVISION"],
            "license": CUA_DRIVER_LICENSE,
            "license_url": f"{cua_driver['CUA_DRIVER_SOURCE']}/blob/{cua_driver['CUA_DRIVER_SOURCE_REVISION']}/LICENSE",
            "target": cua_driver["CUA_DRIVER_TARGET"],
            "archive_sha256": cua_driver["CUA_DRIVER_ARCHIVE_SHA256"],
            "archive_binary_sha256": cua_driver["CUA_DRIVER_BINARY_SHA256"],
            "binary_sha256": cua_driver["CUA_DRIVER_DISTRIBUTION_BINARY_SHA256"],
            "signing_identifier": cua_driver["CUA_DRIVER_SIGNING_IDENTIFIER"],
            "signing_team": cua_driver["CUA_DRIVER_SIGNING_TEAM"],
        },
        {
            "id": "runtime.agent-desktop",
            "name": "agent-desktop",
            "version": agent_desktop["AGENT_DESKTOP_VERSION"],
            "release_tag": agent_desktop["AGENT_DESKTOP_RELEASE_TAG"],
            "source": agent_desktop["AGENT_DESKTOP_SOURCE"],
            "source_revision": agent_desktop["AGENT_DESKTOP_SOURCE_REVISION"],
            "license": AGENT_DESKTOP_LICENSE,
            "license_url": f"{agent_desktop['AGENT_DESKTOP_SOURCE']}/blob/{agent_desktop['AGENT_DESKTOP_SOURCE_REVISION']}/LICENSE",
            "target": agent_desktop["AGENT_DESKTOP_TARGET"],
            "archive_sha256": agent_desktop["AGENT_DESKTOP_ARCHIVE_SHA256"],
            "binary_sha256": agent_desktop["AGENT_DESKTOP_BINARY_SHA256"],
            "helper_sha256": agent_desktop["AGENT_DESKTOP_HELPER_SHA256"],
        },
        {
            "id": "framework.sparkle",
            "name": "Sparkle",
            "version": sparkle["SPARKLE_VERSION"],
            "source": "https://github.com/sparkle-project/Sparkle",
            "source_revision": sparkle["SPARKLE_REVISION"],
            "license": SPARKLE_LICENSE,
            "license_url": f"https://github.com/sparkle-project/Sparkle/blob/{sparkle['SPARKLE_REVISION']}/LICENSE",
            "artifact_sha256": sparkle["SPARKLE_ARTIFACT_SHA256"],
        },
        {
            "id": "tool.xcodegen",
            "name": "XcodeGen",
            "version": xcodegen["XCODEGEN_VERSION"],
            "purl": f"pkg:github/yonaskolb/XcodeGen@{xcodegen['XCODEGEN_VERSION']}",
            "source": XCODEGEN_SOURCE,
            "license": XCODEGEN_LICENSE,
            "license_url": f"{XCODEGEN_SOURCE}/blob/{xcodegen['XCODEGEN_VERSION']}/LICENSE",
            "archive_url": xcodegen["XCODEGEN_ARCHIVE_URL"],
            "archive_sha256": xcodegen["XCODEGEN_ARCHIVE_SHA256"],
            "binary_sha256": xcodegen["XCODEGEN_BINARY_SHA256"],
        },
    ]
    unresolved = []
    for record in nodes.values():
        if record["is_first_party"]:
            continue
        license_info = record["license"]
        package_path = Path(record["path"]) if record["path"] else None
        license_file = license_from_file(package_path)
        if license_info:
            license_id = license_info
            license_name = None
        elif license_file:
            license_id, license_name = license_file
        else:
            license_id = "NOASSERTION"
            license_name = None
        entry = {
            "id": f"swift.{record['identity']}",
            "name": record["name"],
            "version": record["version"],
            "source": record["location"],
            "license": license_id,
        }
        if license_name:
            entry["license_file"] = f"{record['location']}/{license_name}"
        components.append(entry)
        if license_id == "NOASSERTION":
            unresolved.append(record["identity"])
    return sorted(components, key=lambda item: item["id"]), sorted(unresolved)


def sbom_component(record):
    properties = [
        {"name": "perry:identity", "value": record["identity"]},
        {"name": "perry:package-location", "value": record["location"]},
    ]
    component = {
        "bom-ref": package_ref(record["identity"], record["version"]),
        "name": record["name"],
        "scope": "required",
        "type": "library",
        "version": record["version"],
        "properties": properties,
    }
    if record["url"] and not record["is_first_party"] and not record["url"].startswith("/"):
        component["externalReferences"] = [{"type": "vcs", "url": record["url"]}]
    return component


def build_sbom(nodes, edges, roots, runtime, cua_driver, agent_desktop, sparkle, xcodegen):
    runtime_ref = "runtime:codex"
    cua_driver_ref = "runtime:cua-driver"
    agent_desktop_ref = "runtime:agent-desktop"
    sparkle_ref = "framework:sparkle"
    xcodegen_ref = "tool:xcodegen"
    components = [sbom_component(record) for record in nodes.values()]
    components.append(
        {
            "bom-ref": runtime_ref,
            "externalReferences": [
                {
                    "type": "distribution",
                    "url": f"https://github.com/openai/codex/releases/download/rust-v{runtime['CODEX_RUNTIME_VERSION']}/codex-{runtime['CODEX_RUNTIME_TARGET']}.tar.gz",
                },
                {"type": "license", "url": runtime["CODEX_RUNTIME_LICENSE_URL"]},
                {"type": "vcs", "url": runtime["CODEX_RUNTIME_SOURCE"]},
            ],
            "licenses": [{"license": {"id": runtime["CODEX_RUNTIME_LICENSE"]}}],
            "name": "Codex",
            "properties": [
                {"name": "perry:runtime-target", "value": runtime["CODEX_RUNTIME_TARGET"]},
                {"name": "perry:archive-sha256", "value": runtime["CODEX_RUNTIME_ARCHIVE_SHA256"]},
                {"name": "perry:binary-sha256", "value": runtime["CODEX_RUNTIME_BINARY_SHA256"]},
            ],
            "publisher": "OpenAI",
            "scope": "required",
            "type": "application",
            "version": runtime["CODEX_RUNTIME_VERSION"],
        }
    )
    components.append(
        {
            "bom-ref": cua_driver_ref,
            "externalReferences": [
                {"type": "distribution", "url": cua_driver["CUA_DRIVER_ASSET_URL"]},
                {
                    "type": "license",
                    "url": f"{cua_driver['CUA_DRIVER_SOURCE']}/blob/{cua_driver['CUA_DRIVER_SOURCE_REVISION']}/LICENSE",
                },
                {"type": "vcs", "url": cua_driver["CUA_DRIVER_SOURCE"]},
            ],
            "licenses": [{"license": {"id": CUA_DRIVER_LICENSE}}],
            "name": "Cua Driver",
            "properties": [
                {"name": "perry:runtime-target", "value": cua_driver["CUA_DRIVER_TARGET"]},
                {"name": "perry:source-revision", "value": cua_driver["CUA_DRIVER_SOURCE_REVISION"]},
                {"name": "perry:archive-sha256", "value": cua_driver["CUA_DRIVER_ARCHIVE_SHA256"]},
                {"name": "perry:archive-binary-sha256", "value": cua_driver["CUA_DRIVER_BINARY_SHA256"]},
                {"name": "perry:binary-sha256", "value": cua_driver["CUA_DRIVER_DISTRIBUTION_BINARY_SHA256"]},
                {"name": "perry:signing-identifier", "value": cua_driver["CUA_DRIVER_SIGNING_IDENTIFIER"]},
                {"name": "perry:signing-team", "value": cua_driver["CUA_DRIVER_SIGNING_TEAM"]},
            ],
            "scope": "required",
            "type": "application",
            "version": cua_driver["CUA_DRIVER_VERSION"],
        }
    )
    components.append(
        {
            "bom-ref": agent_desktop_ref,
            "externalReferences": [
                {"type": "distribution", "url": agent_desktop["AGENT_DESKTOP_ASSET_URL"]},
                {
                    "type": "license",
                    "url": f"{agent_desktop['AGENT_DESKTOP_SOURCE']}/blob/{agent_desktop['AGENT_DESKTOP_SOURCE_REVISION']}/LICENSE",
                },
                {"type": "vcs", "url": agent_desktop["AGENT_DESKTOP_SOURCE"]},
            ],
            "licenses": [{"license": {"id": AGENT_DESKTOP_LICENSE}}],
            "name": "agent-desktop",
            "properties": [
                {"name": "perry:runtime-target", "value": agent_desktop["AGENT_DESKTOP_TARGET"]},
                {"name": "perry:release-tag", "value": agent_desktop["AGENT_DESKTOP_RELEASE_TAG"]},
                {"name": "perry:source-revision", "value": agent_desktop["AGENT_DESKTOP_SOURCE_REVISION"]},
                {"name": "perry:archive-sha256", "value": agent_desktop["AGENT_DESKTOP_ARCHIVE_SHA256"]},
                {"name": "perry:binary-sha256", "value": agent_desktop["AGENT_DESKTOP_BINARY_SHA256"]},
                {"name": "perry:helper-sha256", "value": agent_desktop["AGENT_DESKTOP_HELPER_SHA256"]},
            ],
            "scope": "required",
            "type": "application",
            "version": agent_desktop["AGENT_DESKTOP_VERSION"],
        }
    )
    components.append(
        {
            "bom-ref": sparkle_ref,
            "externalReferences": [
                {
                    "type": "license",
                    "url": f"https://github.com/sparkle-project/Sparkle/blob/{sparkle['SPARKLE_REVISION']}/LICENSE",
                },
                {"type": "vcs", "url": "https://github.com/sparkle-project/Sparkle"},
            ],
            "licenses": [{"license": {"id": SPARKLE_LICENSE}}],
            "name": "Sparkle",
            "properties": [
                {"name": "perry:source-revision", "value": sparkle["SPARKLE_REVISION"]},
                {"name": "perry:artifact-sha256", "value": sparkle["SPARKLE_ARTIFACT_SHA256"]},
            ],
            "scope": "required",
            "type": "framework",
            "version": sparkle["SPARKLE_VERSION"],
        }
    )
    components.append(
        {
            "bom-ref": xcodegen_ref,
            "externalReferences": [
                {"type": "distribution", "url": xcodegen["XCODEGEN_ARCHIVE_URL"]},
                {
                    "type": "license",
                    "url": f"{XCODEGEN_SOURCE}/blob/{xcodegen['XCODEGEN_VERSION']}/LICENSE",
                },
                {"type": "vcs", "url": XCODEGEN_SOURCE},
            ],
            "licenses": [{"license": {"id": XCODEGEN_LICENSE}}],
            "name": "XcodeGen",
            "purl": f"pkg:github/yonaskolb/XcodeGen@{xcodegen['XCODEGEN_VERSION']}",
            "properties": [
                {"name": "perry:archive-sha256", "value": xcodegen["XCODEGEN_ARCHIVE_SHA256"]},
                {"name": "perry:binary-sha256", "value": xcodegen["XCODEGEN_BINARY_SHA256"]},
            ],
            "scope": "required",
            "type": "application",
            "version": xcodegen["XCODEGEN_VERSION"],
        }
    )
    dependencies = [
        {
            "ref": "application:perry",
            "dependsOn": sorted((*roots, runtime_ref, cua_driver_ref, agent_desktop_ref, sparkle_ref, xcodegen_ref)),
        }
    ]
    dependencies.extend(
        {"dependsOn": sorted(dependencies_for), "ref": ref}
        for ref, dependencies_for in sorted(edges.items())
    )
    return {
        "bomFormat": "CycloneDX",
        "components": sorted(components, key=lambda item: item["bom-ref"]),
        "dependencies": dependencies,
        "metadata": {
            "component": {
                "bom-ref": "application:perry",
                "name": "Perry",
                "type": "application",
                "version": "working-tree",
            },
            "properties": [
                {"name": "perry:runtime-lock", "value": "scripts/codex-runtime.lock"},
                {"name": "perry:cua-driver-lock", "value": "scripts/cua-driver.lock"},
                {"name": "perry:agent-desktop-lock", "value": "scripts/agent-desktop.lock"},
                {"name": "perry:sparkle-lock", "value": "scripts/sparkle.lock"},
                {"name": "perry:xcodegen-lock", "value": "scripts/xcodegen.lock"},
                {"name": "perry:swift-graph", "value": "swift package show-dependencies --format json"},
            ],
        },
        "specVersion": "1.5",
        "version": 1,
    }


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(value, indent=2, sort_keys=True) + "\n"
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--lock-file", type=Path, required=True)
    parser.add_argument("--cua-driver-lock", type=Path, required=True)
    parser.add_argument("--agent-desktop-lock", type=Path, required=True)
    parser.add_argument("--sparkle-lock", type=Path, required=True)
    parser.add_argument("--xcodegen-lock", type=Path, required=True)
    parser.add_argument("--sbom-path", type=Path, required=True)
    parser.add_argument("--licenses-path", type=Path, required=True)
    parser.add_argument("--graph", type=Path, action="append", required=True)
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    runtime = load_runtime_lock(args.lock_file)
    cua_driver = load_cua_driver_lock(args.cua_driver_lock)
    agent_desktop = load_agent_desktop_lock(args.agent_desktop_lock)
    sparkle = load_sparkle_lock(args.sparkle_lock)
    xcodegen = load_xcodegen_lock(args.xcodegen_lock)
    nodes, edges, roots = collect_graph(args.graph, repo_root)
    licenses, unresolved = third_party_components(nodes, runtime, cua_driver, agent_desktop, sparkle, xcodegen)
    if unresolved:
        fail(f"third-party packages need license metadata: {', '.join(unresolved)}")
    write_json(args.sbom_path, build_sbom(nodes, edges, roots, runtime, cua_driver, agent_desktop, sparkle, xcodegen))
    write_json(
        args.licenses_path,
        {
            "components": licenses,
            "schema_version": 1,
            "source": {
                "runtime_lock": "scripts/codex-runtime.lock",
                "cua_driver_lock": "scripts/cua-driver.lock",
                "agent_desktop_lock": "scripts/agent-desktop.lock",
                "sparkle_lock": "scripts/sparkle.lock",
                "xcodegen_lock": "scripts/xcodegen.lock",
                "swift_package_graph": sorted(nodes[ref]["location"] for ref in roots),
            },
        },
    )
    print(f"release metadata generated: {args.sbom_path}, {args.licenses_path}")


if __name__ == "__main__":
    main()
