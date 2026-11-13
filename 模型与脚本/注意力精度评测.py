"""单头注意力真实参数精度评测（本设计格式 x Q7 / QK Q6 / score Q10）。

用法：
    python 注意力精度评测.py [--npz 路径]

输出：模块级对照 NRMSE、削顶数、饱和数，以及各阶段量程。
"""
import argparse
from pathlib import Path

import numpy as np

X_FRAC, X_BITS = 7, 12          # 输入 s12 Q7，范围 ±16
W_FRAC, W_BITS = 12, 12         # 权重 s12 Q12
QK_FRAC, QK_BITS = 6, 12        # Q/K/V s12 Q6，范围 ±32
S_FRAC, S_BITS = 10, 16         # 分数 s16 Q10，范围 ±32
P_FRAC = 15                     # 概率 Q15，每行和 32768
C_FRAC, C_BITS = 8, 12          # 上下文 s12 Q8
O_FRAC, O_BITS = 8, 12          # 输出 s12 Q8

LUT = np.array([32768, 28918, 25520, 22521, 19875, 17539, 15479, 13660, 12055, 10638, 9388,
                8285, 7312, 6452, 5694, 5025, 4435, 3914, 3454, 3048, 2690, 2374, 2095, 1849,
                1631, 1440, 1271, 1121, 990, 873, 771, 680, 600, 530, 468, 414, 366, 323, 286,
                253, 223, 198, 175, 155, 137, 121, 107, 95, 84, 74, 66, 58, 52, 46, 41, 36, 32,
                28, 25, 22, 20, 17, 15, 14], dtype=np.int64)

DEFAULT = Path(__file__).resolve().parent / "attn_layer0.npz"
KEYS = {
    "Wq": "kws_transformer_transformer_block_multi_head_self_attention_dense_1_kernel_0",
    "Wk": "kws_transformer_transformer_block_multi_head_self_attention_dense_2_kernel_0",
    "Wv": "kws_transformer_transformer_block_multi_head_self_attention_dense_3_kernel_0",
    "Wo": "kws_transformer_transformer_block_multi_head_self_attention_dense_4_kernel_0",
    "bo": "kws_transformer_transformer_block_multi_head_self_attention_dense_4_bias_0",
}


def enc(v, frac, bits):
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    s = v * (1 << frac)
    r = np.copysign(np.floor(np.abs(s) + 0.5), s)
    clip = int(np.count_nonzero((r < lo) | (r > hi)))
    return np.clip(r, lo, hi).astype(np.int64), clip


def rnd(v, shift, bits):
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    r = (np.abs(v).astype(np.int64) + (1 << (shift - 1))) >> shift
    r = np.where(v < 0, -r, r)
    sat = int(np.count_nonzero((r < lo) | (r > hi)))
    return np.clip(r, lo, hi), sat


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--npz", type=Path, default=DEFAULT)
    a = ap.parse_args()

    d = np.load(str(a.npz))
    x_f = d["input"].astype(np.float64)
    ref = d["reference"].astype(np.float64)
    Wq, Wk, Wv = (d[KEYS[k]].astype(np.float64) for k in ("Wq", "Wk", "Wv"))
    Wo, bo = (d[KEYS[k]].astype(np.float64) for k in ("Wo", "bo"))

    xq, cx = enc(x_f, X_FRAC, X_BITS)
    wq_, _ = enc(Wq, W_FRAC, W_BITS)
    wk_, _ = enc(Wk, W_FRAC, W_BITS)
    wv_, _ = enc(Wv, W_FRAC, W_BITS)
    wo_, _ = enc(Wo, W_FRAC, W_BITS)
    bo_, cb = enc(bo, W_FRAC, W_BITS)

    Q, _ = rnd(xq @ wq_, X_FRAC + W_FRAC - QK_FRAC, QK_BITS)
    K, _ = rnd(xq @ wk_, X_FRAC + W_FRAC - QK_FRAC, QK_BITS)
    V, _ = rnd(xq @ wv_, X_FRAC + W_FRAC - QK_FRAC, QK_BITS)
    S, s_sat = rnd(Q @ K.T, 2 * QK_FRAC + 3 - S_FRAC, S_BITS)

    P = np.zeros((99, 99), dtype=np.int64)
    for r in range(99):
        row = S[r]
        mx, mxc = row.max(), int(np.argmax(row))
        idx = np.clip((mx - row) >> (S_FRAC - 3), 0, 63)
        e = LUT[idx]
        tot = e.sum()
        for c in range(99):
            if c != mxc:
                P[r, c] = (e[c] * 32768) // tot
        P[r, mxc] = 32768 - P[r].sum()

    C, c_sat = rnd(P @ V, P_FRAC + QK_FRAC - C_FRAC, C_BITS)
    acc_out = C @ wo_ + (bo_ << 8)
    O, o_sat = rnd(acc_out, O_FRAC + W_FRAC - O_FRAC, O_BITS)
    out = O.astype(np.float64) / (1 << O_FRAC)
    nrms = float(np.linalg.norm(out - ref) / np.linalg.norm(ref)) * 100.0
    Qf, Kf, Vf = x_f @ Wq, x_f @ Wk, x_f @ Wv
    Sf = (Qf @ Kf.T) / 8.0
    Sf -= Sf.max(axis=1, keepdims=True)
    Ef = np.exp(Sf)
    Of = ((Ef / Ef.sum(axis=1, keepdims=True)) @ Vf) @ Wo + bo
    ref_nrms = float(np.linalg.norm(Of - ref) / np.linalg.norm(ref)) * 100.0

    print("npz =", a.npz)
    print("format: x Q%d, Q/K/V Q%d, score Q%d, prob Q%d, ctx/out Q%d"
          % (X_FRAC, QK_FRAC, S_FRAC, P_FRAC, C_FRAC))
    print("input abs max     = %.4f   (Q%d range +-%.1f)" % (np.abs(x_f).max(), X_FRAC, 2 ** (X_BITS - 1 - X_FRAC)))
    print("clips  x = %d" % cx)
    print("abs max  Q %d  K %d  V %d   (Q%d limit %d)"
          % (np.abs(Q).max(), np.abs(K).max(), np.abs(V).max(), QK_FRAC, (1 << (QK_BITS - 1)) - 1))
    print("abs max score = %d   saturations = %d" % (np.abs(S).max(), s_sat))
    print("saturations ctx = %d  out = %d" % (c_sat, o_sat))
    print("float recompute vs TF reference = %.6f%%" % ref_nrms)
    print("MODULE-LEVEL NRMSE (fixed point vs float reference) = %.4f%%" % nrms)


if __name__ == "__main__":
    main()