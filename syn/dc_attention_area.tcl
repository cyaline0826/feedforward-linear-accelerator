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

set OUT    "$REPO/syn_out_attn"
set RPT    "$OUT/reports"
set NET    "$OUT/netlist"
set SDCDIR "$OUT/sdc"
set DBDIR  "$OUT/db"

set PERIOD 6.666667
set TOP    attention_single_head
set BUDGET 2250000.0

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

puts "INFO  version   = $sh_product_version"
puts "INFO  period    = $PERIOD ns"
puts "INFO  top       = $TOP"

set defines "SYNTHESIS"
set srcs [list "$REPO/rtl/e203/subsys/t4_ram.v" "$REPO/rtl/e203/subsys/task4.v"]
foreach src $srcs {
    puts "INFO  RTL $src exists=[file exists $src]"
    if {![file exists $src]} {
        puts "ERROR 缺文件 $src"
        exit 1
    }
}

if {[catch { analyze -format verilog -define $defines $srcs } msg]} {
    puts "ERROR analyze 失败: $msg"
    exit 1
}
if {[catch { elaborate $TOP } msg]} {
    puts "ERROR elaborate 失败: $msg"
    exit 1
}
current_design $TOP
if {[catch { link } msg]} {
    puts "ERROR link 失败: $msg"
    exit 1
}

set clk_port "clk"
create_clock -name core_clk -period $PERIOD [get_ports $clk_port]
set_clock_uncertainty 0.05 [get_clocks core_clk]
set_input_delay  0.3 -clock core_clk [remove_from_collection [all_inputs] [get_ports $clk_port]]
set_output_delay 0.3 -clock core_clk [all_outputs]
set_load 0.02 [all_outputs]
if {[sizeof_collection [get_ports clk]] == 0} {
    puts "ERROR 找不到时钟端口 clk"
    exit 1
}

set SVF_FILE [file join $OUT ${TOP}.svf]
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
write_sdc [file join $SDCDIR ${TOP}.sdc]

foreach job [list \
    [list area.rpt        { report_area -hierarchy }] \
    [list area_total.rpt  { report_area }] \
    [list timing_setup.rpt { report_timing -delay_type max -max_paths 10 -significant_digits 6 }] \
    [list constraints.rpt { report_constraint -all_violators }] \
    [list qor.rpt         { report_qor }] \
    [list check_timing.rpt { check_timing }] \
    [list power.rpt       { report_power }]] {
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

set total_area 0.0
set area_raw [file join $RPT area_total.rpt]
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

set n_cells [sizeof_collection [get_cells -hierarchical -filter "is_hierarchical == false"]]
set n_seq   [sizeof_collection [get_cells -hierarchical -filter "is_sequential == true"]]
set n_macro 0
foreach macro {RAMSP4096X16 RAMSP1024X16 RAMSP128X16} {
    set n_macro [expr {$n_macro + [sizeof_collection [get_cells -hierarchical -quiet -filter "ref_name == $macro"]]}]
}

set area_mm2 [expr {$total_area / 1.0e6}]
set margin   [expr {$BUDGET - $total_area}]

set fh [open [file join $OUT summary.txt] w]
puts $fh "# 由 syn/dc_attention_area.tcl 生成（单头注意力模块独立综合，SRAM 宏映射版）"
puts $fh "top=$TOP"
puts $fh "period_ns=$PERIOD"
puts $fh "defines=$defines"
puts $fh "wns_ns=[format %.6f $wns]"
puts $fh "worst_startpoint=$sp"
puts $fh "worst_endpoint=$ep"
puts $fh "total_cell_area_um2=[format %.1f $total_area]"
puts $fh "area_mm2=[format %.6f $area_mm2]"
puts $fh "std_cells=$n_cells"
puts $fh "seq_cells=$n_seq"
puts $fh "sram_macros=$n_macro"
puts $fh "budget_um2=[format %.1f $BUDGET]"
puts $fh "margin_um2=[format %.1f $margin]"
puts $fh "timing_met=[expr {$wns >= 0.0 ? 1 : 0}]"
puts $fh "area_within_budget=[expr {$total_area <= $BUDGET ? 1 : 0}]"
close $fh

puts "ATTN_CELLS=$n_cells"
puts "ATTN_SEQ=$n_seq"
puts "ATTN_MACROS=$n_macro"
puts "ATTN_TOTAL_AREA_UM2=[format %.1f $total_area]"
puts "ATTN_AREA_MM2=[format %.6f $area_mm2]"
puts "ATTN_WNS_NS=[format %.6f $wns]"
puts "INFO  汇总 = [file join $OUT summary.txt]"
exit
