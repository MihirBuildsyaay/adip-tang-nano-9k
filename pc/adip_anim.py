"""adip_anim.py - cycle-by-cycle animation of what the FPGA does for one 4 x 4 run.

Driven by adip_core.cycle_trace(), a Python copy of the RTL dataflow:
  LOAD    16 cycles  one stationary weight byte per cycle into PE(r, c)
  COMPUTE 11 cycles  skewed activations move right, 4-lane partial sums move down,
                     the shared shifter under each column combines the lanes of a
                     finished result and it is written into C
  STORE    1 cycle   -> 28 cycles = the LAT the board reports
Click any PE to see the ADiP trick inside it: x and w split into 2-bit chunks,
16 two-bit multipliers, lane sums, shift-and-add.
Keys: space = play/pause, left/right = step, Home/End.
"""

import tkinter as tk
from tkinter import ttk

import adip_core as core

N = core.N
CAN_W, CAN_H = 1250, 744
GX0, GY0 = 300, 152            # top-left of PE(0, 0)
PW, PH = 128, 86               # PE box
SX, SY = 150, 104              # PE pitch
TOK = 36                       # spacing of queued activations
SH_Y = GY0 + N * SY - 4        # shared shifter row
CY0 = SH_Y + 62                # C matrix
PANEL_X = GX0 + N * SX + 10    # PE detail panel

ROW_COLORS = ["#2f6fd0", "#d9730d", "#228b45", "#8a3fc7"]   # one per output row m
ROW_FILLS = ["#dce9fb", "#fde6cf", "#d6f0dd", "#ecdcf8"]
IDLE_FILL, GRID_LINE, MUTED = "#f6f7f9", "#b8bec8", "#7a828e"
PHASE_COLORS = {"START": "#9aa3ad", "LOAD": "#8e9aaf", "COMPUTE": "#1a73e8",
                "STORE": "#137333", "DONE": "#137333"}
MONO, MONO_B = ("Consolas", 9), ("Consolas", 9, "bold")


class FitCanvas(tk.Canvas):
    """Canvas that draws in fixed layout units (CAN_W x CAN_H) scaled by k to fit the
    window: coordinates, text wrap widths and fonts (in pixels) are multiplied by k."""
    k = 1.0

    def _xy(self, args):
        return [a * self.k for a in args]

    def create_line(self, *args, **kw):
        return super().create_line(*self._xy(args), **kw)

    def create_rectangle(self, *args, **kw):
        return super().create_rectangle(*self._xy(args), **kw)

    def create_text(self, x, y, **kw):
        family, size = (kw.get("font") or ("Segoe UI", 9))[:2]
        style = tuple((kw.get("font") or ())[2:])
        kw["font"] = (family, -max(6, int(round(size * 96 / 72.0 * self.k)))) + style
        if "width" in kw:
            kw["width"] = kw["width"] * self.k
        return super().create_text(x * self.k, y * self.k, **kw)


def pe_xy(r, c):
    return GX0 + c * SX, GY0 + r * SY


def fmt_vals(vals, width=0, sep=" | "):
    return sep.join(str(v).rjust(width) for v in vals)


class AnimWindow:
    """jobs: list of (label, A_tile, B_tile, fpga_C_tile or None) - one entry per FPGA run."""

    def __init__(self, parent, mode, signed, jobs):
        self.mode, self.signed, self.jobs = mode, signed, jobs
        self.win = tk.Toplevel(parent)
        self.win.title("ADiP - how the FPGA calculates it (cycle by cycle)")
        self.playing, self.after_id, self.sel = False, None, (0, 0)
        self.speed = tk.DoubleVar(value=1.0)
        self.fast_load = tk.BooleanVar(value=True)

        top = ttk.Frame(self.win, padding=(8, 6, 8, 0))
        top.pack(fill="x")
        if len(jobs) > 1:
            ttk.Label(top, text="FPGA run:").pack(side="left")
            self.job_cb = ttk.Combobox(top, state="readonly", width=46,
                                       values=["%d / %d   %s" % (i + 1, len(jobs), j[0])
                                               for i, j in enumerate(jobs)])
            self.job_cb.current(0)
            self.job_cb.bind("<<ComboboxSelected>>", lambda e: self.load_job(self.job_cb.current()))
            self.job_cb.pack(side="left", padx=(4, 12))
        ttk.Label(top, text="%s %s   ·   every number below is computed exactly like the Verilog does it"
                  % (core.MODE_NAMES[mode], "signed" if signed else "unsigned"),
                  foreground=MUTED).pack(side="left")

        # fit the drawing on the screen (Windows display scaling can make 744 px too tall);
        # the button bar is packed first at the bottom so it can never be pushed off
        k0 = min(1.0, (self.win.winfo_screenheight() - 170) / float(CAN_H),
                 (self.win.winfo_screenwidth() - 40) / float(CAN_W))
        self.cv = FitCanvas(self.win, width=int(CAN_W * k0), height=int(CAN_H * k0),
                            bg="white", highlightthickness=0)
        self.cv.k = k0
        self.cv.bind("<Button-1>", self._click)

        bar = ttk.Frame(self.win, padding=8)
        bar.pack(side="bottom", fill="x")
        ttk.Button(bar, text="⏮ Reset", command=lambda: self.goto(0)).pack(side="left")
        ttk.Button(bar, text="◀ Back", command=lambda: self.goto(self.idx - 1)).pack(side="left", padx=4)
        self.play_btn = ttk.Button(bar, text="▶ Play", width=10, command=self.toggle_play)
        self.play_btn.pack(side="left")
        ttk.Button(bar, text="Next ▶", command=lambda: self.goto(self.idx + 1, animate=True)).pack(side="left", padx=4)
        ttk.Button(bar, text="End ⏭", command=lambda: self.goto(len(self.steps) - 1)).pack(side="left")
        ttk.Label(bar, text="   Speed").pack(side="left")
        ttk.Scale(bar, from_=0.25, to=4.0, variable=self.speed, length=160).pack(side="left", padx=4)
        ttk.Checkbutton(bar, text="Fast weight loading", variable=self.fast_load).pack(side="left", padx=10)
        ttk.Label(bar, text="Click a PE to look inside it", foreground=MUTED).pack(side="right")

        for key, fn in (("<space>", lambda e: self.toggle_play()),
                        ("<Right>", lambda e: self.goto(self.idx + 1, animate=True)),
                        ("<Left>", lambda e: self.goto(self.idx - 1)),
                        ("<Home>", lambda e: self.goto(0)),
                        ("<End>", lambda e: self.goto(len(self.steps) - 1))):
            self.win.bind(key, fn)
        self.cv.pack(fill="both", expand=True)
        self.cv.bind("<Configure>", self._resize)
        self.win.protocol("WM_DELETE_WINDOW", self.close)
        self.load_job(0)

    # ------------------------------------------------------------------ data
    def load_job(self, k):
        self.stop()
        _, self.A, self.B, self.fpga_C = self.jobs[k]
        self.steps = core.cycle_trace(self.mode, self.A, self.B, self.signed)
        self.wbytes = core.pack_weights(self.B, self.mode, self.signed)
        self.expect_C = core.matmul(self.A, self.B)
        self.goto(0)

    def wbyte(self, r, c):
        return self.wbytes[r * N + c]

    # ------------------------------------------------------------------ playback
    def close(self):
        self.stop()
        self.win.destroy()

    def stop(self):
        self.playing = False
        if self.after_id:
            self.win.after_cancel(self.after_id)
            self.after_id = None
        if hasattr(self, "play_btn"):
            self.play_btn.config(text="▶ Play")

    def toggle_play(self):
        if self.playing:
            self.stop()
            return
        if self.idx >= len(self.steps) - 1:
            self.goto(0)
        self.playing = True
        self.play_btn.config(text="⏸ Pause")
        self._tick()

    def _step_ms(self, step):
        ms = 1100 / max(self.speed.get(), 0.05)
        return ms / 5 if step["phase"] == "LOAD" and self.fast_load.get() else ms

    def _tick(self):
        if not self.playing:
            return
        if self.idx >= len(self.steps) - 1:
            self.stop()
            return
        self.goto(self.idx + 1, animate=True)
        self.after_id = self.win.after(int(self._step_ms(self.steps[self.idx])), self._tick)

    def goto(self, i, animate=False):
        if self.after_id and not self.playing:
            self.win.after_cancel(self.after_id)
            self.after_id = None
        i = max(0, min(i, len(self.steps) - 1))
        prev, self.idx = getattr(self, "idx", 0), i
        if animate and i == prev + 1:
            frames = 14
            dur = self._step_ms(self.steps[i]) * 0.55
            self._tween(i, 1, frames, dur / frames)
        else:
            self.draw(i)

    def _tween(self, i, f, frames, dt):
        try:
            if self.idx != i or not self.win.winfo_exists():
                return
        except tk.TclError:
            return
        if f > frames:
            self.draw(i)
            return
        self.draw(i, tween=f / float(frames))
        self.win.after(max(int(dt), 10), lambda: self._tween(i, f + 1, frames, dt))

    # ------------------------------------------------------------------ drawing
    def draw(self, i, tween=None):
        cv, s = self.cv, self.steps[i]
        cv.delete("all")
        self._draw_header(s)
        self._draw_feeder(s, tween)
        self._draw_grid(s, tween)
        self._draw_shifters(s, tween)
        self._draw_C(s, tween)
        if tween is None:
            self._draw_panel(s)
        else:
            self._draw_tokens(i, tween)

    def _draw_header(self, s):
        cv, total = self.cv, len(self.steps) - 2
        ph = s["phase"]
        if ph == "LOAD":
            r, c = s["load"]
            what = "LOAD weights - cycle %d of 16" % s["cycle"]
            story = ("Weight byte W[%d][%d] = %d (0x%02X) goes into PE(%d,%d) and stays there for the whole run "
                     "(weight-stationary). Partial sums are held at 0 meanwhile."
                     % (r, c, self.wbyte(r, c), self.wbyte(r, c), r, c))
        elif ph == "COMPUTE":
            k = s["cnt"]
            what = "COMPUTE - cnt = %d of %d" % (k, 3 * N - 2)
            feeds = ["row %d gets A[%d][%d]" % (r, k - r, r) for r in range(N) if 0 <= k - r < N]
            story = ("Activations enter with a skew (%s). Each coloured PE multiplies its a by its stationary "
                     "weight and adds the partial sum coming from above."
                     % ("; ".join(feeds) if feeds else "nothing new enters, the last values drain out"))
            if s["capture"]:
                story += "  Finished: " + ", ".join("row %d of column %d" % (m, c) for m, c, _, _ in s["capture"])
        elif ph == "STORE":
            what, story = "STORE", "The last result is written into C. Next cycle the FPGA is DONE and prints the UART report."
        elif ph == "DONE":
            what, story = "DONE", "LAT = %d cycles - the same number the board reports (LAT=0x%03X)." % (total, total)
        else:
            what, story = "Ready", ("Press ▶ Play (or Next). The FPGA first loads the 16 weights, then streams A "
                                    "through the array. Colours = rows of A / C.")
        cv.create_text(16, 14, anchor="nw", font=("Segoe UI", 13, "bold"),
                       text="Cycle %d / %d   ·   %s" % (min(s["cycle"], total), total, what),
                       fill=PHASE_COLORS[ph])
        cv.create_text(16, 40, anchor="nw", width=CAN_W - 40, font=("Segoe UI", 9), text=story, fill="#333")
        ty = 90
        # timeline: one box per cycle
        x0, w = 16, (CAN_W - 32) / float(total)
        for t in range(1, total + 1):
            p = self.steps[t]["phase"]
            col = PHASE_COLORS[p]
            on = t <= s["cycle"] and ph != "START"
            cv.create_rectangle(x0 + (t - 1) * w + 1, ty, x0 + t * w - 1, ty + 12,
                                fill=col if on else "#eceff3", outline="")
            if t == s["cycle"]:
                cv.create_rectangle(x0 + (t - 1) * w, ty - 2, x0 + t * w, ty + 14, outline="#111", width=2)
        cv.create_text(x0, ty + 16, anchor="nw", font=("Segoe UI", 8), fill=MUTED, text="LOAD (16)")
        cv.create_text(x0 + 16 * w, ty + 16, anchor="nw", font=("Segoe UI", 8), fill=MUTED, text="COMPUTE (11)")
        cv.create_text(x0 + 27 * w, ty + 16, anchor="nw", font=("Segoe UI", 8), fill=MUTED, text="STORE")

    def _queue(self, s):
        """(r, m, offset) of activations still waiting left of the array."""
        out = []
        for r in range(N):
            for m in range(N):
                off = (m + r) - s["cnt"]
                if off > 0:
                    out.append((r, m, off))
        return out

    def _draw_feeder(self, s, tween):
        cv = self.cv
        cv.create_text(GX0 - 20, GY0 - 18, anchor="e", font=("Segoe UI", 9, "bold"),
                       text="A enters skewed  →", fill="#333")
        shift = (1 - tween) if (tween is not None and s["phase"] == "COMPUTE") else 0
        for r in range(N):
            y = GY0 + r * SY + PH / 2
            cv.create_text(14, y, anchor="w", font=("Segoe UI", 8), fill=MUTED, text="k=%d" % r)
            cv.create_line(40, y, GX0 - 4, y, fill="#e3e6ea", arrow="last")
        for r, m, off in self._queue(s):
            x = GX0 - 26 - (off - 1 + shift) * TOK
            if x < 46:
                continue
            y = GY0 + r * SY + PH / 2
            self._token(x, y, str(self.A[m][r]), m, small=True)

    def _token(self, x, y, text, m, small=False):
        w = 17 if small else 20
        self.cv.create_rectangle(x - w, y - 10, x + w, y + 10, fill=ROW_FILLS[m],
                                 outline=ROW_COLORS[m], width=2)
        self.cv.create_text(x, y, text=text, font=MONO_B, fill=ROW_COLORS[m])

    def _draw_grid(self, s, tween):
        cv, mode, sg = self.cv, self.mode, self.signed
        n = core.lanes(mode)
        for c in range(N):
            x, _ = pe_xy(0, c)
            cols = "C col %d" % c if n == 1 else "C cols %d-%d" % (c * n, c * n + n - 1)
            cv.create_text(x + PW / 2, GY0 - 18, text=cols, font=("Segoe UI", 8), fill=MUTED)
        for r in range(N):
            for c in range(N):
                x, y = pe_xy(r, c)
                if c < N - 1:
                    cv.create_line(x + PW, y + PH / 2, x + SX, y + PH / 2, fill=GRID_LINE, arrow="last")
                cv.create_line(x + PW / 2, y + PH, x + PW / 2, y + SY, fill=GRID_LINE, arrow="last")
                p = s["pe"][r][c] if s["pe"] else None
                active = p is not None and p["m"] is not None
                loaded = s["loaded"][r][c] or s["phase"] not in ("START", "LOAD")
                loading = s["load"] == (r, c)
                fill = ROW_FILLS[p["m"]] if active and tween is None else IDLE_FILL
                outline = ROW_COLORS[p["m"]] if active else ("#e8710a" if loading else GRID_LINE)
                cv.create_rectangle(x, y, x + PW, y + PH, fill=fill, outline=outline,
                                    width=3 if (r, c) == self.sel else (2 if active or loading else 1),
                                    dash=() if loaded or loading else (3, 3))
                cv.create_text(x + 5, y + 4, anchor="nw", text="PE(%d,%d)" % (r, c),
                               font=("Segoe UI", 7), fill=MUTED)
                if loaded or (loading and tween is None):
                    w = core.pe_weights(self.wbyte(r, c), mode, sg)
                    wide = len(" ".join(map(str, w))) > 7
                    cv.create_text(x + PW - 5, y + 4, anchor="ne", fill="#444",
                                   font=("Consolas", 8, "bold") if wide else MONO_B,
                                   text=("w " if not wide else "") + " ".join(str(v) for v in w))
                if not active or tween is not None:
                    if s["phase"] == "COMPUTE" and tween is None:
                        cv.create_text(x + PW / 2, y + PH / 2 + 6, text="idle (a = 0)",
                                       font=("Segoe UI", 8), fill="#a0a6ae")
                    continue
                prod = core.combine(p["lanes"], mode)
                out = core.combine(p["psum_out"], mode)
                col = ROW_COLORS[p["m"]]
                sep, vf = (" ", ("Consolas", 8)) if mode == 2 else (" | ", MONO)
                cv.create_text(x + 6, y + 24, anchor="nw", font=MONO_B, fill=col,
                               text="a = %d" % p["a"])
                cv.create_text(x + 6, y + 42, anchor="nw", font=vf, fill="#333",
                               text="a·w " + fmt_vals(prod, sep=sep))
                cv.create_text(x + 6, y + 60, anchor="nw", font=(vf[0], vf[1], "bold"), fill=col,
                               text="Σ↓  " + fmt_vals(out, sep=sep))

    def _draw_shifters(self, s, tween):
        cv, mode = self.cv, self.mode
        formula = {0: "L0+4L1+16L2+64L3", 1: "L0+4L1 | L2+4L3", 2: "L0 | L1 | L2 | L3"}[mode]
        caps = {c: (m, res) for m, c, _, res in s["capture"]}
        for c in range(N):
            x, _ = pe_xy(0, c)
            on = c in caps and tween is None
            m = caps[c][0] if c in caps else 0
            cv.create_rectangle(x, SH_Y, x + PW, SH_Y + 44, fill=ROW_FILLS[m] if on else "#fafbfc",
                                outline=ROW_COLORS[m] if on else GRID_LINE, width=2 if on else 1)
            cv.create_text(x + PW / 2, SH_Y + 11, font=("Segoe UI", 7, "bold" if on else "normal"),
                           fill=ROW_COLORS[m] if on else MUTED,
                           text="shifter → C row %d" % m if on else "shared shifter")
            if on:
                cv.create_text(x + PW / 2, SH_Y + 29, fill=ROW_COLORS[m],
                               font=("Consolas", 8, "bold") if mode == 2 else MONO_B,
                               text=fmt_vals(caps[c][1], sep=" " if mode == 2 else " | "))
            else:
                cv.create_text(x + PW / 2, SH_Y + 29, text=formula, font=("Consolas", 7), fill="#a0a6ae")
            cv.create_line(x + PW / 2, SH_Y + 44, x + PW / 2, CY0 - 4, fill=GRID_LINE, arrow="last")

    def _draw_C(self, s, tween):
        cv, C = self.cv, s["C"]
        cols = len(C[0])
        cw = min(84, (PANEL_X + 300 - GX0) / float(cols))
        just = {(m, c * core.lanes(self.mode) + k) for m, c, _, res in s["capture"]
                for k in range(len(res))} if tween is None else set()
        cv.create_text(GX0 - 20, CY0 + 2, anchor="ne", font=("Segoe UI", 9, "bold"), fill="#333",
                       text="C = A × B")
        for m in range(N):
            for j in range(cols):
                x, y = GX0 + j * cw, CY0 + m * 22
                v = C[m][j]
                fill = ROW_FILLS[m] if v is not None else "#fafbfc"
                cv.create_rectangle(x, y, x + cw - 2, y + 20, fill=fill,
                                    outline=ROW_COLORS[m] if (m, j) in just else "#d5d9de",
                                    width=2 if (m, j) in just else 1)
                if v is not None:
                    cv.create_text(x + cw - 6, y + 10, anchor="e", text=str(v),
                                   font=MONO_B if (m, j) in just else MONO, fill="#222")
        if s["phase"] == "DONE":
            ok = C == self.expect_C
            msg = "✔ cycle simulation = A × B" if ok else "✘ cycle simulation differs from A × B"
            if self.fpga_C is not None:
                ok2 = C == self.fpga_C
                msg += ("   ·   ✔ = the FPGA's answer" if ok2 else "   ·   ✘ differs from the FPGA's answer")
                ok = ok and ok2
            cv.create_text(GX0, CY0 + N * 22 + 8, anchor="nw", text=msg,
                           font=("Segoe UI", 10, "bold"), fill="#137333" if ok else "#c5221f")

    def _draw_tokens(self, i, f):
        """Moving values during the transition into step i (f = 0..1)."""
        prev, s = self.steps[i - 1], self.steps[i]
        lerp = lambda a, b: a + (b - a) * f
        if s["phase"] == "LOAD":
            r, c = s["load"]
            x, y = pe_xy(r, c)
            self._token(x + PW / 2, lerp(GY0 - 34, y + PH / 2), str(self.wbyte(r, c)), 0)
            return
        if s["phase"] != "COMPUTE":
            return
        for r in range(N):
            for c in range(N):
                p = s["pe"][r][c]
                if p["m"] is None:
                    continue
                x, y = pe_xy(r, c)
                x_from = x - SX + 30 if c else GX0 - 26
                self._token(lerp(x_from, x + 30), y + 30, str(p["a"]), p["m"])
                if r and prev["pe"] and prev["pe"][r - 1][c]["m"] is not None:
                    v = fmt_vals(core.combine(p["psum_in"], self.mode))
                    self._psum_token(x + PW - 34, lerp(y - SY + PH - 10, y + PH - 22), v, p["m"])
        for m, c, _, res in s["capture"]:
            x, _ = pe_xy(N - 1, c)
            self._psum_token(x + PW / 2, lerp(GY0 + (N - 1) * SY + PH - 10, SH_Y + 22), fmt_vals(res), m)

    def _psum_token(self, x, y, text, m):
        w = max(22, 4 * len(text))
        self.cv.create_rectangle(x - w, y - 9, x + w, y + 9, fill="white", outline=ROW_COLORS[m], width=2)
        self.cv.create_text(x, y, text=text, font=("Consolas", 8, "bold"), fill=ROW_COLORS[m])

    # ------------------------------------------------------------------ inside one PE
    def _resize(self, e):
        k = max(0.4, min(e.width / float(CAN_W), e.height / float(CAN_H)))
        if abs(k - self.cv.k) > 0.005 and hasattr(self, "steps"):
            self.cv.k = k
            self.draw(self.idx)

    def _click(self, e):
        ex, ey = e.x / self.cv.k, e.y / self.cv.k
        for r in range(N):
            for c in range(N):
                x, y = pe_xy(r, c)
                if x <= ex <= x + PW and y <= ey <= y + PH:
                    self.select((r, c))
                    return

    def select(self, rc):
        self.sel = rc
        self.draw(self.idx)

    def _draw_panel(self, s):
        cv, mode, sg = self.cv, self.mode, self.signed
        r, c = self.sel
        x0, y = PANEL_X + 8, GY0 - 26
        cv.create_rectangle(PANEL_X, y - 6, CAN_W - 8, SH_Y + 44, fill="#fbfbfd", outline="#d5d9de")
        lines = []
        add = lambda t, style="n": lines.append((t, style))
        wb = self.wbyte(r, c)
        wl = core.pe_weights(wb, mode, sg)
        wflags = core.w_signed_flags(mode, sg)
        add("Inside PE(%d,%d)  -  cycle %d" % (r, c, s["cycle"]), "h")
        add("w = 0x%02X = %s" % (wb, " ".join(format(wb >> (2 * i) & 3, "02b") for i in (3, 2, 1, 0))))
        add("    %s: %d weight%s  %s" % (core.MODE_NAMES[mode], len(wl), "s" if len(wl) > 1 else "",
                                      fmt_vals(wl)))
        p = s["pe"][r][c] if s["pe"] else None
        if not p or p["m"] is None:
            add("")
            if s["load"] == (r, c):
                add("Loading its weight now (it stays here).")
            elif s["phase"] in ("START", "LOAD"):
                add("Weight loaded - waiting for COMPUTE." if s["loaded"][r][c]
                    else "Waiting for its weight (LOAD).")
            elif s["phase"] in ("STORE", "DONE"):
                add("Run finished - all of C has left the array.")
            else:
                add("No activation this cycle (a = 0): nothing")
                add("is added, the partial sum just passes on.")
            add("")
            add("Press Next / Play and click a coloured PE.", "m")
            self._panel_text(x0, y, lines)
            return
        m = p["m"]
        xc, wc, pp, L = p["xc"], p["wc"], p["pp"], p["lanes"]
        add("x = A[%d][%d] = %d = %s" % (m, r, p["a"], " ".join(
            format(p["xbyte"] >> (2 * i) & 3, "02b") for i in (3, 2, 1, 0))), ("c", m))
        add("chunks  x3 x2 x1 x0 = %s" % " ".join("%2d" % xc[i] for i in (3, 2, 1, 0)))
        add("chunks  w3 w2 w1 w0 = %s" % " ".join("%2d" % wc[j] for j in (3, 2, 1, 0)))
        if sg:
            add("signed chunks (-2..1): x3, %s" % ", ".join("w%d" % j for j in range(4) if wflags[j]), "m")
        add("")
        add("16 two-bit multipliers  x_i · w_j", "b")
        add("         w0   w1   w2   w3")
        for i in range(4):
            add("   x%d  %s" % (i, " ".join("%4d" % pp[i][j] for j in range(4))))
        add("")
        add("4 lanes  L_j = Σ x_i·w_j · 4^i", "b")
        for j in range(4):
            add("   L%d = %s = %d" % (j, " + ".join("%d·%d" % (pp[i][j], 4 ** i) for i in range(4)), L[j]))
        add("")
        add("shared shifter (%s)" % core.MODE_NAMES[mode], "b")
        prod = core.combine(L, mode)
        if mode == 0:
            add("   L0 + 4·L1 + 16·L2 + 64·L3 = %d" % prod[0])
        elif mode == 1:
            add("   L0 + 4·L1 = %d   |   L2 + 4·L3 = %d" % tuple(prod))
        else:
            add("   each lane is one result:")
            add("   %s" % fmt_vals(prod))
        add("   check: %d × w = %s  ✓" % (p["a"], fmt_vals([p["a"] * w for w in wl])), "ok")
        add("")
        add("partial sum  (C row %d, array column %d)" % (m, c), "b")
        pin, pout = core.combine(p["psum_in"], mode), core.combine(p["psum_out"], mode)
        add("   %s  (from %s)" % (fmt_vals(pin), "PE above" if r else "top = 0"))
        add(" + %s" % fmt_vals(prod))
        add(" = %s" % fmt_vals(pout), ("c", m))
        add("   ↓ %s" % ("to the PE below" if r < N - 1 else "to the shared shifter (C row %d)" % m), "m")
        add("")
        add("(the PE really passes the 4 lanes down; they", "m")
        add(" are shown combined here so they read as numbers)", "m")
        self._panel_text(x0, y, lines)

    def _panel_text(self, x0, y, lines):
        for text, style in lines:
            if style == "h":
                font, col, dy = ("Segoe UI", 11, "bold"), "#111", 22
            elif style == "b":
                font, col, dy = MONO_B, "#333", 16
            elif style == "m":
                font, col, dy = ("Segoe UI", 8), MUTED, 14
            elif style == "ok":
                font, col, dy = MONO_B, "#137333", 16
            elif isinstance(style, tuple):
                font, col, dy = MONO_B, ROW_COLORS[style[1]], 16
            else:
                font, col, dy = MONO, "#333", 15 if text else 8
            self.cv.create_text(x0, y, anchor="nw", text=text, font=font, fill=col)
            y += dy
