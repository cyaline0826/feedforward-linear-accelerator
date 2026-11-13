"""逐层 NRMSE 评测：量化数值模型 vs 浮点参考。

按赛题口径：同一层的全部样本先汇总误差平方和与参考平方和，再统一开方；
分母下限取 1e-8。输出同时给出实际参与评测的样本数。
"""
import argparse
import importlib.util
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
REFERENCE = ROOT / "数据与结果" / "浮点参考结果_1000"
MODEL = ROOT / "软件数值模型.py"


def load_model(path):
    spec = importlib.util.spec_from_file_location("model", str(path))
    module = importlib.util.module_from_spec(spec)
    sys.modules["model"] = module
    spec.loader.exec_module(module)
    return module


def load_params(reference, layers):
    params = []
    for index in range(layers):
        data = np.load(str(reference / "params" / ("layer_%02d.npz" % index)))
        params.append((data["weight"].astype(np.float64),
                       data["bias"].astype(np.float64)))
    return params


def evaluate(reference, model, samples, layers):
    params = load_params(reference, layers)
    error_sq = [0.0] * layers
    reference_sq = [0.0] * layers
    worst = [(0.0, -1)] * layers
    clips = 0
    used = 0
    for index in range(samples):
        path = reference / ("sample_%06d.npz" % index)
        if not path.exists():
            break
        used += 1
        data = np.load(str(path))
        for layer in range(layers):
            x = data["layer_%02d_x" % layer].astype(np.float64)
            weight, bias = params[layer]
            y_reference = data["layer_%02d_y" % layer].astype(np.float64)

            x_q, cx = model.encode(x, "x")
            w_q, cw = model.encode(weight, "weight")
            b_q, cb = model.encode(bias, "bias")
            y_q, stats = model.fc1(x_q, w_q, b_q)
            clips += cx + cw + cb + stats["output_saturation"]

            y = np.asarray(y_q, dtype=np.float64) / (1 << model.FRAC["y"])
            e2 = float(np.sum((y - y_reference) ** 2))
            r2 = float(np.sum(y_reference ** 2))
            error_sq[layer] += e2
            reference_sq[layer] += r2
            if e2 / max(r2, 1e-8) > worst[layer][0]:
                worst[layer] = (e2 / max(r2, 1e-8), index)
    return used, error_sq, reference_sq, worst, clips


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=1000)
    parser.add_argument("--layers", type=int, default=12)
    parser.add_argument("--reference", type=Path, default=REFERENCE)
    parser.add_argument("--model", type=Path, default=MODEL)
    args = parser.parse_args()

    model = load_model(args.model)
    used, error_sq, reference_sq, worst, clips = evaluate(
        args.reference, model, args.samples, args.layers)
    if used != args.samples:
        print('ERROR: only %d of %d samples found; result rejected'
              % (used, args.samples), file=sys.stderr)
        sys.exit(1)

    print("format =", model.FORMAT)
    print("samples requested =", args.samples, " evaluated =", used, " clips =", clips)
    maximum = 0.0
    for layer in range(args.layers):
        value = (error_sq[layer] / max(reference_sq[layer], 1e-8)) ** 0.5
        maximum = max(maximum, value)
        print("  layer_%02d aggregate NRMSE = %.4f%%   worst sample %.4f%% (sample_%06d)"
              % (layer, value * 100, worst[layer][0] ** 0.5 * 100, worst[layer][1]))
    total = (sum(error_sq) / max(sum(reference_sq), 1e-8)) ** 0.5
    print("OVERALL aggregate = %.4f%%   max layer aggregate = %.4f%%"
          % (total * 100, maximum * 100))


if __name__ == "__main__":
    main()
