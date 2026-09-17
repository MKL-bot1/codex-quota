#!/usr/bin/env python3
"""Offline, bounded release hygiene checks. Does not print matched sensitive values."""
import argparse
import pathlib
import re
import zipfile

PUBLIC_FILES = {
    '.gitignore', 'README.md', 'SECURITY.md', 'SHARE.md', 'LICENSE', 'build.sh',
    'Sources/main.swift', 'assets/AppIcon.icns', 'assets/AppIcon.png',
    'assets/BrandMark.png', 'assets/StatusIcon.png', 'assets/StatusIcon@2x.png',
    'scripts/render-icons.swift', 'scripts/check-release.py', 'scripts/package.py',
}
APP_FILES = {
    'Contents/Info.plist', 'Contents/MacOS/CodexQuota',
    'Contents/Resources/AppIcon.icns', 'Contents/Resources/BrandMark.png',
    'Contents/Resources/StatusIcon.png', 'Contents/Resources/StatusIcon@2x.png',
    'Contents/Resources/LICENSE', 'Contents/_CodeSignature/CodeResources',
}
PATTERNS = {
    'personal-home-path': re.compile(rb'/' + rb'Users/' + rb'[A-Za-z0-9_.-]+/'),
    'API-key-shape': re.compile(rb'sk' + rb'-(?:proj-)?[A-Za-z0-9_-]{24,}'),
    'GitHub-token-shape': re.compile(rb'gh' + rb'[pousr]_[A-Za-z0-9]{30,}'),
    'JWT-shape': re.compile(rb'eyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}'),
    'account-UUID-shape': re.compile(rb'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'),
    'email-shape': re.compile(rb'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'),
}

def check_bytes(label, data):
    for kind, pattern in PATTERNS.items():
        for match in pattern.finditer(data):
            if kind == 'email-shape' and match.group() == b'StatusIcon@2x.png':
                continue  # Retina asset filename, not an email address.
            raise SystemExit(f'FAIL: {kind} in {label} (value withheld)')

def check_tree(root, allowed, ignore=()):
    found = set()
    for path in root.rglob('*'):
        relative = path.relative_to(root)
        if relative.parts[0] in ignore:
            continue
        if path.is_symlink():
            raise SystemExit(f'FAIL: unexpected symlink {relative}')
        if not path.is_file():
            continue
        name = relative.as_posix()
        if name not in allowed:
            raise SystemExit(f'FAIL: file not in public allowlist: {name}')
        found.add(name)
        check_bytes(name, path.read_bytes())
    missing = allowed - found
    if missing:
        raise SystemExit(f'FAIL: missing files: {sorted(missing)}')
    return len(found)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=pathlib.Path)
    parser.add_argument('--app', type=pathlib.Path)
    parser.add_argument('--zip', type=pathlib.Path)
    args = parser.parse_args()
    count = check_tree(args.source, PUBLIC_FILES, ignore=('.git', 'dist'))
    print(f'PASS: {count} explicitly allowed public source/assets; no sensitive pattern matches')
    if args.app:
        count = check_tree(args.app, APP_FILES)
        print(f'PASS: {count} explicitly allowed app files; no sensitive pattern matches')
    if args.zip:
        expected = {'Codex Quota.app/' + item for item in APP_FILES}
        with zipfile.ZipFile(args.zip) as archive:
            entries = archive.infolist()
            names = [item.filename for item in entries]
            if len(names) != len(set(names)) or set(names) != expected:
                raise SystemExit('FAIL: archive contains unexpected, duplicate or missing paths')
            if archive.testzip() is not None:
                raise SystemExit('FAIL: corrupt archive')
            for item in entries:
                check_bytes(item.filename, archive.read(item))
        print('PASS: archive allowlist, CRC and sensitive-pattern checks')
    print('These bounded checks do not prove absence of every possible secret or vulnerability.')

if __name__ == '__main__':
    main()
