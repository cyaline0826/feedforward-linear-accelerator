# 面向 E203 的 KWT-1 语音指令识别前馈线性计算加速器

2026 年全国大学生嵌入式芯片与系统设计竞赛·芯片设计赛道（本科生组）参赛作品源码。

本仓库包含RTL、验证平台与脚本，对应设计报告中所陈述的16 个乘法器（4 列 × 4 lane）冻结配置。E203 处理器内核、总线、外设等上游代码未收录，
请从 [riscv-mcu/e203_hbirdv2](https://github.com/riscv-mcu/e203_hbirdv2) 获取。

## 关键结果（SMIC 40 nm LL，TT / 1.10 V / 25 ℃，150 MHz）

| 指标 | 值 |
|---|---|
| 单任务周期 | 222,621 拍（1.484140 ms） |
| 吞吐 | 673.79 task/s |
| 加速器面积 | 0.432671 mm²（含接口逻辑 0.432897 mm²），占 2.25 mm² 预算 19.24% |
| 加速器 WNS | +0.603868 ns |
| 整芯片 | 2,757,282.2 µm²，WNS 0，timing_met = 1 |
| 功耗（B 口径） | 12.9378 mW / 19.2016 µJ 每任务 |
| 精度（1000 条验证样本 × 12 层） | 层聚合最大 0.1840%，总体 0.1470% |
| 完整前馈网络（选做） | 868,520 拍，6,336 个输出逐位一致 |
| 单头注意力（选做） | 22 个 SRAM 宏，0.649614 mm²，WNS +0.000088 ns，模型级对照 NRMSE 1.4874% |

## 目录结构

```
rtl/                 自研与改动的 RTL
  task1.v              长度为 64 的点积、偏置处理与数值转换
  task2.v              前馈线性加速器（4 列 × 4 lane = 16 MAC）
  task2_gelu.v         GELU 查表与第二线性层
  task4.v              单头注意力模块（22 个 SRAM 宏映射）
  t4_ram.v             4096/6336/9801/128 四种 SRAM 宏封装
  e203_task_smoke_mmio.v   加速器 MMIO 封装与主口装载引擎
  e203_subsys_mems.v   共享 SRAM 与加速器主口的仲裁（改动）
  e203_subsys_main.v   子系统连线（改动）
  e203_subsys_perips.v 外设端口（改动）
tb/
  tb_top.v             SoC 级测试平台（12 层任务、计时窗口与门控）
vsim/
  tb_task2_sram_functional.sv  FC1 / FFN 模块级回归（含三档写回反压）
  tb_attention_single_head.sv  单头注意力定向向量回归
  tb_t4_ram.sv         SRAM 宏封装时序回归
  gen_layer_vectors.py 12 层向量生成（与软件数值模型同源）
  gen_full_ffn_vectors.py  完整前馈向量生成
  eval_accuracy.py     精度评测（早期版本，赛题口径见 模型与脚本/精度评测.py）
  assemble_o15_firmware.py 固件镜像生成（纯 Python 汇编器）
  o15_task12_sram.S    SoC 任务固件（参数搬运 + 启动 + 读回）
syn/                  逻辑综合脚本（Design Compiler）
模型与脚本/
  软件数值模型.py        与 RTL 逐位一致的定点数值模型
  参数转换脚本.py        浮点→定点量化、打包与解码（六个子命令）
  精度评测.py           按赛题口径统计逐层 NRMSE
  注意力精度评测.py      单头注意力在真实 KWT 参数下的模型级对照
```

## 环境要求

| 用途 | 要求 |
|---|---|
| 仿真 | VCS Q-2020.03-SP2-6（或 ModelSim SE-64 10.1c 跑模块级） |
| 综合 | Design Compiler T-2022.03-SP5-5 + SMIC 40 nm LL 库 |
| 脚本 | Python 3.6+ 与 numpy（参数转换、精度评测） |
| 模型导出 | Python 3.8.20 / TensorFlow 2.4.0 / tensorflow_addons 0.12.1（仅生成浮点参考时需要） |

综合脚本通过环境变量 `SMIC40_LIB` 定位工艺库，缺省回退到工程内
`asic_smic40_task2/lib`：

```csh
setenv SMIC40_LIB <你的库目录>
dc_shell -f syn/dc_accel_area.tcl
```

## 复现流程

以下 8 步对应报告中引用的全部结果。每一步都给出命令与**预期输出**，便于逐项核对。
设工程根目录为 `$REPO`，固件镜像为 `$IMG`，向量目录为 `$VEC`。

### 第 0 步：准备

```csh
# 1) 取得上游 E203 工程（本仓库只含自研与改动部分）
git clone https://github.com/riscv-mcu/e203_hbirdv2.git
cd e203_hbirdv2
# 2) 覆盖本仓库的 rtl/ tb/ vsim/ syn/ 到对应目录
# 3) 指定工艺库（或把库放到 $REPO/asic_smic40_task2/lib）
setenv SMIC40_LIB /path/to/asic_smic40_task2/lib
```

### 第 1 步：生成浮点参考（可选，需 TF 环境）

仅当需要从原始音频重新导出参考时才执行；本仓库不附参考数据。

```csh
python export_kwt1_reference.py --data-dir ./data2 --split validation \
       --count 1000 --out ~/ref_val1000
```

预期：输出目录含 `sample_000000.npz … sample_000999.npz` 与 `params/layer_00.npz … layer_11.npz`。
环境要求 Python 3.8.20 / TensorFlow 2.4.0 / tensorflow_addons 0.12.1。

### 第 2 步：量化打包 + 向量生成 + 同源校验

```csh
python 模型与脚本/参数转换脚本.py convert --reference ~/ref_val1000 --out ~/enc
python vsim/gen_layer_vectors.py --sample 000030 --all --out $VEC
python vsim/gen_layer_vectors.py --check
```

预期：
- `convert` 输出 `CONVERTED 1000 samples; clips: {'weight': 0, 'bias': 0, 'x': 0}`；
- 向量目录含 12 组 `layer_XX_{weight,bias,x,expected}.hex`，每组分别为 16,384 / 256 / 6,336 / 25,344 行；
- `--check` 输出 4 行 OK（四类文件与原模型逐字节一致）。

### 第 3 步：模块级回归（FC1 三档反压 + 完整 FFN）

```csh
vcs -sverilog -top tb_task2_sram_functional \
    rtl/task1.v rtl/task2_gelu.v rtl/task2.v vsim/tb_task2_sram_functional.sv
./simv +BP=0 +WEIGHTS=$VEC/layer_00_weight.hex +BIASES=$VEC/layer_00_bias.hex \
       +INPUTS=$VEC/layer_00_x.hex +EXPECTED=$VEC/layer_00_expected.hex
./simv +BP=4 ... ; ./simv +BP=6 ...
```

预期：三档均打印 `TASK2_SRAM_FC1_PASS outputs=25344`；
`+FULL_FFN=1` 时打印 `TASK2_SRAM_FULL_FFN_PASS outputs=6336`。

### 第 4 步：SRAM 宏封装回归

```csh
vsim -c tb_t4_ram -do "run -all; quit -f"
```

预期：`T4RAM_TB_PASS`（4096 / 6336 / 9801 / 128 四种封装的读写与一拍延迟）。

### 第 5 步：SoC 级 12 层任务

```csh
python vsim/assemble_o15_firmware.py vsim/o15_task12_sram.S $IMG.verilog
cd vsim && make install && make compile SIM=vcs TASK2_SRAM_SIM=1
make run_test DUMPWAVE=0 SIM=vcs TASK2_SRAM_SIM=1 TESTCASE=$IMG \
     TEST_ARGS="+FC1_MMIO=1 +FC1_SRAM=1 +LAYER=0 \
     +WEIGHTS=$VEC/layer_00_weight.hex +BIASES=$VEC/layer_00_bias.hex \
     +INPUTS=$VEC/layer_00_x.hex +EXPECTED=$VEC/layer_00_expected.hex"
```

对 `+LAYER=0` 到 `+LAYER=11` 各跑一次。预期每层输出一行：

```
TASK12_SOC layer=<k> ctrl=... win_start=2650 win_end=225271 win_cycles=222621 pass=1
```

`win_cycles` 必须逐层相同（222,621），说明 12 层任务时序结构一致。

### 第 6 步：逻辑综合

```csh
dc_shell -f syn/dc_accel_area.tcl      # 加速器本体
dc_shell -f syn/dc_arb_area.tcl        # 接口仲裁逻辑
dc_shell -f syn/dc_soc_150m.tcl        # 整芯片
dc_shell -f syn/dc_attention_area.tcl  # 单头注意力
```

预期（SMIC 40 nm LL，TT / 1.10 V / 25 ℃，6.666667 ns）：

| 脚本 | 关键结果 |
|---|---|
| accel | 面积 0.432671 mm²、WNS +0.603868 ns、56 个宏 |
| arb | 111 个单元、4 个触发器、226.31 µm² |
| soc | 2,757,282.2 µm²、WNS 0、`timing_met=1` |
| attention | 0.649614 mm²、WNS +0.000088 ns、22 个宏 |

### 第 7 步：功耗

```csh
setenv SAIF /tmp/o15_R.saif        # 与第 5 步同窗口导出的 SAIF
setenv TASK_CYCLES 222621
dc_shell -f syn/dc_power.tcl
```

预期：B 口径 12.9378 mW / 19.2016 µJ 每任务，窗口比 1.0120（须落在 0.98–1.10）。

### 第 8 步：精度评测

```csh
python 模型与脚本/精度评测.py --samples 1000 --layers 12 --reference ~/ref_val1000
python 模型与脚本/注意力精度评测.py --npz <KWT 第 0 层注意力权重与输入>
```

预期：
- 精度：各层聚合 NRMSE 0.1233%—0.1840%（最大层 layer_06），总体 0.1470%，削顶计数 0；
- 注意力：输入最大 13.4642、无削顶、无饱和，模型级对照 NRMSE 1.4874%。

### 结果对照表

| 报告中的结论 | 由哪一步产出 |
|---|---|
| FC1 25,344 / FFN 6,336 逐位一致 | 第 3 步 |
| 12 层每层 222,621 拍 | 第 5 步 |
| 面积 0.432897 mm²、WNS +0.603868 ns | 第 6 步 |
| 12.9378 mW / 19.2016 µJ | 第 7 步 |
| 精度 0.1840% / 0.1470% | 第 8 步 |
| 注意力 1.4874% | 第 8 步 |

## 数值格式（v2）

| 量 | 格式 | 范围 |
|---|---|---|
| 输入 x、GELU 输入 g | s12 Q8 | ±8 |
| 权重 w、偏置 b | s12 Q12 | ±0.4998 |
| 输出 y | s16 Q10 | ±32 |
| 乘积累加器 | s32 Q20 | — |

输出量化按 `(|acc| + 512) >> 10` 半远离零舍入，随后饱和到 s16。整条通路只做一次舍入。

## 版权与引用

- 本仓库中 `rtl/task*.v`、`rtl/t4_ram.v`、`rtl/e203_task_smoke_mmio.v`、`tb/`、`vsim/`、
  `syn/`、`模型与脚本/` 为本队自主编写；
- `rtl/e203_subsys_*.v` 基于上游 e203_hbirdv2 修改，改动部分以中文注释标注；
- 上游 E203 代码遵循 Apache-2.0 许可，版权归原作者所有；
- KWT-1 模型与预训练权重来自
  [ARM-software/keyword-transformer](https://github.com/ARM-software/keyword-transformer)（commit 237e4097），
  仅用于数值转换与验证，未重新训练、微调或蒸馏。
