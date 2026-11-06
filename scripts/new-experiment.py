#!/usr/bin/env python3
"""Create a self-contained SwiftUI experiment and register it in the workspace."""
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def main():
    if len(sys.argv) != 2 or not re.fullmatch(r"[A-Z][A-Za-z0-9]{1,39}", sys.argv[1]):
        raise SystemExit("Usage: python3 scripts/new-experiment.py PascalCaseName (2–40 characters)")
    name = sys.argv[1]
    root = Path(__file__).resolve().parent.parent
    experiments = root / "Experiments"
    if any(p.name.casefold() == name.casefold() for p in experiments.iterdir()):
        raise SystemExit(f"Experiment already exists: {name}")
    workspace = root / "SwiftUI-Interactions.xcworkspace/contents.xcworkspacedata"
    tree = ET.parse(workspace)
    destination = experiments / name
    shutil.copytree(root / "Templates/Starter", destination)
    # Rename children before parents so every path remains reachable.
    for path in sorted(destination.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if path.is_file():
            text = path.read_text().replace("Starter", name)
            text = text.replace("swiftuiinteractions.starter", "swiftuiinteractions." + name.lower())
            path.write_text(text)
        if "Starter" in path.name:
            path.rename(path.with_name(path.name.replace("Starter", name)))
    readme = (root / "Templates/README.md").read_text().replace("# Experiment name", "# " + name, 1)
    (destination / "README.md").write_text(readme)
    ET.SubElement(tree.getroot(), "FileRef", {"location": f"group:Experiments/{name}/{name}.xcodeproj"})
    ET.indent(tree, space="  ")
    temporary = workspace.with_suffix(".tmp")
    tree.write(temporary, encoding="UTF-8", xml_declaration=True)
    temporary.replace(workspace)
    print(f"Created Experiments/{name}; open the workspace and choose the {name} scheme.")
    print("Next: finish its README, add a preview, and add an entry to the root gallery.")


if __name__ == "__main__":
    main()
