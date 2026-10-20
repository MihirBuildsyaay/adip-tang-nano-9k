# Signed INT8 in the ADiP Tang Nano 9K design

## 1. What "signed" means

An 8-bit byte has 256 patterns. There are two ways to read them:

| Reading | Range | `0x80` (1000 0000) | `0xFF` (1111 1111) |
|---|---|---|---|
| Unsigned (UINT8) | 0 … 255 | 128 | 255 |
| **Signed (INT8)** | **−128 … 127** | **−128** | **−1** |

Signed numbers use **two's complement**. The top bit counts as **negative**:

```
bit:      b7    b6   b5   b4   b3  b2  b1  b0
weight: -128   +64  +32  +16   +8  +4  +2  +1
```

Example: `1011 1011` = −128 + 32 + 16 + 8 + 2 + 1 = **−69**. Read as unsigned, the same byte is 187.

The memory still holds the same bytes. Only the meaning of the top bit changes, and that's why one `I`/`U` flag is enough to switch modes.

## 2. Why it matters (neural networks)

Quantized AI models store weights and activations as INT8, because weights are often negative. Unsigned-only hardware can't run those models directly. With signed support, the array computes real `A × B` products with negative numbers.

## 3. The three precision modes in signed mode

The same weight byte is split differently, and **each weight's top bit is negative**:

| Mode | Weights per byte | Unsigned range | Signed range |
|---|---|---|---|
| 8×8 | 1 × 8-bit | 0…255 | −128…127 (INT8) |
| 8×4 | 2 × 4-bit | 0…15 | −8…7 (INT4) |
| 8×2 | 4 × 2-bit | 0…3 | −2…1 (INT2) |

Example byte `0xBB` = `1011 1011`:
- **8×8:** −69
- **8×4:** `1011`, `1011` → −5, −5
- **8×2:** `10`, `11`, `10`, `11` → −2, −1, −2, −1

## 4. How the hardware does it (the ADiP trick)

The PE has no 8×8 multiplier. It has **sixteen 2-bit × 2-bit multipliers**. An 8-bit number is split into four 2-bit chunks:

```
x = x3·64 + x2·16 + x1·4 + x0
```

In two's complement, **only the top chunk carries the sign**. A 2-bit chunk read as signed is −2…1, and read as unsigned it's 0…3. So the change is small: every 2-bit multiplier got a **"signed chunk" flag** (`rtl/multiplier_2bit.v`):

```verilog
wire signed [2:0] ae = {a_s & a[1], a};   // sign-extend only if a_s = 1
wire signed [2:0] be = {b_s & b[1], b};
assign p = ae * be;                        // -6 .. 9
```

Which chunks are flagged signed:
- **A (activation):** chunk x3, the top chunk.
- **Weights:** the top chunk of *each weight*, which depends on the mode (`rtl/adip_top.v`):

```verilog
wire [3:0] w_s = !sign_q          ? 4'b0000 :   // unsigned: nothing signed
                 (mode_q == 2'd0) ? 4'b1000 :   // 8x8: w3 is the top of the weight
                 (mode_q == 2'd1) ? 4'b1010 :   // 8x4: w3 and w1 are tops of two weights
                                    4'b1111;    // 8x2: every chunk is its own weight
```

Everything after the multipliers (lane adders, accumulators, the shared shifter) just does **two's complement addition**. Addition works the same for signed and unsigned numbers once the values are sign-extended.

### Worked example: −69 × 3 in 8×8 mode

x = 3 = `00 00 00 11`, w = −69 = `10 11 10 11` → chunks w3..w0 = **−2** (signed top), 3, 2, 3

| Lane | x × wⱼ | Shift | Contribution |
|---|---|---|---|
| w0 = 3 | 9 | ×1 | 9 |
| w1 = 2 | 6 | ×4 | 24 |
| w2 = 3 | 9 | ×16 | 144 |
| w3 = −2 | −6 | ×64 | −384 |
| **Sum** | | | **−207** ✓ (= 3 × −69) |

## 5. Bit widths had to grow by 1

Signed results need room for the sign:

| Signal | Before | Now |
|---|---|---|
| Lane product | 10 bits | 11 bits signed |
| Accumulator (PSUM_W) | 12 | 13 |
| Result C (OUT_W) | 18 | 19 |

Largest signed values for N=4: (−128)(−128)·4 = **+65536** and 127·(−128)·4 = **−65024**. Both are tested in phase 7 and phase 8 of `tb/tb_adip_top.v`.

The cost was about 2,200 more LUTs (70% → 95% of the GW1NR-9):

| Design | LUT4 | FF | Fmax (after routing) |
|---|---|---|---|
| Unsigned only | 6064 / 8640 (70%) | 1960 / 6480 (30%) | 59.4 MHz |
| Unsigned + signed INT8 | 8230 / 8640 (95%) | 2059 / 6480 (31%) | 69.6 MHz |

## 6. Printing negatives

`rtl/uart_report.v` used to convert the value straight to decimal. Now it:
1. checks the sign bit,
2. converts the **magnitude** (|value|) to decimal,
3. prints `-` just before the first digit,
4. makes every column one character wider.

```
ADiP MODE=8x8 SIGNED
B matrix (8-bit):
  41  114  -69    4      ← byte 187 is now -69
C = A x B:
    106    -444      30     760
```

## 7. Using it

- **App:** tick **Signed (INT8)**, type negative numbers, then Run.
- **Terminal:** send `I` for signed or `U` for unsigned, then `S` to start. Power-up default is unsigned.
- **Simulation:** `python sim/golden_model.py 4 signed` prints the expected output.
