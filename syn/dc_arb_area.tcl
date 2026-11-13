set script_dir [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $script_dir ..]]

set sh_continue_on_error false

if {[info exists ::env(SMIC40_LIB)]} {
    set LIBDIR $::env(SMIC40_LIB)
} else {
    set LIBDIR [file normalize "$REPO/asic_smic40_task2/lib"]
}
set STDDBS  "$LIBDIR/scc40nll_vhsc40_rvt_tt_v1p1_25c_basic.db"

set PERIOD 6.666667
set TOP    acc_arb_area
set SRC    /tmp/acc_arb_area.v

set_app_var target_library $STDDBS
set_app_var link_library [list "*" $STDDBS]
set_app_var symbol_library {}
set_app_var verilogout_no_tri true

set lines {
{module acc_arb_area (
  input clk, input bus_rst_n,
  input  acc_sram_icb_cmd_valid,
  output acc_sram_icb_cmd_ready,
  input  [31:0] acc_sram_icb_cmd_addr,
  input  acc_sram_icb_cmd_read,
  input  [31:0] acc_sram_icb_cmd_wdata,
  input  [3:0]  acc_sram_icb_cmd_wmask,
  output acc_sram_icb_rsp_valid,
  input  acc_sram_icb_rsp_ready,
  output [31:0] acc_sram_icb_rsp_rdata,
  input  o4_icb_cmd_valid,
  output o4_icb_cmd_ready,
  input  [31:0] o4_icb_cmd_addr,
  input  o4_icb_cmd_read,
  input  [1:0]  o4_icb_cmd_burst,
  input  [1:0]  o4_icb_cmd_beat,
  input  [31:0] o4_icb_cmd_wdata,
  input  [3:0]  o4_icb_cmd_wmask,
  input  o4_icb_cmd_lock,
  input  o4_icb_cmd_excl,
  input  [1:0]  o4_icb_cmd_size,
  output o4_rsp_valid,
  input  o4_rsp_ready,
  output o4_rsp_err,
  output o4_rsp_excl_ok,
  output [31:0] o4_rsp_rdata,
  input  mrg_icb_cmd_ready,
  output mrg_icb_cmd_valid,
  output [31:0] mrg_icb_cmd_addr,
  output mrg_icb_cmd_read,
  output [1:0]  mrg_icb_cmd_burst,
  output [1:0]  mrg_icb_cmd_beat,
  output [31:0] mrg_icb_cmd_wdata,
  output [3:0]  mrg_icb_cmd_wmask,
  output mrg_icb_cmd_lock,
  output mrg_icb_cmd_excl,
  output [1:0]  mrg_icb_cmd_size,
  input  mrg_icb_rsp_valid,
  output mrg_icb_rsp_ready,
  input  mrg_icb_rsp_err,
  input  mrg_icb_rsp_excl_ok,
  input  [31:0] mrg_icb_rsp_rdata
);}
{  // 2-outstanding arbiter: count issued-but-not-responded commands per side.

  reg  [1:0] acc_pend;
  reg  [1:0] o4_pend;
  wire       acc_req = acc_sram_icb_cmd_valid;
  wire       o4_req  = o4_icb_cmd_valid;
  wire grant_acc = (acc_pend != 2'd0) | ((o4_pend == 2'd0) & acc_req);}

{  assign mrg_icb_cmd_valid = grant_acc ? acc_req : o4_req;
  assign mrg_icb_cmd_addr  = grant_acc ? acc_sram_icb_cmd_addr  : o4_icb_cmd_addr;
  assign mrg_icb_cmd_read  = grant_acc ? acc_sram_icb_cmd_read  : o4_icb_cmd_read;
  assign mrg_icb_cmd_burst = grant_acc ? 2'b00                  : o4_icb_cmd_burst;
  assign mrg_icb_cmd_beat  = grant_acc ? 2'b00                  : o4_icb_cmd_beat;
  assign mrg_icb_cmd_wdata = grant_acc ? acc_sram_icb_cmd_wdata : o4_icb_cmd_wdata;
  assign mrg_icb_cmd_wmask = grant_acc ? acc_sram_icb_cmd_wmask : o4_icb_cmd_wmask;
  assign mrg_icb_cmd_lock  = grant_acc ? 1'b0                   : o4_icb_cmd_lock;
  assign mrg_icb_cmd_excl  = grant_acc ? 1'b0                   : o4_icb_cmd_excl;
  assign mrg_icb_cmd_size  = grant_acc ? 2'b10                  : o4_icb_cmd_size;
  assign mrg_icb_rsp_ready = grant_acc ? acc_sram_icb_rsp_ready : o4_rsp_ready;}

{  assign o4_icb_cmd_ready     = grant_acc ? 1'b0 : mrg_icb_cmd_ready;
  assign acc_sram_icb_cmd_ready = grant_acc ? mrg_icb_cmd_ready : 1'b0;}

{  assign o4_rsp_valid     = grant_acc ? 1'b0 : mrg_icb_rsp_valid;
  assign o4_rsp_err       = mrg_icb_rsp_err;
  assign o4_rsp_excl_ok   = mrg_icb_rsp_excl_ok;
  assign o4_rsp_rdata     = mrg_icb_rsp_rdata;
  assign acc_sram_icb_rsp_valid = grant_acc ? mrg_icb_rsp_valid : 1'b0;
  assign acc_sram_icb_rsp_rdata = mrg_icb_rsp_rdata;}

{  wire arb_cmd_hs = mrg_icb_cmd_valid & mrg_icb_cmd_ready;
  wire arb_rsp_hs = mrg_icb_rsp_valid & mrg_icb_rsp_ready;
  always @(posedge clk or negedge bus_rst_n) begin
    if (~bus_rst_n) begin
      acc_pend <= 2'd0;
      o4_pend  <= 2'd0;
    end else begin
      if (arb_cmd_hs && !arb_rsp_hs) begin
        if (grant_acc) acc_pend <= acc_pend + 2'd1;
        else           o4_pend  <= o4_pend  + 2'd1;
      end else if (arb_rsp_hs && !arb_cmd_hs) begin
        if (grant_acc) acc_pend <= acc_pend - 2'd1;
        else           o4_pend  <= o4_pend  - 2'd1;
      end
    end
  end}
{endmodule}
}

set fh [open $SRC w]
foreach blk $lines { puts $fh $blk }
close $fh
puts "INFO  已生成 $SRC"

if {[catch { read_verilog $SRC } msg]} { puts "ERROR read_verilog: $msg"; exit 1 }
if {[catch { current_design $TOP } msg]} { puts "ERROR current_design: $msg"; exit 1 }
if {[catch { link } msg]} { puts "ERROR link: $msg"; exit 1 }

create_clock -name clk -period $PERIOD [get_ports clk]
set_input_delay  -max [expr {$PERIOD * 0.25}] -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay -max [expr {$PERIOD * 0.25}] -clock clk [all_outputs]
set_load 0.05 [all_outputs]

puts "INFO  compile_ultra 开始 [clock format [clock seconds]]"
if {[catch { compile_ultra } msg]} { puts "ERROR compile_ultra: $msg"; exit 1 }
puts "INFO  compile_ultra 结束 [clock format [clock seconds]]"

redirect /tmp/acc_arb_area.rpt { report_area }
set afh [open /tmp/acc_arb_area.rpt r]
set txt [read $afh]
close $afh
set area 0.0
foreach ln [split $txt "\n"] {
    if {[regexp {Total cell area:\s+([0-9.]+)} $ln -> a]} { set area $a }
}
set seq [sizeof_collection [get_cells -hier -filter "is_sequential == true"]]
puts [format "ARB_CELLS=%d" [sizeof_collection [get_cells -hier -filter "is_hierarchical == false"]]]
puts [format "ARB_SEQ=%d" $seq]
puts [format "ARB_STD_AREA_UM2=%.2f" $area]

set wns ""
catch { set wns [get_attribute [current_design] worst_negative_slack_max] }
if {[string is double -strict $wns]} {
    puts [format "ARB_WNS_NS=%.6f" $wns]
} else {
    puts "INFO  WNS 属性不可用（不影响面积测量）"
}
puts "INFO  报告见 /tmp/acc_arb_area.rpt"
