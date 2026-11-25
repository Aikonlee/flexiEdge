#!/usr/bin/env python3
"""Adapt the official Focal Edge UI token generator to PyJWT 2."""
import argparse
from pathlib import Path

OLD = '        algorithm="HS256",\n    ).decode()\n    return access_token\n'
NEW = '        algorithm="HS256",\n    )\n    return access_token.decode("utf-8") if isinstance(access_token, bytes) else access_token\n'

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('access_py', type=Path)
args = parser.parse_args()
source = args.access_py.read_text(encoding='utf-8')
if source.count(NEW) == 1 and OLD not in source:
    raise SystemExit(0)
if source.count(OLD) != 1 or NEW in source:
    parser.error('Unexpected Edge UI access.py; refusing to modify it')
updated = source.replace(OLD, NEW, 1)
compile(updated, str(args.access_py), 'exec')
args.access_py.write_text(updated, encoding='utf-8')
