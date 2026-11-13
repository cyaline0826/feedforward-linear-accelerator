
`include "e203_defines.v"

module tb_top();

  reg  clk;
  reg  lfextclk;
  reg  rst_n;

  wire hfclk = clk;

  `define CPU_TOP u_e203_soc_top.u_e203_subsys_top.u_e203_subsys_main.u_e203_cpu_top
  `define EXU `CPU_TOP.u_e203_cpu.u_e203_core.u_e203_exu
  `define ITCM `CPU_TOP.u_e203_srams.u_e203_itcm_ram.u_e203_itcm_gnrl_ram.u_sirv_sim_ram
  `define DTCM `CPU_TOP.u_e203_srams.u_e203_dtcm_ram.u_e203_dtcm_gnrl_ram.u_sirv_sim_ram
  `define SHARED_SRAM u_e203_soc_top.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_mems.u_shared_sram_mem.u_sirv_sim_ram
  // 共享 SRAM 子系统的 ICB 从口：主机加载参数走这里（模拟组委会的参数加载环境）
  `define SS_MEMS u_e203_soc_top.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_mems
  `define O15_PERIPS u_e203_soc_top.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips
  `define ACC_PORT u_e203_soc_top.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips
  `define PC_WRITE_TOHOST       `E203_PC_SIZE'h80000086
  `define PC_EXT_IRQ_BEFOR_MRET `E203_PC_SIZE'h800000a6
  `define PC_SFT_IRQ_BEFOR_MRET `E203_PC_SIZE'h800000be
  `define PC_TMR_IRQ_BEFOR_MRET `E203_PC_SIZE'h800000d6
  `define PC_AFTER_SETMTVEC     `E203_PC_SIZE'h8000015C

  wire [`E203_XLEN-1:0] x3 = `EXU.u_e203_exu_regfile.rf_r[3];
  wire [`E203_PC_SIZE-1:0] pc = `EXU.u_e203_exu_commit.alu_cmt_i_pc;
  wire [`E203_PC_SIZE-1:0] pc_vld = `EXU.u_e203_exu_commit.alu_cmt_i_valid;

  localparam [31:0] O15_BASE = 32'h1004_2000;
  localparam [31:0] FC1_START_PC = 32'h8000_0018;
  localparam [31:0] FC1_CTRL_ADDR = O15_BASE + 32'h08;
  localparam [31:0] FC1_STATUS_ADDR = O15_BASE + 32'h0c;
  localparam [31:0] FC1_LOAD_ADDR = O15_BASE + 32'h10;
  localparam [31:0] FC1_OUTPUT_ADDR = O15_BASE + 32'h14;
  localparam [31:0] FC1_META_ADDR = O15_BASE + 32'h18;
  localparam [31:0] FC1_LOAD32_ADDR = O15_BASE + 32'h1c;

  localparam [31:0] FC1_WEIGHT_OFFSET = 32'h0000_1000;
  localparam [31:0] FC1_BIAS_OFFSET = 32'h0000_9000;
  localparam [31:0] FC1_INPUT_OFFSET = 32'h0000_9200;
  // 任务控制字放在 ITCM 尾部空闲区（数据用到 0xC380，ITCM 到 0xFFFF），
  // 由本测试平台按 +LAYER=k 写入，固件从 0x8000_F000 读取。
  localparam [31:0] FC1_CTRL_WORD_OFFSET = 32'h0000_F000;
  localparam [31:0] FULL_W1_OFFSET = 32'h0000_0000;
  localparam [31:0] FULL_B1_OFFSET = 32'h0000_8000;
  localparam [31:0] FULL_W2_OFFSET = 32'h0000_8200;
  localparam [31:0] FULL_B2_OFFSET = 32'h0001_0200;
  localparam [31:0] FULL_INPUT_OFFSET = 32'h0001_0280;
  localparam integer SHARED_SRAM_BYTES = 524288;
  localparam integer FC1_WEIGHT_COUNT = 16384;
  localparam integer FC1_BIAS_COUNT = 256;
  localparam integer FC1_INPUT_COUNT = 6336;
  localparam integer FC1_OUTPUT_COUNT = 25344;
  localparam integer FULL_B2_COUNT = 64;
  localparam integer FULL_OUTPUT_COUNT = 6336;
  localparam integer FC1_LOAD_COUNT = FC1_WEIGHT_COUNT + FC1_BIAS_COUNT + FC1_INPUT_COUNT;
  localparam integer FULL_LOAD_COUNT = FC1_WEIGHT_COUNT + FC1_BIAS_COUNT
                                       + FC1_WEIGHT_COUNT + FULL_B2_COUNT + FC1_INPUT_COUNT;
  localparam [2:0] FC1_KIND_NONE = 3'd0;
  localparam [2:0] FC1_KIND_OUTPUT = 3'd1;
  localparam [2:0] FC1_KIND_META = 3'd2;
  localparam [2:0] FC1_KIND_STATUS = 3'd3;
  localparam [2:0] FC1_KIND_ID = 3'd4;

  reg [8*300:1] testcase;
  integer dumpwave;
  integer i;
  integer fc1_mode_arg;
  integer full_ffn_mode_arg;
  integer fc1_byte_addr;
  reg [7:0] itcm_mem [0:(`E203_ITCM_RAM_DP*8)-1];

  wire fc1_o15_cmd_valid = `O15_PERIPS.o15_icb_cmd_valid;
  wire fc1_o15_cmd_ready = `O15_PERIPS.o15_icb_cmd_ready;
  wire [31:0] fc1_o15_cmd_addr = `O15_PERIPS.o15_icb_cmd_addr;
  wire fc1_o15_cmd_read = `O15_PERIPS.o15_icb_cmd_read;
  wire [31:0] fc1_o15_cmd_wdata = `O15_PERIPS.o15_icb_cmd_wdata;
  wire [3:0] fc1_o15_cmd_wmask = `O15_PERIPS.o15_icb_cmd_wmask;
  wire fc1_o15_rsp_valid = `O15_PERIPS.o15_icb_rsp_valid;
  wire fc1_o15_rsp_ready = `O15_PERIPS.o15_icb_rsp_ready;
  wire fc1_o15_rsp_err = `O15_PERIPS.o15_icb_rsp_err;
  wire [31:0] fc1_o15_rsp_rdata = `O15_PERIPS.o15_icb_rsp_rdata;
  wire fc1_task_start_valid, fc1_task_start_ready, fc1_task_load_ready;
  wire fc1_task_busy, fc1_task_error;
  wire [3:0] fc1_task_state;
  assign fc1_task_start_valid = 1'b0;
  assign fc1_task_start_ready = 1'b0;
  assign fc1_task_load_ready = 1'b0;
  assign fc1_task_busy = 1'b0;
  assign fc1_task_error = 1'b0;
  assign fc1_task_state = 4'b0;

  reg fc1_mmio;
  reg full_ffn_mmio;
  // +FFN_STAGED=1：完整前馈的参数先落在 ITCM（W1/b1）与 DTCM（W2/b2/X），
  // 由固件在计时窗口内拷进共享 SRAM。ITCM/DTCM 各 64 KB，合计 128 KB，
  // 足够装 39,424 个 16 位字（78,848 B）；单独 ITCM 只有 64 KB 装不下。
  reg ffn_staged;
  integer ffn_staged_arg;
  // +FC1_SRAM=1：单层 FC1 的参数写进共享 SRAM（L16 官方流程），
  // 需配合固件 o15_task12_sram.S；默认为 0 时写 ITCM（本地快速回归）。
  reg fc1_sram_use;
  reg fc1_accel_load;
  integer fc1_sram_arg;
  reg [8*1024-1:0] fc1_weights_file, fc1_biases_file, fc1_inputs_file, fc1_expected_file;
  reg [8*1024-1:0] full_weights2_file, full_biases2_file;
  reg [15:0] fc1_weights [0:FC1_WEIGHT_COUNT-1];
  reg [15:0] fc1_biases [0:FC1_BIAS_COUNT-1];
  reg [15:0] fc1_inputs [0:FC1_INPUT_COUNT-1];
  reg [15:0] fc1_expected [0:FC1_OUTPUT_COUNT-1];
  reg [15:0] full_weights2 [0:FC1_WEIGHT_COUNT-1];
  reg [15:0] full_biases2 [0:FULL_B2_COUNT-1];

  // 扁平参数序号 -> 期望的 16 位字，顺序：W1, b1, [W2, b2,] X
  function automatic [15:0] expected_load_word(input integer idx);
    integer k;
    begin
      if (idx < FC1_WEIGHT_COUNT) begin
        expected_load_word = fc1_weights[idx];
      end else if (idx < FC1_WEIGHT_COUNT + FC1_BIAS_COUNT) begin
        k = idx - FC1_WEIGHT_COUNT;
        expected_load_word = fc1_biases[k];
      end else if (full_ffn_mmio
                   && idx < FC1_WEIGHT_COUNT + FC1_BIAS_COUNT + FC1_WEIGHT_COUNT) begin
        k = idx - FC1_WEIGHT_COUNT - FC1_BIAS_COUNT;
        expected_load_word = full_weights2[k];
      end else if (full_ffn_mmio && idx < FC1_WEIGHT_COUNT + FC1_BIAS_COUNT
                                        + FC1_WEIGHT_COUNT + FULL_B2_COUNT) begin
        k = idx - FC1_WEIGHT_COUNT - FC1_BIAS_COUNT - FC1_WEIGHT_COUNT;
        expected_load_word = full_biases2[k];
      end else if (full_ffn_mmio) begin
        k = idx - FC1_WEIGHT_COUNT - FC1_BIAS_COUNT - FC1_WEIGHT_COUNT - FULL_B2_COUNT;
        expected_load_word = fc1_inputs[k];
      end else begin
        k = idx - FC1_WEIGHT_COUNT - FC1_BIAS_COUNT;
        expected_load_word = fc1_inputs[k];
      end
    end
  endfunction
  reg [15:0] full_expected [0:FULL_OUTPUT_COUNT-1];
  reg [2:0] fc1_pending_kind;
  reg [31:0] fc1_pending_addr;
  reg fc1_pending_read;
  reg [31:0] fc1_pending_wdata;
  integer fc1_load_count;
  integer accel_read_cmd_count;
  integer accel_read_rsp_count;
  integer accel_word_index;
  reg [31:0] accel_expected_addr;
  reg [31:0] accel_expected_data;
  // 相位计时：装载完成 / 首个输出响应，用于把窗口切成三段
  // 注意：ph_load_done 只在“CPU 推送装载”模式有效（由 fc1_load_count 达标触发），
  // 主口直读模式下 CPU 推 0 笔，因此另设 mp_acc_done 记录“第 11,488 笔主口响应”。
  // 四个 ph_* 必须给初值，否则 flag 初值为 X，if(!flag) 永远不成立。
  reg [31:0] cycle_count;
  reg [31:0] ph_load_done_cycle = 32'd0;
  reg [31:0] ph_first_out_cycle = 32'd0;
  reg        ph_load_done_flag  = 1'b0;
  reg        ph_first_out_flag  = 1'b0;
  reg [31:0] mp_acc_done_cycle  = 32'd0;
  reg        mp_acc_done_flag   = 1'b0;
  integer fc1_start_count;
  integer fc1_output_count;
  integer fc1_meta_count;
  // 读回开销分解用的访问计数（只统计，不改变功能）
  integer fc1_status_count;   // STATUS 读命令次数（固件每输出轮询一次，可能重试）
  integer fc1_status_miss;    // 其中 result_valid 尚未就绪的次数（纯等待）
  reg fc1_done_seen;
  reg fc1_result_valid_seen;
  integer fc1_vector_index;
  integer fc1_start_pc_count;
  reg [31:0] fc1_last_valid_pc;
  wire o15_mmio_test = fc1_mmio || full_ffn_mmio;
  wire [31:0] o15_load_limit = full_ffn_mmio ? FULL_LOAD_COUNT : FC1_LOAD_COUNT;
  wire [31:0] o15_output_limit = full_ffn_mmio ? FULL_OUTPUT_COUNT : FC1_OUTPUT_COUNT;

  // ------------------------------------------------------------------
  // 12 任务测量支持（赛题：本科为覆盖 12 层参数的 12 次线性计算）
  //   layer_param : +LAYER=k 选层，写入 ITCM 尾部供固件读取
  //   win_*       : 单任务计时窗口，按 L99 定义
  //                 start = CPU 写 O15 CTRL（输入和参数开始装载）
  //                 end   = CPU 读完最后一个输出（结果全部写回）
  // ------------------------------------------------------------------
  integer    layer_param;
  wire [3:0] layer_arg = layer_param[3:0];
  // CTRL 字格式：bit[0] 是启动位（task_start_valid 要求 cmd_wdata[0] 为 1），
  //              bit[2] = 从共享 SRAM 直读，bit[1] = full_ffn，bit[7:4] = layer_id。
  // 原固件写死 1 = 启动 + layer 0；这里改成 (layer<<4)|1 以覆盖 12 层。
  //
  // 用 reg + 过程赋值而不是 wire + 连续赋值：+LAYER 由同一个 initial 块里的
  // $value$plusargs 写进 layer_param，连续赋值要晚一个 delta 才更新，于是紧随
  // 其后的 ITCM 控制字写入会读到旧值（ModelSim 下实测写成 000000x1）。过程赋值
  // 是立即生效的，两个仿真器上都能拿到正确的控制字。
  reg  [31:0] layer_ctrl_word;

  reg        win_started;
  reg        win_done;
  reg [31:0] win_start_cycle;
  reg [31:0] win_end_cycle;
  reg        icb_load_mode;

  always @(posedge hfclk or negedge rst_n) begin
    if (rst_n == 1'b0) begin
      fc1_start_pc_count <= 0;
      fc1_last_valid_pc <= 32'b0;
    end else if (o15_mmio_test && pc_vld) begin
      fc1_last_valid_pc <= pc;
      if (pc == FC1_START_PC)
        fc1_start_pc_count <= fc1_start_pc_count + 1;
    end
  end

  always @(posedge hfclk or negedge rst_n) begin
    if (rst_n == 1'b0) begin
      fc1_pending_kind <= FC1_KIND_NONE;
      fc1_pending_addr <= 32'b0;
      fc1_pending_read <= 1'b0;
      fc1_pending_wdata <= 32'b0;
      fc1_load_count <= 0;
      fc1_start_count <= 0;
      fc1_output_count <= 0;
      fc1_meta_count <= 0;
      fc1_status_count <= 0;
      fc1_status_miss <= 0;
      fc1_done_seen <= 1'b0;
      fc1_result_valid_seen <= 1'b0;
    end else if (o15_mmio_test) begin
      if (fc1_o15_cmd_valid && fc1_o15_cmd_ready) begin
        fc1_pending_kind <= FC1_KIND_NONE;
        fc1_pending_addr <= fc1_o15_cmd_addr;
        fc1_pending_read <= fc1_o15_cmd_read;
        fc1_pending_wdata <= fc1_o15_cmd_wdata;
        if (!fc1_o15_cmd_read && fc1_o15_cmd_addr == FC1_CTRL_ADDR) begin
          if (fc1_o15_cmd_wmask !== 4'hf
                  || fc1_o15_cmd_wdata !== (full_ffn_mmio ? 32'd3 :
                                              (layer_ctrl_word | (fc1_accel_load ? 32'd4 : 32'd0)))
                  || fc1_start_count != 0 || fc1_load_count != 0)
            $fatal(1, "O15 expected one start (layer %0d, ctrl %h) before parameter loads: got %h",
                   layer_arg, layer_ctrl_word, fc1_o15_cmd_wdata);
          fc1_start_count <= fc1_start_count + 1;
        end else if (!fc1_o15_cmd_read && (fc1_o15_cmd_addr == FC1_LOAD_ADDR
                                        || fc1_o15_cmd_addr == FC1_LOAD32_ADDR)) begin
          // +0x10 送 1 个参数；+0x1c 送 2 个（低半字在前，对应共享 SRAM 连续地址递增）
          if (fc1_o15_cmd_wmask !== 4'hf || fc1_start_count != 1
                  || fc1_load_count >= o15_load_limit)
            $fatal(1, "O15 unexpected parameter write %0d: %h", fc1_load_count,
                   fc1_o15_cmd_wdata);
          if (fc1_o15_cmd_wdata[15:0] !== expected_load_word(fc1_load_count))
            $fatal(1, "FC1 param %0d (lo): got %h expected %h", fc1_load_count,
                   fc1_o15_cmd_wdata[15:0], expected_load_word(fc1_load_count));
          if (fc1_o15_cmd_addr == FC1_LOAD32_ADDR) begin
            if (fc1_load_count + 1 >= o15_load_limit)
              $fatal(1, "O15 packed write overruns limit: %0d", fc1_load_count);
            if (fc1_o15_cmd_wdata[31:16] !== expected_load_word(fc1_load_count + 1))
              $fatal(1, "FC1 param %0d (hi): got %h expected %h", fc1_load_count + 1,
                     fc1_o15_cmd_wdata[31:16], expected_load_word(fc1_load_count + 1));
            fc1_load_count <= fc1_load_count + 2;
            if (fc1_load_count + 2 == o15_load_limit) begin
              ph_load_done_cycle <= cycle_count;
              ph_load_done_flag  <= 1'b1;
            end
          end else begin
            fc1_load_count <= fc1_load_count + 1;
          if (fc1_load_count + 1 == o15_load_limit) begin
            ph_load_done_cycle <= cycle_count;
            ph_load_done_flag  <= 1'b1;
          end
          end
        end else if (!fc1_o15_cmd_read) begin
          $fatal(1, "FC1 unexpected O15 write at %h", fc1_o15_cmd_addr);
        end

        if (fc1_o15_cmd_read && fc1_o15_cmd_addr == O15_BASE) begin
          fc1_pending_kind <= FC1_KIND_ID;
        end else if (fc1_o15_cmd_read && fc1_o15_cmd_addr == FC1_OUTPUT_ADDR) begin
          // 成对读取：一次 32 位读拿回两个结果，所以读的次数字号必须是偶数。
          // wrapper 在缓冲未满时保持 cmd_ready=0，命令不会在这里出现，
          // 因此不再需要 result_valid / metadata 前置检查。
          if ((!fc1_accel_load && fc1_load_count != o15_load_limit)
                  || (fc1_accel_load && accel_read_rsp_count != FC1_LOAD_COUNT / 2)
                  || fc1_output_count >= o15_output_limit
                  || (fc1_output_count % 2) != 0)
            $fatal(1, "FC1 output read at unexpected state: outputs=%0d loads=%0d",
                   fc1_output_count, fc1_load_count);
          fc1_pending_kind <= FC1_KIND_OUTPUT;
        end else if (fc1_o15_cmd_read && fc1_o15_cmd_addr == FC1_META_ADDR) begin
          // metadata 只在末尾读一次，允许在任何已有结果之后
          if (fc1_output_count == 0)
            $fatal(1, "FC1 metadata read before any output");
          fc1_pending_kind <= FC1_KIND_META;
        end else if (fc1_o15_cmd_read && fc1_o15_cmd_addr == FC1_STATUS_ADDR) begin
          fc1_pending_kind <= FC1_KIND_STATUS;
          fc1_status_count <= fc1_status_count + 1;
        end else if (fc1_o15_cmd_read) begin
          $fatal(1, "FC1 unexpected O15 read at %h", fc1_o15_cmd_addr);
        end
      end

      if (fc1_o15_rsp_valid && fc1_o15_rsp_ready) begin
        if (fc1_o15_rsp_err)
          $fatal(1, "FC1 O15 response error addr=%h read=%b wdata=%h kind=%0d loads=%0d starts=%0d outputs=%0d metadata=%0d rdata=%h start_valid=%b start_ready=%b load_ready=%b busy=%b task_error=%b state=%h",
                 fc1_pending_addr, fc1_pending_read, fc1_pending_wdata,
                 fc1_pending_kind, fc1_load_count, fc1_start_count,
                 fc1_output_count, fc1_meta_count, fc1_o15_rsp_rdata,
                 fc1_task_start_valid, fc1_task_start_ready,
                 fc1_task_load_ready, fc1_task_busy, fc1_task_error,
                 fc1_task_state);
        case (fc1_pending_kind)
          FC1_KIND_ID: begin
            if (fc1_o15_rsp_rdata !== 32'h5441_534b)
              $fatal(1, "FC1 O15 ID mismatch: %h", fc1_o15_rsp_rdata);
          end
          FC1_KIND_OUTPUT: begin
            // 一次读回两个结果：[15:0] 是先产出的，[31:16] 是后产出的
            if (fc1_output_count + 2 > o15_output_limit)
              $fatal(1, "O15 CPU read too many output words: %0d", fc1_output_count);
            if (full_ffn_mmio) begin
              if (fc1_o15_rsp_rdata[15:0] !== full_expected[fc1_output_count])
                $fatal(1, "O15 FFN output %0d (lo): got %h expected %h",
                       fc1_output_count, fc1_o15_rsp_rdata[15:0],
                       full_expected[fc1_output_count]);
              if (fc1_o15_rsp_rdata[31:16] !== full_expected[fc1_output_count+1])
                $fatal(1, "O15 FFN output %0d (hi): got %h expected %h",
                       fc1_output_count+1, fc1_o15_rsp_rdata[31:16],
                       full_expected[fc1_output_count+1]);
            end else begin
              if (fc1_o15_rsp_rdata[15:0] !== fc1_expected[fc1_output_count])
                $fatal(1, "FC1 output %0d (lo): got %h expected %h",
                       fc1_output_count, fc1_o15_rsp_rdata[15:0],
                       fc1_expected[fc1_output_count]);
              if (fc1_o15_rsp_rdata[31:16] !== fc1_expected[fc1_output_count+1])
                $fatal(1, "FC1 output %0d (hi): got %h expected %h",
                       fc1_output_count+1, fc1_o15_rsp_rdata[31:16],
                       fc1_expected[fc1_output_count+1]);
            end
            fc1_output_count <= fc1_output_count + 2;
            if (!ph_first_out_flag) begin
              ph_first_out_cycle <= cycle_count;
              ph_first_out_flag  <= 1'b1;
            end
          end
          FC1_KIND_META: begin
            // 只在末尾读一次：地址字段应为最后一个结果的下标，
            // 高 16 位（9 个保留位 + 7 位溢出计数）与饱和位都应为 0。
            if (fc1_output_count == 0)
              $fatal(1, "FC1 metadata read before any output");
            if (fc1_o15_rsp_rdata[14:0] !== (fc1_output_count - 1)
                    || fc1_o15_rsp_rdata[16] !== 1'b0
                    || fc1_o15_rsp_rdata[22:17] !== 6'b0
                    || fc1_o15_rsp_rdata[31:23] !== 9'b0)
              $fatal(1, "FC1 metadata: %h (outputs=%0d)", fc1_o15_rsp_rdata, fc1_output_count);
            fc1_meta_count <= fc1_meta_count + 1;
          end
          FC1_KIND_STATUS: begin
            if (fc1_o15_rsp_rdata[2])
              $fatal(1, "FC1 accelerator error status: %h", fc1_o15_rsp_rdata);
            // result_valid 未就绪 → 这次轮询是纯等待，单独计数
            // STATUS 的 bit4 现在是成对缓冲满标志（原为 write_valid）。
            // 固件不再逐输出轮询，所以这里只做记录，不参与通过判定。
            fc1_result_valid_seen <= fc1_o15_rsp_rdata[4];
            if (fc1_o15_rsp_rdata[1]) begin
              if (fc1_o15_rsp_rdata[0] || fc1_o15_rsp_rdata[3] || fc1_o15_rsp_rdata[4]
                      || (!fc1_accel_load && fc1_load_count != o15_load_limit)
                      || (fc1_accel_load && accel_read_rsp_count != FC1_LOAD_COUNT / 2)
                      || fc1_start_count != 1
                      || fc1_output_count != o15_output_limit
                      || fc1_meta_count > 1)
                $fatal(1, "O15 done status before all MMIO checks completed");
              fc1_done_seen <= 1'b1;
            end
          end
          default: begin end
        endcase
        fc1_pending_kind <= FC1_KIND_NONE;
      end
    end
  end

  always @(posedge hfclk or negedge rst_n) begin
    if (!rst_n) begin
      accel_read_cmd_count <= 0;
      accel_read_rsp_count <= 0;
    end else if (fc1_accel_load) begin
      if (`ACC_PORT.acc_sram_icb_cmd_valid && `ACC_PORT.acc_sram_icb_cmd_ready) begin
        accel_word_index = accel_read_cmd_count;
        if (accel_word_index < 8192)
          accel_expected_addr = 32'hA000_0000 + accel_word_index * 4;
        else if (accel_word_index < 8320)
          accel_expected_addr = 32'hA000_8000 + (accel_word_index - 8192) * 4;
        else
          accel_expected_addr = 32'hA001_0280 + (accel_word_index - 8320) * 4;
        if (`ACC_PORT.acc_sram_icb_cmd_read !== 1'b1
                || `ACC_PORT.acc_sram_icb_cmd_addr !== accel_expected_addr
                || accel_word_index >= FC1_LOAD_COUNT / 2)
          $fatal(1, "accelerator SRAM command %0d: read=%b addr=%h expected=%h",
                 accel_word_index, `ACC_PORT.acc_sram_icb_cmd_read,
                 `ACC_PORT.acc_sram_icb_cmd_addr, accel_expected_addr);
        accel_read_cmd_count <= accel_read_cmd_count + 1;
      end
      if (`ACC_PORT.acc_sram_icb_rsp_valid && `ACC_PORT.acc_sram_icb_rsp_ready) begin
        accel_word_index = accel_read_rsp_count * 2;
        accel_expected_data = {expected_load_word(accel_word_index + 1),
                               expected_load_word(accel_word_index)};
        if (accel_read_rsp_count >= FC1_LOAD_COUNT / 2
                || `ACC_PORT.acc_sram_icb_rsp_rdata !== accel_expected_data)
          $fatal(1, "accelerator SRAM response %0d: got=%h expected=%h",
                 accel_read_rsp_count, `ACC_PORT.acc_sram_icb_rsp_rdata,
                 accel_expected_data);
        accel_read_rsp_count <= accel_read_rsp_count + 1;
        if (accel_read_rsp_count + 1 == FC1_LOAD_COUNT / 2) begin
          if (accel_read_cmd_count != FC1_LOAD_COUNT / 2)
            $fatal(1, "accelerator responses completed before all commands: cmds=%0d",
                   accel_read_cmd_count);
        end
      end
    end
  end

  reg [31:0] pc_write_to_host_cnt;
  reg [31:0] pc_write_to_host_cycle;
  reg [31:0] valid_ir_cycle;
  reg pc_write_to_host_flag;

  always @(posedge hfclk or negedge rst_n)
  begin 
    if(rst_n == 1'b0) begin
        pc_write_to_host_cnt <= 32'b0;
        pc_write_to_host_flag <= 1'b0;
        pc_write_to_host_cycle <= 32'b0;
    end
    else if (pc_vld & (pc == `PC_WRITE_TOHOST)) begin
        pc_write_to_host_cnt <= pc_write_to_host_cnt + 1'b1;
        pc_write_to_host_flag <= 1'b1;
        if (pc_write_to_host_flag == 1'b0) begin
            pc_write_to_host_cycle <= cycle_count;
        end
    end
  end

  always @(posedge hfclk or negedge rst_n)
  begin 
    if(rst_n == 1'b0) begin
        cycle_count <= 32'b0;
    end
    else begin
        cycle_count <= cycle_count + 1'b1;
    end
  end

  // ------------------------------------------------------------------
  // 单任务计时窗口（赛题 L99）
  //   起：CPU 写 O15 CTRL —— 自此开始装载输入与参数
  //   止：CPU 读走第 FC1_OUTPUT_COUNT 个输出 —— 结果全部写回
  // 任务开始前的复位与 CPU 启动都不在窗口内，与赛题口径一致。
  // ------------------------------------------------------------------
  // 计时起点判定（B 口径）：只认“第一笔被共享 SRAM 接受的参数写”。
  // 若 FC1_SRAM=1 时窗口被“写 CTRL”抢先打开，说明固件没做真实搬运，
  // 必须当场报错——否则窗口会变短、吞吐虚高，而测试台仍然打印 PASS。
  // 参数区写事务另做计数，收尾时校验总数。
  wire win_sram_wr = `SS_MEMS.mem_icb_cmd_valid && `SS_MEMS.mem_icb_cmd_ready
                     && !`SS_MEMS.mem_icb_cmd_read
                     && (`SS_MEMS.mem_icb_cmd_addr[31:19] == 13'h1400);
  wire win_ctrl_wr = fc1_o15_cmd_valid && fc1_o15_cmd_ready
                     && !fc1_o15_cmd_read && fc1_o15_cmd_addr == FC1_CTRL_ADDR;

  reg [15:0] sram_param_wr_cnt;
  always @(posedge hfclk or negedge rst_n)
  begin
    if (rst_n == 1'b0)
        sram_param_wr_cnt <= 16'd0;
    else if (`SS_MEMS.mem_icb_cmd_valid && `SS_MEMS.mem_icb_cmd_ready
             && !`SS_MEMS.mem_icb_cmd_read
             && (`SS_MEMS.mem_icb_cmd_addr[31:20] == 12'hA00))
        sram_param_wr_cnt <= sram_param_wr_cnt + 16'd1;
  end

  always @(posedge hfclk or negedge rst_n)
  begin
    if (rst_n == 1'b0) begin
        win_started     <= 1'b0;
        win_done        <= 1'b0;
        win_start_cycle <= 32'b0;
        win_end_cycle   <= 32'b0;
    end
    else if (o15_mmio_test) begin
        if (!win_started && (win_sram_wr || win_ctrl_wr)) begin
            if (fc1_sram_use && !full_ffn_mmio && win_ctrl_wr && !win_sram_wr)
                $fatal(1, "window opened by CTRL write before any shared-SRAM parameter write: FC1_SRAM=1 requires the firmware to copy parameters first");
            win_started     <= 1'b1;
            win_start_cycle <= cycle_count;
        end
        // 计时终点：最后一个输出字的**响应握手**（结果真正交到 CPU），
        // 而不是发出读命令的时刻 —— 后者比响应早 1—3 个总线往返周期，
        // 会少算尾部延迟（赛题 L99 要求计到"结果全部写回"）。
        // 成对读取后每个响应带回两个结果，所以判据是"这次响应之后刚好读满"，
        // 而不是 fc1_output_count == limit-1（那是逐个读取时代的奇数值，永不命中）。
        if (win_started && !win_done && fc1_o15_rsp_valid && fc1_o15_rsp_ready
                && fc1_pending_kind == FC1_KIND_OUTPUT
                && (fc1_output_count + 2 == o15_output_limit)) begin
            if (fc1_sram_use && !full_ffn_mmio && sram_param_wr_cnt != 16'd11488)
                $fatal(1, "shared-SRAM parameter writes = %0d, expected 11488 (W1 8192 + b1 128 + X 3168)", sram_param_wr_cnt);
            win_done      <= 1'b1;
            win_end_cycle <= cycle_count;
        end
    end
  end

  // ------------------------------------------------------------------
  // 主口带宽只读诊断（不改任何被测逻辑）
  //   目的：判断“11,488 字 / 45,952 拍 = 4 拍/字”到底是
  //         (a) 单笔在途的协议限制 → SRAM 在往返期间空闲，允许 2 笔在途即可提速；
  //         (b) 共享 SRAM 端口带宽限制 → 端口本来就忙，改协议无益。
  //   判据：spare 占 span 的比例高 → (a)；busy 高而 spare 低 → (b)。
  // ------------------------------------------------------------------
  wire acc_cmd_vld = `ACC_PORT.u_e203_task_smoke_mmio.acc_sram_icb_cmd_valid;
  wire acc_cmd_rdy = `ACC_PORT.u_e203_task_smoke_mmio.acc_sram_icb_cmd_ready;
  wire acc_rsp_vld = `ACC_PORT.u_e203_task_smoke_mmio.acc_sram_icb_rsp_valid;
  wire mrg_cmd_vld = `SS_MEMS.mrg_icb_cmd_valid;
  wire mrg_cmd_rdy = `SS_MEMS.mrg_icb_cmd_ready;

  reg        acc_rd_on;
  reg [15:0] acc_rd_cmds;
  reg [15:0] acc_rd_rsps;
  reg [31:0] acc_rd_span;
  reg [31:0] acc_rd_spare;   // 取数期间：共享 SRAM 命令口没有命令
  reg [31:0] acc_rd_busy;    // 取数期间：有命令但 SRAM 未 ready（反压）
  reg [15:0] acc_rd_overlap; // 发命令时已有未收回响应的次数（>0 即证明并发在途）

  always @(posedge hfclk or negedge rst_n) begin
    if (rst_n == 1'b0) begin
        acc_rd_on      <= 1'b0;
        acc_rd_cmds    <= 16'd0;
        acc_rd_rsps    <= 16'd0;
        acc_rd_span    <= 32'd0;
        acc_rd_spare   <= 32'd0;
        acc_rd_busy    <= 32'd0;
        acc_rd_overlap <= 16'd0;
    end else begin
        if (acc_cmd_vld && acc_cmd_rdy) begin
            if (!acc_rd_on) begin
                acc_rd_on    <= 1'b1;
                acc_rd_span  <= 32'd0;
                acc_rd_spare <= 32'd0;
                acc_rd_busy  <= 32'd0;
            end
            // 此刻还有响应没回来 → 这一笔是在“另一笔在途”时发出的
            if (acc_rd_cmds != acc_rd_rsps)
                acc_rd_overlap <= acc_rd_overlap + 16'd1;
            acc_rd_cmds <= acc_rd_cmds + 16'd1;
        end
        if (acc_rd_on) begin
            acc_rd_span <= acc_rd_span + 32'd1;
            if (!mrg_cmd_vld)                acc_rd_spare <= acc_rd_spare + 32'd1;
            if (mrg_cmd_vld && !mrg_cmd_rdy) acc_rd_busy  <= acc_rd_busy  + 32'd1;
            if (acc_rsp_vld) begin
                acc_rd_rsps <= acc_rd_rsps + 16'd1;
                // 第 11,488 笔响应返回后关闭统计（这正是“取数段结束”的时刻）
                if (acc_rd_rsps == 16'd11487) begin
                    acc_rd_on         <= 1'b0;
                    mp_acc_done_cycle <= cycle_count;
                    mp_acc_done_flag  <= 1'b1;
                end
            end
        end
    end
  end

  wire i_valid = `EXU.i_valid;
  wire i_ready = `EXU.i_ready;

  always @(posedge hfclk or negedge rst_n)
  begin 
    if(rst_n == 1'b0) begin
        valid_ir_cycle <= 32'b0;
    end
    else if(i_valid & i_ready & (pc_write_to_host_flag == 1'b0)) begin
        valid_ir_cycle <= valid_ir_cycle + 1'b1;
    end
  end


  // Randomly force the external interrupt
  `define EXT_IRQ u_e203_soc_top.u_e203_subsys_top.u_e203_subsys_main.plic_ext_irq
  `define SFT_IRQ u_e203_soc_top.u_e203_subsys_top.u_e203_subsys_main.clint_sft_irq
  `define TMR_IRQ u_e203_soc_top.u_e203_subsys_top.u_e203_subsys_main.clint_tmr_irq

  `define U_CPU u_e203_soc_top.u_e203_subsys_top.u_e203_subsys_main.u_e203_cpu_top.u_e203_cpu
  `define ITCM_BUS_ERR `U_CPU.u_e203_itcm_ctrl.sram_icb_rsp_err
  `define ITCM_BUS_READ `U_CPU.u_e203_itcm_ctrl.sram_icb_rsp_read
  `define STATUS_MIE   `U_CPU.u_e203_core.u_e203_exu.u_e203_exu_commit.u_e203_exu_excp.status_mie_r

  wire stop_assert_irq = (pc_write_to_host_cnt > 32);

  reg tb_itcm_bus_err;

  reg tb_ext_irq;
  reg tb_tmr_irq;
  reg tb_sft_irq;
  initial begin
    tb_ext_irq = 1'b0;
    tb_tmr_irq = 1'b0;
    tb_sft_irq = 1'b0;
  end

`ifdef ENABLE_TB_FORCE
  initial begin
    tb_itcm_bus_err = 1'b0;
    #100
    @(pc == `PC_AFTER_SETMTVEC ) // Wait the program goes out the reset_vector program
    forever begin
      repeat ($urandom_range(1, 20)) @(posedge clk) tb_itcm_bus_err = 1'b0; // Wait random times
      repeat ($urandom_range(1, 200)) @(posedge clk) tb_itcm_bus_err = 1'b1; // Wait random times
      if(stop_assert_irq) begin
          break;
      end
    end
  end


  initial begin
    force `EXT_IRQ = tb_ext_irq;
    force `SFT_IRQ = tb_sft_irq;
    force `TMR_IRQ = tb_tmr_irq;
       // We force the bus-error only when:
       //   It is in common code, not in exception code, by checking MIE bit
       //   It is in read operation, not write, otherwise the test cannot recover
    force `ITCM_BUS_ERR = tb_itcm_bus_err
                        & `STATUS_MIE 
                        & `ITCM_BUS_READ
                        ;
  end


  initial begin
    #100
    @(pc == `PC_AFTER_SETMTVEC ) // Wait the program goes out the reset_vector program
    forever begin
      repeat ($urandom_range(1, 1000)) @(posedge clk) tb_ext_irq = 1'b0; // Wait random times
      tb_ext_irq = 1'b1; // assert the irq
      @((pc == `PC_EXT_IRQ_BEFOR_MRET)) // Wait the program run into the IRQ handler by check PC values
      tb_ext_irq = 1'b0;
      if(stop_assert_irq) begin
          break;
      end
    end
  end

  initial begin
    #100
    @(pc == `PC_AFTER_SETMTVEC ) // Wait the program goes out the reset_vector program
    forever begin
      repeat ($urandom_range(1, 1000)) @(posedge clk) tb_sft_irq = 1'b0; // Wait random times
      tb_sft_irq = 1'b1; // assert the irq
      @((pc == `PC_SFT_IRQ_BEFOR_MRET)) // Wait the program run into the IRQ handler by check PC values
      tb_sft_irq = 1'b0;
      if(stop_assert_irq) begin
          break;
      end
    end
  end

  initial begin
    #100
    @(pc == `PC_AFTER_SETMTVEC ) // Wait the program goes out the reset_vector program
    forever begin
      repeat ($urandom_range(1, 1000)) @(posedge clk) tb_tmr_irq = 1'b0; // Wait random times
      tb_tmr_irq = 1'b1; // assert the irq
      @((pc == `PC_TMR_IRQ_BEFOR_MRET)) // Wait the program run into the IRQ handler by check PC values
      tb_tmr_irq = 1'b0;
      if(stop_assert_irq) begin
          break;
      end
    end
  end
`endif

  // 可选看门狗：12 任务测量时要跑 12 次仿真，某一次挂住会白等。
  // 单任务窗口约 16.2 ms 仿真时间，200 ms 足够。用 +TASK12_TIMEOUT 显式开启。
  initial begin
    if ($test$plusargs("TASK12_TIMEOUT")) begin
      #200_000_000;
      $display("TASK12_SOC_TIMEOUT watchdog fired after 200 ms");
      $finish;
    end
  end

  initial begin
    $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");  
    if($value$plusargs("TESTCASE=%s",testcase))begin
      $display("TESTCASE=%s",testcase);
    end

    fc1_mmio = 1'b0;
    full_ffn_mmio = 1'b0;
    fc1_mode_arg = 0;
    if ($value$plusargs("FC1_MMIO=%d", fc1_mode_arg)) begin
      if (fc1_mode_arg != 0 && fc1_mode_arg != 1)
        $fatal(1, "FC1_MMIO must be 0 or 1");
      fc1_mmio = (fc1_mode_arg == 1);
    end
    full_ffn_mode_arg = 0;
    if ($value$plusargs("FULL_FFN_MMIO=%d", full_ffn_mode_arg)) begin
      if (full_ffn_mode_arg != 0 && full_ffn_mode_arg != 1)
        $fatal(1, "FULL_FFN_MMIO must be 0 or 1");
      full_ffn_mmio = (full_ffn_mode_arg == 1);
    end
    layer_param = 0;
    if ($value$plusargs("LAYER=%d", layer_param)) begin
      if (layer_param < 0 || layer_param > 11)
        $fatal(1, "LAYER must be 0..11");
      $display("LAYER=%0d ctrl_word=%h", layer_param, {24'b0, layer_param[3:0], 3'b0, 1'b1});
    end
    layer_ctrl_word = {24'b0, layer_param[3:0], 3'b0, 1'b1};
    icb_load_mode = $test$plusargs("ICB_LOAD");
    if (fc1_mmio && full_ffn_mmio)
      $fatal(1, "Select only one of FC1_MMIO or FULL_FFN_MMIO");
    fc1_sram_arg = 0;
    if ($value$plusargs("FC1_SRAM=%d", fc1_sram_arg)) begin
      if (fc1_sram_arg < 0 || fc1_sram_arg > 1)
        $fatal(1, "FC1_SRAM must be 0 or 1");
    end
    fc1_sram_use = (fc1_sram_arg == 1);
    ffn_staged = 1'b0;
    if ($value$plusargs("FFN_STAGED=%d", ffn_staged_arg)) begin
      if (ffn_staged_arg != 0 && ffn_staged_arg != 1)
        $fatal(1, "FFN_STAGED must be 0 or 1");
      ffn_staged = (ffn_staged_arg == 1);
    end
    if (ffn_staged && !full_ffn_mmio)
      $fatal(1, "FFN_STAGED=1 requires +FULL_FFN_MMIO=1");
    if (ffn_staged)
      $display("FFN_STAGED=1: W1/b1 staged in ITCM, W2/b2/X staged in DTCM");
    fc1_accel_load = fc1_sram_use && !full_ffn_mmio;
    if (fc1_accel_load && icb_load_mode)
      $fatal(1, "ICB_LOAD drives the CPU mem_icb port; use the CPU lw/sw loader for accelerator direct-read tests");
    if (fc1_sram_use && !fc1_mmio)
      $fatal(1, "FC1_SRAM=1 requires +FC1_MMIO=1");
    if (fc1_sram_use)
      $display("FC1_SRAM=1: parameters taken from SHARED SRAM (use o15_task12_sram.S)");
    if (fc1_mmio || full_ffn_mmio) begin
      if (!$value$plusargs("WEIGHTS=%s", fc1_weights_file))
        $fatal(1, "Pass +WEIGHTS=<file> for layer_00_weight.hex");
      if (!$value$plusargs("BIASES=%s", fc1_biases_file))
        $fatal(1, "Pass +BIASES=<file> for layer_00_bias.hex");
      if (!$value$plusargs("INPUTS=%s", fc1_inputs_file))
        $fatal(1, "Pass +INPUTS=<file> for sample_000030/layer_00_x.hex");
      if (!$value$plusargs("EXPECTED=%s", fc1_expected_file))
        $fatal(1, "Pass +EXPECTED=<file> for FC1 or full FFN outputs");
      if (full_ffn_mmio) begin
        if (!$value$plusargs("WEIGHTS2=%s", full_weights2_file))
          $fatal(1, "Pass +WEIGHTS2=<file> for layer_00_weight2.hex");
        if (!$value$plusargs("BIASES2=%s", full_biases2_file))
          $fatal(1, "Pass +BIASES2=<file> for layer_00_bias2.hex");
      end
      $readmemh(fc1_weights_file, fc1_weights);
      $readmemh(fc1_biases_file, fc1_biases);
      $readmemh(fc1_inputs_file, fc1_inputs);
      if (full_ffn_mmio) begin
        $readmemh(full_weights2_file, full_weights2);
        $readmemh(full_biases2_file, full_biases2);
        $readmemh(fc1_expected_file, full_expected);
      end else begin
        $readmemh(fc1_expected_file, fc1_expected);
      end
      for (fc1_vector_index = 0; fc1_vector_index < FC1_WEIGHT_COUNT;
           fc1_vector_index = fc1_vector_index + 1)
        if ((^fc1_weights[fc1_vector_index]) === 1'bx)
          $fatal(1, "FC1 weight vector incomplete at %0d", fc1_vector_index);
      for (fc1_vector_index = 0; fc1_vector_index < FC1_BIAS_COUNT;
           fc1_vector_index = fc1_vector_index + 1)
        if ((^fc1_biases[fc1_vector_index]) === 1'bx)
          $fatal(1, "FC1 bias vector incomplete at %0d", fc1_vector_index);
      for (fc1_vector_index = 0; fc1_vector_index < FC1_INPUT_COUNT;
           fc1_vector_index = fc1_vector_index + 1)
        if ((^fc1_inputs[fc1_vector_index]) === 1'bx)
          $fatal(1, "FC1 input vector incomplete at %0d", fc1_vector_index);
      if (full_ffn_mmio) begin
        for (fc1_vector_index = 0; fc1_vector_index < FC1_WEIGHT_COUNT;
             fc1_vector_index = fc1_vector_index + 1)
          if ((^full_weights2[fc1_vector_index]) === 1'bx)
            $fatal(1, "Full FFN FC2 weight vector incomplete at %0d", fc1_vector_index);
        for (fc1_vector_index = 0; fc1_vector_index < FULL_B2_COUNT;
             fc1_vector_index = fc1_vector_index + 1)
          if ((^full_biases2[fc1_vector_index]) === 1'bx)
            $fatal(1, "Full FFN FC2 bias vector incomplete at %0d", fc1_vector_index);
        for (fc1_vector_index = 0; fc1_vector_index < FULL_OUTPUT_COUNT;
             fc1_vector_index = fc1_vector_index + 1)
          if ((^full_expected[fc1_vector_index]) === 1'bx)
            $fatal(1, "Full FFN expected vector incomplete at %0d", fc1_vector_index);
        if (FULL_INPUT_OFFSET + FC1_INPUT_COUNT * 2 > SHARED_SRAM_BYTES)
          $fatal(1, "Full FFN vectors exceed shared SRAM capacity");
      end else begin
        for (fc1_vector_index = 0; fc1_vector_index < FC1_OUTPUT_COUNT;
             fc1_vector_index = fc1_vector_index + 1)
          if ((^fc1_expected[fc1_vector_index]) === 1'bx)
            $fatal(1, "FC1 expected vector incomplete at %0d", fc1_vector_index);
      end
      if (FC1_INPUT_OFFSET + FC1_INPUT_COUNT * 2 > (1 << `E203_ITCM_ADDR_WIDTH))
        $fatal(1, "FC1 vectors exceed ITCM capacity");
    end

    pc_write_to_host_flag <=0;
    clk   <=0;
    lfextclk   <=0;
    rst_n <=0;

    $readmemh({testcase, ".verilog"}, itcm_mem);
    for (i=0;i<(`E203_ITCM_RAM_DP);i=i+1) begin
        `ITCM.mem_r[i][00+7:00] = itcm_mem[i*8+0];
        `ITCM.mem_r[i][08+7:08] = itcm_mem[i*8+1];
        `ITCM.mem_r[i][16+7:16] = itcm_mem[i*8+2];
        `ITCM.mem_r[i][24+7:24] = itcm_mem[i*8+3];
        `ITCM.mem_r[i][32+7:32] = itcm_mem[i*8+4];
        `ITCM.mem_r[i][40+7:40] = itcm_mem[i*8+5];
        `ITCM.mem_r[i][48+7:48] = itcm_mem[i*8+6];
        `ITCM.mem_r[i][56+7:56] = itcm_mem[i*8+7];
    end

    if (fc1_mmio || full_ffn_mmio) begin
      if (full_ffn_mmio && ffn_staged) begin
        // W1 → ITCM 0x1000（32,768 B）；b1 → ITCM 0x9000（512 B）
        for (i = 0; i < FC1_WEIGHT_COUNT; i = i + 1) begin
          fc1_byte_addr = 32'h1000 + i * 2;
          `ITCM.mem_r[fc1_byte_addr >> 3][(fc1_byte_addr & 7)*8 +: 8] = fc1_weights[i][7:0];
          `ITCM.mem_r[(fc1_byte_addr+1) >> 3][((fc1_byte_addr+1) & 7)*8 +: 8] = fc1_weights[i][15:8];
        end
        for (i = 0; i < FC1_BIAS_COUNT; i = i + 1) begin
          fc1_byte_addr = 32'h9000 + i * 2;
          `ITCM.mem_r[fc1_byte_addr >> 3][(fc1_byte_addr & 7)*8 +: 8] = fc1_biases[i][7:0];
          `ITCM.mem_r[(fc1_byte_addr+1) >> 3][((fc1_byte_addr+1) & 7)*8 +: 8] = fc1_biases[i][15:8];
        end
        // W2 → DTCM 0x0000（32,768 B）；b2 → DTCM 0x8000（128 B）；X → DTCM 0x8080（12,672 B）
        for (i = 0; i < FC1_WEIGHT_COUNT; i = i + 1) begin
          fc1_byte_addr = 32'h0000 + i * 2;
          `DTCM.mem_r[fc1_byte_addr >> 2][(fc1_byte_addr & 3)*8 +: 8] = full_weights2[i][7:0];
          `DTCM.mem_r[(fc1_byte_addr+1) >> 2][((fc1_byte_addr+1) & 3)*8 +: 8] = full_weights2[i][15:8];
        end
        for (i = 0; i < FULL_B2_COUNT; i = i + 1) begin
          fc1_byte_addr = 32'h8000 + i * 2;
          `DTCM.mem_r[fc1_byte_addr >> 2][(fc1_byte_addr & 3)*8 +: 8] = full_biases2[i][7:0];
          `DTCM.mem_r[(fc1_byte_addr+1) >> 2][((fc1_byte_addr+1) & 3)*8 +: 8] = full_biases2[i][15:8];
        end
        for (i = 0; i < FC1_INPUT_COUNT; i = i + 1) begin
          fc1_byte_addr = 32'h8080 + i * 2;
          `DTCM.mem_r[fc1_byte_addr >> 2][(fc1_byte_addr & 3)*8 +: 8] = fc1_inputs[i][7:0];
          `DTCM.mem_r[(fc1_byte_addr+1) >> 2][((fc1_byte_addr+1) & 3)*8 +: 8] = fc1_inputs[i][15:8];
        end
        $display("Full FFN vectors staged: ITCM W1@0x1000 b1@0x9000, DTCM W2@0x0000 b2@0x8000 X@0x8080");
      end else if (full_ffn_mmio) begin
        for (i = 0; i < FC1_WEIGHT_COUNT; i = i + 1) begin
          fc1_byte_addr = FULL_W1_OFFSET + i * 2;
          `SHARED_SRAM.mem_r[fc1_byte_addr >> 2][(fc1_byte_addr & 3)*8 +: 8] = fc1_weights[i][7:0];
          `SHARED_SRAM.mem_r[(fc1_byte_addr+1) >> 2][((fc1_byte_addr+1) & 3)*8 +: 8] = fc1_weights[i][15:8];
        end
        for (i = 0; i < FC1_BIAS_COUNT; i = i + 1) begin
          fc1_byte_addr = FULL_B1_OFFSET + i * 2;
          `SHARED_SRAM.mem_r[fc1_byte_addr >> 2][(fc1_byte_addr & 3)*8 +: 8] = fc1_biases[i][7:0];
          `SHARED_SRAM.mem_r[(fc1_byte_addr+1) >> 2][((fc1_byte_addr+1) & 3)*8 +: 8] = fc1_biases[i][15:8];
        end
        for (i = 0; i < FC1_WEIGHT_COUNT; i = i + 1) begin
          fc1_byte_addr = FULL_W2_OFFSET + i * 2;
          `SHARED_SRAM.mem_r[fc1_byte_addr >> 2][(fc1_byte_addr & 3)*8 +: 8] = full_weights2[i][7:0];
          `SHARED_SRAM.mem_r[(fc1_byte_addr+1) >> 2][((fc1_byte_addr+1) & 3)*8 +: 8] = full_weights2[i][15:8];
        end
        for (i = 0; i < FULL_B2_COUNT; i = i + 1) begin
          fc1_byte_addr = FULL_B2_OFFSET + i * 2;
          `SHARED_SRAM.mem_r[fc1_byte_addr >> 2][(fc1_byte_addr & 3)*8 +: 8] = full_biases2[i][7:0];
          `SHARED_SRAM.mem_r[(fc1_byte_addr+1) >> 2][((fc1_byte_addr+1) & 3)*8 +: 8] = full_biases2[i][15:8];
        end
        for (i = 0; i < FC1_INPUT_COUNT; i = i + 1) begin
          fc1_byte_addr = FULL_INPUT_OFFSET + i * 2;
          `SHARED_SRAM.mem_r[fc1_byte_addr >> 2][(fc1_byte_addr & 3)*8 +: 8] = fc1_inputs[i][7:0];
          `SHARED_SRAM.mem_r[(fc1_byte_addr+1) >> 2][((fc1_byte_addr+1) & 3)*8 +: 8] = fc1_inputs[i][15:8];
        end
        $display("Full FFN vectors loaded into shared SRAM: W1=%0d B1=%0d W2=%0d B2=%0d X=%0d",
                 FC1_WEIGHT_COUNT, FC1_BIAS_COUNT, FC1_WEIGHT_COUNT, FULL_B2_COUNT,
                 FC1_INPUT_COUNT);
      end else begin
        // 单层 FC1 的参数来源有两种：
        //   +FC1_SRAM=1 → 写共享 SRAM（0xA000_0000 起，与 L16 的官方流程一致，
        //                 配合固件 o15_task12_sram.S 使用）
        //   默认        → 写 ITCM（本地快速回归，配合 o15_task12_soc.S 使用）
        // 两种情况下控制字都仍放在 ITCM 0x8000_F000，因为只有 3 个字。
        // 注：这里原有一条 `fc1_sram_use && icb_load_mode` 的“层次写共享 SRAM”分支，
        // 与上方的 $fatal（ICB_LOAD 与加速器直读互斥）矛盾，永远不可达，已删除。
        // 共享 SRAM 里的参数一律由固件用真实 lw/sw 写入（见 o15_task12_sram.S），
        // 测试台只在 0 时刻把参数放进 ITCM。
        begin
          for (i = 0; i < FC1_WEIGHT_COUNT; i = i + 1) begin
            fc1_byte_addr = FC1_WEIGHT_OFFSET + i * 2;
            `ITCM.mem_r[fc1_byte_addr >> 3][(fc1_byte_addr & 7)*8 +: 8] = fc1_weights[i][7:0];
            `ITCM.mem_r[(fc1_byte_addr+1) >> 3][((fc1_byte_addr+1) & 7)*8 +: 8] = fc1_weights[i][15:8];
          end
          for (i = 0; i < FC1_BIAS_COUNT; i = i + 1) begin
            fc1_byte_addr = FC1_BIAS_OFFSET + i * 2;
            `ITCM.mem_r[fc1_byte_addr >> 3][(fc1_byte_addr & 7)*8 +: 8] = fc1_biases[i][7:0];
            `ITCM.mem_r[(fc1_byte_addr+1) >> 3][((fc1_byte_addr+1) & 7)*8 +: 8] = fc1_biases[i][15:8];
          end
          for (i = 0; i < FC1_INPUT_COUNT; i = i + 1) begin
            fc1_byte_addr = FC1_INPUT_OFFSET + i * 2;
            `ITCM.mem_r[fc1_byte_addr >> 3][(fc1_byte_addr & 7)*8 +: 8] = fc1_inputs[i][7:0];
            `ITCM.mem_r[(fc1_byte_addr+1) >> 3][((fc1_byte_addr+1) & 7)*8 +: 8] = fc1_inputs[i][15:8];
          end
          $display("FC1 vectors loaded into ITCM: W1=%0d B1=%0d X=%0d",
                   FC1_WEIGHT_COUNT, FC1_BIAS_COUNT, FC1_INPUT_COUNT);
        end
        // 任务控制字写入 ITCM 尾部，固件从 0x8000_F000 读取。
        // SRAM 加载流程下**不在这里写**：要等参数全部写进共享 SRAM 之后才放行，
        // 否则 CPU 会抢在参数写完之前开始搬运（见下文 loader 之后）。
        if (!icb_load_mode) begin
            `ITCM.mem_r[FC1_CTRL_WORD_OFFSET >> 3][(FC1_CTRL_WORD_OFFSET & 7)*8 +: 32]
                = layer_ctrl_word;
            $display("FC1 task control word @0x8000_%h = %h (layer %0d)",
                     FC1_CTRL_WORD_OFFSET, layer_ctrl_word, layer_param[3:0]);
        end else begin
            // ICB 模式：先把该地址清 0，固件在这里自旋；参数写完再放行
            `ITCM.mem_r[FC1_CTRL_WORD_OFFSET >> 3][(FC1_CTRL_WORD_OFFSET & 7)*8 +: 32] = 32'd0;
        end
      end
    end

    $display("ITCM 0x00: %h", `ITCM.mem_r[8'h00]);
    $display("ITCM 0x01: %h", `ITCM.mem_r[8'h01]);
    $display("ITCM 0x02: %h", `ITCM.mem_r[8'h02]);
    $display("ITCM 0x03: %h", `ITCM.mem_r[8'h03]);
    $display("ITCM 0x04: %h", `ITCM.mem_r[8'h04]);
    $display("ITCM 0x05: %h", `ITCM.mem_r[8'h05]);
    $display("ITCM 0x06: %h", `ITCM.mem_r[8'h06]);
    $display("ITCM 0x07: %h", `ITCM.mem_r[8'h07]);
    $display("ITCM 0x16: %h", `ITCM.mem_r[8'h16]);
    $display("ITCM 0x20: %h", `ITCM.mem_r[8'h20]);

    #120 rst_n <=1;

    if (o15_mmio_test) begin
      wait (fc1_done_seen && (x3 === 32'd1));
      if (full_ffn_mmio)
        $display("FULL_FFN_CPU_MMIO_PASS loads=%0d outputs=%0d metadata=%0d",
                 fc1_load_count, fc1_output_count, fc1_meta_count);
      else if (fc1_accel_load)
        $display("FC1_ACCEL_SRAM_PASS read_commands=%0d read_responses=%0d outputs=%0d",
                 accel_read_cmd_count, accel_read_rsp_count, fc1_output_count);
      else
        $display("FC1_CPU_MMIO_PASS loads=%0d outputs=%0d metadata=%0d",
                 fc1_load_count, fc1_output_count, fc1_meta_count);
    end else begin
      @(pc_write_to_host_cnt == 32'd8) #10 rst_n <=1;
`ifdef ENABLE_TB_FORCE
      @((~tb_tmr_irq) & (~tb_sft_irq) & (~tb_ext_irq)) #10 rst_n <=1;// Wait the interrupt to complete
`endif
    end

        $display("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~~~~ Test Result Summary ~~~~~~~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~");
        $display("~TESTCASE: %s ~~~~~~~~~~~~~", testcase);
        $display("~~~~~~~~~~~~~~Total cycle_count value: %d ~~~~~~~~~~~~~", cycle_count);
        $display("~~~~~~~~~~The valid Instruction Count: %d ~~~~~~~~~~~~~", valid_ir_cycle);
        $display("~~~~~The test ending reached at cycle: %d ~~~~~~~~~~~~~", pc_write_to_host_cycle);
        if (o15_mmio_test) begin
          $display("TASK12_SOC layer=%0d ctrl=%h win_start=%0d win_end=%0d win_cycles=%0d pass=%0d",
                   layer_arg, layer_ctrl_word, win_start_cycle, win_end_cycle,
                   (win_done ? (win_end_cycle - win_start_cycle) : 32'hFFFF_FFFF),
                   (fc1_done_seen && (x3 === 32'd1)));
          // 主口带宽只读诊断：spare/span 高 → 协议受限（可提速）；busy 高 → 端口受限。
          if (acc_rd_cmds != 16'd0)
            $display("ACC_RD_DIAG cmds=%0d rsps=%0d span=%0d spare=%0d busy=%0d overlap=%0d spare_pct=%0d%%",
                     acc_rd_cmds, acc_rd_rsps, acc_rd_span, acc_rd_spare, acc_rd_busy, acc_rd_overlap,
                     (acc_rd_span == 0 ? 32'd0 : (acc_rd_spare * 100) / acc_rd_span));
          // 分段：start → 第 11,488 笔主口响应（取数段结束）→ 窗口结束
          if (mp_acc_done_flag)
            $display("ACC_PHASE start=%0d acc_done=%0d acc_span=%0d tail=%0d end=%0d",
                     win_start_cycle, mp_acc_done_cycle,
                     (mp_acc_done_cycle - win_start_cycle),
                     (win_end_cycle - mp_acc_done_cycle), win_end_cycle);
          // 读回访问分解：固件每个输出做 STATUS + OUTPUT + META 三次总线访问。
          // cycles_per_access 用来判断开销是每笔访问的固定成本，还是轮询/等待。
          $display("TASK12_PHASE start=%0d load_done=%0d(flag=%0d) first_out=%0d(flag=%0d) end=%0d",
           win_start_cycle, ph_load_done_cycle, ph_load_done_flag,
           ph_first_out_cycle, ph_first_out_flag, win_end_cycle);
  $display("TASK12_ACCESS status=%0d status_miss=%0d output=%0d meta=%0d total=%0d",
                   fc1_status_count, fc1_status_miss, fc1_output_count, fc1_meta_count,
                   fc1_status_count + fc1_output_count + fc1_meta_count);
        end
        $display("~~~~~~~~~~~~~~~The final x3 Reg value: %d ~~~~~~~~~~~~~", x3);
        $display("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~");
    // TEST_PASS 必须同时要求：固件报告成功（x3==1）**且**计时窗口真正闭合。
    // 否则 win_done 未触发时会打印 win_cycles=0xFFFFFFFF 哨兵值却仍报 PASS，
    // 让"功能通过"掩盖"计时无效"。
    if ((x3 == 1) && (!o15_mmio_test || win_done)) begin
        $display("~~~~~~~~~~~~~~~~ TEST_PASS ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~ #####     ##     ####    #### ~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~ #    #   #  #   #       #     ~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~ #    #  #    #   ####    #### ~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~ #####   ######       #       #~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~ #       #    #  #    #  #    #~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~ #       #    #   ####    #### ~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~");
    end
    else begin
        $display("~~~~~~~~~~~~~~~~ TEST_FAIL ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~######    ##       #    #     ~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~#        #  #      #    #     ~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~#####   #    #     #    #     ~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~#       ######     #    #     ~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~#       #    #     #    #     ~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~#       #    #     #    ######~~~~~~~~~~~~~~~~");
        $display("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~");
        if (x3 == 1 && o15_mmio_test && !win_done)
            $display("FC1 timing invalid: win_done never asserted (win_cycles would be 0xFFFFFFFF)");
    end
    #10
     $finish;
  end

  initial begin
    #40000000
    if (o15_mmio_test) begin
      $display("FC1 debug: rst_n=%b pc=%h last_valid_pc=%h pc_valid=%b dispatched=%0d x3=%h start_pc_count=%0d start_count=%0d pending=%0d",
               rst_n, pc, fc1_last_valid_pc, pc_vld, valid_ir_cycle, x3,
               fc1_start_pc_count, fc1_start_count, fc1_pending_kind);
      $display("FC1 debug regs: t0=%h t1=%h t2=%h t3=%h",
               `EXU.u_e203_exu_regfile.rf_r[5],
               `EXU.u_e203_exu_regfile.rf_r[6],
               `EXU.u_e203_exu_regfile.rf_r[7],
               `EXU.u_e203_exu_regfile.rf_r[28]);
      $display("FC1 debug O15: cmd_valid=%b cmd_ready=%b addr=%h read=%b wdata=%h rsp_valid=%b rsp_ready=%b rsp_err=%b",
               fc1_o15_cmd_valid, fc1_o15_cmd_ready, fc1_o15_cmd_addr,
               fc1_o15_cmd_read, fc1_o15_cmd_wdata, fc1_o15_rsp_valid,
               fc1_o15_rsp_ready, fc1_o15_rsp_err);
      $display("FC1 debug IFU: pc_r=%h req=%b/%b req_pc=%h rsp=%b/%b instr=%h ir=%b/%b reset_req=%b bpu_wait=%b",
               `CPU_TOP.u_e203_cpu.u_e203_core.u_e203_ifu.u_e203_ifu_ifetch.pc_r,
               `CPU_TOP.u_e203_cpu.u_e203_core.u_e203_ifu.ifu_req_valid,
               `CPU_TOP.u_e203_cpu.u_e203_core.u_e203_ifu.ifu_req_ready,
               `CPU_TOP.u_e203_cpu.u_e203_core.u_e203_ifu.ifu_req_pc,
               `CPU_TOP.u_e203_cpu.u_e203_core.u_e203_ifu.ifu_rsp_valid,
               `CPU_TOP.u_e203_cpu.u_e203_core.u_e203_ifu.ifu_rsp_ready,
               `CPU_TOP.u_e203_cpu.u_e203_core.u_e203_ifu.ifu_rsp_instr,
               `CPU_TOP.u_e203_cpu.u_e203_core.u_e203_ifu.ifu_o_valid,
               `CPU_TOP.u_e203_cpu.u_e203_core.u_e203_ifu.ifu_o_ready,
               `CPU_TOP.u_e203_cpu.u_e203_core.u_e203_ifu.u_e203_ifu_ifetch.reset_req_r,
               `CPU_TOP.u_e203_cpu.u_e203_core.u_e203_ifu.u_e203_ifu_ifetch.bpu_wait);
      $display("FC1 debug ITCM: req=%b/%b addr=%h rsp=%b/%b err=%b data=%h sel_ifu=%b ram_req=%b/%b rsp=%b/%b ram_cs=%b ram_addr=%h",
               `CPU_TOP.u_e203_cpu.ifu2itcm_icb_cmd_valid,
               `CPU_TOP.u_e203_cpu.ifu2itcm_icb_cmd_ready,
               `CPU_TOP.u_e203_cpu.ifu2itcm_icb_cmd_addr,
               `CPU_TOP.u_e203_cpu.ifu2itcm_icb_rsp_valid,
               `CPU_TOP.u_e203_cpu.ifu2itcm_icb_rsp_ready,
               `CPU_TOP.u_e203_cpu.ifu2itcm_icb_rsp_err,
               `CPU_TOP.u_e203_cpu.ifu2itcm_icb_rsp_rdata,
               `CPU_TOP.u_e203_cpu.u_e203_itcm_ctrl.sram_sel_ifu,
               `CPU_TOP.u_e203_cpu.u_e203_itcm_ctrl.sram_icb_cmd_valid,
               `CPU_TOP.u_e203_cpu.u_e203_itcm_ctrl.sram_icb_cmd_ready,
               `CPU_TOP.u_e203_cpu.u_e203_itcm_ctrl.sram_icb_rsp_valid,
               `CPU_TOP.u_e203_cpu.u_e203_itcm_ctrl.sram_icb_rsp_ready,
               `CPU_TOP.u_e203_cpu.u_e203_itcm_ctrl.itcm_ram_cs,
               `CPU_TOP.u_e203_cpu.u_e203_itcm_ctrl.itcm_ram_addr);
      $fatal(1, "FC1 CPU MMIO timeout: loads=%0d outputs=%0d metadata=%0d",
             fc1_load_count, fc1_output_count, fc1_meta_count);
    end else begin
      $display("Time Out !!!");
      $finish;
    end
  end

  always
  begin 
     #3.333333 clk <= ~clk;
  end

  always
  begin 
     #33 lfextclk <= ~lfextclk;
  end



  
  
  initial begin
    if($value$plusargs("DUMPWAVE=%d",dumpwave)) begin
      if(dumpwave != 0) begin

	 `ifdef vcs
            $display("VCS used");
            $fsdbDumpfile("tb_top.fsdb");
            $fsdbDumpvars(0, tb_top, "+mda");
         `endif

	 `ifdef iverilog
            $display("iverlog used");
	    $dumpfile("tb_top.vcd");
            $dumpvars(0, tb_top);
         `endif
      end
    end
  end




  wire jtag_TDI = 1'b0;
  wire jtag_TDO;
  wire jtag_TCK = 1'b0;
  wire jtag_TMS = 1'b0;
  wire jtag_TRST = 1'b0;

  wire jtag_DRV_TDO = 1'b0;


e203_soc_top u_e203_soc_top(
   
   .hfextclk(hfclk),
   .hfxoscen(),

   .lfextclk(lfextclk),
   .lfxoscen(),

   .io_pads_jtag_TCK_i_ival (jtag_TCK),
   .io_pads_jtag_TMS_i_ival (jtag_TMS),
   .io_pads_jtag_TDI_i_ival (jtag_TDI),
   .io_pads_jtag_TDO_o_oval (jtag_TDO),
   .io_pads_jtag_TDO_o_oe (),

   .io_pads_gpioA_i_ival(32'b0),
   .io_pads_gpioA_o_oval(),
   .io_pads_gpioA_o_oe  (),

   .io_pads_gpioB_i_ival(32'b0),
   .io_pads_gpioB_o_oval(),
   .io_pads_gpioB_o_oe  (),

   .io_pads_qspi0_sck_o_oval (),
   .io_pads_qspi0_cs_0_o_oval(),
   .io_pads_qspi0_dq_0_i_ival(1'b1),
   .io_pads_qspi0_dq_0_o_oval(),
   .io_pads_qspi0_dq_0_o_oe  (),
   .io_pads_qspi0_dq_1_i_ival(1'b1),
   .io_pads_qspi0_dq_1_o_oval(),
   .io_pads_qspi0_dq_1_o_oe  (),
   .io_pads_qspi0_dq_2_i_ival(1'b1),
   .io_pads_qspi0_dq_2_o_oval(),
   .io_pads_qspi0_dq_2_o_oe  (),
   .io_pads_qspi0_dq_3_i_ival(1'b1),
   .io_pads_qspi0_dq_3_o_oval(),
   .io_pads_qspi0_dq_3_o_oe  (),

   .io_pads_aon_erst_n_i_ival (rst_n),//This is the real reset, active low
   .io_pads_aon_pmu_dwakeup_n_i_ival (1'b1),

   .io_pads_aon_pmu_vddpaden_o_oval (),
    .io_pads_aon_pmu_padrst_o_oval    (),

    .io_pads_bootrom_n_i_ival       (1'b0),// In Simulation we boot from ROM
    .io_pads_dbgmode0_n_i_ival       (1'b1),
    .io_pads_dbgmode1_n_i_ival       (1'b1),
    .io_pads_dbgmode2_n_i_ival       (1'b1) 
);


endmodule


