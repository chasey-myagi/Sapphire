#!/usr/bin/env python3
"""Compile production policy and weather card for focused macOS layout checks."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sources = [
    ROOT / "Sapphire/Notch/WidgetLayoutPolicy.swift",
    ROOT / "Sapphire/Widgets/Weather/WeatherWidgetView.swift",
    ROOT / "script/fixtures/widget-layout-probe.swift",
]
with tempfile.TemporaryDirectory(prefix="sapphire-widget-layout-") as directory:
    probe = Path(directory) / "probe.swift"
    probe.write_text("\n".join(source.read_text() for source in sources))
    binary = Path(directory) / "probe"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(probe), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)])
    raise SystemExit(result.returncode)
