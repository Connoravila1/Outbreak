"""Build every sound into client/public/audio. Usage: OUTBREAK_SOUND_RAW=<raw dir> python build.py [prefix]"""
import sys

import lib
import sfx  # noqa: F401  (registers recipes)
try:
    import beds  # noqa: F401
except ImportError:
    pass

if __name__ == "__main__":
    only = sys.argv[1] if len(sys.argv) > 1 else None
    lib.write_manifest(lib.build_all(only))
