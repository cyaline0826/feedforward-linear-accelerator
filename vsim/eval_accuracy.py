"""逐层 NRMSE 评测：量化数值模型 vs 浮点参考，512 条验证样本 × 12 层。

用法（在仓库根目录）：
    python vsim/eval_accuracy.py
    python vsim/eval_accuracy.py --samples 512 --layers 12

口径：
    对每个样本、每一层，y_float = x_f @ w_f + b_f（浮点），
    y_q = 软件数值模型.fc1(encode(x), encode(w), encode(b))（整数，s16 Q10），
    y_dec = y_q / 1024（反量化），
    NRMSE = ||y_dec - y_float||_2 / ||y_float||_2。
    报每层最大值与 12 层总最大值。
"""
import argparse
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SUBMISSION = ROOT.parent / "提交资料"
REFERENCE = SUBMISSION / "数据与结果" / "浮点参考结果"

def load_model():
    spec = importlib.util.spec_from_file_location(
        "num_model", SUBMISSION / "软件数值模型.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["num_model"] = module
    spec.loader.exec_module(module)
    return module

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=512)
    ap.add_argument("--layers", type=int, default=12)
    ap.add_argument("--json", default="")
    ap.add_argument("--csv", default="")
    args = ap.parse_args()

    model = load_model()
    per_layer = {}
    rows = []
    worst = (0.0, -1, -1)

    params = []
    for layer in range(args.layers):
        data = np.load(REFERENCE / "params" / f"layer_{layer:02d}.npz")
        params.append((data["weight"].astype(np.float64),
                       data["bias"].astype(np.float64)))

    for index in range(args.samples):
        path = REFERENCE / f"sample_{index:06d}.npz"
        if not path.exists():
            break
        sample = np.load(path)
        for layer in range(args.layers):
            key = f"layer_{layer:02d}_x"
            if key not in sample:
                continue
            x_f = sample[key].astype(np.float64)
            w_f, b_f = params[layer]

            ref_key = f"layer_{layer:02d}_y"
            y_f = (sample[ref_key].astype(np.float64)
                   if ref_key in sample else x_f @ w_f + b_f)

            x_q, _ = model.encode(x_f, "x")
            w_q, _ = model.encode(w_f, "weight")
            b_q, _ = model.encode(b_f, "bias")
            y_q, _ = model.fc1(x_q, w_q, b_q)
            y_dec = np.asarray(y_q, dtype=np.float64) / 1024.0

            denom = np.linalg.norm(y_f)
            err = np.linalg.norm(y_dec - y_f)
            nrms = float(err / denom) if denom > 0 else 0.0

            rows.append((index, layer, nrms))
            if nrms > per_layer.get(layer, 0.0):
                per_layer[layer] = nrms
            if nrms > worst[0]:
                worst = (nrms, index, layer)

    print(f"样本数 {args.samples}，层数 {args.layers}")
    for layer in range(args.layers):
        if layer in per_layer:
            print(f"  layer_{layer:02d} 最大 NRMSE = {per_layer[layer] * 100:.4f}%")
    print(f"12 层总最大 NRMSE = {worst[0] * 100:.4f}%"
          f"（sample_{worst[1]:06d}, layer_{worst[2]:02d}）")
    if args.csv:
        with open(args.csv, "w", encoding="ascii", newline="\n") as handle:
            handle.write("sample,layer,nrmse_pct\n")
            for index, layer, value in rows:
                handle.write(f"{index},{layer},{value * 100:.6f}\n")
    if args.json:
        Path(args.json).write_text(json.dumps({
            "samples": args.samples,
            "layers": args.layers,
            "per_layer_max_pct": {k: v * 100 for k, v in per_layer.items()},
            "overall_max_pct": worst[0] * 100,
            "worst_sample": worst[1],
            "worst_layer": worst[2],
        }, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0

if __name__ == "__main__":
    sys.exit(main())
