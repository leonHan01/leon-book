#!/usr/bin/env python3
"""Content-based build inputs and the deliberately narrow editor-resource fast path."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

STATE_NAME = "leonbook-build-inputs.json"
EDITOR_DIR = "Sources/LeonBook/Resources"


def editor_asset(name):
    path = Path(name)
    return str(path.parent) == EDITOR_DIR and (
        (path.name.startswith("RichArticle") and path.suffix in (".js", ".css"))
        or path.name == "RichArticleEditor.html"
    )


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def capture(macos):
    inputs = [macos / name for name in (
        "Package.swift", "Package.resolved", "scripts/build-app.sh",
        "scripts/swift-sdk.sh", "scripts/swift-cache.sh", "scripts/build-state.py",
    )]
    for folder in ("Sources", "Resources"):
        inputs.extend(sorted((macos / folder).rglob("*")))
    state = {"version": 1, "native": {}, "editor": {}}
    for path in inputs:
        if path.is_file():
            name = str(path.relative_to(macos))
            group = "editor" if editor_asset(name) and not path.is_symlink() else "native"
            state[group][name] = digest(path)
    # Changing SDK selection must not reuse a binary built for another SDK.
    state["native"]["@sdk"] = os.environ.get("LEON_BOOK_SDK_PATH", "")
    state["native"]["@developer"] = os.environ.get("DEVELOPER_DIR", "")
    return state


def read_state(path):
    state = json.loads(path.read_text())
    if (state.get("version") != 1 or not isinstance(state.get("native"), dict)
            or not isinstance(state.get("editor"), dict)
            or not all(editor_asset(name) for name in state["editor"])):
        raise ValueError("Unsupported build input manifest")
    return state


def status(app, configuration, system, current):
    resources = app / "Contents/Resources"
    bundle = resources / "LeonBookMac_LeonBook.bundle"
    try:
        for executable in ("LeonBook", "LeonBookCLI"):
            path = app / "Contents/MacOS" / executable
            if not path.is_file() or not os.access(path, os.X_OK):
                return "build"
        if not bundle.is_dir():
            return "build"
        if (resources / "leonbook-build-configuration").read_text().strip() != configuration:
            return "build"
        if (resources / "leonbook-build-system").read_text().strip() != system:
            return "build"
        previous = read_state(resources / STATE_NAME)
        if previous["native"] != current["native"]:
            return "build"
        if previous["editor"] != current["editor"]:
            return "resources"
        for name, expected in current["editor"].items():
            if digest(bundle / Path(name).name) != expected:
                return "resources"
        return "unchanged"
    except (OSError, ValueError, TypeError, AttributeError):
        # Legacy/incomplete apps get one full build to establish a trusted baseline.
        return "build"


def sync_editor(macos, app, snapshot):
    bundle = app / "Contents/Resources/LeonBookMac_LeonBook.bundle"
    wanted = {Path(name).name for name in snapshot["editor"]}
    for path in bundle.iterdir():
        if editor_asset(EDITOR_DIR + "/" + path.name) and path.name not in wanted:
            path.unlink()
    for name in snapshot["editor"]:
        destination = bundle / Path(name).name
        # Never follow a link out of a copied bundle when refreshing a resource.
        if destination.is_symlink():
            destination.unlink()
        shutil.copy2(macos / name, destination)


def main():
    command, macos_name, *args = sys.argv[1:]
    macos = Path(macos_name)
    if command == "capture":
        Path(args[0]).write_text(json.dumps(capture(macos), sort_keys=True) + "\n")
    elif command == "status":
        app, configuration, system, *snapshot = args
        current = read_state(Path(snapshot[0])) if snapshot else capture(macos)
        print(status(Path(app), configuration, system, current))
    elif command == "sync-editor":
        app, snapshot = args
        sync_editor(macos, Path(app), read_state(Path(snapshot)))
    else:
        raise ValueError("Unknown build-state command: " + command)


if __name__ == "__main__":
    main()
