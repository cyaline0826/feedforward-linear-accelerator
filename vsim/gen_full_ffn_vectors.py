"""生成完整前馈（FC1 + GELU + FC2）的 W2 / b2 / expected 向量。

与 gen_layer_vectors.py 一样，直接调用《提交资料/软件数值模型.py》，
保证向量与 RTL 的定点合同一致：
    W2、b2 : s12 Q12
    expected: s16 Q10（FC2 输出）
"""
import argparse
import importlib
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
SUBMIT = HERE.parents[1] / "提交资料"
DATA = SUBMIT / "数据与结果"
REFERENCE = DATA / "浮点参考结果"
FFN_PARAMS = DATA / "完整前馈参数"

sys.path.insert(0, str(SUBMIT))
_model = importlib.import_module("软件数值模型")

def to_hex(int_values, kind):
    flat = np.asarray(int_values, dtype=np.int64).reshape(-1)
    bits = _model.BITS[kind]
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if flat.size and (flat.min() < lo or flat.max() > hi):
        raise ValueError(f"值超出 s{bits} 范围")
    return [f"{int(w):04x}" for w in (flat & 0xFFFF).astype(np.uint16)]

def write_hex(path, words):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="ascii", newline="\n") as h:
        h.write("\n".join(words) + "\n")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--sample", default="000000")
    p.add_argument("--layer", type=int, default=0)
    p.add_argument("--out", default=str(HERE / "o15_full_ffn_vectors"))
    a = p.parse_args()

    data = np.load(REFERENCE / f"sample_{a.sample}.npz")
    params = np.load(REFERENCE / "params" / f"layer_{a.layer:02d}.npz")
    x_f = data[f"layer_{a.layer:02d}_x"]
    w1_f, b1_f = params["weight"], params["bias"]

    p2 = np.load(FFN_PARAMS / f"layer_{a.layer:02d}.npz")
    w2_f, b2_f = p2["weight"], p2["bias"]

    x_q, cx = _model.encode(x_f, "x")
    w1_q, cw1 = _model.encode(w1_f, "weight")
    b1_q, cb1 = _model.encode(b1_f, "bias")
    w2_q, cw2 = _model.encode(w2_f, "weight2")
    b2_q, cb2 = _model.encode(b2_f, "bias2")

    y_q, stats = _model.ffn(x_q, w1_q, b1_q, w2_q, b2_q)

    out = Path(a.out)
    write_hex(out / "weights2.hex", to_hex(w2_q, "weight2"))
    write_hex(out / "biases2.hex", to_hex(b2_q, "bias2"))
    write_hex(out / "expected.hex", to_hex(y_q, "z"))

    write_hex(out / "weight.hex", to_hex(w1_q, "weight"))
    write_hex(out / "bias.hex", to_hex(b1_q, "bias"))
    write_hex(out / "x.hex", to_hex(x_q, "x"))

    clips = {"x": cx, "weight": cw1, "bias": cb1, "weight2": cw2, "bias2": cb2}
    clips.update(stats)
    print(f"sample_{a.sample} layer_{a.layer:02d} -> {out}")
    print("  weights2=16384 biases2=64 expected=6336")
    print("  削顶/溢出:", clips)
    assert clips["fc1_output_saturation"] == 0 and clips["fc2_output_saturation"] == 0

if __name__ == "__main__":
    main()
