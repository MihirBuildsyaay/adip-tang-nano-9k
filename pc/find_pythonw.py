"""Prints the path of pythonw.exe next to the running python.exe (used by install_autostart.bat)."""
import os, sys
print(os.path.join(os.path.dirname(sys.executable), "pythonw.exe"))
