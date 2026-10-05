#!/usr/bin/env python3
"""Render split-infra-docker templates into INFRA_ROOT using site.env."""
from __future__ import annotations

import argparse
import os
import shutil
import stat
import subprocess
from pathlib import Path


def load_env(path: Path) -> dict[str, str]:
    vals: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        vals[k.strip()] = v.strip().strip("'\"")
    return vals


def mount_unit(data_mount: str) -> str:
    r = subprocess.run(
        ["systemd-escape", "-p", "--suffix=mount", data_mount],
        check=True,
        capture_output=True,
        text=True,
    )
    return r.stdout.strip()


def subst(text: str, mapping: dict[str, str]) -> str:
    for k, v in mapping.items():
        text = text.replace(f"__{k}__", v)
    return text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--site", required=True, help="path to site.env")
    parser.add_argument(
        "--skill-root",
        default=str(Path(__file__).resolve().parent.parent),
    )
    args = parser.parse_args()

    site = Path(args.site).resolve()
    cfg = load_env(site)
    required = ["INFRA_ROOT", "DATA_MOUNT", "ADMIN_USER", "ADMIN_GROUP"]
    missing = [k for k in required if not cfg.get(k)]
    if missing:
        raise SystemExit(f"site.env missing: {', '.join(missing)}")

    infra = Path(cfg["INFRA_ROOT"])
    boot = infra / "bootstrap"
    boot.mkdir(parents=True, exist_ok=True)

    mapping = {
        "INFRA_ROOT": cfg["INFRA_ROOT"].rstrip("/"),
        "DATA_MOUNT": cfg["DATA_MOUNT"].rstrip("/"),
        "ADMIN_USER": cfg["ADMIN_USER"],
        "ADMIN_GROUP": cfg["ADMIN_GROUP"],
        "MOUNT_UNIT": cfg.get("MOUNT_UNIT") or mount_unit(cfg["DATA_MOUNT"]),
    }

    skill = Path(args.skill_root)
    tdir = skill / "templates"
    if not tdir.is_dir():
        raise SystemExit(f"templates not found: {tdir}")

    boot.mkdir(parents=True, exist_ok=True)
    for src in tdir.iterdir():
        if not src.is_file():
            continue
        dest = boot / src.name
        dest.write_text(subst(src.read_text(), mapping))
        mode = os.stat(src).st_mode
        dest.chmod(mode & 0o777)

    if site.resolve() != (boot / "site.env").resolve():
        shutil.copy2(site, boot / "site.env")

    for path in [
        boot / "install.sh",
        boot / "backup.sh",
        boot / "docker-infra-post.sh",
        boot / "docker-infra-bridge.sh",
        boot / "docker-infra.wrapper",
        boot / "render.py",
    ]:
        if path.exists():
            path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    src_render = Path(__file__).resolve()
    dest_render = (boot / "render.py").resolve()
    if src_render != dest_render:
        shutil.copy2(src_render, dest_render)

    print(f"rendered -> {boot}")
    print(f"MOUNT_UNIT={mapping['MOUNT_UNIT']}")


if __name__ == "__main__":
    main()
