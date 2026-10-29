#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
TEXT_FILE_SUFFIXES = {".md", ".txt", ".py", ".sh", ".service", ".path", ".rules", ".conf", ".yml", ".yaml"}
PATH_REF_RE = re.compile(r"(?<![A-Za-z0-9_./-])(?P<path>(?:scripts|config|docs|patches)/[^\s`'\")*{]+)")
EXECSTART_RE = re.compile(r"^Exec(?:Start|Stop)=([^\s]+)", re.MULTILINE)


def fail(message: str) -> None:
    print(f"[FAIL] {message}")


def ok(message: str) -> None:
    print(f"[OK] {message}")


def iter_text_files() -> list[Path]:
    files: list[Path] = []
    for path in REPO_ROOT.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix.lower() in TEXT_FILE_SUFFIXES:
            files.append(path)
    return sorted(files)


def check_required_files() -> list[str]:
    required = [
        REPO_ROOT / "README.md",
        REPO_ROOT / "docs" / "install.md",
        REPO_ROOT / "docs" / "audio-driver-notes.md",
        REPO_ROOT / "docs" / "validation.md",
        REPO_ROOT / "scripts" / "validate-repo.py",
        REPO_ROOT / "scripts" / "setup-linux.sh",
        REPO_ROOT / "scripts" / "install-ddj1000-linux-stack.sh",
        REPO_ROOT / "scripts" / "install-ddj1000-host-stack.sh",
        REPO_ROOT / "scripts" / "install-ddj1000-audio-driver.sh",
        REPO_ROOT / "scripts" / "runtime" / "ddj1000-host-stack-service.sh",
        REPO_ROOT / "scripts" / "runtime" / "ddj1000-unlock-service.py",
        REPO_ROOT / "scripts" / "runtime" / "ddj1000-audio-rebind.sh",
        REPO_ROOT / "scripts" / "runtime" / "ddj1000-startup-prep.sh",
        REPO_ROOT / "scripts" / "runtime" / "ddj1000-usb-probe.py",
        REPO_ROOT / "scripts" / "runtime" / "ddj1000-audio-stream.py",
        REPO_ROOT / "patches" / "linux" / "snd-usb-audio-ddj1000-6.12.patch",
        REPO_ROOT / "dkms" / "dkms.conf",
        REPO_ROOT / "dkms" / "Makefile",
        REPO_ROOT / "dkms" / "prepare-sources.sh",
        REPO_ROOT / ".github" / "workflows" / "static-checks.yml",
    ]
    failures: list[str] = []
    for path in required:
        if not path.exists():
            failures.append(f"missing required file: {path.relative_to(REPO_ROOT)}")
    return failures


def check_repo_local_references() -> list[str]:
    failures: list[str] = []
    for file_path in iter_text_files():
        text = file_path.read_text(encoding="utf-8")
        for match in PATH_REF_RE.finditer(text):
            ref = match.group("path")
            if "*" in ref or "{" in ref:
                continue
            target = REPO_ROOT / Path(ref)
            if not target.exists():
                failures.append(
                    f"broken repo reference in {file_path.relative_to(REPO_ROOT)}: {ref}"
                )
    return failures


def check_systemd_exec_targets() -> list[str]:
    failures: list[str] = []
    systemd_root = REPO_ROOT / "config" / "systemd"
    for unit_file in systemd_root.rglob("*"):
        if unit_file.suffix not in {".service", ".path"}:
            continue
        text = unit_file.read_text(encoding="utf-8")
        for command in EXECSTART_RE.findall(text):
            command_name = Path(command).name
            target = REPO_ROOT / "scripts" / command_name
            runtime_target = REPO_ROOT / "scripts" / "runtime" / command_name
            fallback_names = {command_name.removeprefix("ddj1000-")}
            fallback_targets = [REPO_ROOT / "scripts" / name for name in fallback_names if name != command_name]
            runtime_fallback_targets = [REPO_ROOT / "scripts" / "runtime" / name for name in fallback_names if name != command_name]
            if command.startswith("/usr/local/bin/") and not target.exists() and not runtime_target.exists() and not any(path.exists() for path in fallback_targets + runtime_fallback_targets):
                failures.append(
                    f"systemd target missing for {unit_file.relative_to(REPO_ROOT)}: scripts/{command_name}"
                )
    return failures


def check_python_shebangs() -> list[str]:
    failures: list[str] = []
    for script in (REPO_ROOT / "scripts").rglob("*.py"):
        first_line = script.read_text(encoding="utf-8").splitlines()[0]
        if first_line.strip() != "#!/usr/bin/env python3":
            failures.append(f"unexpected Python shebang in {script.relative_to(REPO_ROOT)}")
    return failures


def main() -> int:
    failures: list[str] = []
    failures.extend(check_required_files())
    failures.extend(check_repo_local_references())
    failures.extend(check_systemd_exec_targets())
    failures.extend(check_python_shebangs())

    if failures:
        for message in failures:
            fail(message)
        print(f"[FAIL] smoke check failed with {len(failures)} issue(s)")
        return 1

    ok("required files present")
    ok("repo-local references resolved")
    ok("systemd targets resolved")
    ok("python script shebangs consistent")
    ok("smoke check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())