set sh_continue_on_error false

set script_dir [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $script_dir ..]]

set OUT [file join $REPO syn_out_gls]
set RPT  [file join $OUT reports]
set NET  [file join $OUT netlist]
set TOP  task2

foreach d [list $OUT $RPT $NET] { file mkdir $d }

if {[info exists ::env(SMIC40_LIB)]} {
    set LIBDIR $::env(SMIC40_LIB)
} else {
    set LIBDIR [file normalize "$REPO/asic_smic40_task2/lib"]
}
set STDDBS  "$LIBDIR/scc40nll_vhsc40_rvt_tt_v1p1_25c_basic.db"
set SRAMDBS [list "$LIBDIR/RAMSP4096X16_tt_1p10v_1p10v_25c.db" \
                  "$LIBDIR/RAMSP1024X16_tt_1p10v_1p10v_25c.db" \
                  "$LIBDIR/RAMSP128X16_tt_1p10v_1p10v_25c.db"]

set_app_var synthetic_library "dw_foundation.sldb"
set _sp [list . $LIBDIR]
if {[info exists ::env(SYNOPSYS)]} { lappend _sp "$::env(SYNOPSYS)/libraries/syn" }
set_app_var search_path [concat $search_path $_sp]
set_app_var target_library $STDDBS
set_app_var link_library [concat [list "*" $STDDBS] $SRAMDBS [list "dw_foundation.sldb"]]
set_app_var hdlin_preserve_sequential true
set_app_var verilogout_no_tri true
set_app_var write_name_nets_same_as_ports true

puts "INFO  top = $TOP"
puts "INFO  period = 6.666667 ns"

set defines "SYNTHESIS"
puts "INFO  配置 = P=4 + X 容量对齐（单一固定配置）"
puts "INFO  defines = $defines"
set rtl_files [list \
    "$REPO/rtl/e203/subsys/task1.v" \
    "$REPO/rtl/e203/subsys/task2.v" \
    "$REPO/rtl/e203/subsys/task2_gelu.v"]
foreach f $rtl_files {
    puts "INFO  RTL $f exists=[file exists $f]"
    if {![file exists $f]} { puts "ERROR 缺文件 $f"; exit 1 }
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
if {[catch { link } msg]} {
    puts "ERROR link 失败: $msg"
    exit 1
}
puts "INFO  link 完成，顶层 = $TOP"

set exp_4096 0
set exp_1024 40
set exp_128  16
set m4096  [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == RAMSP4096X16"]]
set m1024 [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == RAMSP1024X16"]]
set m128  [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == RAMSP128X16"]]
puts "INFO  RAMSP4096X16  = $m4096 (期望 $exp_4096)"
puts "INFO  RAMSP1024X16  = $m1024 (期望 $exp_1024)"
puts "INFO  RAMSP128X16   = $m128 (期望 $exp_128)"
if {$m4096 != $exp_4096 || $m1024 != $exp_1024 || $m128 != $exp_128} {
    puts "ERROR 宏数量不符（4096: $m4096/$exp_4096，1024: $m1024/$exp_1024，128: $m128/$exp_128），终止。"
    exit 1
}
set_dont_touch [get_cells -hierarchical -quiet -filter "ref_name == RAMSP4096X16 || ref_name == RAMSP128X16 || ref_name == RAMSP1024X16"]

create_clock -name clk -period 6.666667 [get_ports clk]
set_clock_uncertainty -setup 0.20 [get_clocks clk]
set_clock_uncertainty -hold  0.13 [get_clocks clk]
if {[sizeof_collection [get_ports -quiet rst_n]] > 0} {
    catch { set_ideal_network [get_ports rst_n] }
}
set budget 2.0
set data_in [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay  -max $budget -clock clk $data_in -add_delay
set_input_delay  -min 0.0     -clock clk $data_in -add_delay
set_output_delay -max $budget -clock clk [all_outputs] -add_delay
set_output_delay -min 0.0     -clock clk [all_outputs] -add_delay

set SVF_FILE [file join $OUT task2.svf]
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
write_sdf [file join $NET ${TOP}.sdf]
foreach f [list [file join $NET ${TOP}.v] [file join $NET ${TOP}.sdf]] {
    puts "INFO  已写出 $f exists=[file exists $f]"
}

set jobs {
    {area.rpt         { report_area }}
    {timing_setup.rpt { report_timing -delay_type max -max_paths 10 -nworst 2 -significant_digits 6 }}
    {qor.rpt          { report_qor }}
}
foreach job $jobs {
    set name [lindex $job 0]
    if {[catch { redirect [file join $RPT $name] [lindex $job 1] } msg]} {
        puts "WARNING 生成 $name 失败: $msg"
    }
}

set worst [get_timing_paths -delay_type max -max_paths 2 -nworst 1]
set wns 1.0e9
foreach_in_collection p $worst {
    set s [get_attribute $p slack]
    if {$s < $wns} { set wns $s }
}
if {$wns > 1.0e8} { set wns 0.0 }

puts "============================================================"
puts [format "INFO  task2 WNS = %.6f ns" $wns]
puts "============================================================"
if {$wns >= 0.0} {
    puts "RESULT: TASK2_TIMING_MET"
} else {
    puts [format "RESULT: TASK2_TIMING_VIOLATED wns=%.6f" $wns]
}
exit 0
