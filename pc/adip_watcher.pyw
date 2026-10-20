"""adip_watcher.pyw - invisible helper: opens the ADiP app when the board is plugged in.

Started automatically at Windows login by install_autostart.bat (runs with
pythonw.exe, so there is no console window). Every 1.5 s it lists the COM
ports; when a port with the board's USB ID appears it starts adip_gui.py
(or, if the app is already open, brings it to the front).
Stop it with uninstall_autostart.bat.
"""
import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import adip_core as core  # noqa: E402

try:
    import serial.tools.list_ports as list_ports
except ImportError:          # pyserial missing: nothing we can do silently
    sys.exit(1)

PID_FILE = os.path.join(HERE, ".watcher.pid")
GUI = os.path.join(HERE, "adip_gui.py")


def single_instance():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", core.WATCHER_SOCKET_PORT))
        s.listen(1)
        return s
    except OSError:
        return None


def open_gui():
    try:   # app already open -> bring it to the front (it then auto-connects)
        with socket.create_connection(("127.0.0.1", core.GUI_SOCKET_PORT), timeout=0.5) as c:
            c.sendall(b"show")
        return
    except OSError:
        pass
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    subprocess.Popen([sys.executable, GUI, "--auto"], cwd=HERE, creationflags=flags)


def main():
    lock = single_instance()
    if lock is None:
        return                      # another watcher is already running
    try:
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    was_present = False
    while True:
        try:
            present = bool(core.candidate_ports(list_ports.comports()))
        except Exception:
            present = False
        if present and not was_present:
            time.sleep(1.0)         # give Windows a moment to finish installing the port
            open_gui()
        was_present = present
        time.sleep(1.5)


if __name__ == "__main__":
    main()
