"""FC1 and complete FFN integer model: Q8 activations, Q12 weights, s16 Q10 output, signed 32-bit accumulator."""
from pathlib import Path
import math
import numpy as np

# 数值格式 v2：
#   激活 x、GELU 输出 g：s12 Q8   （范围 ±8，步长 1/256）
#   权重 w、w2、偏置 b、b2：s12 Q12（范围 ±0.4998，步长 1/4096）
#   输出 y、z：s16 Q10           （范围 ±32，步长 1/1024）
# 乘积的小数位为 8 + 12 = 20；偏置 Q12 左移 8 位后同样是 Q20；
# 输出 Q10 由累加器右移 10 位（半远离零舍入，偏移 2^9 = 512）得到。
FORMAT = 's12q8_wq12_out_s16q10_acc32_v2'
SHAPES = {'x': (99, 64), 'weight': (64, 256), 'bias': (256,), 'y': (99, 256),
          'g': (99, 256), 'weight2': (256, 64), 'bias2': (64,), 'z': (99, 64)}
FRAC = {'x': 8, 'weight': 12, 'bias': 12, 'y': 10, 'g': 8,
        'weight2': 12, 'bias2': 12, 'z': 10}
BITS = {'x': 12, 'weight': 12, 'bias': 12, 'y': 16, 'g': 12,
        'weight2': 12, 'bias2': 12, 'z': 16}
ACC_FRAC = 20                        # 乘积小数位 = FRAC['x'] + FRAC['weight']
OUT_SHIFT = ACC_FRAC - FRAC['y']     # = 10
OUT_ROUND = 1 << (OUT_SHIFT - 1)     # = 512


def _limit(kind):
    bits = BITS[kind]
    return -(1 << (bits - 1)), (1 << (bits - 1)) - 1


def encode(values, kind):
    values = np.asarray(values, dtype=np.float64)
    if values.shape != SHAPES[kind] or not np.isfinite(values).all():
        raise ValueError('Invalid finite tensor shape for ' + kind)
    lo, hi = _limit(kind)
    scaled = values * (1 << FRAC[kind])
    rounded = np.copysign(np.floor(np.abs(scaled) + 0.5), scaled)
    clips = int(np.count_nonzero((rounded < lo) | (rounded > hi)))
    return np.clip(rounded, lo, hi).astype(np.int64), clips


def checked(values, kind):
    lo, hi = _limit(kind)
    values = np.asarray(values)
    if (values.shape != SHAPES[kind] or values.dtype.kind not in 'iu'
            or np.any(values < lo) or np.any(values > hi)):
        raise ValueError('Invalid integer tensor for ' + kind)
    return values.astype(np.int64)


def decode(values, kind):
    return checked(values, kind).astype(np.float64) / (1 << FRAC[kind])


def _round_out(acc, kind):
    """累加器（Q20）→ 输出（s16 Q10），半远离零舍入后饱和。"""
    lo, hi = _limit(kind)
    rounded = (np.abs(acc) + OUT_ROUND) >> OUT_SHIFT
    rounded = np.where(acc < 0, -rounded, rounded)
    clips = int(np.count_nonzero((rounded < lo) | (rounded > hi)))
    return np.clip(rounded, lo, hi), clips


def fc1(x, weight, bias):
    x, weight, bias = (checked(v, k) for v, k in
                       ((x, 'x'), (weight, 'weight'), (bias, 'bias')))
    # Bias enters at Q20 (Q12 << 8); visit k=0..63 without intermediate rounding.
    acc = np.broadcast_to(bias << 8, SHAPES['y']).copy()
    overflows = 0
    for k in range(64):
        acc += x[:, k:k+1] * weight[k:k+1, :]
        overflows += int(np.count_nonzero((acc < -(1 << 31)) | (acc >= (1 << 31))))
        acc = ((acc + (1 << 31)) % (1 << 32)) - (1 << 31)
    out, clips = _round_out(acc, 'y')
    return out, {'accumulator_overflow': overflows, 'output_saturation': clips}


def to_gelu_input(y_q10):
    """输出（s16 Q10）截断到 GELU 查表所需的 s12 Q8，对应 RTL 的 rounded_y[15:2]。"""
    return checked(checked(y_q10, 'y') >> 2, 'g')


def gelu(values):
    values = np.asarray(values)
    lo, hi = _limit('g')
    if values.dtype.kind not in 'iu' or np.any(values < lo) or np.any(values > hi):
        raise ValueError('Invalid signed 12-bit GELU input')
    # x*Phi(x) = max(x,0) - abs(x)*Phi(-abs(x)); the correction fits six bits.
    correction = np.array([math.floor(i * .5 * math.erfc(i / (256 * math.sqrt(2))) + .5)
                           for i in range(1024)], dtype=np.int64)
    values = values.astype(np.int64)
    magnitude = np.abs(values)
    delta = np.where(magnitude < 1024, correction[np.minimum(magnitude, 1023)], 0)
    return np.maximum(values, 0) - delta


def fc2(activated, weight, bias):
    activated = checked(activated, 'g')
    weight, bias = checked(weight, 'weight2'), checked(bias, 'bias2')
    acc = np.broadcast_to(bias << 8, SHAPES['z']).copy()
    overflows = 0
    for k in range(256):
        acc += activated[:, k:k+1] * weight[k:k+1, :]
        overflows += int(np.count_nonzero((acc < -(1 << 31)) | (acc >= (1 << 31))))
        acc = ((acc + (1 << 31)) % (1 << 32)) - (1 << 31)
    out, clips = _round_out(acc, 'z')
    return out, {'accumulator_overflow': overflows, 'output_saturation': clips}


def ffn(x, weight, bias, weight2, bias2):
    hidden, first_stats = fc1(x, weight, bias)
    output, second_stats = fc2(gelu(to_gelu_input(hidden)), weight2, bias2)
    stats = {'fc1_' + key: value for key, value in first_stats.items()}
    stats.update({'fc2_' + key: value for key, value in second_stats.items()})
    return output, stats


def write_tensor(path, values, kind):
    values = checked(values, kind)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    values.astype('<i2').tofile(str(path))
    # One 16-bit word per line, suitable for $readmemh into [15:0].
    path.with_suffix('.hex').write_text(''.join('{:04x}\n'.format(int(v) & 65535)
                                               for v in values.flat), encoding='ascii')


def read_tensor(path, kind):
    path = Path(path)
    if path.stat().st_size != int(np.prod(SHAPES[kind])) * 2:
        raise ValueError('Incorrect binary length: ' + str(path))
    return checked(np.fromfile(str(path), dtype='<i2').reshape(SHAPES[kind]), kind)
