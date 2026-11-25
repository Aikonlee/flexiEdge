"""Select the supported system-checker backend on Debian."""
import sys
from pathlib import Path

path = Path(sys.argv[1])
old = '    module_name = distro.name().lower()\n    module = importlib.import_module(module_name)'
new = '    module_name = "ubuntu" if distro.id() == "debian" else distro.name().lower()\n    module = importlib.import_module(module_name)'
source = path.read_text(encoding='utf-8')
if source.count(new) == 1 and old not in source:
    sys.exit(0)
if source.count(old) != 1 or new in source:
    sys.exit('Unexpected checker selector; no changes applied')
updated = source.replace(old, new, 1)
compile(updated, str(path), 'exec')
path.write_text(updated, encoding='utf-8')
