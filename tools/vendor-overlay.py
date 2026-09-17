#!/usr/bin/env python3
"""Pack the proprietary files pulled from the user's own device into an overlay tarball for a prebuilt root filesystem.

The published images contain no vendor files; install.sh builds this overlay on the host and android-install.sh
unpacks it over the system. The layout matches rootfs/assemble.sh and openwrt/build-rootfs.sh:
  firmware/            -> usr/lib/firmware (Ubuntu) or lib/firmware (OpenWrt)
  android-subset/      -> opt/mu300/android (dev/__properties__ becomes dev-properties)
  android-gpu-subset/  -> opt/mu300/android (files already taken from android-subset win)
"""
import argparse
import os
import tarfile
from pathlib import Path


def add_tree(tar, src: Path, dest: str, seen: set, rename=None):
    for root, dirs, files in os.walk(src, followlinks=False):
        dirs.sort()
        rel_root = Path(root).relative_to(src)
        entries = [(d, True) for d in dirs] + [(f, False) for f in sorted(files)]
        # symlinks to directories show up in dirs but must be stored as links
        for name, _ in entries:
            path = Path(root) / name
            rel = (rel_root / name).as_posix()
            if rename:
                rel = rename(rel)
                if rel is None:
                    continue
            arc = f'{dest}/{rel}'
            if arc in seen:
                continue
            seen.add(arc)
            info = tar.gettarinfo(str(path), arcname=arc)
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            if info.isfile():
                with open(path, 'rb') as f:
                    tar.addfile(info, f)
            else:
                tar.addfile(info)
        dirs[:] = [d for d in dirs if not (Path(root) / d).is_symlink()]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--os', required=True, choices=['ubuntu', 'openwrt'])
    ap.add_argument('--firmware', type=Path)
    ap.add_argument('--android-subset', type=Path, required=True)
    ap.add_argument('--gpu-subset', type=Path)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()

    def android(rel):
        if rel == 'dev':
            return None
        if rel == 'dev/__properties__':
            return 'dev-properties'
        return rel

    def gpu(rel):
        return None if rel == 'dev' or rel.startswith('dev/') else rel

    seen = set()
    with tarfile.open(a.out, 'w:gz', format=tarfile.GNU_FORMAT) as tar:
        if a.firmware and a.firmware.is_dir():
            add_tree(tar, a.firmware, 'usr/lib/firmware' if a.os == 'ubuntu' else 'lib/firmware', seen)
        add_tree(tar, a.android_subset, 'opt/mu300/android', seen, android)
        if a.gpu_subset and a.gpu_subset.is_dir():
            add_tree(tar, a.gpu_subset, 'opt/mu300/android', seen, gpu)
    print(f'{a.out}: {len(seen)} entries')


if __name__ == '__main__':
    main()
