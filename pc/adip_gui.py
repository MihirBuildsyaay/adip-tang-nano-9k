"""adip_gui.py - laptop app for the ADiP Tang Nano 9K accelerator.

  * choose the COM port of the board (the Tang Nano's USB-UART, 115200)
  * pick the precision mode (8b x 8b, 8b x 4b, 8b x 2b), unsigned or signed INT8
  * type matrix A and matrix B
  * "Run on FPGA" sends everything over UART, the FPGA computes C = A x B
    and the answer is shown in a separate "Result" window, checked against a
    calculation done on the PC, together with latency and throughput.
  * Matrix size 8 x 8 / 16 x 16 switches to TILING: the 4 x 4 array computes the
    big product block by block (one FPGA run per block), the PC adds the blocks.
  * "Animate" replays the calculation cycle by cycle (LOAD / COMPUTE / STORE) exactly as
    the Verilog does it, down to the 2-bit chunk multipliers inside a PE.
  * "Demo mode" works without the board (to try the app first).
  * finds and connects to the board by itself; started by adip_watcher.pyw it
    opens automatically when the board is plugged in.

Needs:  pip install pyserial        (tkinter comes with python.org Python)
Run:    python pc/adip_gui.py       or double-click run_gui.bat
"""

import os
import queue
import random
import socket
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk, messagebox, filedialog

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adip_core as core  # noqa: E402
import adip_anim  # noqa: E402

try:
    import serial
    import serial.tools.list_ports
    HAVE_SERIAL = True
except ImportError:
    HAVE_SERIAL = False

BAUD = 115200
REPLY_TIMEOUT_S = 3.0

OK_BG, BAD_BG, NORMAL_BG = "#e6f4ea", "#fde2e1", "white"
TILE_BG, OK_TILE_BG = "#e8effa", "#cfe8d6"     # shading of every other 4 x 4 block


class AdipApp:
    def __init__(self, root):
        self.root = root
        self.ser = None
        self.busy = False
        self.q = queue.Queue()
        self.result_win = None
        self.port_vidpid = (None, None)
        self.auto_running = False

        root.title("ADiP Matrix Accelerator - Tang Nano 9K")
        root.minsize(720, 560)
        self.mode = tk.IntVar(value=0)
        self.signed = tk.BooleanVar(value=False)
        self.demo = tk.BooleanVar(value=not HAVE_SERIAL)
        self.size = tk.IntVar(value=core.N)

        self._build_connection_bar()
        self._build_mode_bar()
        self._build_size_bar()
        self.mat_frame = ttk.Frame(root, padding=(10, 4))
        self.mat_frame.pack(fill="x")
        self._build_buttons()
        self._build_log()

        self.a_entries, self.b_entries = [], []
        self._build_matrices(fill="default")
        self.refresh_ports()
        self.root.after(100, self._poll_queue)
        if HAVE_SERIAL:
            self.root.after(400, self.auto_connect)
        if not HAVE_SERIAL:
            self.log("pyserial is not installed -> only Demo mode is available.\n"
                     "Install it with:  pip install pyserial")

    # ------------------------------------------------------------------ layout
    def _build_connection_bar(self):
        bar = ttk.Frame(self.root, padding=(10, 8, 10, 2))
        bar.pack(fill="x")
        ttk.Label(bar, text="Board port:").pack(side="left")
        self.port_cb = ttk.Combobox(bar, width=38, state="readonly")
        self.port_cb.pack(side="left", padx=4)
        ttk.Button(bar, text="Refresh", command=self.refresh_ports).pack(side="left")
        ttk.Button(bar, text="Find board", command=self.auto_connect).pack(side="left", padx=(4, 0))
        self.conn_btn = ttk.Button(bar, text="Connect", command=self.toggle_connect)
        self.conn_btn.pack(side="left", padx=4)
        ttk.Checkbutton(bar, text="Demo mode (no board)", variable=self.demo).pack(side="left", padx=8)
        self.status = ttk.Label(bar, text="Not connected", foreground="gray")
        self.status.pack(side="right")

    def _build_mode_bar(self):
        bar = ttk.Frame(self.root, padding=(10, 4))
        bar.pack(fill="x")
        ttk.Label(bar, text="Precision mode:").pack(side="left")
        for m in (0, 1, 2):
            ttk.Radiobutton(bar, text=core.MODE_NAMES[m], value=m, variable=self.mode,
                            command=self.on_mode_change).pack(side="left", padx=6)
        ttk.Checkbutton(bar, text="Signed (INT8)", variable=self.signed,
                        command=self.on_mode_change).pack(side="left", padx=(12, 0))
        self.mode_hint = ttk.Label(bar, foreground="gray")
        self.mode_hint.pack(side="left", padx=10)

    def _build_size_bar(self):
        self.size_bar = bar = ttk.Frame(self.root, padding=(10, 2))
        bar.pack(fill="x")
        ttk.Label(bar, text="Matrix size:").pack(side="left")
        ttk.Radiobutton(bar, text="4 x 4  (direct)", value=core.N, variable=self.size,
                        command=self.on_mode_change).pack(side="left", padx=6)
        for s in core.TILE_SIZES:
            ttk.Radiobutton(bar, text="%d x %d  (tiling)" % (s, s), value=s, variable=self.size,
                            command=self.on_mode_change).pack(side="left", padx=6)
        # shown only for tiled sizes (packed in _build_tiled_matrices)
        self.tile_banner = tk.Label(self.root, anchor="w", justify="left", padx=8, pady=4,
                                    bg="#fff4e0", fg="#8a4b00", font=("Segoe UI", 9))

    def _build_buttons(self):
        bar = ttk.Frame(self.root, padding=(10, 6))
        bar.pack(fill="x")
        ttk.Button(bar, text="Demo values", command=lambda: self._build_matrices("default")).pack(side="left")
        ttk.Button(bar, text="Random", command=lambda: self._build_matrices("random")).pack(side="left", padx=4)
        ttk.Button(bar, text="Clear", command=lambda: self._build_matrices("zero")).pack(side="left")
        self.run_btn = ttk.Button(bar, text="Run on FPGA  ▶", command=self.run)
        self.run_btn.pack(side="right")
        ttk.Button(bar, text="Animate: how it is calculated", command=self.animate_inputs
                   ).pack(side="right", padx=(0, 6))
        self.pbar = ttk.Progressbar(bar, length=160, mode="determinate")
        self.progress_lbl = ttk.Label(bar, foreground="#1a5fb4")
        self.progress_lbl.pack(side="right", padx=8)

    def _build_log(self):
        frm = ttk.LabelFrame(self.root, text="UART log (raw text from the board)", padding=4)
        frm.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        self.log_txt = tk.Text(frm, height=8, font=("Consolas", 9), wrap="none")
        sb = ttk.Scrollbar(frm, command=self.log_txt.yview)
        self.log_txt.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        self.log_txt.pack(fill="both", expand=True)

    def _grid(self, parent, rows, cols, values, width, block=None):
        """Entry grid; `block` = (rows, cols) of a tile -> every other tile shaded."""
        entries = []
        for r in range(rows):
            row = []
            for c in range(cols):
                base = NORMAL_BG
                if block and (r // block[0] + c // block[1]) % 2:
                    base = TILE_BG
                e = tk.Entry(parent, width=width, justify="right", bg=base,
                             font=("Consolas", 9 if block else 10))
                e.base_bg = base
                e.insert(0, str(values[r][c]))
                e.grid(row=r + 1, column=c, padx=1, pady=1)
                row.append(e)
            entries.append(row)
        return entries

    def _build_matrices(self, fill):
        mode, sg, size = self.mode.get(), self.signed.get(), self.size.get()
        for w in self.mat_frame.winfo_children():
            w.destroy()
        if size != core.N:
            self._build_tiled_matrices(fill, mode, sg, size)
            return
        self.tile_banner.pack_forget()
        cols = core.b_cols(mode)
        (alo, ahi), (blo, bhi) = core.a_range(sg), core.b_range(mode, sg)
        if fill == "default":
            A = core.default_A()
            B = core.unpack_weights(core.default_w_bytes(), mode, sg)
        elif fill == "random":
            A = [[random.randint(alo, ahi) for _ in range(core.N)] for _ in range(core.N)]
            B = [[random.randint(blo, bhi) for _ in range(cols)] for _ in range(core.N)]
        else:
            A = [[0] * core.N for _ in range(core.N)]
            B = [[0] * cols for _ in range(core.N)]

        fa = ttk.LabelFrame(self.mat_frame, padding=6,
                            text="Matrix A  (4 x 4, values %d to %d)" % (alo, ahi))
        fa.pack(side="left", anchor="n")
        self.a_entries = self._grid(fa, core.N, core.N, A, 5)

        fb = ttk.LabelFrame(self.mat_frame, padding=6,
                            text="Matrix B  (4 x %d, values %d to %d)" % (cols, blo, bhi))
        fb.pack(side="left", anchor="n", padx=10)
        self.b_entries = self._grid(fb, core.N, cols, B, 5 if mode == 0 else 3)
        self.mode_hint.config(text="C will be 4 x %d  (%d weights per PE)" % (cols, core.lanes(mode)))

    def _build_tiled_matrices(self, fill, mode, sg, size):
        (alo, ahi), (blo, bhi) = core.a_range(sg), core.b_range(mode, sg)
        if fill == "default":
            A, B = core.default_square(size, mode, sg)
        elif fill == "random":
            A = [[random.randint(alo, ahi) for _ in range(size)] for _ in range(size)]
            B = [[random.randint(blo, bhi) for _ in range(size)] for _ in range(size)]
        else:
            A = [[0] * size for _ in range(size)]
            B = [[0] * size for _ in range(size)]
        w, nb = core.b_cols(mode), size // core.N
        ncb, runs = core.tile_cols(size, mode), len(core.tile_plan(size, mode))

        tabs = ttk.Notebook(self.mat_frame)
        tabs.pack(side="left", anchor="n")
        fa, fb = ttk.Frame(tabs, padding=6), ttk.Frame(tabs, padding=6)
        tabs.add(fa, text="  Matrix A  (%d x %d, values %d to %d)  " % (size, size, alo, ahi))
        tabs.add(fb, text="  Matrix B  (%d x %d, values %d to %d)  " % (size, size, blo, bhi))
        self.a_entries = self._grid(fa, size, size, A, 4, block=(core.N, core.N))
        self.b_entries = self._grid(fb, size, size, B, 4 if mode == 0 else 3, block=(core.N, w))
        self.mode_hint.config(text="C will be %d x %d  (%d FPGA runs)" % (size, size, runs))

        pad = "  (last B block padded with zero columns)" if ncb * w > size else ""
        self.tile_banner.config(text=(
            "⚙  TILING MODE - the FPGA array is only 4 x 4, so this %d x %d product is computed block by block.\n"
            "A is cut into 4 x 4 tiles, B into 4 x %d tiles (%s: %d weight(s) per PE)%s.  Shaded blocks = tiles.\n"
            "FPGA runs = %d row blocks x %d column blocks x %d K blocks = %d.   The FPGA does every multiply-add "
            "of a block; the PC adds the %d partial blocks of each C tile."
            % (size, size, w, core.MODE_NAMES[mode], core.lanes(mode), pad, nb, ncb, nb, runs, nb)))
        self.tile_banner.pack(fill="x", padx=10, pady=(2, 0), after=self.size_bar)

    # ------------------------------------------------------------------ helpers
    def log(self, text):
        self.log_txt.insert("end", text.replace("\r", "") + ("" if text.endswith("\n") else "\n"))
        self.log_txt.see("end")

    def on_mode_change(self):
        self._build_matrices("default")

    def _read_grid(self, entries, vrange, name):
        vmin, vmax = vrange
        vals, ok = [], True
        for r, row in enumerate(entries):
            vrow = []
            for c, e in enumerate(row):
                txt = e.get().strip()
                try:
                    v = int(txt)
                    good = vmin <= v <= vmax
                except ValueError:
                    v, good = 0, False
                e.config(bg=getattr(e, "base_bg", NORMAL_BG) if good else BAD_BG)
                ok &= good
                vrow.append(v)
            vals.append(vrow)
        if not ok:
            raise ValueError("Some values in matrix %s are not whole numbers %d..%d "
                             "(marked red)." % (name, vmin, vmax))
        return vals

    # ------------------------------------------------------------------ serial
    def refresh_ports(self):
        if not HAVE_SERIAL:
            self.port_cb["values"] = ["(pyserial not installed)"]
            self.port_cb.current(0)
            return
        ports = list(serial.tools.list_ports.comports())
        names = ["%s - %s" % (p.device, p.description) for p in ports]
        self.port_cb["values"] = names or ["(no COM ports found)"]
        self.port_cb.current(0)
        cands = core.candidate_ports(ports)
        if cands:
            self.port_cb.current(ports.index(cands[0]))

    def toggle_connect(self):
        if self.ser:
            self.ser.close()
            self.ser = None
            self.conn_btn.config(text="Connect")
            self.status.config(text="Not connected", foreground="gray")
            return
        if not HAVE_SERIAL:
            messagebox.showerror("pyserial missing", "Run:  pip install pyserial")
            return
        port = self.port_cb.get().split(" - ")[0]
        if not port.upper().startswith(("COM", "/DEV/")):
            messagebox.showerror("No port", "Plug in the board and press Refresh.")
            return
        try:
            ser = serial.Serial(port, BAUD, timeout=0.05)
        except Exception as ex:  # port busy (another terminal open?) etc.
            messagebox.showerror("Cannot open " + port,
                                 "%s\n\nClose any other serial terminal using this port." % ex)
            return
        self._set_connected(ser, port)

    def _set_connected(self, ser, port, found=False):
        self.ser = ser
        self.port_vidpid = (None, None)
        for p in serial.tools.list_ports.comports():
            if p.device == port:
                self.port_vidpid = (p.vid, p.pid)
        self.conn_btn.config(text="Disconnect")
        self.status.config(text="%s: %s @ %d" % ("Board found" if found else "Connected", port, BAUD),
                           foreground="green")
        self.demo.set(False)
        self.log("Connected to %s%s" % (port, "  (ADiP board answered)" if found else ""))

    def _mark_disconnected(self, why=""):
        try:
            if self.ser:
                self.ser.close()
        except Exception:
            pass
        self.ser = None
        self.conn_btn.config(text="Connect")
        self.status.config(text="Not connected" + (" - " + why if why else ""), foreground="gray")

    # ---- automatic board detection -------------------------------------------
    def auto_connect(self):
        """Look for the board on its known USB IDs and connect if it answers."""
        if not HAVE_SERIAL or self.ser or self.auto_running:
            return
        self.refresh_ports()
        cands = [p.device for p in core.candidate_ports(serial.tools.list_ports.comports())]
        if not cands:
            self.status.config(text="Board not found - plug it in, or pick the port and Connect",
                               foreground="gray")
            return
        self.auto_running = True
        self.status.config(text="Looking for the board on %s ..." % ", ".join(cands), foreground="#b06000")
        threading.Thread(target=self._auto_worker, args=(cands,), daemon=True).start()

    def _auto_worker(self, cands):
        for port in cands:
            try:
                ser = serial.Serial(port, BAUD, timeout=0.05)
            except Exception:
                continue
            try:
                if core.probe(ser):
                    self.q.put(("found", (ser, port)))
                    return
            except Exception:
                pass
            ser.close()
        self.q.put(("notfound", cands))

    def bring_to_front(self):
        try:
            self.root.deiconify()
            self.root.lift()
            self.root.attributes("-topmost", True)
            self.root.after(300, lambda: self.root.attributes("-topmost", False))
            self.root.focus_force()
        except tk.TclError:
            pass
        self.auto_connect()

    def _exchange(self, cmd):
        """Send one command, collect the reply until DONE (called from a thread)."""
        self.ser.reset_input_buffer()
        self.ser.write(cmd)
        self.ser.flush()
        buf, t0 = "", time.time()
        while time.time() - t0 < REPLY_TIMEOUT_S:
            chunk = self.ser.read(512)
            if chunk:
                buf += chunk.decode("ascii", errors="replace")
                if "DONE" in buf and buf.rstrip().endswith("DONE"):
                    time.sleep(0.05)
                    buf += self.ser.read(64).decode("ascii", errors="replace")
                    break
        return buf

    def _worker(self, cmd):
        """Runs in a thread: send command, collect the reply until DONE."""
        try:
            self.q.put(("reply", self._exchange(cmd)))
        except Exception as ex:
            self.q.put(("error", str(ex)))

    def _tiled_worker(self, cmds):
        """Runs in a thread: one FPGA run per tile, in order."""
        try:
            t0, replies = time.time(), []
            for n, cmd in enumerate(cmds, 1):
                replies.append(self._exchange(cmd))
                self.q.put(("progress", (n, len(cmds))))
            self.q.put(("tiled", (replies, time.time() - t0)))
        except Exception as ex:
            self.q.put(("error", str(ex)))

    def _show_progress(self, done, total):
        if not total:
            self.pbar.pack_forget()
            self.progress_lbl.config(text="")
            return
        if not self.pbar.winfo_ismapped():
            self.pbar.pack(side="right", before=self.progress_lbl)
        self.pbar.config(maximum=total, value=done)
        self.progress_lbl.config(text="FPGA run %d / %d" % (done, total))

    def _poll_queue(self):
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "found":
                    self.auto_running = False
                    if self.ser:                       # user connected meanwhile
                        payload[0].close()
                    else:
                        self._set_connected(payload[0], payload[1], found=True)
                    continue
                if kind == "notfound":
                    self.auto_running = False
                    self.status.config(text="No ADiP reply on %s - is the board programmed?"
                                       % ", ".join(payload), foreground="#c5221f")
                    continue
                if kind == "show":
                    self.bring_to_front()
                    continue
                if kind == "progress":
                    self._show_progress(*payload)
                    continue
                self.busy = False
                self.run_btn.config(state="normal")
                self._show_progress(0, 0)
                if kind == "error":
                    self._mark_disconnected("connection lost")
                    messagebox.showerror("Serial error",
                                         "%s\n\nWas the board unplugged? Plug it in and press Find board." % payload)
                elif kind == "tiled":
                    self._handle_tiled(payload[0], payload[1], source="FPGA")
                else:
                    self._handle_reply(payload, source="FPGA")
        except queue.Empty:
            pass
        self.root.after(100, self._poll_queue)

    # ------------------------------------------------------------------ run
    def run(self):
        if self.busy:
            return
        if self.size.get() != core.N:
            self.run_tiled()
            return
        mode, sg = self.mode.get(), self.signed.get()
        try:
            A = self._read_grid(self.a_entries, core.a_range(sg), "A")
            B = self._read_grid(self.b_entries, core.b_range(mode, sg), "B")
            cmd = core.build_command(mode, A, B, sg)
        except ValueError as ex:
            messagebox.showwarning("Check your input", str(ex))
            return
        self.sent = (mode, sg, A, B)
        self.log("\n>>> sending %d bytes: %s, mode %s, A, W (packed), start"
                 % (len(cmd), "signed" if sg else "unsigned", core.MODE_NAMES[mode]))

        if self.demo.get() or not self.ser:
            if not self.demo.get():
                messagebox.showinfo("Not connected", "Connect to the board first, or tick Demo mode.")
                return
            self._handle_reply(core.expected_report(mode, A, B, signed=sg), source="DEMO (PC only)")
            return

        self.busy = True
        self.run_btn.config(state="disabled")
        threading.Thread(target=self._worker, args=(cmd,), daemon=True).start()

    def _handle_reply(self, text, source):
        self.log(text if text else "(no reply)")
        mode, sg, A, B = self.sent
        try:
            rep = core.parse_report(text)
        except core.ReportError as ex:
            messagebox.showerror("No valid result",
                                 "Could not read the FPGA reply: %s\n\nCheck: right COM port, "
                                 "board programmed with the latest bitstream, 115200 baud." % ex)
            return
        if source == "FPGA":
            core.save_board_id(*self.port_vidpid)   # remember this board for auto-detect
        expect_C = core.matmul(A, B)
        checks = {
            "mode": rep["mode"] == mode,
            "signed/unsigned setting": rep["signed"] == sg,
            "A": rep["A"] == A,
            "B": rep["B"] == B,
        }
        self.show_result(rep, expect_C, checks, source)

    # ------------------------------------------------------------------ animation
    @staticmethod
    def _tile_label(i, j, k):
        return "C block (%d,%d) += A block (%d,%d) x B block (%d,%d)" % (i, j, i, k, k, j)

    def animate_inputs(self):
        """Animate the numbers currently typed in (no board needed)."""
        mode, sg, size = self.mode.get(), self.signed.get(), self.size.get()
        try:
            A = self._read_grid(self.a_entries, core.a_range(sg), "A")
            B = self._read_grid(self.b_entries, core.b_range(mode, sg), "B")
        except ValueError as ex:
            messagebox.showwarning("Check your input", str(ex))
            return
        if size == core.N:
            jobs = [("C = A x B", A, B, None)]
        else:
            jobs = [(self._tile_label(i, j, k),) + core.tile_operands(A, B, mode, i, j, k) + (None,)
                    for i, j, k in core.tile_plan(size, mode)]
        adip_anim.AnimWindow(self.root, mode, sg, jobs)

    # ------------------------------------------------------------------ tiled run (8 x 8, 16 x 16)
    def run_tiled(self):
        mode, sg, size = self.mode.get(), self.signed.get(), self.size.get()
        try:
            A = self._read_grid(self.a_entries, core.a_range(sg), "A")
            B = self._read_grid(self.b_entries, core.b_range(mode, sg), "B")
        except ValueError as ex:
            messagebox.showwarning("Check your input", str(ex))
            return
        jobs = []
        for i, j, k in core.tile_plan(size, mode):
            At, Bt = core.tile_operands(A, B, mode, i, j, k)
            jobs.append((i, j, k, At, Bt, core.build_command(mode, At, Bt, sg)))
        self.sent_tiled = (mode, sg, size, A, B, jobs)
        self.log("\n>>> TILING %d x %d, %s %s: %d FPGA runs (%d bytes each)"
                 % (size, size, core.MODE_NAMES[mode], "signed" if sg else "unsigned",
                    len(jobs), len(jobs[0][-1])))

        if self.demo.get() or not self.ser:
            if not self.demo.get():
                messagebox.showinfo("Not connected", "Connect to the board first, or tick Demo mode.")
                return
            replies = [core.expected_report(mode, At, Bt, signed=sg) for _, _, _, At, Bt, _ in jobs]
            self._handle_tiled(replies, None, source="DEMO (PC only)")
            return

        self.busy = True
        self.run_btn.config(state="disabled")
        self._show_progress(0, len(jobs))
        threading.Thread(target=self._tiled_worker, args=([jb[-1] for jb in jobs],), daemon=True).start()

    def _handle_tiled(self, replies, elapsed, source):
        mode, sg, size, A, B, jobs = self.sent_tiled
        C = [[0] * size for _ in range(size)]
        total_lat, bad_runs, tile_C = 0, [], []
        for n, (text, (i, j, k, At, Bt, _)) in enumerate(zip(replies, jobs), 1):
            try:
                rep = core.parse_report(text)
            except core.ReportError as ex:
                self.log(text if text else "(no reply)")
                messagebox.showerror("No valid result",
                                     "FPGA run %d of %d (A block row %d, K block %d, B block column %d) "
                                     "gave no valid reply: %s" % (n, len(jobs), i, k, j, ex))
                return
            received = (rep["mode"] == mode and rep["signed"] == sg
                        and rep["A"] == At and rep["B"] == Bt)
            if not received:
                bad_runs.append(n)
            if n == 1:
                self.log(text)          # one full report as an example, then one line per run
            self.log("run %2d/%d  C block (%d,%d) += A(%d,%d) x B(%d,%d)   LAT=%d cycles  %s"
                     % (n, len(jobs), i, j, i, k, k, j, rep["lat"],
                        "ok" if received else "INPUT NOT RECEIVED CORRECTLY"))
            total_lat += rep["lat"]
            tile_C.append(rep["C"])
            core.add_tile(C, rep["C"], mode, i, j)
        if source == "FPGA":
            core.save_board_id(*self.port_vidpid)
        self.show_tiled_result({
            "mode": mode, "signed": sg, "size": size, "A": A, "B": B, "C": C,
            "expect_C": core.matmul(A, B), "runs": len(jobs), "total_lat": total_lat,
            "elapsed": elapsed, "bad_runs": bad_runs, "source": source,
            "anim_jobs": [(self._tile_label(i, j, k), At, Bt, Ct)
                          for (i, j, k, At, Bt, _), Ct in zip(jobs, tile_C)]})

    # ------------------------------------------------------------------ result window
    def show_result(self, rep, expect_C, checks, source):
        if self.result_win is None or not self.result_win.winfo_exists():
            self.result_win = tk.Toplevel(self.root)
        win = self.result_win
        win.title("ADiP Result")
        for w in win.winfo_children():
            w.destroy()
        win.lift()

        C, mode, lat = rep["C"], rep["mode"], rep["lat"]
        macs, per_cycle, mmacs = core.throughput(mode, lat)
        match = C == expect_C and all(checks.values())

        top = ttk.Frame(win, padding=12)
        top.pack(fill="both", expand=True)
        ttk.Label(top, text="C = A × B", font=("Segoe UI", 16, "bold")).grid(row=0, column=0, sticky="w")
        info = "Source: %s     Mode: %s %s     Size: 4 × %d" % (
            source, core.MODE_NAMES[mode], "signed" if rep["signed"] else "unsigned", len(C[0]))
        ttk.Label(top, text=info).grid(row=1, column=0, sticky="w", pady=(2, 0))
        ttk.Label(top, text="Latency: %d clock cycles = %.2f µs at %.0f MHz   (%d multiply-adds)"
                  % (lat, lat / core.CLK_MHZ, core.CLK_MHZ, macs)
                  ).grid(row=2, column=0, sticky="w")
        ttk.Label(top, text="Throughput: %.2f MAC/cycle = %.1f MMAC/s = %.1f MOPS at %.0f MHz"
                  % (per_cycle, mmacs, 2 * mmacs, core.CLK_MHZ)
                  ).grid(row=3, column=0, sticky="w", pady=(0, 8))

        grid = tk.Frame(top, bg="#999999")
        grid.grid(row=4, column=0, sticky="w")
        tk.Label(grid, text="", bg="#eeeeee", width=4).grid(row=0, column=0, padx=1, pady=1, sticky="nsew")
        for j in range(len(C[0])):
            tk.Label(grid, text="c%d" % j, bg="#eeeeee", font=("Segoe UI", 9, "bold")
                     ).grid(row=0, column=j + 1, padx=1, pady=1, sticky="nsew")
        for i, row in enumerate(C):
            tk.Label(grid, text="r%d" % i, bg="#eeeeee", font=("Segoe UI", 9, "bold")
                     ).grid(row=i + 1, column=0, padx=1, pady=1, sticky="nsew")
            for j, v in enumerate(row):
                good = v == expect_C[i][j]
                tk.Label(grid, text=str(v), width=7, anchor="e", font=("Consolas", 12),
                         bg=OK_BG if good else BAD_BG
                         ).grid(row=i + 1, column=j + 1, padx=1, pady=1, sticky="nsew")

        if match:
            msg, col = "✔  Correct - every value matches the PC calculation", "#137333"
        else:
            bad = sum(v != e for r1, r2 in zip(C, expect_C) for v, e in zip(r1, r2))
            parts = ["%d value(s) differ from the PC calculation (red)" % bad] if bad else []
            parts += ["FPGA did not receive %s correctly" % k for k, ok in checks.items() if not ok]
            msg, col = "✘  " + "; ".join(parts), "#c5221f"
        tk.Label(top, text=msg, fg=col, font=("Segoe UI", 11, "bold")).grid(row=5, column=0, sticky="w", pady=10)

        btns = ttk.Frame(top)
        btns.grid(row=6, column=0, sticky="w")
        ttk.Button(btns, text="Save as CSV", command=lambda: self.save_csv(rep)).pack(side="left")
        mode_s, sg_s, A_s, B_s = self.sent
        ttk.Button(btns, text="▶ Animate this calculation",
                   command=lambda: adip_anim.AnimWindow(self.root, mode_s, sg_s,
                                                        [("C = A x B", A_s, B_s, rep["C"])])
                   ).pack(side="left", padx=6)
        ttk.Button(btns, text="Close", command=win.destroy).pack(side="left", padx=6)

    def save_csv(self, rep):
        path = filedialog.asksaveasfilename(defaultextension=".csv",
                                            filetypes=[("CSV", "*.csv")],
                                            initialfile="adip_result.csv")
        if not path:
            return
        with open(path, "w") as f:
            macs, per_cycle, mmacs = core.throughput(rep["mode"], rep["lat"])
            f.write("mode,%s\nsigned,%s\nlatency_cycles,%d\n" % (
                core.MODE_NAMES[rep["mode"]], "yes" if rep["signed"] else "no", rep["lat"]))
            f.write("multiply_adds,%d\nmac_per_cycle,%.3f\nmmac_per_s_at_%.0fMHz,%.2f\n\n"
                    % (macs, per_cycle, core.CLK_MHZ, mmacs))
            for name in ("A", "B", "C"):
                f.write("%s\n" % name)
                for row in rep[name]:
                    f.write(",".join(str(v) for v in row) + "\n")
                f.write("\n")

    def show_tiled_result(self, res):
        if self.result_win is None or not self.result_win.winfo_exists():
            self.result_win = tk.Toplevel(self.root)
        win = self.result_win
        win.title("ADiP Result - tiling")
        for w in win.winfo_children():
            w.destroy()
        win.lift()

        size, mode, C, expect_C = res["size"], res["mode"], res["C"], res["expect_C"]
        w, nb = core.b_cols(mode), size // core.N
        macs = size ** 3                                    # useful multiply-adds of the product
        per_cycle = macs / float(res["total_lat"]) if res["total_lat"] else 0.0
        bad = sum(v != e for r1, r2 in zip(C, expect_C) for v, e in zip(r1, r2))
        match = not bad and not res["bad_runs"]

        top = ttk.Frame(win, padding=12)
        top.pack(fill="both", expand=True)
        ttk.Label(top, text="C = A × B   (%d × %d, tiling)" % (size, size),
                  font=("Segoe UI", 16, "bold")).grid(row=0, column=0, sticky="w")
        tk.Label(top, text="⚙  Computed with TILING on the 4 × 4 systolic array", fg="#8a4b00",
                 bg="#fff4e0", padx=6, font=("Segoe UI", 10, "bold")).grid(row=1, column=0, sticky="w", pady=4)
        lines = [
            "Source: %s     Mode: %s %s" % (res["source"], core.MODE_NAMES[mode],
                                            "signed" if res["signed"] else "unsigned"),
            "Tiles: A -> 4 × 4,  B -> 4 × %d   =>   %d row blocks × %d column blocks × %d K blocks = %d FPGA runs"
            % (w, nb, core.tile_cols(size, mode), nb, res["runs"]),
            "FPGA compute: %d runs × %d cycles = %d clock cycles = %.1f µs at %.0f MHz   (%d multiply-adds)"
            % (res["runs"], res["total_lat"] // max(res["runs"], 1), res["total_lat"],
               res["total_lat"] / core.CLK_MHZ, core.CLK_MHZ, macs),
            "Throughput (array only): %.2f MAC/cycle = %.1f MMAC/s = %.1f MOPS at %.0f MHz"
            % (per_cycle, per_cycle * core.CLK_MHZ, 2 * per_cycle * core.CLK_MHZ, core.CLK_MHZ),
        ]
        if res["elapsed"] is not None:
            lines.append("Total time incl. USB serial: %.2f s  - the 115200-baud UART link, not the array, "
                         "is the bottleneck" % res["elapsed"])
        for n, txt in enumerate(lines):
            ttk.Label(top, text=txt).grid(row=2 + n, column=0, sticky="w")
        row0 = 2 + len(lines)

        grid = tk.Frame(top, bg="#999999")
        grid.grid(row=row0, column=0, sticky="w", pady=(8, 0))
        tk.Label(grid, text="", bg="#eeeeee", width=3).grid(row=0, column=0, padx=1, pady=1, sticky="nsew")
        for j in range(size):
            tk.Label(grid, text="c%d" % j, bg="#eeeeee", font=("Segoe UI", 8, "bold")
                     ).grid(row=0, column=j + 1, padx=1, pady=1, sticky="nsew")
        for i, row in enumerate(C):
            tk.Label(grid, text="r%d" % i, bg="#eeeeee", font=("Segoe UI", 8, "bold")
                     ).grid(row=i + 1, column=0, padx=1, pady=1, sticky="nsew")
            for j, v in enumerate(row):
                shade = OK_TILE_BG if (i // core.N + j // core.N) % 2 else OK_BG
                tk.Label(grid, text=str(v), width=8 if size > 8 else 9, anchor="e",
                         font=("Consolas", 9 if size > 8 else 11),
                         bg=shade if v == expect_C[i][j] else BAD_BG
                         ).grid(row=i + 1, column=j + 1, padx=1, pady=1, sticky="nsew")

        if match:
            msg, col = ("✔  Correct - all %d values match the PC calculation  (%d / %d FPGA runs verified)"
                        % (size * size, res["runs"], res["runs"]), "#137333")
        else:
            parts = ["%d value(s) differ from the PC calculation (red)" % bad] if bad else []
            if res["bad_runs"]:
                parts.append("FPGA did not receive the inputs of run(s) %s correctly"
                             % ", ".join(map(str, res["bad_runs"])))
            msg, col = "✘  " + "; ".join(parts), "#c5221f"
        tk.Label(top, text=msg, fg=col, font=("Segoe UI", 11, "bold")
                 ).grid(row=row0 + 1, column=0, sticky="w", pady=10)

        btns = ttk.Frame(top)
        btns.grid(row=row0 + 2, column=0, sticky="w")
        ttk.Button(btns, text="Save as CSV", command=lambda: self.save_csv_tiled(res)).pack(side="left")
        ttk.Button(btns, text="▶ Animate the block runs",
                   command=lambda: adip_anim.AnimWindow(self.root, res["mode"], res["signed"], res["anim_jobs"])
                   ).pack(side="left", padx=6)
        ttk.Button(btns, text="Close", command=win.destroy).pack(side="left", padx=6)

    def save_csv_tiled(self, res):
        path = filedialog.asksaveasfilename(defaultextension=".csv",
                                            filetypes=[("CSV", "*.csv")],
                                            initialfile="adip_tiled_%dx%d.csv" % (res["size"], res["size"]))
        if not path:
            return
        macs = res["size"] ** 3
        per_cycle = macs / float(res["total_lat"]) if res["total_lat"] else 0.0
        with open(path, "w") as f:
            f.write("matrix_size,%dx%d\nmethod,tiling on 4x4 array\nmode,%s\nsigned,%s\n" % (
                res["size"], res["size"], core.MODE_NAMES[res["mode"]], "yes" if res["signed"] else "no"))
            f.write("fpga_runs,%d\ntotal_fpga_cycles,%d\nmultiply_adds,%d\nmac_per_cycle,%.3f\n"
                    "mmac_per_s_at_%.0fMHz,%.2f\n" % (res["runs"], res["total_lat"], macs, per_cycle,
                                                       core.CLK_MHZ, per_cycle * core.CLK_MHZ))
            if res["elapsed"] is not None:
                f.write("total_time_incl_uart_s,%.3f\n" % res["elapsed"])
            f.write("\n")
            for name in ("A", "B", "C"):
                f.write("%s\n" % name)
                for row in res[name]:
                    f.write(",".join(str(v) for v in row) + "\n")
                f.write("\n")


def _single_instance():
    """Return a listening socket, or None if the app is already open (it is told
    to come to the front instead)."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        srv.bind(("127.0.0.1", core.GUI_SOCKET_PORT))
        srv.listen(2)
        return srv
    except OSError:
        srv.close()
        try:
            with socket.create_connection(("127.0.0.1", core.GUI_SOCKET_PORT), timeout=1) as c:
                c.sendall(b"show")
        except OSError:
            pass
        return None


def _listen(srv, q):
    while True:
        try:
            conn, _ = srv.accept()
            with conn:
                conn.recv(16)
            q.put(("show", None))
        except OSError:
            return


def main():
    srv = _single_instance()
    if srv is None:
        return
    root = tk.Tk()
    try:
        ttk.Style().theme_use("vista" if sys.platform == "win32" else "clam")
    except tk.TclError:
        pass
    app = AdipApp(root)
    threading.Thread(target=_listen, args=(srv, app.q), daemon=True).start()
    if "--auto" in sys.argv:
        root.after(200, app.bring_to_front)
    root.mainloop()


if __name__ == "__main__":
    main()
