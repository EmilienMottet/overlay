#!/usr/bin/env python3
"""Minimal ASAR archive extractor (read-only, zero dependencies).

Unpacks an Electron ``app.asar`` (plus its sibling ``app.asar.unpacked``)
so the tree can be patched and shipped on Linux without the upstream
``@electron/asar`` Node tool, which is not packaged in Gentoo.

Usage:
    asar.py extract <archive.asar> <dest-dir>
"""
import json
import os
import shutil
import struct
import sys


def read_header(fp):
    # Electron asar uses Chromium's Pickle framing:
    #   uint32  size-pickle payload length (always 4)
    #   uint32  header-buffer length        -> data region starts at 8 + this
    #   uint32  header-pickle payload length
    #   uint32  JSON string length
    #   <JSON header bytes>
    head = fp.read(16)
    if len(head) < 16:
        raise ValueError("not an asar archive (truncated header)")
    header_buf_len = struct.unpack("<I", head[4:8])[0]
    json_len = struct.unpack("<I", head[12:16])[0]
    json_bytes = fp.read(json_len)
    if len(json_bytes) < json_len:
        raise ValueError("not an asar archive (truncated JSON header)")
    data_start = 8 + header_buf_len
    return json.loads(json_bytes.decode("utf-8")), data_start


def _safe_join(dest, rel):
    out = os.path.normpath(os.path.join(dest, rel))
    if out != dest and not out.startswith(dest + os.sep):
        raise ValueError("path traversal blocked: %s" % rel)
    return out


def extract_node(node, rel, fp, data_start, dest, unpacked_dir):
    if "files" in node:
        target = _safe_join(dest, rel) if rel else dest
        os.makedirs(target, exist_ok=True)
        for name, child in node["files"].items():
            extract_node(child, os.path.join(rel, name), fp, data_start,
                         dest, unpacked_dir)
        return

    out = _safe_join(dest, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)

    if "link" in node:
        if os.path.lexists(out):
            os.remove(out)
        os.symlink(node["link"], out)
        return

    if node.get("unpacked"):
        shutil.copyfile(os.path.join(unpacked_dir, rel), out)
    else:
        offset = int(node["offset"])
        size = int(node["size"])
        fp.seek(data_start + offset)
        remaining = size
        with open(out, "wb") as o:
            while remaining > 0:
                chunk = fp.read(min(1 << 20, remaining))
                if not chunk:
                    raise ValueError("unexpected EOF while reading %s" % rel)
                o.write(chunk)
                remaining -= len(chunk)

    if node.get("executable"):
        os.chmod(out, 0o755)


def extract(archive, dest):
    unpacked_dir = archive + ".unpacked"
    dest = os.path.abspath(dest)
    with open(archive, "rb") as fp:
        header, data_start = read_header(fp)
        os.makedirs(dest, exist_ok=True)
        extract_node(header, "", fp, data_start, dest, unpacked_dir)


def main(argv):
    if len(argv) != 4 or argv[1] != "extract":
        sys.stderr.write(__doc__ or "")
        return 2
    extract(argv[2], argv[3])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
