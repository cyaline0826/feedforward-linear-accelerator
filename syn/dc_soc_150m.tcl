set script_dir [file dirname [file normalize [info script]]]
set REPO       [file normalize [file join $script_dir ..]]

set sh_continue_on_error false

if {[info exists ::env(SMIC40_LIB)]} {
    set LIBDIR $::env(SMIC40_LIB)
} else {
    set LIBDIR [file normalize "$REPO/asic_smic40_task2/lib"]
}
set STDDBS  "$LIBDIR/scc40nll_vhsc40_rvt_tt_v1p1_25c_basic.db"
set SRAMDBS [list "$LIBDIR/RAMSP4096X16_tt_1p10v_1p10v_25c.db" \
                  "$LIBDIR/RAMSP1024X16_tt_1p10v_1p10v_25c.db" \
                  "$LIBDIR/RAMSP128X16_tt_1p10v_1p10v_25c.db"]

set OUT      "$REPO/syn_out_150m"
set RPT      "$OUT/reports"
set NET      "$OUT/netlist"
set SDCDIR   "$OUT/sdc"
set DBDIR    "$OUT/db"

set PERIOD   6.666667          ;# 150 MHz
set LF_PERIOD 30517.578125     ;# 32.768 kHz
set JTAG_PER 100.0             ;# 10 MHz，声明用的调试口假设
set TOP      e203_soc_top

foreach d [list $OUT $RPT $NET $SDCDIR $DBDIR] { file mkdir $d }

set_app_var synthetic_library "dw_foundation.sldb"

set _sp [list . $LIBDIR]
if {[info exists ::env(SYNOPSYS)]} {
    lappend _sp "$::env(SYNOPSYS)/libraries/syn"
}
set_app_var search_path [concat $search_path $_sp]
set_app_var target_library $STDDBS
set_app_var link_library [concat [list "*" $STDDBS] $SRAMDBS [list "dw_foundation.sldb"]]
set_app_var symbol_library {}
set_app_var hdlin_preserve_sequential true
set_app_var verilogout_no_tri true
set_app_var write_name_nets_same_as_ports true

puts "INFO  version        = $sh_product_version"
puts "INFO  synthetic_lib  = $synthetic_library"
puts "INFO  target_library = $target_library"
puts "INFO  link_library   = $link_library"
puts "INFO  period         = $PERIOD ns"

set incdirs [list "$REPO/rtl/e203/core" "$REPO/rtl/e203/perips" \
                  "$REPO/rtl/e203/perips/apb_i2c"]
set_app_var hdlin_include_dirs $incdirs

set_app_var search_path [concat $search_path $incdirs]

foreach d $incdirs {
    puts "INFO  incdir $d  isdir=[file isdirectory $d]"
}
set defines_file [file join $REPO rtl/e203/core e203_defines.v]
puts "INFO  e203_defines.v = $defines_file  exists=[file exists $defines_file]"
if {![file exists $defines_file]} {
    puts "ERROR 找不到 e203_defines.v，头文件路径不对，analyze 必然失败。"
    exit 1
}

set defines "SYNTHESIS DISABLE_SV_ASSERTION E203_USE_SMIC40_SRAM"

puts "INFO  配置 = P=4 并行 + X 容量对齐（单一固定配置）"
puts "INFO  defines        = $defines"

set rtl_files [concat \
    [glob -nocomplain -directory "$REPO/rtl/e203" */*.v] \
    [glob -nocomplain -directory "$REPO/rtl/e203" */*/*.v]]
puts "INFO  RTL dir        = $REPO/rtl/e203"
puts "INFO  RTL files      = [llength $rtl_files]"
if {[llength $rtl_files] == 0} {
    puts "ERROR 在 $REPO/rtl/e203 下一个 .v 都没找到，工程根目录判断错了。"
    exit 1
}
puts "INFO  第一个文件     = [lindex $rtl_files 0]"

set top_file ""
set other_files {}
foreach f $rtl_files {
    if {[file tail $f] eq "${TOP}.v"} { set top_file $f } else { lappend other_files $f }
}
puts "INFO  TOP 文件       = $top_file"
if {$top_file eq ""} {
    puts "ERROR 文件列表里没有 ${TOP}.v，glob 没有覆盖 soc 目录。"
    exit 1
}
set rtl_files [concat $other_files [list $top_file]]

foreach src $rtl_files {
    if {[catch { analyze -format verilog -define $defines $src } msg]} {
        puts "ERROR analyze 失败: $src"
        puts "      $msg"
        exit 1
    }
}

if {[catch { set designs [list_designs] } msg]} {
    puts "INFO  list_designs 不可用: $msg"
} else {
    puts "INFO  list_designs（仅供参考，可能为空）= $designs"
}

if {[catch { elaborate $TOP } msg]} {
    puts "ERROR elaborate 失败: $msg"
    puts "      诊断：单独重新分析顶层文件，看 include 是否解析成功："
    catch { analyze -format verilog -define $defines $top_file }
    puts "      诊断结束。"
    exit 1
}
if {[catch { current_design $TOP } msg]} {
    puts "ERROR current_design 失败（$TOP 不在 WORK 库里）: $msg"
    exit 1
}
puts "INFO  elaborate 完成，顶层 = [current_design]"
if {[catch { link } msg]} {
    puts "ERROR link 失败: $msg"
    exit 1
}

set exp_4096 80
set exp_1024 40
set exp_128  16
set exp_accel_macro 56
set m4096  [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == RAMSP4096X16"]]
set m1024 [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == RAMSP1024X16"]]
set m128  [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == RAMSP128X16"]]
puts "INFO  RAMSP4096X16  = $m4096 (期望 $exp_4096)"
puts "INFO  RAMSP1024X16  = $m1024 (期望 $exp_1024)"
puts "INFO  RAMSP128X16   = $m128 (期望 $exp_128)"
if {$m4096 == 0 || $m128 == 0} {
    puts "ERROR SRAM 宏没有 link 进网表，面积与功耗结论会全错，终止。"
    exit 1
}
if {$m4096 != $exp_4096 || $m1024 != $exp_1024 || $m128 != $exp_128} {
    puts "ERROR 宏数量与预期不符（4096: $m4096/$exp_4096，1024: $m1024/$exp_1024，128: $m128/$exp_128），终止。"
    exit 1
}
set_dont_touch [get_cells -hierarchical -quiet -filter "ref_name == RAMSP4096X16 || ref_name == RAMSP128X16 || ref_name == RAMSP1024X16"]

proc dc_sum_area {cells} {
    set total 0.0
    foreach_in_collection c $cells {
        set total [expr {$total + [get_attribute $c area]}]
    }
    return $total
}

set all_macro_cells [get_cells -hierarchical -quiet \
    -filter "ref_name == RAMSP4096X16 || ref_name == RAMSP128X16 || ref_name == RAMSP1024X16"]
set accel_macro_count 0
set accel_macro_area 0.0
foreach_in_collection c $all_macro_cells {
    set full_name [get_object_name $c]
    if {[string match *task_smoke* $full_name]} {
        incr accel_macro_count
        set accel_macro_area [expr {$accel_macro_area + [get_attribute $c area]}]
    }
}
puts "INFO  加速器 SRAM 宏 = $accel_macro_count 个, 面积 [format %.1f $accel_macro_area] um2"
if {$accel_macro_count != $exp_accel_macro} {
    puts "WARNING 加速器 SRAM 宏不是 $exp_accel_macro 个，面积预算口径与预期不一致"
}

create_clock -name hfclk    -period $PERIOD    [get_ports hfextclk]
create_clock -name lfclk    -period $LF_PERIOD [get_ports lfextclk]
create_clock -name jtag_tck -period $JTAG_PER  [get_ports io_pads_jtag_TCK_i_ival]

set_clock_uncertainty -setup [expr {$PERIOD * 0.03}] [get_clocks hfclk]
set_clock_uncertainty -hold  [expr {$PERIOD * 0.02}] [get_clocks hfclk]
set_clock_transition -max   [expr {$PERIOD * 0.02}] [get_clocks hfclk]
set_clock_transition -min   0.0                     [get_clocks hfclk]

set_clock_groups -asynchronous \
    -group [get_clocks hfclk] -group [get_clocks lfclk] -group [get_clocks jtag_tck]

foreach p {io_pads_aon_erst_n_i_ival io_pads_dbgmode0_n_i_ival \
           io_pads_dbgmode1_n_i_ival io_pads_dbgmode2_n_i_ival \
           io_pads_bootrom_n_i_ival io_pads_aon_pmu_dwakeup_n_i_ival} {
    if {[sizeof_collection [get_ports -quiet $p]] > 0} {
        set_ideal_network [get_ports $p]
    }
}

set pad_budget [expr {$PERIOD * 0.25}]
set clk_ports  [get_ports {hfextclk lfextclk io_pads_jtag_TCK_i_ival}]
set data_in    [remove_from_collection [all_inputs] $clk_ports]
set_input_delay  -max $pad_budget -clock hfclk $data_in -add_delay
set_input_delay  -min 0.0        -clock hfclk $data_in -add_delay
set_output_delay -max $pad_budget -clock hfclk [all_outputs] -add_delay
set_output_delay -min 0.0        -clock hfclk [all_outputs] -add_delay
set_load 0.05 [all_outputs]

set_max_transition 0.5 [current_design]
set_max_fanout     32  [current_design]

if {[catch { redirect [file join $RPT check_timing_pre_compile.rpt] { check_timing } } msg]} {
    puts "WARNING 编译前 check_timing 失败（不影响继续）: $msg"
}

set SVF_FILE [file join $OUT soc.svf]
if {[catch { set_svf $SVF_FILE } msg]} {
    puts "WARNING set_svf 失败: $msg"
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
write_sdc  [file join $SDCDIR ${TOP}.sdc]
write_sdf  [file join $NET ${TOP}.sdf]
foreach f [list [file join $NET ${TOP}.v] [file join $DBDIR ${TOP}.ddc] \
                [file join $SDCDIR ${TOP}.sdc] [file join $NET ${TOP}.sdf]] {
    puts "INFO  已写出 $f exists=[file exists $f]"
}

set jobs {
    {area.rpt          { report_area -hierarchy }}
    {timing_setup.rpt  { report_timing -delay_type max -max_paths 50 -nworst 4 -significant_digits 6 }}
    {timing_hold.rpt   { report_timing -delay_type min -max_paths 20 -nworst 2 -significant_digits 6 }}
    {constraints.rpt   { report_constraint -all_violators -verbose }}
    {qor.rpt           { report_qor }}
    {clocks.rpt        { report_clock -attributes -skew }}
    {check_timing.rpt  { check_timing }}
    {check_design.rpt  { check_design }}
    {power.rpt         { report_power }}
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
set wns_clock ""
set path_count [sizeof_collection $worst]
puts "INFO  report_timing 路径数 = $path_count"
foreach_in_collection path $worst {
    set s [get_attribute $path slack]
    set c [get_attribute $path capturing_clock]
    puts "INFO    clock=$c slack=[format %.6f $s]"
    if {$s < $wns} {
        set wns $s
        set wns_clock $c
        set sp [get_attribute $path startpoint]
        set ep [get_attribute $path endpoint]
    }
}
if {$path_count == 0} {
    puts "WARNING 没有时序路径 —— 时钟可能没有传播到触发器"
    set wns 0.0
}

set sram_clk [get_pins -hierarchical -quiet -regexp {.*u_sram/CLK$}]
set sram_clk_count [sizeof_collection $sram_clk]
puts "INFO  SRAM 宏 CLK 引脚 = $sram_clk_count"

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
        puts "WARNING 没能从 report_area 解析出 Total cell area"
    }
}

set sram_area 0.0
foreach macro {RAMSP4096X16 RAMSP1024X16 RAMSP128X16} {
    set cells [get_cells -hierarchical -quiet -filter "ref_name == $macro"]
    set n [sizeof_collection $cells]
    set a 0.0
    if {$n > 0} { set a [dc_sum_area $cells] }
    puts "INFO  $macro x $n, 合计面积 [format %.1f $a] um2"
    set sram_area [expr {$sram_area + $a}]
}
set std_area [expr {$total_area - $sram_area}]
if {$std_area < 0.0} {
    puts "ERROR 统计出的 SRAM 面积大于总面积，宏型号列表可能仍有遗漏。"
    exit 1
}

puts "INFO  加速器内部 SRAM 宏 $accel_macro_count 个, 面积 [format %.1f $accel_macro_area] um2"

set fh [open [file join $OUT summary.txt] w]
puts $fh "# 由 syn/dc_soc_150m.tcl 生成"
puts $fh "top=$TOP"
puts $fh "period_ns=$PERIOD"
puts $fh "synthetic_library=$synthetic_library"
puts $fh "target_library=$target_library"
puts $fh "link_library=$link_library"
puts $fh "defines=$defines"
puts $fh "wns_ns=[format %.6f $wns]"
puts $fh "worst_startpoint=$sp"
puts $fh "worst_endpoint=$ep"
puts $fh "total_cell_area_um2=[format %.1f $total_area]"
puts $fh "sram_area_um2=[format %.1f $sram_area]"
puts $fh "std_cell_area_um2=[format %.1f $std_area]"
puts $fh "sram_4096_count=$m4096"
puts $fh "sram_1024_count=$m1024"
puts $fh "sram_128_count=$m128"
puts $fh "sram_clk_pins=$sram_clk_count"
puts $fh "accel_macro_count=$accel_macro_count"
puts $fh "accel_macro_area_um2=[format %.1f $accel_macro_area]"
puts $fh "timing_met=[expr {$wns >= 0.0 ? 1 : 0}]"
close $fh

puts "============================================================"
puts "INFO  最差 setup slack = [format %.6f $wns] ns"
puts "INFO  起点 = $sp"
puts "INFO  终点 = $ep"
puts "INFO  全 SoC 单元面积 = [format %.1f $total_area] um2"
puts "INFO     其中 SRAM 宏 = [format %.1f $sram_area] um2"
puts "INFO     其中标准单元 = [format %.1f $std_area] um2"
puts "INFO  加速器 $accel_macro_count 宏面积 = [format %.1f $accel_macro_area] um2（对 2.25e6 um2 预算）"
puts "============================================================"
if {$wns >= 0.0} {
    puts "RESULT: SETUP_MET_150MHZ"
} else {
    puts "RESULT: SETUP_VIOLATED_150MHZ wns=[format %.6f $wns]"
}
exit 0
