#!/usr/bin/env python3
"""Package only explicitly allowed app files. Run build.sh first."""
from pathlib import Path
import hashlib
import subprocess
import sys
import zipfile
from importlib.util import spec_from_file_location, module_from_spec

root = Path(__file__).resolve().parents[1]
spec = spec_from_file_location('release_checks', root / 'scripts/check-release.py')
checks = module_from_spec(spec)
spec.loader.exec_module(checks)
app = root / 'dist/Codex Quota.app'
checks.check_tree(root, checks.PUBLIC_FILES, ignore=('.git', 'dist'))
checks.check_tree(app, checks.APP_FILES)
archive_path = root / 'dist/Codex-Quota-v1.1.0-macOS-universal.zip'
with zipfile.ZipFile(archive_path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for relative in sorted(checks.APP_FILES):
        source = app / relative
        info = zipfile.ZipInfo('Codex Quota.app/' + relative, date_time=(2026, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = (0o100755 if relative == 'Contents/MacOS/CodexQuota' else 0o100644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, source.read_bytes())
digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
(root / 'dist/SHA256SUMS.txt').write_text(f'{digest}  {archive_path.name}\n')
subprocess.run([sys.executable, str(root / 'scripts/check-release.py'), str(root), '--app', str(app), '--zip', str(archive_path)], check=True)
print(f'Packaged: {archive_path.name}')
