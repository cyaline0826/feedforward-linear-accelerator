set sh_continue_on_error false

set script_dir [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $script_dir ..]]
set OUT  [file join $REPO syn_out_accel]
set TOP  e203_task_smoke_mmio

set NETLIST [file join $OUT netlist ${TOP}.v]
set STUBS   [file join $REPO syn lec sram_macro_stubs.v]

set rtl_files [list \
    [file join $REPO rtl/e203/subsys/task1.v] \
    [file join $REPO rtl/e203/subsys/task2.v] \
    [file join $REPO rtl/e203/subsys/task2_gelu.v] \
    [file join $REPO rtl/e203/subsys/e203_task_smoke_mmio.v]]

if {[info exists ::env(SMIC40_LIB)]} {
    set LIBDIR $::env(SMIC40_LIB)
} else {
    set LIBDIR [file normalize "$REPO/asic_smic40_task2/lib"]
}
set STDDBS  "$LIBDIR/scc40nll_vhsc40_rvt_tt_v1p1_25c_basic.db"
set SRAMDBS [list "$LIBDIR/RAMSP4096X16_tt_1p10v_1p10v_25c.db" \
                  "$LIBDIR/RAMSP128X16_tt_1p10v_1p10v_25c.db"]
set ALLDBS  [concat [list $STDDBS] $SRAMDBS]

set_app_var search_path [concat $search_path [list . $LIBDIR]]
set_app_var link_path   [concat [list "*" $STDDBS] $SRAMDBS]
set_app_var target_library $STDDBS
set_app_var link_library   [concat [list "*" $STDDBS] $SRAMDBS]
puts "INFO  link_path      = $link_path"
puts "INFO  link_library   = $link_library"

foreach lib $ALLDBS {
    puts "INFO  lib $lib exists=[file exists $lib]"
    if {[catch { read_db $lib } msg]} {
        puts "WARNING read_db 失败: $lib"
        puts "        $msg"
    } else {
        puts "INFO  read_db OK: $lib"
    }
}

foreach f [concat $rtl_files [list $NETLIST $STUBS]] {
    puts "INFO  $f exists=[file exists $f]"
    if {![file exists $f]} {
        puts "ERROR 缺文件 $f"
        exit 1
    }
}

catch { set_app_var hdlin_vrlg_std 2001 }
catch { set_app_var synopsys_auto_setup true }
catch { set_app_var verification_set_undriven_signals synthesis }

proc lec_status_text {outdir} {
    set f [file join $outdir lec_status.txt]
    if {[catch { redirect $f { report_status } } msg]} {
        return "redirect_failed: $msg"
    }
    if {![file exists $f]} { return "" }
    set fh [open $f r]
    set t [read $fh]
    close $fh
    return $t
}

proc lec_impl_set {outdir} {
    set t [lec_status_text $outdir]
    puts "-------- report_status --------"
    puts $t
    puts "-------------------------------"
    if {[regexp {Implementation\s*:\s*<None>} $t]} { return 0 }
    if {[regexp {Implementation\s*:\s*i:/WORK/} $t]} { return 1 }
    return 0
}

proc lec_make_wrappers {files defines wkdir} {
    file mkdir $wkdir
    set out {}
    set i 0
    foreach f $files {
        set w [file join $wkdir [format "wrap_%03d_%s" $i [file tail $f]]]
        set fh [open $w w]
        foreach d $defines { puts $fh "`define $d" }
        puts $fh "`include \"$f\""
        close $fh
        lappend out $w
        incr i
    }
    return $out
}

set defines_list {TASK2_USE_SMIC40_SRAM}
puts "INFO  编译宏 = $defines_list"
set wrapdir [file join $OUT lec_wrap]
set wrappers [lec_make_wrappers $rtl_files $defines_list $wrapdir]
puts "INFO  已生成 [llength $wrappers] 个包装文件到 $wrapdir"

foreach w $wrappers {
    if {[catch { read_verilog -container r -libname WORK $w } msg]} {
        puts "ERROR 参考端 read_verilog 失败: $w"
        puts "      $msg"
        exit 1
    }
}
read_verilog -container r -libname WORK $STUBS
if {[catch { set_top r:/WORK/$TOP } msg]} {
    puts "ERROR set_top r: 失败: $msg"
    exit 1
}
puts "INFO  参考端顶层 = r:/WORK/$TOP"

puts "INFO  读入网表 $NETLIST"
if {[catch { read_verilog -container i -libname WORK $NETLIST } msg]} {
    puts "ERROR 实现端 read_verilog 失败: $msg"
    exit 1
}
read_verilog -container i -libname WORK $STUBS
if {[catch { set_top i:/WORK/$TOP } msg]} {
    puts "ERROR set_top i: 失败: $msg"
    exit 1
}
puts "INFO  实现端顶层 = i:/WORK/$TOP"

if {![lec_impl_set $OUT]} {
    puts "ERROR 实现端顶层仍为 <None>。绝大多数情况是标准单元库没有被链接："
    puts "      检查上面 read_db 是否成功，以及是否有 'Cannot link cell' 警告。"
    exit 1
}

foreach macro {RAMSP4096X16 RAMSP128X16} {
    foreach side {r i} {
        if {[catch { set_black_box ${side}:/WORK/$macro } msg]} {
            puts "WARNING ${side} 侧无法把 $macro 设为黑盒: $msg"
        }
    }
}

set SVF_FILE [file join $OUT accel.svf]
if {[file exists $SVF_FILE]} {
    if {[catch { set_svf $SVF_FILE } msg]} {
        if {[catch { read_svf -pre $SVF_FILE } msg2]} {
            puts "WARNING SVF 读取失败: set_svf=$msg / read_svf=$msg2"
        } else {
            puts "INFO  read_svf 成功: $SVF_FILE"
        }
    } else {
        puts "INFO  set_svf 成功: $SVF_FILE"
    }
} else {
    puts "WARNING 找不到 $SVF_FILE —— 名称匹配可能出错，失败点可能全是假失配。"
    puts "        先重跑 syn/dc_accel_area.tcl 生成 SVF。"
}

puts "INFO  match 开始"
match
if {![lec_impl_set $OUT]} {
    puts "ERROR match 后实现端仍未设定，终止（不产生结论）。"
    exit 1
}
puts "INFO  match 完成"

puts "INFO  verify 开始"
verify
puts "INFO  verify 完成"

if {![lec_impl_set $OUT]} {
    puts "ERROR verify 后实现端仍未设定，结论无效。"
    exit 1
}

set ap_rpt [file join $OUT lec_analyze_points.rpt]
set ap_ok 0
foreach cmd {{analyze_points -failing} {analyze_points}} {
    if {[catch { redirect $ap_rpt $cmd } msg]} {
        puts "INFO  $cmd 不可用: $msg"
    } else {
        set ap_ok 1
        break
    }
}
if {$ap_ok && [file exists $ap_rpt]} {
    set fh [open $ap_rpt r]
    set ap_body [read $fh]
    close $fh
    puts "-------- analyze_points --------"
    puts $ap_body
    puts "--------------------------------"

    if {[regexp -nocase {Unmatched Cone Inputs} $ap_body]} {
        set um_rpt [file join $OUT lec_unmatched_points.rpt]
        if {[catch { redirect $um_rpt { report_unmatched_points } } msg]} {
            puts "WARNING report_unmatched_points 失败: $msg"
        } else {
            set fh [open $um_rpt r]
            set um_body [read $fh]
            close $fh
            puts "-------- report_unmatched_points --------"
            puts $um_body
            puts "-----------------------------------------"
        }
    }
} else {
    puts "WARNING analyze_points 未能执行，仅能看 report_failing_points。"
}

set fp_rpt [file join $OUT lec_failing_points.rpt]
catch { redirect $fp_rpt { report_failing_points } }
set fp_body ""
if {[file exists $fp_rpt]} {
    set fh [open $fp_rpt r]
    set fp_body [read $fh]
    close $fh
}
puts "-------- report_failing_points --------"
puts $fp_body
puts "---------------------------------------"

set lec_ok -1
set nfail -1

if {[regexp -nocase {available before matching} $fp_body]} {
    puts "ERROR 报告显示尚未匹配，结果无效。"
    set lec_ok -1
} elseif {[regexp -nocase {No failing compare points} $fp_body]} {
    set nfail 0
    set lec_ok 1
} elseif {[regexp -nocase {([0-9]+)\s+Failing compare points} $fp_body -> nf]} {
    set nfail $nf
    if {$nf > 0} { set lec_ok 0 } else { set lec_ok 1 }
} else {
    puts "WARNING 无法从 report_failing_points 判断，请人工看上面的输出。"
    set lec_ok -1
}

if {[regexp -nocase {([0-9]+)\s+Unverified} $fp_body -> nunv]} {
    puts "INFO  Unverified 比较点 = $nunv（含 SRAM 黑盒导致，报告中须列出）"
}

set summary [file join $OUT summary_lec.txt]
set fh [open $summary w]
puts $fh "# 由 syn/fm_lec_accel.tcl 生成（加速器 IP 级 LEC）"
puts $fh "top=$TOP"
puts $fh "reference=rtl/e203/subsys/{task1,task2,task2_gelu,e203_task_smoke_mmio}.v"
puts $fh "defines=$defines_list"
puts $fh "target_library=$target_library"
puts $fh "implementation=$NETLIST"
puts $fh "lec_pass=$lec_ok"
close $fh

puts "============================================================"
puts "INFO  汇总已写入 $summary"
if {$lec_ok == 1} {
    puts "RESULT: LEC_PASS"
    exit 0
} elseif {$lec_ok == 0} {
    puts "RESULT: LEC_FAIL"
    exit 1
} else {
    puts "RESULT: LEC_UNKNOWN（不得当作通过）"
    exit 1
}
