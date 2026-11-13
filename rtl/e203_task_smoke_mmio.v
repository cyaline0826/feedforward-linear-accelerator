module e203_task_smoke_mmio (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [31:0] cmd_addr,
    input  wire        cmd_read,
    input  wire [31:0] cmd_wdata,
    input  wire [3:0]  cmd_wmask,
    output wire        rsp_valid,
    input  wire        rsp_ready,
    output reg         rsp_err,
    output reg  [31:0] rsp_rdata,

    output wire        acc_sram_icb_cmd_valid,
    input  wire        acc_sram_icb_cmd_ready,
    output wire [31:0] acc_sram_icb_cmd_addr,
    output wire        acc_sram_icb_cmd_read,
    output wire [31:0] acc_sram_icb_cmd_wdata,
    output wire [3:0]  acc_sram_icb_cmd_wmask,
    input  wire        acc_sram_icb_rsp_valid,
    output wire        acc_sram_icb_rsp_ready,
    input  wire [31:0] acc_sram_icb_rsp_rdata
);
    localparam [31:0] ID_ADDR      = 32'h1004_2000;
    localparam [31:0] SCRATCH_ADDR = 32'h1004_2004;
    localparam [31:0] CTRL_ADDR    = 32'h1004_2008;
    localparam [31:0] STATUS_ADDR  = 32'h1004_200c;
    localparam [31:0] INPUT_ADDR   = 32'h1004_2010;
    localparam [31:0] OUTPUT_ADDR  = 32'h1004_2014;
    localparam [31:0] META_ADDR    = 32'h1004_2018;
    localparam [31:0] INPUT32_ADDR = 32'h1004_201c;

    localparam [31:0] PMEM_ADDR    = 32'h1004_2020;
    localparam [31:0] PMEM_DATA    = 32'h1004_2024;
    localparam [31:0] PMEM_STATUS  = 32'h1004_2028;
    localparam [31:0] ID_VALUE     = 32'h5441_534b;

    reg [31:0] scratch;
    reg [31:0] control;
    reg [31:0] result_meta;
    reg result_meta_valid;
    reg done_sticky;
    reg error_sticky;
    reg rsp_valid_r;

    reg  [15:0] in_q [0:7];
    reg  [2:0]  in_wr_ptr, in_rd_ptr;
    reg  [3:0]  in_cnt;
    localparam [3:0] IN_DEPTH = 4'd8;
    wire        in_empty = (in_cnt == 4'd0);

    reg  [13:0] st_idx;
    reg  [13:0] st_left;
    reg         st_run;
    reg         st_cmd;
    reg  [1:0]  st_out;

    reg  [31:0] st_rbuf [0:1];
    reg  [0:0]  rb_wr, rb_rd;
    reg  [1:0]  rb_cnt;

    wire [31:0] st_addr = (st_idx < 14'd8320)
                          ? (32'hA000_0000 + {16'b0, st_idx, 2'b00})
                          : (32'hA000_8080 + {16'b0, st_idx, 2'b00});
    wire [2:0]  st_total = {1'b0, rb_cnt} + {1'b0, st_out};
    wire        rb_push  = (rb_cnt != 2'd0) && (in_cnt <= (IN_DEPTH - 4'd2));

    wire        st_issue = st_run && !st_cmd && (st_left != 14'd0) && (st_total < 3'd2);

    assign acc_sram_icb_cmd_valid = st_cmd;
    assign acc_sram_icb_cmd_addr  = st_addr;
    assign acc_sram_icb_cmd_read  = 1'b1;
    assign acc_sram_icb_cmd_wdata = 32'b0;
    assign acc_sram_icb_cmd_wmask = 4'b0;
    assign acc_sram_icb_rsp_ready = 1'b1;

    reg  [15:0] out_q [0:7];
    reg  [2:0]  out_wr_ptr, out_rd_ptr;
    reg  [3:0]  out_cnt;
    localparam [3:0] OUT_DEPTH = 4'd8;
    wire        pair_avail = (out_cnt >= 4'd2);
    wire        out_read_req = cmd_valid && cmd_read && (cmd_addr == OUTPUT_ADDR);

    wire task_start_ready;
    wire task_load_ready;
    wire task_write_valid;
    wire [14:0] task_write_addr;
    wire signed [15:0] task_write_data;
    wire task_write_saturated;
    wire [6:0] task_write_overflow;
    wire task_busy;
    wire task_done;
    wire task_error;
    wire task_start_valid = cmd_valid && cmd_ready && !cmd_read
                          && (cmd_addr == CTRL_ADDR) && cmd_wmask == 4'b1111
                          && cmd_wdata[0] && cmd_wdata[31:8] == 24'b0
                          && cmd_wdata[7:4] < 4'd12 && task_start_ready;

    wire task_load_valid = !in_empty;
    wire [15:0] task_load_data = in_q[in_rd_ptr];
    wire load_pop = !in_empty && task_load_ready;
    wire load_req16 = cmd_valid && !cmd_read && (cmd_addr == INPUT_ADDR)
                    && (cmd_wmask == 4'b1111);
    wire load_req32 = cmd_valid && !cmd_read && (cmd_addr == INPUT32_ADDR)
                    && (cmd_wmask == 4'b1111);
    wire [3:0] load_need = load_req32 ? 4'd2 : (load_req16 ? 4'd1 : 4'd0);
    wire load_fits = ((in_cnt + load_need) <= IN_DEPTH);
    wire load_push16 = load_req16 && cmd_ready;
    wire load_push32 = load_req32 && cmd_ready;
    wire queue_push = rb_push || load_push16 || load_push32;
    wire [3:0] queue_push_count = (rb_push || load_push32) ? 4'd2
                                : load_push16 ? 4'd1 : 4'd0;

    wire task_write_ready = (out_cnt != OUT_DEPTH);

    wire out_push = task_write_valid && task_write_ready;
    wire out_pop  = cmd_valid && cmd_ready && cmd_read && (cmd_addr == OUTPUT_ADDR);
    wire [31:0] task_status = {27'b0, pair_avail, task_load_ready,
                               error_sticky, done_sticky, task_busy};

    assign cmd_ready = rst_n && !rsp_valid_r && !(out_read_req && !pair_avail)
                     && (load_need == 4'd0 || load_fits)
                     && !(rb_push && (load_req16 || load_req32));
    assign rsp_valid = rsp_valid_r;

    task2 u_task2 (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(task_start_valid),
        .start_ready(task_start_ready),
        .layer_id(task_start_valid ? cmd_wdata[7:4] : control[7:4]),
        .full_ffn(task_start_valid ? cmd_wdata[1] : control[1]),
        .load_valid(task_load_valid),
        .load_ready(task_load_ready),
        .load_data(task_load_data),
        .write_valid(task_write_valid),
        .write_ready(task_write_ready),
        .write_addr(task_write_addr),
        .write_data(task_write_data),
        .write_saturated(task_write_saturated),
        .write_overflow_count(task_write_overflow),
        .busy(task_busy),
        .done(task_done),
        .error(task_error),
        .active_layer()
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scratch <= 32'b0;
            control <= 32'b0;
            result_meta <= 32'b0;
            result_meta_valid <= 1'b0;
            done_sticky <= 1'b0;
            error_sticky <= 1'b0;
            rsp_valid_r <= 1'b0;
            rsp_err <= 1'b0;
            rsp_rdata <= 32'b0;
            out_wr_ptr <= 3'd0;
            out_rd_ptr <= 3'd0;
            out_cnt    <= 4'd0;
            in_wr_ptr  <= 3'd0;
            in_rd_ptr  <= 3'd0;
            in_cnt     <= 4'd0;
        end else begin
            if (rsp_valid_r && rsp_ready)
                rsp_valid_r <= 1'b0;

            if (rb_push) begin

                in_q[in_wr_ptr]        <= st_rbuf[rb_rd][15:0];
                in_q[in_wr_ptr + 3'd1] <= st_rbuf[rb_rd][31:16];
                in_wr_ptr <= in_wr_ptr + 3'd2;
            end else if (load_push16 || load_push32) begin
                in_q[in_wr_ptr] <= cmd_wdata[15:0];
                if (load_push32) begin
                    in_q[in_wr_ptr + 3'd1] <= cmd_wdata[31:16];
                    in_wr_ptr <= in_wr_ptr + 3'd2;
                end else begin
                    in_wr_ptr <= in_wr_ptr + 3'd1;
                end
            end
            if (load_pop)
                in_rd_ptr <= in_rd_ptr + 3'd1;
            if (queue_push || load_pop)
                in_cnt <= in_cnt + queue_push_count - (load_pop ? 4'd1 : 4'd0);

            if (task_done)
                done_sticky <= 1'b1;
            if (task_error)
                error_sticky <= 1'b1;

            if (out_push) begin
                out_q[out_wr_ptr] <= task_write_data;
                out_wr_ptr <= out_wr_ptr + 3'd1;
                result_meta <= {9'b0, task_write_overflow,
                                task_write_saturated, task_write_addr};
                result_meta_valid <= 1'b1;
            end

            out_cnt <= out_cnt + (out_push ? 4'd1 : 4'd0) - (out_pop ? 4'd2 : 4'd0);

            if (cmd_valid && cmd_ready) begin
                rsp_valid_r <= 1'b1;
                rsp_err <= 1'b0;
                rsp_rdata <= 32'b0;

                if (cmd_read) begin
                    case (cmd_addr)
                        ID_ADDR: rsp_rdata <= ID_VALUE;
                        SCRATCH_ADDR: rsp_rdata <= scratch;
                        CTRL_ADDR: rsp_rdata <= control;
                        STATUS_ADDR: rsp_rdata <= task_status;
                        INPUT_ADDR: rsp_err <= 1'b1;
                        INPUT32_ADDR: rsp_err <= 1'b1;
                        OUTPUT_ADDR: begin

                            rsp_rdata <= {out_q[out_rd_ptr + 3'd1], out_q[out_rd_ptr]};
                            out_rd_ptr <= out_rd_ptr + 3'd2;
                        end
                        META_ADDR: begin
                            if (result_meta_valid)
                                rsp_rdata <= result_meta;
                            else
                                rsp_err <= 1'b1;
                        end
                        default: rsp_err <= 1'b1;
                    endcase
                end else if (cmd_addr == SCRATCH_ADDR) begin
                    if (cmd_wmask[0]) scratch[7:0] <= cmd_wdata[7:0];
                    if (cmd_wmask[1]) scratch[15:8] <= cmd_wdata[15:8];
                    if (cmd_wmask[2]) scratch[23:16] <= cmd_wdata[23:16];
                    if (cmd_wmask[3]) scratch[31:24] <= cmd_wdata[31:24];
                end else if (cmd_addr == CTRL_ADDR) begin
                    if (cmd_wmask != 4'b1111 || cmd_wdata[31:8] != 24'b0
                            || (cmd_wdata[0] && (cmd_wdata[7:4] >= 4'd12
                                                || !task_start_ready))) begin
                        rsp_err <= 1'b1;
                        error_sticky <= 1'b1;
                    end else begin
                        control <= {24'b0, cmd_wdata[7:1], 1'b0};
                        if (cmd_wdata[0]) begin
                            done_sticky <= 1'b0;
                            error_sticky <= 1'b0;
                            result_meta_valid <= 1'b0;

                            out_wr_ptr <= 3'd0;
                            out_rd_ptr <= 3'd0;
                            out_cnt    <= 4'd0;

                            in_wr_ptr  <= 3'd0;
                            in_rd_ptr  <= 3'd0;
                            in_cnt     <= 4'd0;
                        end
                    end
                end else if (cmd_addr == INPUT_ADDR) begin

                    if (cmd_wmask != 4'b1111) begin
                        rsp_err <= 1'b1;
                        error_sticky <= 1'b1;
                    end
                end else if (cmd_addr == PMEM_ADDR) begin
                    if (cmd_wmask != 4'b1111) begin
                        rsp_err <= 1'b1;
                        error_sticky <= 1'b1;
                    end
                end else if (cmd_addr == INPUT32_ADDR) begin
                    if (cmd_wmask != 4'b1111) begin
                        rsp_err <= 1'b1;
                        error_sticky <= 1'b1;
                    end
                end else begin
                    rsp_err <= 1'b1;
                end
            end
        end
    end

    wire st_cmd_hs = st_cmd && acc_sram_icb_cmd_ready;
    wire st_rsp_hs = acc_sram_icb_rsp_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_run  <= 1'b0;
            st_cmd  <= 1'b0;
            st_idx  <= 14'd0;
            st_left <= 14'd0;
            st_out  <= 2'd0;
            rb_wr   <= 1'b0;
            rb_rd   <= 1'b0;
            rb_cnt  <= 2'd0;
        end else if (task_start_valid && cmd_wdata[2]) begin
            st_run  <= 1'b1;
            st_cmd  <= 1'b1;
            st_idx  <= 14'd0;
            st_left <= 14'd11488;
            st_out  <= 2'd0;
            rb_wr   <= 1'b0;
            rb_rd   <= 1'b0;
            rb_cnt  <= 2'd0;
        end else begin

            if (st_cmd_hs) begin
                st_cmd  <= 1'b0;
                st_idx  <= st_idx + 14'd1;
                st_left <= st_left - 14'd1;
            end
            if (st_issue)
                st_cmd <= 1'b1;

            if (st_rsp_hs) begin
                st_rbuf[rb_wr] <= acc_sram_icb_rsp_rdata;
                rb_wr  <= rb_wr + 1'b1;
            end

            case ({st_cmd_hs, st_rsp_hs})
                2'b10:   st_out <= st_out + 2'd1;
                2'b01:   st_out <= st_out - 2'd1;
                default: st_out <= st_out;
            endcase

            if (rb_push)
                rb_rd  <= rb_rd + 1'b1;

            rb_cnt <= rb_cnt + (st_rsp_hs ? 2'd1 : 2'd0)
                             - (rb_push   ? 2'd1 : 2'd0);

            if (st_run && (st_left == 14'd0) && (st_out == 2'd0) && (rb_cnt == 2'd0)
                    && !st_rsp_hs && !rb_push)
                st_run <= 1'b0;
        end
    end

endmodule
