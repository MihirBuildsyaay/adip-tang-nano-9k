#!/usr/bin/env python3
"""Golden model + cycle-accurate model of the ADiP-style systolic array.

Usage:  python3 golden_model.py [N] [signed]     (default N=4, unsigned)

Prints, for each precision mode, the expected UART output of the FPGA design
(same format as uart_report.v) and cross-checks the cycle-level dataflow
(2-bit chunk multipliers, skew, column accumulation, shared shifter) against a
plain matrix multiplication. With "signed", A is INT8 and B is INT8 / INT4 /
INT2 two's complement (the FPGA's 'I' command).
"""
import sys

N = int(sys.argv[1]) if len(sys.argv) > 1 else 4
SIGNED = len(sys.argv) > 2 and sys.argv[2].lower().startswith("s")

# Default memory contents (must match input_memory.v / weight_memory.v reset values)
A_BYTES = [[(r * N + c + 1) & 0xFF for c in range(N)] for r in range(N)]
W = [[(73 * (r * N + c) + 41) & 0xFF for c in range(N)] for r in range(N)]


def sx(v, bits, signed=True):
    """Interpret the low `bits` of v as unsigned or two's complement."""
    v &= (1 << bits) - 1
    return v - (1 << bits) if signed and v >> (bits - 1) else v


def a_val(byte):
    return sx(byte, 8, SIGNED)


A = [[a_val(b) for b in row] for row in A_BYTES]


def signed_chunks(mode):
    """w_s: which 2-bit weight chunks are the signed top chunk of a weight."""
    if not SIGNED:
        return [False] * 4
    return [[False, False, False, True], [False, True, False, True], [True] * 4][mode]


def lane(xbyte, wbyte, j, mode):
    """Lane j of reconfigurable_multiplier.v: sum_i x_i * w_j << 2i (2-bit chunks)."""
    wj = sx(wbyte >> (2 * j), 2, signed_chunks(mode)[j])
    return sum(sx(xbyte >> (2 * i), 2, SIGNED and i == 3) * wj << (2 * i) for i in range(4))


def logical_weights(mode):
    """Expand packed weight bytes into the logical weight matrix B (N x N*n)."""
    n, bits = 1 << mode, 8 >> mode
    return [[sx(W[r][c] >> (bits * k), bits, SIGNED) for c in range(N) for k in range(n)]
            for r in range(N)]


def plain_matmul(A, B):
    return [[sum(A[m][k] * B[k][j] for k in range(len(B))) for j in range(len(B[0]))]
            for m in range(len(A))]


def cycle_model(mode):
    """Bit/cycle-level model of the RTL (weight stationary, skewed inputs)."""
    a_reg = [[0] * N for _ in range(N)]                 # a_out registers of each PE
    ps = [[[0] * 4 for _ in range(N)] for _ in range(N)]  # psum_out regs [r][c][lane]
    out = {}                                            # (m, c) -> 4 slots
    last = 3 * N - 2
    for cnt in range(0, last + 1):
        # combinational inputs this cycle
        a_in_edge = [A_BYTES[cnt - r][r] if 0 <= cnt - r < N else 0 for r in range(N)]
        # capture (uses register values visible during this cycle)
        for c in range(N):
            m = cnt - N - c
            if 0 <= m < N:
                L = ps[N - 1][c]
                if mode == 0:
                    s = [L[0] + (L[1] << 2) + (L[2] << 4) + (L[3] << 6), 0, 0, 0]
                elif mode == 1:
                    s = [L[0] + (L[1] << 2), L[2] + (L[3] << 2), 0, 0]
                else:
                    s = list(L)
                out[(m, c)] = s
        # clock edge: compute next register state
        new_a = [[0] * N for _ in range(N)]
        new_ps = [[[0] * 4 for _ in range(N)] for _ in range(N)]
        for r in range(N):
            for c in range(N):
                a_in = a_in_edge[r] if c == 0 else a_reg[r][c - 1]
                new_a[r][c] = a_in
                for j in range(4):
                    top = ps[r - 1][c][j] if r > 0 else 0
                    new_ps[r][c][j] = top + lane(a_in, W[r][c], j, mode)
        a_reg, ps = new_a, new_ps
    n = 1 << mode
    C = [[out[(m, j // n)][j % n] for j in range(N * n)] for m in range(N)]
    return C


def uart_text(mode, C, lat):
    """Exact text printed by uart_report.v (decimal, right-aligned)."""
    m = "842"[mode]
    wa, wb, wc = (3, 3, 6) if mode == 0 else (3, 2, 5) if mode == 1 else (3, 1, 4)
    if SIGNED:                          # one column wider for the '-'
        wa, wb, wc = wa + 1, wb + 1, wc + 1

    def rows(M, w):
        return "".join(" ".join(str(v).rjust(w) for v in r) + "\r\n" for r in M)
    s = "ADiP MODE=8x%s%s\r\n" % (m, " SIGNED" if SIGNED else "")
    s += "A matrix:\r\n" + rows(A, wa)
    s += "\r\nB matrix (%s-bit):\r\n" % m + rows(logical_weights(mode), wb)
    s += "\r\nC = A x B:\r\n" + rows(C, wc)
    s += "\r\nLAT=0x%03X cycles\r\nDONE\r\n\r\n" % lat
    return s


if __name__ == "__main__":
    lat = N * N + (3 * N - 1) + 1
    print("%s arithmetic, N = %d\n" % ("Signed INT8" if SIGNED else "Unsigned", N))
    for mode in range(3):
        B = logical_weights(mode)
        ref = plain_matmul(A, B)
        got = cycle_model(mode)
        assert ref == got, "MISMATCH in mode %d" % mode
        print("mode %d (8x%s): cycle model == plain A*B   [C is %dx%d]" %
              (mode, "842"[mode], N, N << mode))
    print("\nLatency START->DONE = %d cycles (0x%03X)\n" % (lat, lat))
    for mode in range(3):
        print("=" * 8, "expected UART output, mode", mode, "=" * 8)
        print(uart_text(mode, cycle_model(mode), lat).replace("\r", ""))
