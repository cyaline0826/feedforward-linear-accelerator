`timescale 1ns/1ps

module task2 (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               start_valid,
    output wire               start_ready,
    input  wire        [3:0]   layer_id,
    input  wire               full_ffn,
    input  wire               load_valid,
    output wire               load_ready,
    input  wire        [15:0]  load_data,
    output wire               write_valid,
    input  wire               write_ready,
    output wire        [14:0]  write_addr,
    output wire signed [15:0]  write_data,
    output wire               write_saturated,
    output wire        [6:0]   write_overflow_count,
    output wire               busy,
    output reg                done,
    output reg                error,
    output reg         [3:0]   active_layer
);
    localparam [3:0] IDLE = 4'd0, LOAD_W1 = 4'd1, LOAD_B1 = 4'd2,
                     LOAD_W2 = 4'd3, LOAD_B2 = 4'd4, LOAD_X = 4'd5,
                     READ_BIAS = 4'd6, START_MAC = 4'd7, FEED = 4'd8,
                     ROUND = 4'd9, SAVE_HIDDEN = 4'd10, WAIT_WRITE = 4'd11;
    reg [3:0] state;
    reg full_mode, second_stage;
    reg [14:0] load_index, output_index;
    reg [12:0] row_base;
    reg [7:0] column, inner;

    reg signed [31:0] accumulator_q [0:3];
    reg [6:0] overflow_count, result_overflow;
    reg [1:0] res_idx;

    reg signed [15:0] obuf_y [0:3];
    reg obuf_sat [0:3];
    reg [1:0] obuf_rd;
    reg [2:0] obuf_cnt;
    reg [14:0] push_count;

    wire [15:0] bias_q_c [0:3];
    wire canonical = load_data[15:12] == {4{load_data[11]}};
    wire load_accept = load_valid && load_ready && canonical;
    wire weight_write = load_accept && ((state == LOAD_W1) || (state == LOAD_W2));
    wire bias_write = load_accept && ((state == LOAD_B1) || (state == LOAD_B2));
    wire x_write = load_accept && (state == LOAD_X);
    wire hidden_write = (state == SAVE_HIDDEN);
    wire signed [15:0] rounded_y_q [0:3];
    wire signed [11:0] gelu_y_q [0:3];
    wire sata_q [0:3];
    wire [14:0] last_output = full_mode ? 15'd6335 : 15'd25343;

    wire [6:0] bias_wr_offset = second_stage ? {1'b0, load_index[5:0]} : load_index[6:0];

    wire [7:0] last_inner = second_stage ? 8'd63 : 8'd15;

    wire [7:0] next_column = ((second_stage && (column == 8'd60)) ||
                              (!second_stage && (column == 8'd252)))
                           ? 8'd0 : (column + 8'd4);
    wire       next_stage  = second_stage ? ((column == 8'd60) ? 1'b0 : 1'b1)
                                          : ((column == 8'd252) ? (full_mode ? 1'b1 : 1'b0)
                                                                : 1'b0);
    wire [12:0] next_row_base = ((second_stage && (column == 8'd60)) ||
                                 (!second_stage && (column == 8'd252)))
                              ? row_base + 13'd64 : row_base;

    wire at_stage_edge = !second_stage && full_mode && (column == 8'd252);

    wire need_fetch_state = at_stage_edge || second_stage;
    wire fetch_next = (state == FEED) && (inner == last_inner) && !need_fetch_state;
    wire [7:0]  f_col  = fetch_next ? next_column   : column;
    wire [12:0] f_row  = fetch_next ? next_row_base : row_base;
    wire        f_stage = fetch_next ? next_stage   : second_stage;

    wire [7:0] fetch_inner = ((state == START_MAC) || fetch_next) ? 8'd0 : inner + 8'd1;
    wire fetch_pair = (state == START_MAC) || fetch_next
                   || ((state == FEED) && (inner != last_inner));
    wire weight_read_p4 = fetch_pair && !weight_write;

    wire       bias_prefetch = (state == FEED) && (inner == last_inner);
    wire       bias_sel_next = bias_prefetch || (state == ROUND);
    wire [7:0] bias_col      = bias_sel_next ? next_column : column;
    wire       bias_stage    = bias_sel_next ? next_stage  : second_stage;
    wire bias_read = ((state == READ_BIAS) || bias_prefetch) && !bias_write;
    wire x_read = fetch_pair && !f_stage && !x_write;
    wire hidden_read = fetch_pair && f_stage && !hidden_write;

    wire [15:0] weight_q_g [0:15];
    wire [15:0] x_q_l [0:3];
    wire signed [11:0] hidden_q_l [0:3];

    wire loading_w2 = (state == LOAD_W2);
    wire [1:0]  weight_wr_col  = load_index[1:0];
    wire [1:0]  weight_wr_lane = load_index[13:12];
    wire [4:0]  weight_wr_bank = (loading_w2 ? 5'd16 : 5'd0)
                               + {weight_wr_col, weight_wr_lane};
    wire [9:0]  weight_wr_offset = loading_w2 ? {load_index[11:6], load_index[5:2]}
                                              : {load_index[11:8], load_index[7:2]};
    wire [9:0]  weight_rd_offset = f_stage ? {fetch_inner[5:0], f_col[5:2]}
                                           : {fetch_inner[3:0], f_col[7:2]};

    wire [4:0]  weight_rd_stage = f_stage ? 5'd16 : 5'd0;

    wire [1:0]  x_wr_bank = load_index[5:4];
    wire [10:0] x_wr_offset = {load_index[12:6], load_index[3:0]};
    wire [10:0] x_rd_offset = {f_row[12:6], fetch_inner[3:0]};

    wire [7:0]  hidden_col = column + {6'd0, res_idx};
    wire [1:0]  hidden_wr_bank = hidden_col[7:6];
    wire [6:0]  hidden_wr_offset = {1'b0, hidden_col[5:0]};
    wire signed [11:0] gelu_sel = gelu_y_q[res_idx];
    wire [15:0] hidden_wdata = {{4{gelu_sel[11]}}, gelu_sel};
    wire [6:0]  hidden_rd_offset = {1'b0, fetch_inner[5:0]};

    wire [15:0] bias_bank_q [0:11];
    reg  [3:0]  bias_q_bank;

    wire [15:0] weight_bank_q [0:31];
    wire [15:0] x_phys_q [0:7];
    reg         x_half_q;
    wire [15:0] hidden_bank_q [0:3];

    genvar weight_bank, bias_bank, x_bank, hidden_bank;
    generate
        for (weight_bank = 0; weight_bank < 32; weight_bank = weight_bank + 1) begin : g_weight_sram

            wire       is_stage2     = (weight_bank >= 16);
            wire wr_sel = weight_write && (weight_wr_bank == weight_bank);

            wire rd_sel = weight_read_p4 && (is_stage2 == second_stage);
            RAMSP1024X16 u_sram (
                .A(wr_sel ? weight_wr_offset : weight_rd_offset),
                .CLK(clk), .D(load_data),
                .Q(weight_bank_q[weight_bank]), .CEN(~(wr_sel || rd_sel)),
                .WEN({16{~weight_write}}), .GWEN(~wr_sel),
                .RET1N(1'b1), .EMA(3'b010), .EMAW(2'b00)
            );
        end

        for (bias_bank = 0; bias_bank < 8; bias_bank = bias_bank + 1) begin : g_bias_sram
            wire wr_sel = bias_write && (state == LOAD_B1)
                       && ((bias_bank % 2) == load_index[7]);
            wire rd_sel = bias_read && !bias_stage
                       && ((bias_bank % 2) == bias_col[7]);
            wire [6:0] rd_off = {bias_col[6:2], 2'b00} + (bias_bank / 2);
            RAMSP128X16 u_sram (
                .A(wr_sel ? bias_wr_offset : rd_off), .CLK(clk), .D(load_data),
                .Q(bias_bank_q[bias_bank]), .CEN(~(wr_sel || rd_sel)),
                .WEN({16{~bias_write}}), .GWEN(~wr_sel),
                .RET1N(1'b1), .EMA(3'b010), .EMAW(2'b00)
            );
        end

        for (bias_bank = 8; bias_bank < 12; bias_bank = bias_bank + 1) begin : g_bias_s2
            wire wr_sel = bias_write && (state == LOAD_B2);
            wire rd_sel = bias_read && bias_stage;
            wire [6:0] rd_off = {1'b0, bias_col[5:2], 2'b00} + (bias_bank - 8);
            RAMSP128X16 u_sram (
                .A(wr_sel ? bias_wr_offset : rd_off), .CLK(clk), .D(load_data),
                .Q(bias_bank_q[bias_bank]), .CEN(~(wr_sel || rd_sel)),
                .WEN({16{~bias_write}}), .GWEN(~wr_sel),
                .RET1N(1'b1), .EMA(3'b010), .EMAW(2'b00)
            );
        end

        for (x_bank = 0; x_bank < 8; x_bank = x_bank + 1) begin : g_x_sram

            wire [1:0] logical_bank = x_bank / 2;
            wire       half         = x_bank % 2;
            wire wr_sel = x_write && (x_wr_bank == logical_bank)
                                  && (x_wr_offset[10] == half);
            wire rd_sel = x_read && (x_rd_offset[10] == half);
            RAMSP1024X16 u_sram (
                .A(wr_sel ? x_wr_offset[9:0] : x_rd_offset[9:0]),
                .CLK(clk), .D(load_data),
                .Q(x_phys_q[x_bank]), .CEN(~(wr_sel || rd_sel)),
                .WEN({16{~x_write}}), .GWEN(~wr_sel),
                .RET1N(1'b1), .EMA(3'b010), .EMAW(2'b00)
            );
        end
        for (hidden_bank = 0; hidden_bank < 4; hidden_bank = hidden_bank + 1) begin : g_hidden_sram
            wire wr_sel = hidden_write && (hidden_wr_bank == hidden_bank);
            wire rd_sel = hidden_read && (hidden_bank <= 3);
            RAMSP128X16 u_sram (
                .A(wr_sel ? hidden_wr_offset : hidden_rd_offset),
                .CLK(clk), .D(hidden_wdata),
                .Q(hidden_bank_q[hidden_bank]),
                .CEN(~(wr_sel || rd_sel)),
                .WEN({16{~hidden_write}}), .GWEN(~wr_sel),
                .RET1N(1'b1), .EMA(3'b010), .EMAW(2'b00)
            );
        end
    endgenerate

    assign weight_q_g[ 0] = weight_bank_q[weight_rd_stage + 5'd0];
    assign weight_q_g[ 1] = weight_bank_q[weight_rd_stage + 5'd1];
    assign weight_q_g[ 2] = weight_bank_q[weight_rd_stage + 5'd2];
    assign weight_q_g[ 3] = weight_bank_q[weight_rd_stage + 5'd3];
    assign weight_q_g[ 4] = weight_bank_q[weight_rd_stage + 5'd4];
    assign weight_q_g[ 5] = weight_bank_q[weight_rd_stage + 5'd5];
    assign weight_q_g[ 6] = weight_bank_q[weight_rd_stage + 5'd6];
    assign weight_q_g[ 7] = weight_bank_q[weight_rd_stage + 5'd7];
    assign weight_q_g[ 8] = weight_bank_q[weight_rd_stage + 5'd8];
    assign weight_q_g[ 9] = weight_bank_q[weight_rd_stage + 5'd9];
    assign weight_q_g[10] = weight_bank_q[weight_rd_stage + 5'd10];
    assign weight_q_g[11] = weight_bank_q[weight_rd_stage + 5'd11];
    assign weight_q_g[12] = weight_bank_q[weight_rd_stage + 5'd12];
    assign weight_q_g[13] = weight_bank_q[weight_rd_stage + 5'd13];
    assign weight_q_g[14] = weight_bank_q[weight_rd_stage + 5'd14];
    assign weight_q_g[15] = weight_bank_q[weight_rd_stage + 5'd15];

    assign x_q_l[0] = x_half_q ? x_phys_q[1] : x_phys_q[0];
    assign x_q_l[1] = x_half_q ? x_phys_q[3] : x_phys_q[2];
    assign x_q_l[2] = x_half_q ? x_phys_q[5] : x_phys_q[4];
    assign x_q_l[3] = x_half_q ? x_phys_q[7] : x_phys_q[6];
    assign hidden_q_l[0] = hidden_bank_q[0][11:0];
    assign hidden_q_l[1] = hidden_bank_q[1][11:0];
    assign hidden_q_l[2] = hidden_bank_q[2][11:0];
    assign hidden_q_l[3] = hidden_bank_q[3][11:0];

    assign bias_q_c[0] = bias_stage ? bias_bank_q[8]  : bias_bank_q[{3'b000, bias_col[7]}];
    assign bias_q_c[1] = bias_stage ? bias_bank_q[9]  : bias_bank_q[{2'b01, bias_col[7]}];
    assign bias_q_c[2] = bias_stage ? bias_bank_q[10] : bias_bank_q[{2'b10, bias_col[7]}];
    assign bias_q_c[3] = bias_stage ? bias_bank_q[11] : bias_bank_q[{2'b11, bias_col[7]}];

    always @(posedge clk) begin
        if (!rst_n)         x_half_q <= 1'b0;
        else if (x_read)    x_half_q <= x_rd_offset[10];
    end

    wire signed [11:0] operand_l [0:3];
    assign operand_l[0] = second_stage ? hidden_q_l[0] : $signed(x_q_l[0][11:0]);
    assign operand_l[1] = second_stage ? hidden_q_l[1] : $signed(x_q_l[1][11:0]);
    assign operand_l[2] = second_stage ? hidden_q_l[2] : $signed(x_q_l[2][11:0]);
    assign operand_l[3] = second_stage ? hidden_q_l[3] : $signed(x_q_l[3][11:0]);

    wire signed [32:0] tsum_g [0:3];
    wire signed [32:0] acc4_g [0:3];
    wire [2:0] ovf_g [0:3];

    genvar gc;
    generate
        for (gc = 0; gc < 4; gc = gc + 1) begin : g_col
            wire signed [23:0] p0 = operand_l[0] * $signed(weight_q_g[4*gc+0][11:0]);
            wire signed [23:0] p1 = operand_l[1] * $signed(weight_q_g[4*gc+1][11:0]);
            wire signed [23:0] p2 = operand_l[2] * $signed(weight_q_g[4*gc+2][11:0]);
            wire signed [23:0] p3 = operand_l[3] * $signed(weight_q_g[4*gc+3][11:0]);
            wire signed [32:0] t01 = {{9{p0[23]}}, p0} + {{9{p1[23]}}, p1};
            wire signed [32:0] t23 = {{9{p2[23]}}, p2} + {{9{p3[23]}}, p3};
            wire signed [32:0] tsum = t01 + t23;
            wire signed [32:0] acc0 = {accumulator_q[gc][31], accumulator_q[gc]};
            wire signed [32:0] acc4 = acc0 + tsum;
            assign tsum_g[gc] = tsum;
            assign acc4_g[gc] = acc4;
            assign ovf_g[gc] = {2'b00, (t01[32]  != t01[31])}
                             + {2'b00, (t23[32]  != t23[31])}
                             + {2'b00, (tsum[32] != tsum[31])}
                             + {2'b00, (acc4[32] != acc4[31])};
        end
    endgenerate

    assign start_ready = rst_n && (state == IDLE);
    assign load_ready = rst_n && ((state == LOAD_W1) || (state == LOAD_B1) ||
                                 (state == LOAD_W2) || (state == LOAD_B2) || (state == LOAD_X));
    assign busy = rst_n && (state != IDLE);

    assign write_valid = rst_n && (obuf_cnt != 3'd0);
    assign write_addr = output_index;
    assign write_data = obuf_y[obuf_rd];
    assign write_saturated = obuf_sat[obuf_rd];
    assign write_overflow_count = result_overflow;

    task1_round_sat quantizer0 (.acc(accumulator_q[0]), .y(rounded_y_q[0]), .saturated(sata_q[0]));
    task1_round_sat quantizer1 (.acc(accumulator_q[1]), .y(rounded_y_q[1]), .saturated(sata_q[1]));
    task1_round_sat quantizer2 (.acc(accumulator_q[2]), .y(rounded_y_q[2]), .saturated(sata_q[2]));
    task1_round_sat quantizer3 (.acc(accumulator_q[3]), .y(rounded_y_q[3]), .saturated(sata_q[3]));

    wire signed [13:0] gelu_in_wide [0:3];
    wire signed [11:0] gelu_in_q8 [0:3];
    assign gelu_in_wide[0] = rounded_y_q[0][15:2];
    assign gelu_in_wide[1] = rounded_y_q[1][15:2];
    assign gelu_in_wide[2] = rounded_y_q[2][15:2];
    assign gelu_in_wide[3] = rounded_y_q[3][15:2];
    assign gelu_in_q8[0] = gelu_in_wide[0][11:0];
    assign gelu_in_q8[1] = gelu_in_wide[1][11:0];
    assign gelu_in_q8[2] = gelu_in_wide[2][11:0];
    assign gelu_in_q8[3] = gelu_in_wide[3][11:0];
    wire gelu_en = rst_n && full_mode && !second_stage && (state == ROUND);

    wire round_stage1 = full_mode && !second_stage;
    wire round_push   = !round_stage1 && (obuf_cnt == 3'd0);
    task2_gelu act0 (.clk(clk), .enable(gelu_en), .x(gelu_in_q8[0]), .y(gelu_y_q[0]));
    task2_gelu act1 (.clk(clk), .enable(gelu_en), .x(gelu_in_q8[1]), .y(gelu_y_q[1]));
    task2_gelu act2 (.clk(clk), .enable(gelu_en), .x(gelu_in_q8[2]), .y(gelu_y_q[2]));
    task2_gelu act3 (.clk(clk), .enable(gelu_en), .x(gelu_in_q8[3]), .y(gelu_y_q[3]));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            full_mode <= 1'b0;
            second_stage <= 1'b0;
            load_index <= 15'd0;
            output_index <= 15'd0;
            row_base <= 13'd0;
            column <= 8'd0;
            inner <= 8'd0;
            accumulator_q[0] <= 32'sd0;
            accumulator_q[1] <= 32'sd0;
            accumulator_q[2] <= 32'sd0;
            accumulator_q[3] <= 32'sd0;
            res_idx <= 2'd0;
            overflow_count <= 7'd0;
            result_overflow <= 7'd0;
            obuf_rd <= 2'd0;
            obuf_cnt <= 3'd0;
            push_count <= 15'd0;
            active_layer <= 4'd0;
            done <= 1'b0;
            error <= 1'b0;
        end else begin
            done <= 1'b0;
            error <= 1'b0;
            case (state)
                IDLE: begin
                    if (start_valid && start_ready) begin
                        if (layer_id < 4'd12) begin
                            active_layer <= layer_id;
                            full_mode <= full_ffn;
                            second_stage <= 1'b0;
                            load_index <= 15'd0;
                            output_index <= 15'd0;
                            row_base <= 13'd0;
                            column <= 8'd0;
                            inner <= 8'd0;
                            obuf_rd <= 2'd0;
                            obuf_cnt <= 3'd0;
                            push_count <= 15'd0;
                            state <= LOAD_W1;
                        end else begin
                            error <= 1'b1;
                        end
                    end
                end
                LOAD_W1, LOAD_B1, LOAD_W2, LOAD_B2, LOAD_X: begin
                    if (load_valid && load_ready) begin
                        if (!canonical) begin
                            error <= 1'b1;
                            state <= IDLE;
                        end else if (((state == LOAD_W1 || state == LOAD_W2) && load_index == 15'd16383) ||
                                     (state == LOAD_B1 && load_index == 15'd255) ||
                                     (state == LOAD_B2 && load_index == 15'd63) ||
                                     (state == LOAD_X && load_index == 15'd6335)) begin
                            load_index <= 15'd0;
                            case (state)
                                LOAD_W1: state <= LOAD_B1;
                                LOAD_B1: state <= full_mode ? LOAD_W2 : LOAD_X;
                                LOAD_W2: state <= LOAD_B2;
                                LOAD_B2: state <= LOAD_X;
                                default: state <= READ_BIAS;
                            endcase
                        end else begin
                            load_index <= load_index + 15'd1;
                        end
                    end
                end
                READ_BIAS: begin
                    res_idx <= 2'd0;
                    state <= START_MAC;
                end
                START_MAC: begin
                    accumulator_q[0] <= {{12{bias_q_c[0][11]}}, bias_q_c[0][11:0], 8'b0};
                    accumulator_q[1] <= {{12{bias_q_c[1][11]}}, bias_q_c[1][11:0], 8'b0};
                    accumulator_q[2] <= {{12{bias_q_c[2][11]}}, bias_q_c[2][11:0], 8'b0};
                    accumulator_q[3] <= {{12{bias_q_c[3][11]}}, bias_q_c[3][11:0], 8'b0};
                    overflow_count <= 7'd0;
                    inner <= 8'd0;
                    state <= FEED;
                end
                FEED: begin
                    accumulator_q[0] <= acc4_g[0][31:0];
                    accumulator_q[1] <= acc4_g[1][31:0];
                    accumulator_q[2] <= acc4_g[2][31:0];
                    accumulator_q[3] <= acc4_g[3][31:0];

                    overflow_count <= overflow_count + {4'd0, ovf_g[0]} + {4'd0, ovf_g[1]}
                                                  + {4'd0, ovf_g[2]} + {4'd0, ovf_g[3]};
                    if (inner == last_inner)
                        state <= ROUND;
                    else
                        inner <= inner + 8'd1;
                end
                ROUND: begin

                    if (round_stage1 || round_push) begin
                        accumulator_q[0] <= {{12{bias_q_c[0][11]}}, bias_q_c[0][11:0], 8'b0};
                        accumulator_q[1] <= {{12{bias_q_c[1][11]}}, bias_q_c[1][11:0], 8'b0};
                        accumulator_q[2] <= {{12{bias_q_c[2][11]}}, bias_q_c[2][11:0], 8'b0};
                        accumulator_q[3] <= {{12{bias_q_c[3][11]}}, bias_q_c[3][11:0], 8'b0};
                        result_overflow <= overflow_count;
                        overflow_count <= 7'd0;
                        inner <= 8'd0;
                    end
                    if (round_stage1) begin

                        state <= SAVE_HIDDEN;
                    end else if (round_push) begin

                        obuf_y[0] <= rounded_y_q[0];
                        obuf_y[1] <= rounded_y_q[1];
                        obuf_y[2] <= rounded_y_q[2];
                        obuf_y[3] <= rounded_y_q[3];
                        obuf_sat[0] <= sata_q[0];
                        obuf_sat[1] <= sata_q[1];
                        obuf_sat[2] <= sata_q[2];
                        obuf_sat[3] <= sata_q[3];
                        obuf_rd <= 2'd0;
                        obuf_cnt <= 3'd4;
                        push_count <= push_count + 15'd4;
                        if (push_count + 15'd4 == last_output + 15'd1) begin
                            state <= WAIT_WRITE;
                        end else begin
                            if (second_stage) begin
                                if (column == 8'd60) begin
                                    column <= 8'd0;
                                    row_base <= row_base + 13'd64;
                                    second_stage <= 1'b0;
                                end else begin
                                    column <= column + 8'd4;
                                end
                            end else if (column == 8'd252) begin
                                column <= 8'd0;
                                if (full_mode) second_stage <= 1'b1;
                                else row_base <= row_base + 13'd64;
                            end else begin
                                column <= column + 8'd4;
                            end
                            state <= need_fetch_state ? START_MAC : FEED;
                        end
                    end
                end
                SAVE_HIDDEN: begin

                    if (res_idx == 2'd3) begin
                        res_idx <= 2'd0;
                        if (column == 8'd252) begin
                            second_stage <= 1'b1;
                            column <= 8'd0;
                        end else begin
                            column <= column + 8'd4;
                        end

                        state <= (column == 8'd252) ? START_MAC : FEED;
                    end else begin
                        res_idx <= res_idx + 2'd1;
                    end
                end
                WAIT_WRITE: begin

                    if (obuf_cnt == 3'd1 && write_ready) begin
                        done <= 1'b1;
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase

            if (obuf_cnt != 3'd0 && write_ready) begin
                output_index <= output_index + 15'd1;
                obuf_rd <= obuf_rd + 2'd1;
                obuf_cnt <= obuf_cnt - 3'd1;
            end
        end
    end
endmodule
