"""adip_core.py - PC-side logic for the ADiP Tang Nano 9K accelerator.

No GUI and no serial code here, so it can be tested on its own:
    python pc/adip_core.py        (runs the self-test)

Protocol (PC -> FPGA, 115200 8N1), see rtl/uart_cmd.v:
    'I' / 'U'         signed (A = INT8, B = INT8/INT4/INT2) / unsigned arithmetic
    'M' <mode>        mode 0 = 8b x 8b, 1 = 8b x 4b, 2 = 8b x 2b
    'A' <16 bytes>    activation matrix A, row-major
    'W' <16 bytes>    packed weight bytes, row-major (one byte per PE)
    'S'               start; the FPGA answers with a text report ending in DONE
"""

N = 4
CLK_MHZ = 27.0

MODE_NAMES = {0: "8b x 8b", 1: "8b x 4b", 2: "8b x 2b"}
MODE_BITS = {0: 8, 1: 4, 2: 2}


def lanes(mode):
    """Weights packed into one 8-bit word: 1, 2 or 4."""
    return 1 << mode


def b_cols(mode):
    """Columns of the logical weight matrix B (and of C)."""
    return N * lanes(mode)


def a_range(signed=False):
    """(min, max) of an A value."""
    return (-128, 127) if signed else (0, 255)


def b_range(mode, signed=False):
    """(min, max) of a B value: 8 / 4 / 2 bit, unsigned or two's complement."""
    bits = MODE_BITS[mode]
    if signed:
        return -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return 0, (1 << bits) - 1


def b_max(mode):
    return b_range(mode)[1]


def throughput(mode, lat, clk_mhz=CLK_MHZ):
    """Multiply-adds of one run and the resulting throughput.
    Returns (macs, macs_per_cycle, mega_macs_per_second)."""
    macs = N * N * b_cols(mode)
    per_cycle = macs / float(lat) if lat else 0.0
    return macs, per_cycle, per_cycle * clk_mhz


# ---------------------------------------------------------------- default data
def default_A():
    return [[(r * N + c + 1) & 0xFF for c in range(N)] for r in range(N)]


def default_w_bytes():
    return [(73 * i + 41) & 0xFF for i in range(N * N)]


# ---------------------------------------------------------------- weight packing
def unpack_weights(wbytes, mode, signed=False):
    """Packed bytes (N*N, row-major) -> logical B matrix (N x N*lanes)."""
    n, bits = lanes(mode), MODE_BITS[mode]
    mask = (1 << bits) - 1
    B = [[0] * (N * n) for _ in range(N)]
    for r in range(N):
        for c in range(N):
            byte = wbytes[r * N + c]
            for k in range(n):
                v = (byte >> (bits * k)) & mask
                if signed and v >> (bits - 1):
                    v -= 1 << bits
                B[r][c * n + k] = v
    return B


def pack_weights(B, mode, signed=False):
    """Logical B matrix (N x N*lanes) -> packed bytes (N*N, row-major)."""
    n, bits = lanes(mode), MODE_BITS[mode]
    lo, hi = b_range(mode, signed)
    out = []
    for r in range(N):
        for c in range(N):
            byte = 0
            for k in range(n):
                v = B[r][c * n + k]
                if not lo <= v <= hi:
                    raise ValueError("B[%d][%d] = %d is out of range %d..%d"
                                     % (r, c * n + k, v, lo, hi))
                byte |= (v & ((1 << bits) - 1)) << (bits * k)
            out.append(byte)
    return out


def matmul(A, B):
    return [[sum(A[m][k] * B[k][j] for k in range(len(B))) for j in range(len(B[0]))]
            for m in range(len(A))]


# ---------------------------------------------------------------- tiling (bigger matrices)
# The array is fixed at N x N. A bigger product C = A x B (size x size) is split into
# blocks: every FPGA run multiplies an N x N tile of A by an N x b_cols(mode) tile of B.
# The FPGA does all multiply-adds inside a tile; the PC adds the size/N partial tiles
# along K and places the C tiles. Lower precision = wider B tile = fewer runs.
TILE_SIZES = (8, 16)


def tile_cols(size, mode):
    """Column blocks of B for a size x size product (the last one zero-padded)."""
    return -(-size // b_cols(mode))


def tile_plan(size, mode):
    """(i, j, k) for every FPGA run: row block i of A, column block j of B, K block k."""
    nb = size // N
    return [(i, j, k) for i in range(nb) for j in range(tile_cols(size, mode)) for k in range(nb)]


def tile_operands(A, B, mode, i, j, k):
    """The N x N tile of A and the N x b_cols(mode) tile of B for one run.
    B columns past the right edge are padded with 0."""
    w = b_cols(mode)
    At = [A[i * N + r][k * N:(k + 1) * N] for r in range(N)]
    Bt = [[B[k * N + r][c] if c < len(B[0]) else 0 for c in range(j * w, (j + 1) * w)]
          for r in range(N)]
    return At, Bt


def add_tile(C, Ct, mode, i, j):
    """C[row block i, column block j] += Ct (padded columns are dropped)."""
    w = b_cols(mode)
    for r in range(N):
        for c in range(w):
            if j * w + c < len(C[0]):
                C[i * N + r][j * w + c] += Ct[r][c]


def default_square(size, mode, signed=False):
    """Demo A and B (size x size), same pattern as the built-in data, in range for the mode."""
    def wrap(v, bits):
        v &= (1 << bits) - 1
        return v - (1 << bits) if signed and v >> (bits - 1) else v
    bits = MODE_BITS[mode]
    A = [[wrap(r * size + c + 1, 8) for c in range(size)] for r in range(size)]
    B = [[wrap(73 * (r * size + c) + 41, bits) for c in range(size)] for r in range(size)]
    return A, B


# ---------------------------------------------------------------- cycle-accurate trace
# Python copy of the RTL dataflow, used by the animation (adip_anim.py):
#   LOAD    N*N cycles  one stationary weight byte per cycle into PE(r, c)
#   COMPUTE 3N-1 cycles row r of the array gets A[cnt-r][r] (skew); activations
#                       move right, 4-lane partial sums move down, one PE per clock;
#                       column c finishes row m = cnt-N-c through its shared shifter
#   STORE   1 cycle     -> N*N + 3N = 28 cycles for N = 4
def chunk_vals(byte, signed_flags):
    """The four 2-bit chunks c0..c3 of a byte; chunk i is two's complement if signed_flags[i]."""
    out = []
    for i in range(4):
        v = (byte >> (2 * i)) & 3
        if signed_flags[i] and v & 2:
            v -= 4
        out.append(v)
    return out


def w_signed_flags(mode, signed):
    """Which weight chunks are the (signed) top chunk of a weight, as w_s in adip_top.v."""
    if not signed:
        return [False] * 4
    return [[False, False, False, True], [False, True, False, True], [True] * 4][mode]


def pe_math(xbyte, wbyte, mode, signed):
    """One PE in one cycle: x chunks, w chunks, the 16 2b x 2b products pp[i][j] = x_i * w_j
    and the 4 lane sums L_j = sum_i pp[i][j] * 4^i (reconfigurable_multiplier.v)."""
    xc = chunk_vals(xbyte, [False, False, False, signed])
    wc = chunk_vals(wbyte, w_signed_flags(mode, signed))
    pp = [[xc[i] * wc[j] for j in range(4)] for i in range(4)]
    lane_sums = [sum(pp[i][j] * 4 ** i for i in range(4)) for j in range(4)]
    return xc, wc, pp, lane_sums


def combine(lane_sums, mode):
    """Shared shifter: 4 lane sums -> the 1 / 2 / 4 results of the mode."""
    L = lane_sums
    if mode == 0:
        return [L[0] + 4 * L[1] + 16 * L[2] + 64 * L[3]]
    if mode == 1:
        return [L[0] + 4 * L[1], L[2] + 4 * L[3]]
    return list(L)


def pe_weights(wbyte, mode, signed):
    """The logical weights held by one PE (1, 2 or 4 of them)."""
    bits = MODE_BITS[mode]
    out = []
    for k in range(lanes(mode)):
        v = (wbyte >> (bits * k)) & ((1 << bits) - 1)
        if signed and v >> (bits - 1):
            v -= 1 << bits
        out.append(v)
    return out


def cycle_trace(mode, A, B, signed=False):
    """Every clock cycle of one run, as a list of dicts (index 0 = before START).

    step keys: cycle, phase ('START', 'LOAD', 'COMPUTE', 'STORE', 'DONE'), cnt (COMPUTE
    counter, -1 before / 3N-1 after), load (r, c) or None, loaded [[bool]],
    pe [[dict or None]] (COMPUTE only: a, xbyte, m, xc, wc, pp, lanes, psum_in, psum_out),
    capture [(m, c, lanes, results)], C (logical result matrix so far, None = not yet written).
    """
    wb = pack_weights(B, mode, signed)
    W = [wb[r * N:(r + 1) * N] for r in range(N)]
    n = lanes(mode)
    loaded = [[False] * N for _ in range(N)]
    a_reg = [[None] * N for _ in range(N)]                  # (xbyte, m) leaving each PE
    ps = [[[0] * 4 for _ in range(N)] for _ in range(N)]    # 4-lane psum registers
    C = [[None] * (N * n) for _ in range(N)]

    def snap(**kw):
        d = dict(cycle=len(steps), load=None, pe=None, capture=[],
                 loaded=[row[:] for row in loaded], C=[row[:] for row in C])
        d.update(kw)
        return d

    steps = []
    steps.append(snap(phase="START", cnt=-1))
    for r in range(N):                                      # LOAD (clr keeps psums at 0)
        for c in range(N):
            steps.append(snap(phase="LOAD", cnt=-1, load=(r, c)))
            loaded[r][c] = True
    for cnt in range(3 * N - 1):                            # COMPUTE
        edge = [(A[cnt - r][r] & 0xFF, cnt - r) if 0 <= cnt - r < N else None for r in range(N)]
        capture = []
        for c in range(N):
            m = cnt - N - c
            if 0 <= m < N:
                capture.append((m, c, ps[N - 1][c][:], combine(ps[N - 1][c], mode)))
        pe = [[None] * N for _ in range(N)]
        new_a = [[None] * N for _ in range(N)]
        new_ps = [[None] * N for _ in range(N)]
        for r in range(N):
            for c in range(N):
                a_in = edge[r] if c == 0 else a_reg[r][c - 1]
                xbyte, m = a_in if a_in else (0, None)
                top = ps[r - 1][c] if r else [0] * 4
                xc, wc, pp, ln = pe_math(xbyte, W[r][c], mode, signed)
                out = [top[j] + ln[j] for j in range(4)]
                pe[r][c] = dict(a=(xbyte - 256 if signed and xbyte > 127 else xbyte), xbyte=xbyte,
                                m=m, wbyte=W[r][c], xc=xc, wc=wc, pp=pp, lanes=ln,
                                psum_in=top, psum_out=out)
                new_a[r][c] = a_in
                new_ps[r][c] = out
        for m, c, _, res in capture:                        # written at the clock edge
            for k in range(n):
                C[m][c * n + k] = res[k]
        steps.append(snap(phase="COMPUTE", cnt=cnt, pe=pe, capture=capture))
        a_reg, ps = new_a, new_ps
    steps.append(snap(phase="STORE", cnt=3 * N - 1))
    steps.append(snap(phase="DONE", cnt=3 * N - 1))
    return steps


# ---------------------------------------------------------------- command bytes
def build_command(mode, A, B, signed=False):
    """Bytes to send: signed/unsigned, set mode, load A, load W, start."""
    lo, hi = a_range(signed)
    flat_a = []
    for r in range(N):
        for c in range(N):
            v = A[r][c]
            if not lo <= v <= hi:
                raise ValueError("A[%d][%d] = %d is out of range %d..%d" % (r, c, v, lo, hi))
            flat_a.append(v & 0xFF)
    return ((b"I" if signed else b"U") +
            b"M" + bytes([mode]) +
            b"A" + bytes(flat_a) +
            b"W" + bytes(pack_weights(B, mode, signed)) +
            b"S")


# ---------------------------------------------------------------- report text
def expected_report(mode, A, B, lat=N * N + 3 * N, signed=False):
    """The exact text uart_report.v prints (used for the offline demo + tests)."""
    m = "842"[mode]
    wb, wc = {0: (3, 6), 1: (2, 5), 2: (1, 4)}[mode]
    wa = 3
    if signed:                      # one column wider for the '-'
        wa, wb, wc = wa + 1, wb + 1, wc + 1

    def rows(M, w):
        return "".join(" ".join(str(v).rjust(w) for v in r) + "\r\n" for r in M)

    s = "ADiP MODE=8x%s%s\r\n" % (m, " SIGNED" if signed else "")
    s += "A matrix:\r\n" + rows(A, wa)
    s += "\r\nB matrix (%s-bit):\r\n" % m + rows(B, wb)
    s += "\r\nC = A x B:\r\n" + rows(matmul(A, B), wc)
    s += "\r\nLAT=0x%03X cycles\r\nDONE\r\n\r\n" % lat
    return s


class ReportError(Exception):
    pass


def parse_report(text):
    """Parse the FPGA's text report. Uses the LAST complete report in `text`.

    Returns dict: mode, signed, A, B, C (lists of int rows), lat (cycles).
    """
    lines = [ln.rstrip("\r") for ln in text.replace("\r\n", "\n").split("\n")]
    starts = [i for i, ln in enumerate(lines) if ln.startswith("ADiP MODE=8x")]
    if not starts:
        raise ReportError("no 'ADiP MODE=' header received")
    i = starts[-1]
    tag = lines[i][len("ADiP MODE=8x"):].split()
    if not tag or tag[0] not in ("8", "4", "2") or tag[1:] not in ([], ["SIGNED"]):
        raise ReportError("unknown mode in header: %r" % lines[i])
    mode = {"8": 0, "4": 1, "2": 2}[tag[0]]
    signed = tag[1:] == ["SIGNED"]

    def find(prefix, start):
        for j in range(start, len(lines)):
            if lines[j].startswith(prefix):
                return j
        raise ReportError("'%s' not found" % prefix)

    def grab(after, cols):
        rows = []
        for j in range(after + 1, after + 1 + N):
            if j >= len(lines):
                raise ReportError("report ended early")
            try:
                vals = [int(x) for x in lines[j].split()]
            except ValueError:
                raise ReportError("bad number in line: %r" % lines[j])
            if len(vals) != cols:
                raise ReportError("expected %d values, got %d: %r" % (cols, len(vals), lines[j]))
            rows.append(vals)
        return rows

    ja = find("A matrix:", i)
    jb = find("B matrix", ja)
    jc = find("C = A x B:", jb)
    jl = find("LAT=", jc)
    find("DONE", jl)
    A = grab(ja, N)
    B = grab(jb, b_cols(mode))
    C = grab(jc, b_cols(mode))
    lat_txt = lines[jl][4:].split()[0]
    lat = int(lat_txt, 16) if lat_txt.lower().startswith("0x") else int(lat_txt)
    return {"mode": mode, "signed": signed, "A": A, "B": B, "C": C, "lat": lat}


# ---------------------------------------------------------------- board detection
# USB IDs of the board's serial port. The Tang Nano 9K's USB chip is expected to
# show up as 0403:6010; the app also LEARNS the real ID the first time it gets a
# valid ADiP reply (saved in board_id.json), so other IDs work after one manual run.
import json as _json
import os as _os
import time as _time

DEFAULT_IDS = [(0x0403, 0x6010)]
ID_FILE = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "board_id.json")
GUI_SOCKET_PORT = 47321          # local port: lets a 2nd launch bring the open app to front
WATCHER_SOCKET_PORT = 47322      # local port: keeps a single watcher running


def load_board_ids():
    ids = []
    try:
        with open(ID_FILE) as f:
            ids = [tuple(x) for x in _json.load(f)]
    except (OSError, ValueError, TypeError):
        pass
    for d in DEFAULT_IDS:
        if d not in ids:
            ids.append(d)
    return ids


def save_board_id(vid, pid):
    if vid is None or pid is None:
        return
    ids = []
    try:
        with open(ID_FILE) as f:
            ids = [tuple(x) for x in _json.load(f)]
    except (OSError, ValueError, TypeError):
        pass
    if (vid, pid) not in ids:
        ids.insert(0, (vid, pid))
        try:
            with open(ID_FILE, "w") as f:
                _json.dump([list(x) for x in ids], f)
        except OSError:
            pass


def candidate_ports(ports):
    """Ports (from serial.tools.list_ports.comports()) that look like the board,
    learned IDs first."""
    ids = load_board_ids()
    found = [p for p in ports if (getattr(p, "vid", None), getattr(p, "pid", None)) in ids]
    found.sort(key=lambda p: ids.index((p.vid, p.pid)))
    return found


def probe(ser, timeout=1.5):
    """Send 'S' (start) and check that an ADiP report comes back.
    Harmless for the board: it just recomputes with the data it already has."""
    ser.reset_input_buffer()
    ser.write(b"S")
    buf, t0 = "", _time.time()
    while _time.time() - t0 < timeout:
        chunk = ser.read(512)
        if chunk:
            buf += chunk.decode("ascii", errors="replace")
            if buf.rstrip().endswith("DONE"):
                break
    try:
        parse_report(buf)
        return True
    except ReportError:
        return False


# ---------------------------------------------------------------- self-test
def _self_test():
    import random
    rnd = random.Random(1)
    # known value from the README: C[0][0] in 8x8 mode with the default data
    B0 = unpack_weights(default_w_bytes(), 0)
    assert matmul(default_A(), B0)[0][0] == 1130
    # signed default data, row 0 in 8x8 mode (matches the simulation printout)
    B0s = unpack_weights(default_w_bytes(), 0, signed=True)
    assert matmul(default_A(), B0s)[0] == [106, -444, 30, 760]
    for trial in range(600):
        mode, sg = trial % 3, (trial // 3) % 2 == 1
        alo, ahi = a_range(sg)
        blo, bhi = b_range(mode, sg)
        A = [[rnd.randint(alo, ahi) for _ in range(N)] for _ in range(N)]
        B = [[rnd.randint(blo, bhi) for _ in range(b_cols(mode))] for _ in range(N)]
        packed = pack_weights(B, mode, sg)
        assert unpack_weights(packed, mode, sg) == B
        cmd = build_command(mode, A, B, sg)
        assert len(cmd) == 1 + 2 + 1 + 16 + 1 + 16 + 1 and cmd[2] == mode and cmd[-1:] == b"S"
        assert cmd[:1] == (b"I" if sg else b"U")
        noise = "ADiP MODE=8x8\r\nA matrix:\r\n  1\r\n"  # old partial output before
        rep = parse_report(noise + expected_report(mode, A, B, signed=sg))
        assert rep["mode"] == mode and rep["signed"] == sg and rep["A"] == A and rep["B"] == B
        assert rep["C"] == matmul(A, B) and rep["lat"] == 28
    # extreme values
    for mode in range(3):
        for sg in (False, True):
            (alo, ahi), (blo, bhi) = a_range(sg), b_range(mode, sg)
            for a, b in ((ahi, bhi), (alo, blo), (ahi, blo)):
                A = [[a] * N for _ in range(N)]
                B = [[b] * b_cols(mode) for _ in range(N)]
                assert parse_report(expected_report(mode, A, B, signed=sg))["C"] == matmul(A, B)
    # throughput: 8x8 mode = 64 MACs in 28 cycles
    macs, pc, mm = throughput(0, 28)
    assert macs == 64 and abs(pc - 64 / 28.0) < 1e-9 and abs(mm - 64 / 28.0 * 27) < 1e-9
    # cycle trace (animation model): 28 cycles, final C == A x B, every PE's lane math exact
    for trial in range(120):
        mode, sg = trial % 3, (trial // 3) % 2 == 1
        (alo, ahi), (blo, bhi) = a_range(sg), b_range(mode, sg)
        A = [[rnd.randint(alo, ahi) for _ in range(N)] for _ in range(N)]
        B = [[rnd.randint(blo, bhi) for _ in range(b_cols(mode))] for _ in range(N)]
        steps = cycle_trace(mode, A, B, sg)
        assert len(steps) - 2 == N * N + 3 * N == 28
        assert steps[-1]["C"] == matmul(A, B)
        wb = pack_weights(B, mode, sg)
        for s in steps:
            for row in s["pe"] or []:
                for p in row:
                    w = pe_weights(p["wbyte"], mode, sg)
                    assert combine(p["lanes"], mode) == [p["a"] * wk for wk in w]
        assert [pe_weights(b, mode, sg) for b in wb[:N]] == [B[0][c * lanes(mode):(c + 1) * lanes(mode)]
                                                             for c in range(N)]
    # tiling: per-tile FPGA reports put together must equal the full product
    runs = {8: (8, 4, 4), 16: (64, 32, 16)}
    for size in TILE_SIZES:
        for mode in range(3):
            assert len(tile_plan(size, mode)) == runs[size][mode]
            for sg in (False, True):
                (alo, ahi), (blo, bhi) = a_range(sg), b_range(mode, sg)
                tests = [default_square(size, mode, sg),
                         ([[rnd.randint(alo, ahi) for _ in range(size)] for _ in range(size)],
                          [[rnd.randint(blo, bhi) for _ in range(size)] for _ in range(size)]),
                         ([[alo] * size] * size, [[blo] * size] * size)]
                for A, B in tests:
                    C = [[0] * size for _ in range(size)]
                    for i, j, k in tile_plan(size, mode):
                        At, Bt = tile_operands(A, B, mode, i, j, k)
                        build_command(mode, At, Bt, sg)          # in range
                        rep = parse_report(expected_report(mode, At, Bt, signed=sg))
                        assert rep["A"] == At and rep["B"] == Bt
                        add_tile(C, rep["C"], mode, i, j)
                    assert C == matmul(A, B)
    print("adip_core self-test: PASS")


if __name__ == "__main__":
    _self_test()
