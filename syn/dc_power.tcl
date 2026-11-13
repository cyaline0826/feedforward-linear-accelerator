set sh_continue_on_error false

set script_dir [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $script_dir ..]]

set OUT [file join $REPO syn_out_150m]
puts "INFO  功耗配置 = P=4 + X 容量对齐（syn_out_150m）"
set TOP  e203_soc_top

set NETLIST [file join $OUT netlist ${TOP}.v]
set SDC     [file join $OUT sdc ${TOP}.sdc]

if {[info exists ::env(SMIC40_LIB)]} {
    set LIBDIR $::env(SMIC40_LIB)
} else {
    set LIBDIR [file normalize "$REPO/asic_smic40_task2/lib"]
}
set STDDBS  "$LIBDIR/scc40nll_vhsc40_rvt_tt_v1p1_25c_basic.db"

set SRAMDBS [list "$LIBDIR/RAMSP4096X16_tt_1p10v_1p10v_25c.db" \
                  "$LIBDIR/RAMSP1024X16_tt_1p10v_1p10v_25c.db" \
                  "$LIBDIR/RAMSP128X16_tt_1p10v_1p10v_25c.db"]

set_app_var search_path [concat $search_path [list . $LIBDIR]]
set_app_var link_path   [concat [list "*" $STDDBS] $SRAMDBS]
set_app_var target_library $STDDBS
set_app_var link_library   [concat [list "*" $STDDBS] $SRAMDBS]
catch { set_app_var power_analysis_mode averaged }

set saif ""
if {[info exists ::env(SAIF)]} { set saif [string trim $::env(SAIF)] }
if {$saif eq ""} {
    set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : ""}]
    set cands {}
    if {$home ne ""} {
        set cands [concat $cands [glob -nocomplain [file join $home Desktop *.saif]]]
        set cands [concat $cands [glob -nocomplain [file join $home Desktop *.SAIF]]]
    }
    puts "INFO  未设置 SAIF 环境变量。可用候选："
    foreach c $cands { puts "        $c" }
    if {[llength $cands] == 0} {
        puts "ERROR 桌面上没有找到 .saif 文件。"
    }
    puts "      用法: setenv SAIF <上面某个路径> 然后重跑。"
    exit 1
}
if {![file exists $saif]} {
    puts "ERROR SAIF 不存在: $saif"
    exit 1
}
puts "INFO  SAIF = $saif"

set saif_tag [file rootname [file tail $saif]]
puts "INFO  SAIF_TAG = $saif_tag"

set n_tasks 1
if {[info exists ::env(N_TASKS)]} {
    set n_tasks [expr {int($::env(N_TASKS))}]
}
if {$n_tasks <= 0} {
    puts "ERROR N_TASKS 必须是正整数。"
    exit 1
}
if {![info exists ::env(TASK_CYCLES)]} {
    puts "ERROR 必须设置 TASK_CYCLES（SAIF 工作负载的 L99 任务窗口总周期数）。"
    exit 1
}
if {[catch { set task_cycles [expr {int($::env(TASK_CYCLES))}] }]} {
    puts "ERROR TASK_CYCLES 必须是正整数。"
    exit 1
}
if {$task_cycles <= 0 || $task_cycles < $n_tasks} {
    puts "ERROR TASK_CYCLES 必须为正数且不少于 N_TASKS。"
    exit 1
}
set VDD  1.1
set FREQ 150.0e6
set task_window_s  [expr {double($task_cycles) / double($n_tasks) / $FREQ}]
set task_window_ns [expr {$task_window_s * 1.0e9}]
puts "INFO  完成任务数 = $n_tasks"
puts [format "INFO  L99 任务窗口 = %.6f ns/task @ %.3f MHz" \
      $task_window_ns [expr {$FREQ / 1.0e6}]]

proc saif_window_ns {path} {
    set fh [open $path r]
    set head [read $fh 8192]
    close $fh
    set dur 0
    set unit_scale 1.0e-15      ;# 默认 1 fs
    if {[regexp {\(TIMESCALE\s+([0-9.]+)\s+([A-Za-z]+)} $head -> n unit]} {
        set n [expr {double($n)}]
        switch -- [string tolower $unit] {
            fs      { set unit_scale [expr {1.0e-15 * $n}] }
            ps      { set unit_scale [expr {1.0e-12 * $n}] }
            ns      { set unit_scale [expr {1.0e-9  * $n}] }
            us      { set unit_scale [expr {1.0e-6  * $n}] }
            default { set unit_scale [expr {1.0e-15 * $n}] }
        }
    }
    if {[regexp {\(DURATION\s+([0-9]+)} $head -> d]} { set dur $d }
    if {$dur == 0} {
        puts "WARNING 没能从 SAIF 头里解析 DURATION，窗口时间不可信。"
    }
    return [expr {double($dur) * $unit_scale * 1.0e9}]
}

set window_ns [saif_window_ns $saif]
set window_s  [expr {$window_ns * 1.0e-9}]
puts [format "INFO  SAIF 平均功耗窗口 = %.0f ns = %.6f s" $window_ns $window_s]

if {$window_ns <= 0.0 || $task_window_ns <= 0.0} {
    puts "ERROR SAIF 窗口或任务窗口为 0（SAIF=$window_ns ns, L99=$task_window_ns ns），无法核对，终止。"
    exit 1
}
set wratio [expr {$window_ns / $task_window_ns}]
puts [format "INFO  SAIF/L99 窗口比 = %.4f（要求 0.98 ~ 1.10）" $wratio]
if {$wratio < 0.98 || $wratio > 1.10} {
    puts "ERROR SAIF 活动窗口与任务计时窗口不一致，能耗口径不成立，终止。"
    puts "      SAIF=$window_ns ns，L99=$task_window_ns ns，比值=$wratio"
    puts "      处理：按当前 TASK_CYCLES 重录 VCD/SAIF，或修正 TASK_CYCLES。"
    exit 1
}

if {![file exists $NETLIST]} {
    puts "ERROR 找不到网表: $NETLIST"
    exit 1
}
puts "INFO  启动 SAIF 名称映射 ..."
if {[catch { saif_map -start } msg]} {
    puts "ERROR saif_map -start 失败: $msg"
    exit 1
}
puts "INFO  读入网表 $NETLIST"
read_verilog $NETLIST

current_design $TOP
if {[catch { link } msg]} {
    puts "ERROR link 失败: $msg"
    exit 1
}
puts "INFO  当前设计应为 = $TOP"
if {[catch { source $SDC } msg]} {
    puts "ERROR 读 SDC 失败: $msg"
    exit 1
}
puts "INFO  已读入 $SDC"

catch { update_timing }

set exp_4096 80
set exp_1024 40
set exp_128  16
set m4096  [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == RAMSP4096X16"]]
set m1024 [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == RAMSP1024X16"]]
set m128  [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == RAMSP128X16"]]
puts "INFO  RAMSP4096X16  = $m4096 (期望 $exp_4096)"
puts "INFO  RAMSP1024X16  = $m1024 (期望 $exp_1024)"
puts "INFO  RAMSP128X16   = $m128 (期望 $exp_128)"
if {$m4096 != $exp_4096 || $m1024 != $exp_1024 || $m128 != $exp_128} {
    puts "ERROR 功耗网表的宏数量与所选配置不符，说明网表与配置错配，终止。"
    exit 1
}

puts "INFO  创建 SAIF 名称映射 ..."
if {[catch { saif_map -create_map -input $saif -source tb_top/u_e203_soc_top } msg]} {
    puts "ERROR saif_map -create_map 失败: $msg"
    exit 1
}
puts "INFO  read_saif ..."
if {[catch { read_saif -input $saif -instance_name tb_top/u_e203_soc_top -map_names } msg]} {
    puts "ERROR read_saif 失败: $msg"
    exit 1
}

set map_rpt [file join $OUT saif_map_summary_${saif_tag}.rpt]
if {[catch { redirect $map_rpt { saif_map -report -rtl_summary } } msg]} {
    puts "ERROR SAIF 映射摘要生成失败: $msg"
    exit 1
}
set coverage_rpt [file join $OUT saif_coverage_${saif_tag}.rpt]
if {[catch { redirect $coverage_rpt { report_saif -missing -rtl_saif } } msg]} {
    puts "ERROR SAIF 覆盖报告生成失败: $msg"
    exit 1
}
puts "INFO  SAIF 映射摘要 = $map_rpt"
puts "INFO  SAIF 活动覆盖/缺失清单 = $coverage_rpt"

proc lec_parse_missing_seq {path} {
    set out {}
    if {![file exists $path]} { return $out }
    set fh [open $path r]
    set body [read $fh]
    close $fh
    set in_seq 0
    foreach line [split $body "\n"] {
        if {[string match "*Non-annotated sequential cells*" $line]} { set in_seq 1; continue }
        if {[string match "*Non-annotated three-state cells*" $line]} { set in_seq 0; continue }
        if {$in_seq} {
            set t [string trim $line]

            if {$t ne "" && ![regexp {^[0-9]+ } $t]} { lappend out $t }
        }
    }
    return $out
}

set missing_cells [lec_parse_missing_seq $coverage_rpt]
puts "INFO  saif_missing_seq_cells = [llength $missing_cells]"
foreach c $missing_cells { puts "        MISS $c" }

proc lec_reg_internal_mw {path} {
    if {![file exists $path]} { return 0.0 }
    set fh [open $path r]
    set body [read $fh]
    close $fh
    if {[regexp -line {^register\s+([0-9.eE+-]+)} $body -> v]} {
        return [expr {double($v)}]
    }
    return 0.0
}
set rpt_before [file join $OUT saif_power_before_annot.rpt]
catch { redirect $rpt_before { report_power -verbose } }
set reg_before [lec_reg_internal_mw $rpt_before]
puts [format "INFO  before annotate: register internal = %.6f mW" $reg_before]

set coll ""
if {[llength $missing_cells] > 0} {
    set coll [get_cells -quiet $missing_cells]
    puts "INFO  annotate: direct_match = [sizeof_collection $coll]"
    if {[sizeof_collection $coll] == 0} {
        set coll [get_cells -quiet -hierarchical *read_bank_reg*]
        puts "INFO  annotate: wildcard_match = [sizeof_collection $coll]"
    }
}
puts "INFO  annotate: target_cells = [sizeof_collection $coll]"
foreach_in_collection c $coll { puts "        ANNOT [get_object_name $c]" }

set annot_ok 0
if {[sizeof_collection $coll] > 0} {
    if {[catch {
        set_switching_activity -static_probability 0.5 -toggle_rate 1.0 \
            -period 6.666667 -type registers $coll
    } msg]} {
        puts "WARNING annotate on cells failed: $msg"
    } else {
        set annot_ok 1
        puts "INFO  annotate: cells done"
    }
    set q_nets ""
    foreach_in_collection c $coll {
        set qp [get_pins -quiet [get_object_name $c]/Q]
        if {[sizeof_collection $qp] > 0} {
            set q_nets [add_to_collection -unique $q_nets [get_nets -quiet -of_objects $qp]]
        }
    }
    puts "INFO  annotate: q_nets = [sizeof_collection $q_nets]"
    if {[sizeof_collection $q_nets] > 0} {
        if {[catch {
            set_switching_activity -static_probability 0.5 -toggle_rate 1.0 \
                -period 6.666667 $q_nets
        } msg]} {
            puts "WARNING annotate on nets failed: $msg"
        } else {
            set annot_ok 1
            puts "INFO  annotate: nets done"
        }
    }
} else {
    puts "WARNING annotate: 没有匹配到任何单元，补标未执行"
}

set coverage_after [file join $OUT saif_coverage_after_${saif_tag}.rpt]
catch { redirect $coverage_after { report_saif -missing -rtl_saif } }
set still [lec_parse_missing_seq $coverage_after]
puts "INFO  saif_missing_seq_cells_after = [llength $still] -> $coverage_after"

set rpt [file join $OUT [file rootname [file tail $saif]]_power.rpt]
if {[catch { redirect $rpt { report_power -verbose } } msg]} {
    puts "WARNING report_power -verbose 失败，改用 report_power: $msg"
    catch { redirect $rpt { report_power } }
}
set reg_after [lec_reg_internal_mw $rpt]
puts [format "INFO  after annotate: register internal = %.6f mW" $reg_after]
set reg_delta [expr {$reg_after - $reg_before}]
puts [format "INFO  register internal delta = %+.6f mW" $reg_delta]

if {$annot_ok && $reg_delta > 0.0} {
    puts "ANNOT_RESULT: EFFECTIVE"
} elseif {$annot_ok} {
    puts "WARNING 补标命令执行成功但 register 组功耗无变化，需人工确认是否被接受。"
    puts "ANNOT_RESULT: UNVERIFIED"
} else {
    puts "WARNING 补标未执行成功；未标注项仍按无活动处理，功耗不可作为最终值。"
    puts "ANNOT_RESULT: FAILED"
}
puts "INFO  功耗报告 = $rpt"

proc to_watts {val unit} {
    set v [expr {double($val)}]
    switch -- [string tolower $unit] {
        w   { return $v }
        mw  { return [expr {$v * 1.0e-3}] }
        uw  { return [expr {$v * 1.0e-6}] }
        nw  { return [expr {$v * 1.0e-9}] }
        pw  { return [expr {$v * 1.0e-12}] }
        default { return $v }
    }
}

set total_w 0.0
set dyn_w   0.0
set leak_w  0.0
set got 0
if {![catch { set dcoll [get_designs $TOP] }]} {
    if {![catch {
        set total_w [get_attribute $dcoll total_power]
        set dyn_w   [get_attribute $dcoll dynamic_power]
        set leak_w  [get_attribute $dcoll leakage_power]
        set got 1
    } msg]} {
        puts "INFO  get_attribute 取功耗成功"
    } else {
        puts "INFO  get_attribute 取功耗不可用: $msg"
    }
}

if {!$got || $total_w <= 0.0} {
    puts "INFO  改为从报告文本解析功耗"
    set body ""
    if {[file exists $rpt]} {
        set fh [open $rpt r]
        set body [read $fh]
        close $fh
    }
    if {[regexp -nocase {Total\s+Dynamic\s+Power\s*=\s*([0-9.eE+-]+)\s*([munpW]+)} $body -> v u]} {
        set dyn_w [to_watts $v $u]
    }
    if {[regexp -nocase {(?:Cell|Total)\s+Leakage\s+Power\s*=\s*([0-9.eE+-]+)\s*([munpW]+)} $body -> v u]} {
        set leak_w [to_watts $v $u]
    }
    if {[regexp -nocase {Total\s+Power\s*=\s*([0-9.eE+-]+)\s*([munpW]+)} $body -> v u]} {
        set total_w [to_watts $v $u]
    }
    proc _nz {v} { if {[string is double -strict $v]} { return $v }; return 0.0 }
set total_w [_nz $total_w]
set dyn_w [_nz $dyn_w]
set leak_w [_nz $leak_w]
if {$total_w <= 0.0 && ($dyn_w + $leak_w) > 0.0} {
        set total_w [expr {$dyn_w + $leak_w}]
    }
    if {$total_w <= 0.0} {
        puts "WARNING 没能解析出功耗，请直接看 $rpt"
    }
}

set energy_j 0.0
if {$total_w > 0.0 && $task_window_s > 0.0} {
    set energy_j [expr {$total_w * $task_window_s}]
}

set ck_pins [get_pins -hierarchical -quiet -filter "name == CK"]
set ck_count [sizeof_collection $ck_pins]
set c_ck_pf 0.0
set ck_missing 0
foreach_in_collection p $ck_pins {
    if {[catch { set c_ck_pf [expr {$c_ck_pf + [get_attribute $p capacitance]}] }]} {
        incr ck_missing
    }
}
set p_clock_w [expr {$c_ck_pf * 1.0e-12 * $VDD * $VDD * $FREQ}]
puts [format "INFO  时钟引脚 %d 个，累计 pin 电容 %.4f pF（取不到电容 %d 个）" \
      $ck_count $c_ck_pf $ck_missing]
puts [format "INFO  按引脚电容重算时钟功耗 = %.4f mW" [expr {$p_clock_w * 1000.0}]]

set body ""
if {[file exists $rpt]} {
    set fh [open $rpt r]
    set body [read $fh]
    close $fh
}
set p_nonclock_mw 0.0
set p_leak_uw    0.0
set saw_table    0
foreach line [split $body "\n"] {
    if {[regexp {^\s*(memory|clock_network|register|combinational|macro|pad|io_pad)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)} \
            $line -> grp i s l tot]} {
        set saw_table 1
        set p_leak_uw [expr {$p_leak_uw + $l}]
        if {$grp ne "clock_network"} {
            set p_nonclock_mw [expr {$p_nonclock_mw + $i + $s}]
        }
    }
}
puts [format "INFO  非时钟动态功耗 = %.4f mW，总漏电 = %.4f mW（分组表解析=%d）" \
      $p_nonclock_mw [expr {$p_leak_uw / 1000.0}] $saw_table]

if {$saw_table == 0 || $p_nonclock_mw <= 0.0} {
    puts "ERROR 功耗分组表未识别（saw_table=$saw_table, p_nonclock=$p_nonclock_mw mW），"
    puts "      B 口径会退化成只剩时钟项，终止，不输出任何能耗结论。"
    exit 1
}
if {$ck_missing != 0} {
    puts "ERROR 有 $ck_missing 个时钟引脚取不到电容，时钟重算不完整，终止。"
    exit 1
}
if {$ck_count < 1000} {
    puts "ERROR 只找到 $ck_count 个时钟引脚（预期约 1.2 万），网表或 SAIF 不对，终止。"
    exit 1
}

set p_logic_w [expr {($p_nonclock_mw + $p_leak_uw / 1000.0) / 1000.0}]

set p_est_w   [expr {$p_logic_w + $p_clock_w}]

set e_wlm_j  $energy_j
set e_logic_j 0.0
set e_est_j   0.0
if {$task_window_s > 0.0} {
    set e_logic_j [expr {$p_logic_w * $task_window_s}]
    set e_est_j   [expr {$p_est_w   * $task_window_s}]
}

set corr [file join $OUT [file rootname [file tail $saif]]_power_corrected.txt]
set fh [open $corr w]
puts $fh "# 由 syn/dc_power.tcl 生成（时钟网络功耗修正）"
puts $fh "saif=$saif"
puts $fh "saif_window_ns=[format %.0f $window_ns]"
puts $fh "saif_map_report=$map_rpt"
puts $fh "saif_coverage_report=$coverage_rpt"
puts $fh "task_cycles_total=$task_cycles"
puts $fh "task_window_ns=[format %.6f $task_window_ns]"
puts $fh "n_tasks=$n_tasks"
puts $fh "vdd=$VDD"
puts $fh "freq_hz=$FREQ"
puts $fh "ck_pin_count=$ck_count"
puts $fh "ck_pin_cap_pf=[format %.4f $c_ck_pf]"
puts $fh "# 口径 A：DC 原始报告（含 WLM 外插的假时钟负载，仅作上界参考）"
puts $fh "A_total_power_mw=[format %.4f [expr {$total_w * 1000.0}]]"
puts $fh "A_energy_per_task_j=[format %.6e $e_wlm_j]"
puts $fh "# 口径 B：主用估计（非时钟分组取自 DC，时钟按引脚电容重算）"
puts $fh "B_clock_power_mw=[format %.4f [expr {$p_clock_w * 1000.0}]]"
puts $fh "B_nonclock_dynamic_mw=[format %.4f $p_nonclock_mw]"
puts $fh "B_leakage_mw=[format %.4f [expr {$p_leak_uw / 1000.0}]]"
puts $fh "B_total_power_mw=[format %.4f [expr {$p_est_w * 1000.0}]]"
puts $fh "B_energy_per_task_j=[format %.6e $e_est_j]"
puts $fh "# 口径 C：纯逻辑下界（不含任何时钟项）"
puts $fh "C_total_power_mw=[format %.4f [expr {$p_logic_w * 1000.0}]]"
puts $fh "C_energy_per_task_j=[format %.6e $e_logic_j]"
close $fh

puts "============================================================"
puts "INFO  功耗三种口径（SAIF 平均窗口 [format %.0f $window_ns] ns；L99 能耗窗口 [format %.6f $task_window_ns] ns/task）"
puts [format "INFO  A 上界 含 WLM 时钟 : %8.4f mW   能耗 %.6e J/task" \
      [expr {$total_w * 1000.0}] $e_wlm_j]
puts [format "INFO  B 主用 引脚电容时钟: %8.4f mW   能耗 %.6e J/task" \
      [expr {$p_est_w * 1000.0}] $e_est_j]
puts [format "INFO  C 下界 不含时钟    : %8.4f mW   能耗 %.6e J/task" \
      [expr {$p_logic_w * 1000.0}] $e_logic_j]
puts "INFO  修正报告 = $corr"
puts "============================================================"

set summary [file join $OUT [file rootname [file tail $saif]]_power_summary.txt]
set fh [open $summary w]
puts $fh "# 由 syn/dc_power.tcl 生成"
puts $fh "saif=$saif"
puts $fh "netlist=$NETLIST"
puts $fh "sdc=$SDC"
puts $fh "saif_window_ns=[format %.0f $window_ns]"
puts $fh "task_cycles_total=$task_cycles"
puts $fh "task_window_ns=[format %.6f $task_window_ns]"
puts $fh "n_tasks=$n_tasks"
puts $fh "sram_4096_count=$m4096"
puts $fh "sram_1024_count=$m1024"
puts $fh "sram_128_count=$m128"
puts $fh "total_power_mw=[format %.4f [expr {$total_w * 1000.0}]]"
puts $fh "dynamic_power_mw=[format %.4f [expr {$dyn_w * 1000.0}]]"
puts $fh "leakage_power_mw=[format %.4f [expr {$leak_w * 1000.0}]]"
puts $fh "energy_per_task_j=[format %.6e $energy_j]"
close $fh

puts "============================================================"
puts [format "INFO  平均功耗   = %.4f mW" [expr {$total_w * 1000.0}]]
puts [format "INFO    动态     = %.4f mW" [expr {$dyn_w * 1000.0}]]
puts [format "INFO    静态     = %.4f mW" [expr {$leak_w * 1000.0}]]
puts [format "INFO  SAIF 窗口 = %.0f ns；L99 能耗窗口 = %.6f ns/task；任务数 = %d" \
      $window_ns $task_window_ns $n_tasks]
puts [format "INFO  单任务能耗 = %.6e J/task" $energy_j]
puts "INFO  汇总 = $summary"
puts "============================================================"
if {$energy_j > 0.0} {
    puts "RESULT: POWER_REPORTED_COVERAGE_REVIEW_REQUIRED"
    puts "INFO: 查阅 saif_coverage.rpt；未标注项须有实测或明确的非零假设后，功耗才可作为最终值。"
    exit 0
} else {
    puts "RESULT: POWER_UNKNOWN（功耗或窗口为 0，检查报告）"
    exit 1
}
