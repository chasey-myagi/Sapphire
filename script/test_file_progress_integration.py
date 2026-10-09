#!/usr/bin/env python3
"""Exercise the real file-progress subscription on a disposable macOS CI host."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def main():
    if (os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"):
        sys.exit("This integration test starts native services; use a disposable GitHub-hosted macOS runner.")

    repo = Path(__file__).resolve().parent.parent
    temporary = Path(os.environ["RUNNER_TEMP"])
    results = temporary / "SapphireFileProgressResults"
    results.mkdir(parents=True, exist_ok=True)
    method = "testFileTaskChangesDriveActivityAndStopDetachesObserver"
    command = [
        "xcodebuild", "-project", str(repo / "Sapphire.xcodeproj"),
        "-scheme", "SapphireLocalizationTests", "-configuration", "Debug",
        "-xcconfig", str(repo / "config/LocalPublic.xcconfig"),
        "-derivedDataPath", str(temporary / "SapphireFileProgress"),
        "-clonedSourcePackagesDirPath", str(temporary / "SourcePackages"),
        "-onlyUsePackageVersionsFromResolvedFile",
        "-destination", "platform=macOS,arch=arm64",
        "-only-testing:SapphireLocalizationTests/FileProgressIntegrationTests/" + method,
        "-parallel-testing-enabled", "NO",
        "-test-timeouts-enabled", "YES",
        "-maximum-test-execution-time-allowance", "60",
        "CODE_SIGNING_ALLOWED=NO", "test",
    ]
    environment = os.environ.copy()
    # xcodebuild documents TEST_RUNNER_<VAR> forwarding to hosted tests.
    environment["TEST_RUNNER_SAPPHIRE_FILE_PROGRESS_INTEGRATION"] = "1"
    environment["TEST_RUNNER_GITHUB_ACTIONS"] = "true"
    source = repo / "Sapphire/LiveActivities/LiveActivityManager.swift"
    original = source.read_bytes()
    summary = {
        "sourceSHA256": hashlib.sha256(original).hexdigest(),
        "test": method,
        "green": False,
        "missingSubscriptionFails": False,
    }

    def run(name):
        log_path = results / (name + ".log")
        with log_path.open("w") as log:
            result = subprocess.run(
                command + ["-resultBundlePath", str(results / (name + ".xcresult"))],
                env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=1200,
            )
        return result.returncode, log_path.read_text(errors="replace")

    try:
        code, log = run("restored-subscription")
        if code != 0 or not re.search(r"Test Case .*" + method + r".* passed", log):
            raise RuntimeError("Real integration test did not pass; inspect restored-subscription.log")
        summary["green"] = True

        # Remove only the observer that was accidentally deleted during pruning.
        start_marker = b"        FileDropManager.shared.$tasks\n"
        end_marker = b"            .store(in: &cancellables)\n"
        if original.count(start_marker) != 1:
            raise RuntimeError("FileDrop subscription is not unique; inspect the mutation boundary")
        start = original.index(start_marker)
        end = original.index(end_marker, start) + len(end_marker)
        source.write_bytes(original[:start] + original[end:])
        code, log = run("missing-subscription")
        if (code == 0 or "FILE_PROGRESS_TASK_DID_NOT_APPEAR" not in log
                or not re.search(r"Test Case .*" + method + r".* failed", log)):
            raise RuntimeError("Missing observer was not caught by the expected runtime assertion")
        summary["missingSubscriptionFails"] = True
    finally:
        source.write_bytes(original)
        summary["sourceRestored"] = source.read_bytes() == original
        (results / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
