set script_dir [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $script_dir ..]]

set sh_continue_on_error false

if {[info exists ::env(SMIC40_LIB)]} {
    set LIBDIR $::env(SMIC40_LIB)
} else {
    set LIBDIR [file normalize "$REPO/asic_smic40_task2/lib"]
}
set STDDBS  "$LIBDIR/scc40nll_vhsc40_rvt_tt_v1p1_25c_basic.db"
set SRAMDBS [list "$LIBDIR/RAMSP4096X16_tt_1p10v_1p10v_25c.db" \
                  "$LIBDIR/RAMSP128X16_tt_1p10v_1p10v_25c.db" \
                  "$LIBDIR/RAMSP1024X16_tt_1p10v_1p10v_25c.db"]

set OUT    "$REPO/syn_out_accel"
set RPT    "$OUT/reports"
set NET    "$OUT/netlist"
set SDCDIR "$OUT/sdc"
set DBDIR  "$OUT/db"

set PERIOD 6.666667
set TOP    e203_task_smoke_mmio
set BUDGET 2250000.0          ;# 2.25 mm2，单位 um2

foreach d [list $OUT $RPT $NET $SDCDIR $DBDIR] { file mkdir $d }

set_app_var synthetic_library "dw_foundation.sldb"
set _sp [list . $LIBDIR]
if {[info exists ::env(SYNOPSYS)]} { lappend _sp "$::env(SYNOPSYS)/libraries/syn" }
set_app_var search_path [concat $search_path $_sp]
set_app_var target_library $STDDBS
set_app_var link_library [concat [list "*" $STDDBS] $SRAMDBS [list "dw_foundation.sldb"]]
set_app_var symbol_library {}
set_app_var hdlin_preserve_sequential true
set_app_var verilogout_no_tri true
set_app_var write_name_nets_same_as_ports true

puts "INFO  version        = $sh_product_version"
puts "INFO  synthetic_lib  = $synthetic_library"
puts "INFO  period         = $PERIOD ns"
puts "INFO  top            = $TOP"

set defines "SYNTHESIS"

puts "INFO  配置 = P=4 并行 + X 容量对齐（8 个 1024×16 宏，4 逻辑 bank × 2 半区），单一固定配置"
puts "INFO  defines        = $defines"

set rtl_files [list \
    "$REPO/rtl/e203/subsys/task1.v" \
    "$REPO/rtl/e203/subsys/task2.v" \
    "$REPO/rtl/e203/subsys/task2_gelu.v" \
    "$REPO/rtl/e203/subsys/e203_task_smoke_mmio.v"]
foreach f $rtl_files {
    puts "INFO  RTL $f exists=[file exists $f]"
    if {![file exists $f]} {
        puts "ERROR 缺文件 $f"
        exit 1
    }
}

foreach src $rtl_files {
    if {[catch { analyze -format verilog -define $defines $src } msg]} {
        puts "ERROR analyze 失败: $src"
        puts "      $msg"
        exit 1
    }
}
if {[catch { elaborate $TOP } msg]} {
    puts "ERROR elaborate 失败: $msg"
    exit 1
}
if {[catch { current_design $TOP } msg]} {
    puts "ERROR current_design 失败: $msg"
    exit 1
}
puts "INFO  elaborate 完成，顶层 = [current_design]"
if {[catch { link } msg]} {
    puts "ERROR link 失败: $msg"
    exit 1
}

set exp_4096 0
set exp_1024 40
set exp_128  16
set m4096 [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == RAMSP4096X16"]]
set m1024 [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == RAMSP1024X16"]]
set m128  [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == RAMSP128X16"]]
puts "INFO  RAMSP4096X16 = $m4096 (期望 $exp_4096)"
puts "INFO  RAMSP1024X16 = $m1024 (期望 $exp_1024)"
puts "INFO  RAMSP128X16  = $m128 (期望 $exp_128)"
if {$m4096 != $exp_4096 || $m1024 != $exp_1024 || $m128 != $exp_128} {
    puts "ERROR 加速器宏数量不符（4096×16: $m4096/$exp_4096，1024×16: $m1024/$exp_1024，128×16: $m128/$exp_128），面积口径与预期不符，终止。"
    exit 1
}
set_dont_touch [get_cells -hierarchical -quiet -filter "ref_name == RAMSP4096X16 || ref_name == RAMSP128X16 || ref_name == RAMSP1024X16"]

create_clock -name clk -period $PERIOD [get_ports clk]
set_clock_uncertainty -setup [expr {$PERIOD * 0.03}] [get_clocks clk]
set_clock_uncertainty -hold  [expr {$PERIOD * 0.02}] [get_clocks clk]
set_clock_transition -max [expr {$PERIOD * 0.02}] [get_clocks clk]
set_clock_transition -min 0.0 [get_clocks clk]

if {[sizeof_collection [get_ports -quiet rst_n]] > 0} {
    catch { set_ideal_network [get_ports rst_n] }
}

set budget [expr {$PERIOD * 0.30}]
set data_in [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay  -max $budget -clock clk $data_in -add_delay
set_input_delay  -min 0.0     -clock clk $data_in -add_delay
set_output_delay -max $budget -clock clk [all_outputs] -add_delay
set_output_delay -min 0.0     -clock clk [all_outputs] -add_delay
set_load 0.02 [all_outputs]
set_max_transition 0.5 [current_design]
set_max_fanout 32 [current_design]

if {[catch { redirect [file join $RPT check_timing_pre.rpt] { check_timing } } msg]} {
    puts "WARNING 编译前 check_timing 失败: $msg"
}

set SVF_FILE [file join $OUT accel.svf]
if {[catch { set_svf $SVF_FILE } msg]} {
    puts "WARNING set_svf 失败（LEC 可能失配）: $msg"
} else {
    puts "INFO  SVF = $SVF_FILE"
}

puts "INFO  compile_ultra 开始 [clock format [clock seconds]]"
if {[catch { compile_ultra } msg]} {
    puts "ERROR compile_ultra 失败: $msg"
    exit 1
}
puts "INFO  compile_ultra 结束 [clock format [clock seconds]]"

write -hierarchy -format verilog -output [file join $NET ${TOP}.v]
write -format ddc -hierarchy -output [file join $DBDIR ${TOP}.ddc]
write_sdc [file join $SDCDIR ${TOP}.sdc]
write_sdf [file join $NET ${TOP}.sdf]
foreach f [list [file join $NET ${TOP}.v] [file join $DBDIR ${TOP}.ddc] \
                [file join $SDCDIR ${TOP}.sdc] [file join $NET ${TOP}.sdf]] {
    puts "INFO  已写出 $f exists=[file exists $f]"
}

set jobs {
    {area.rpt         { report_area -hierarchy }}
    {timing_setup.rpt { report_timing -delay_type max -max_paths 20 -nworst 4 -significant_digits 6 }}
    {constraints.rpt  { report_constraint -all_violators }}
    {qor.rpt          { report_qor }}
    {check_timing.rpt { check_timing }}
    {power.rpt        { report_power }}
}
foreach job $jobs {
    set name [lindex $job 0]
    if {[catch { redirect [file join $RPT $name] [lindex $job 1] } msg]} {
        puts "WARNING 生成 $name 失败: $msg"
    }
}

set worst [get_timing_paths -delay_type max -max_paths 4 -nworst 1]
set wns 1.0e9
set sp ""
set ep ""
set pc [sizeof_collection $worst]
foreach_in_collection p $worst {
    set s [get_attribute $p slack]
    if {$s < $wns} {
        set wns $s
        set sp [get_attribute $p startpoint]
        set ep [get_attribute $p endpoint]
    }
}
if {$pc == 0} { set wns 0.0; puts "WARNING 没有时序路径" }

set area_raw [file join $RPT area_total.rpt]
set total_area 0.0
if {[catch { redirect $area_raw { report_area } } msg]} {
    puts "WARNING report_area 失败: $msg"
}
if {[file exists $area_raw]} {
    set fh [open $area_raw r]
    set body [read $fh]
    close $fh
    if {[regexp {Total cell area:\s+([0-9.]+)} $body -> area_str]} {
        set total_area [expr {double($area_str)}]
    } else {
        puts "WARNING 没能解析 Total cell area"
    }
}

proc dc_sum_area {cells} {
    set t 0.0
    foreach_in_collection c $cells { set t [expr {$t + [get_attribute $c area]}] }
    return $t
}

set sram_area 0.0

foreach macro {RAMSP4096X16 RAMSP1024X16 RAMSP128X16} {
    set cells [get_cells -hierarchical -quiet -filter "ref_name == $macro"]
    set n [sizeof_collection $cells]
    set a 0.0
    if {$n > 0} { set a [dc_sum_area $cells] }
    puts "INFO  $macro x $n, 面积 [format %.1f $a] um2"
    set sram_area [expr {$sram_area + $a}]
}
set std_area [expr {$total_area - $sram_area}]
if {$std_area < 0.0} {
    puts "ERROR 统计出的 SRAM 面积大于总面积，宏型号列表可能仍有遗漏。"
    exit 1
}
set area_mm2 [expr {$total_area / 1.0e6}]
set margin   [expr {$BUDGET - $total_area}]

set fh [open [file join $OUT summary.txt] w]
puts $fh "# 由 syn/dc_accel_area.tcl 生成（加速器独立综合）"
puts $fh "top=$TOP"
puts $fh "period_ns=$PERIOD"
puts $fh "defines=$defines"
puts $fh "wns_ns=[format %.6f $wns]"
puts $fh "worst_startpoint=$sp"
puts $fh "worst_endpoint=$ep"
puts $fh "total_area_um2=[format %.1f $total_area]"
puts $fh "sram_area_um2=[format %.1f $sram_area]"
puts $fh "std_cell_area_um2=[format %.1f $std_area]"
puts $fh "area_mm2=[format %.6f $area_mm2]"
puts $fh "budget_um2=[format %.0f $BUDGET]"
puts $fh "margin_um2=[format %.1f $margin]"
puts $fh "sram_4096_count=$m4096"
puts $fh "sram_1024_count=$m1024"
puts $fh "sram_128_count=$m128"
puts $fh "accel_macro_count=[expr {$m4096 + $m1024 + $m128}]"
puts $fh "timing_met=[expr {$wns >= 0.0 ? 1 : 0}]"
puts $fh "area_within_budget=[expr {$margin >= 0.0 ? 1 : 0}]"
close $fh

puts "============================================================"
puts "INFO  加速器 setup slack = [format %.6f $wns] ns"
puts "INFO  起点 = $sp"
puts "INFO  终点 = $ep"
puts "INFO  加速器总面积 = [format %.1f $total_area] um2 = [format %.4f $area_mm2] mm2"
puts "INFO     其中 SRAM 宏 = [format %.1f $sram_area] um2"
puts "INFO     其中标准单元 = [format %.1f $std_area] um2"
puts "INFO  预算 2.25 mm2 = 2250000 um2，裕量 [format %.1f $margin] um2"
puts "============================================================"
if {$wns >= 0.0} {
    puts "RESULT: ACCEL_TIMING_MET"
} else {
    puts [format "RESULT: ACCEL_TIMING_VIOLATED wns=%.6f" $wns]
}
if {$margin >= 0.0} {
    puts "RESULT: ACCEL_AREA_WITHIN_BUDGET"
} else {
    puts "RESULT: ACCEL_AREA_OVER_BUDGET"
}
exit 0
