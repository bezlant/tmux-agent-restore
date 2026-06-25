#!/usr/bin/env python3
"""Find a Claude session whose first custom-title matches a target."""

import json
import os
import re
import sys


def jsonl_files_newest_first(project_dir):
    files = []
    try:
        names = os.listdir(project_dir)
    except OSError:
        return None

    for name in names:
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(project_dir, name)
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        files.append((mtime, path, name))

    files.sort(reverse=True)
    return files


def is_safe_session_id(session_id):
    return bool(session_id) and not session_id.startswith("-") and bool(
        re.fullmatch(r"[A-Za-z0-9_.:-]+", session_id)
    )


def find_session(project_dir, target):
    if not os.path.isdir(project_dir):
        return None

    files = jsonl_files_newest_first(project_dir)
    if files is None:
        return None

    for _, path, name in files:
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except (json.JSONDecodeError, ValueError):
                        continue
                    if obj.get("type") == "custom-title":
                        if obj.get("customTitle") == target:
                            session_id = name[:-6]
                            if is_safe_session_id(session_id):
                                return session_id
                        break
        except OSError:
            continue

    return None


def main():
    if len(sys.argv) != 3:
        return 2

    session_id = find_session(sys.argv[1], sys.argv[2])
    if not session_id:
        return 1

    print(session_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
