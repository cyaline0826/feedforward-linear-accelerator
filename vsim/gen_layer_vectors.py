"""生成 12 层 FC1 的硬件向量（W1 / b1 / X / 期望整数 Y）。

用途
----
赛题的吞吐量测试要求"覆盖 12 层参数的 12 次线性计算"，每个任务从参数与
输入开始装载计时。此前仓库里只有 layer 0 一套向量，无法跑 12 个任务。

本脚本直接调用《提交资料/软件数值模型.py》里的 encode / fc1，保证生成的
向量与已提交的软件数值模型逐位一致，不重新实现量化规则。

用法
----
    # 1) 自校验：复现已提交的向量，逐字节比对
    python gen_layer_vectors.py --check

    # 2) 生成某一层的向量
    python gen_layer_vectors.py --sample 000030 --layer 3 --out ./layer_03

    # 3) 一次生成 12 层（12 任务吞吐测量用）
    python gen_layer_vectors.py --sample 000030 --all --out ./task12

关于样本编号
------------
仓库里已提交的 `vsim/o15_fc1_vectors/` 对应的是 **sample_000030 的 layer 0**，
不是 sample_000000。这是遍历 512 个样本、按编码后的 X 逐字比对唯一命中得出的
结论（weights/biases 只与层有关，所以任何样本都能对上，只有 X 能定样本）。
因此 12 层向量统一用 sample_000030 生成，保证与既有 golden 同源可比。

输出文件（每行一个 4 位十六进制 16 位字，供 $readmemh 使用）
    layer_LL_weight.hex   16384 字  W1，k*256+n
    layer_LL_bias.hex       256 字  b1
    layer_LL_x.hex         6336 字  X，m*64+k
    layer_LL_expected.hex 25344 字  软件数值模型的整数 Y
"""

import argparse
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
SUBMISSION = REPO.parent / "提交资料"
REFERENCE = SUBMISSION / "数据与结果" / "浮点参考结果"
VECTORS_DIR = REPO / "vsim" / "o15_fc1_vectors"

sys.path.insert(0, str(SUBMISSION))
import importlib

_model = importlib.import_module("软件数值模型")

def to_hex_words(int_values, kind="y"):
    """整数 -> 符号扩展到 16 位的 4 位十六进制字符串序列。

    范围按软件数值模型的 BITS 判定：激活/权重/偏置是 s12，输出是 s16。
    """
    flat = np.asarray(int_values, dtype=np.int64).reshape(-1)
    bits = getattr(_model, "BITS", {}).get(kind, 12)
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if flat.size and (flat.min() < lo or flat.max() > hi):
        raise ValueError(f"值超出 s{bits} 范围，不能写入 16 位字")
    words = (flat & 0xFFFF).astype(np.uint16)
    return [f"{int(w):04x}" for w in words]

def write_hex(path, words):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="ascii", newline="\n") as handle:
        handle.write("\n".join(words))
        handle.write("\n")
    return path

def load_layer(sample, layer):
    """返回 (x_float, weight_float, bias_float)，形状与软件模型一致。"""
    params = np.load(REFERENCE / "params" / f"layer_{layer:02d}.npz")
    data = np.load(REFERENCE / f"sample_{sample}.npz")
    x = data[f"layer_{layer:02d}_x"]
    weight = params["weight"]
    bias = params["bias"]
    return x, weight, bias

def build_layer(sample, layer):
    """量化一层参数与输入，并算出软件数值模型的整数输出。"""
    x_f, w_f, b_f = load_layer(sample, layer)
    x_q, x_clip = _model.encode(x_f, "x")
    w_q, w_clip = _model.encode(w_f, "weight")
    b_q, b_clip = _model.encode(b_f, "bias")
    y_q, stats = _model.fc1(x_q, w_q, b_q)
    clips = {"x": x_clip, "weight": w_clip, "bias": b_clip,
             "output_saturation": stats["output_saturation"],
             "accumulator_overflow": stats["accumulator_overflow"]}
    return {"x": x_q, "weight": w_q, "bias": b_q, "y": y_q}, clips

def emit(prefix, tensors, out_dir):
    files = {}

    for name, key in (("weight", "weight"), ("bias", "bias"),
                      ("x", "x"), ("expected", "y")):
        path = Path(out_dir) / f"{prefix}_{name}.hex"
        files[name] = write_hex(path, to_hex_words(tensors[key], key))
    return files

def read_words(path):
    with open(path, "r", encoding="ascii") as handle:
        return [line.strip().lower() for line in handle if line.strip()]

def cmd_check(args):
    """复现已提交的向量并逐字节比对。"""

    tensors, clips = build_layer(args.check_sample, 0)
    ok = True
    pairs = (("weight", "weights.hex"), ("bias", "biases.hex"),
             ("x", "inputs.hex"), ("y", "expected.hex"))
    for key, filename in pairs:
        expected_path = VECTORS_DIR / filename
        if not expected_path.exists():
            print(f"SKIP  {filename}（仓库中不存在）")
            ok = False
            continue
        mine = to_hex_words(tensors[key])
        theirs = read_words(expected_path)
        if len(mine) != len(theirs):
            print(f"FAIL  {filename}: 字数 {len(mine)} != {len(theirs)}")
            ok = False
            continue
        diff = [i for i, (a, b) in enumerate(zip(mine, theirs)) if a != b]
        if diff:
            print(f"FAIL  {filename}: {len(diff)} 个字不同，首个 index {diff[0]} "
                  f"本机 {mine[diff[0]]} 仓库 {theirs[diff[0]]}")
            ok = False
        else:
            print(f"OK    {filename}: {len(mine)} 字逐字节一致")
    print(f"sample={args.check_sample} layer=0 量化统计: {clips}")
    return 0 if ok else 1

def cmd_generate(args):
    layers = range(12) if args.all else [args.layer]
    out_dir = Path(args.out)
    total_clips = {}
    for layer in layers:
        tensors, clips = build_layer(args.sample, layer)
        files = emit(f"layer_{layer:02d}", tensors, out_dir)
        for key, value in clips.items():
            total_clips[key] = total_clips.get(key, 0) + int(value)
        sizes = " ".join(f"{k}={len(read_words(v))}" for k, v in files.items())
        print(f"layer_{layer:02d}  {sizes}")
    print(f"输出目录: {out_dir.resolve()}")
    print(f"12 层累计量化统计: {total_clips}")
    if total_clips.get("accumulator_overflow", 0):
        print("WARNING 出现累加器溢出，说明输入超出 s12 设计范围，结果不可用")
    return 0

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true",
                        help="复现已提交的向量并逐字节比对")
    parser.add_argument("--check-sample", default="000030",
                        help="自校验用的样本编号，默认 000030（已提交向量即此样本）")
    parser.add_argument("--sample", default="000030", help="样本编号，默认 000030")
    parser.add_argument("--layer", type=int, default=0, help="单层编号 0..11")
    parser.add_argument("--all", action="store_true", help="生成全部 12 层")
    parser.add_argument("--out", default=".", help="输出目录")
    args = parser.parse_args()
    if args.check:
        return cmd_check(args)
    return cmd_generate(args)

if __name__ == "__main__":
    sys.exit(main())
