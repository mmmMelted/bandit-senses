"""Pack the mod into BanditSenses.vmz (zip with mod.txt at the root) for Metro Mod Loader.

    python build.py
"""
import pathlib
import zipfile

ROOT = pathlib.Path(__file__).parent
OUT = ROOT / "BanditSenses.vmz"

with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    z.write(ROOT / "mod.txt", "mod.txt")
    for f in sorted((ROOT / "BanditSenses").rglob("*")):
        if f.is_file():
            z.write(f, f.relative_to(ROOT).as_posix())
print(f"built {OUT} ({OUT.stat().st_size} bytes)")
