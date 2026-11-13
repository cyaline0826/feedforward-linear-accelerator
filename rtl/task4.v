`timescale 1ns/1ps

module attention_single_head (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               load_valid,
    output wire               load_ready,
    input  wire        [3:0]  load_kind,
    input  wire       [15:0]  load_index,
    input  wire signed [15:0] load_data,
    input  wire               start_valid,
    output wire               start_ready,
    output reg                out_valid,
    input  wire               out_ready,
    output reg        [15:0]  out_index,
    output reg signed [15:0]  out_data,
    output wire               busy,
    output reg                done,
    output reg                error
);

    localparam [3:0] LOAD_X  = 4'd0, LOAD_WQ = 4'd1, LOAD_WK = 4'd2, LOAD_WV = 4'd3,
                     LOAD_BQ = 4'd4, LOAD_BK = 4'd5, LOAD_BV = 4'd6, LOAD_WO = 4'd7,
                     LOAD_BO = 4'd8;

    localparam [4:0] ST_IDLE = 5'd0, ST_Q = 5'd1, ST_K = 5'd2, ST_V = 5'd3,
                     ST_SCORE = 5'd4, ST_SMAX = 5'd5, ST_SEXP = 5'd6,
                     ST_SNORM = 5'd7, ST_CONTEXT = 5'd8, ST_OUT_PROJ = 5'd9,
                     ST_OUTPUT = 5'd10;

    reg [4:0]  state;
    reg [6:0]  row, col, ph;
    reg        half;
    reg signed [63:0] acc;
    reg        out_pend;

    reg signed [15:0] row_max;
    reg [6:0]  row_max_col;
    reg [31:0] row_sum;
    reg [31:0] norm_sum;

    reg signed [11:0] bq_r [0:63];
    reg signed [11:0] bk_r [0:63];
    reg signed [11:0] bv_r [0:63];
    reg signed [11:0] bo_r [0:63];

    reg        x_we;
    reg [12:0] x_a;
    reg [15:0] x_d;
    wire [15:0] x_q;
    reg        q_we;   reg [12:0] q_a;   reg [15:0] q_d;   wire [15:0] q_q;
    reg        k_we;   reg [12:0] k_a;   reg [15:0] k_d;   wire [15:0] k_q;
    reg        v_we;   reg [12:0] v_a;   reg [15:0] v_d;   wire [15:0] v_q;
    reg        ct_we;  reg [12:0] ct_a;  reg [15:0] ct_d;  wire [15:0] ct_q;
    reg        om_we;  reg [12:0] om_a;  reg [15:0] om_d;  wire [15:0] om_q;
    reg        wq_we;  reg [11:0] wq_a;  reg [15:0] wq_d;  wire [15:0] wq_q;
    reg        wk_we;  reg [11:0] wk_a;  reg [15:0] wk_d;  wire [15:0] wk_q;
    reg        wv_we;  reg [11:0] wv_a;  reg [15:0] wv_d;  wire [15:0] wv_q;
    reg        wo_we;  reg [11:0] wo_a;  reg [15:0] wo_d;  wire [15:0] wo_q;
    reg        sc_we;  reg [13:0] sc_a;  reg [15:0] sc_d;  wire [15:0] sc_q;
    reg        pr_we;  reg [13:0] pr_a;  reg [15:0] pr_d;  wire [15:0] pr_q;

    t4_ram6336 u_x   (.clk(clk), .we(x_we),  .addr(x_a),  .wdata(x_d),  .rdata(x_q));
    t4_ram6336 u_q   (.clk(clk), .we(q_we),  .addr(q_a),  .wdata(q_d),  .rdata(q_q));
    t4_ram6336 u_k   (.clk(clk), .we(k_we),  .addr(k_a),  .wdata(k_d),  .rdata(k_q));
    t4_ram6336 u_v   (.clk(clk), .we(v_we),  .addr(v_a),  .wdata(v_d),  .rdata(v_q));
    t4_ram6336 u_ct  (.clk(clk), .we(ct_we), .addr(ct_a), .wdata(ct_d), .rdata(ct_q));
    t4_ram6336 u_om  (.clk(clk), .we(om_we), .addr(om_a), .wdata(om_d), .rdata(om_q));
    t4_ram4096 u_wq  (.clk(clk), .we(wq_we), .addr(wq_a), .wdata(wq_d), .rdata(wq_q));
    t4_ram4096 u_wk  (.clk(clk), .we(wk_we), .addr(wk_a), .wdata(wk_d), .rdata(wk_q));
    t4_ram4096 u_wv  (.clk(clk), .we(wv_we), .addr(wv_a), .wdata(wv_d), .rdata(wv_q));
    t4_ram4096 u_wo  (.clk(clk), .we(wo_we), .addr(wo_a), .wdata(wo_d), .rdata(wo_q));
    t4_ram9801 u_sc  (.clk(clk), .we(sc_we), .addr(sc_a), .wdata(sc_d), .rdata(sc_q));
    t4_ram9801 u_pr  (.clk(clk), .we(pr_we), .addr(pr_a), .wdata(pr_d), .rdata(pr_q));

`ifndef SYNTHESIS
    function [15:0] dbg_score(input [13:0] a); dbg_score = u_sc.peek(a); endfunction
    function [15:0] dbg_prob (input [13:0] a); dbg_prob  = u_pr.peek(a); endfunction
`endif

    assign busy = (state != ST_IDLE);
    assign load_ready = (state == ST_IDLE);
    assign start_ready = (state == ST_IDLE) && !load_valid;

    function automatic signed [11:0] round_q20_to_q8;
        input signed [63:0] value;
        reg signed [63:0] magnitude, rounded;
        begin
            magnitude = (value < 0) ? -value : value;
            rounded = (magnitude + 64'sd2048) >>> 12;
            if (value < 0) rounded = -rounded;
            if (rounded > 64'sd2047) round_q20_to_q8 = 12'sh7ff;
            else if (rounded < -64'sd2048) round_q20_to_q8 = -12'sd2048;
            else round_q20_to_q8 = rounded[11:0];
        end
    endfunction

    function automatic signed [11:0] round_q19_to_q6;
        input signed [63:0] value;
        reg signed [63:0] magnitude, rounded;
        begin
            magnitude = (value < 0) ? -value : value;
            rounded = (magnitude + 64'sd4096) >>> 13;
            if (value < 0) rounded = -rounded;
            if (rounded > 64'sd2047) round_q19_to_q6 = 12'sh7ff;
            else if (rounded < -64'sd2048) round_q19_to_q6 = -12'sd2048;
            else round_q19_to_q6 = rounded[11:0];
        end
    endfunction
    function automatic signed [15:0] round_q16_to_q13;
        input signed [63:0] value;
        reg signed [63:0] magnitude, rounded;
        begin
            magnitude = (value < 0) ? -value : value;
            rounded = (magnitude + 64'sd16) >>> 5;
            if (value < 0) rounded = -rounded;
            if (rounded > 64'sd32767) round_q16_to_q13 = 16'sh7fff;
            else if (rounded < -64'sd32768) round_q16_to_q13 = -16'sd32768;
            else round_q16_to_q13 = rounded[15:0];
        end
    endfunction

    function automatic signed [11:0] round_q23_to_q8;
        input signed [63:0] value;
        reg signed [63:0] magnitude, rounded;
        begin
            magnitude = (value < 0) ? -value : value;
            rounded = (magnitude + 64'sd4096) >>> 13;
            if (value < 0) rounded = -rounded;
            if (rounded > 64'sd2047) round_q23_to_q8 = 12'sh7ff;
            else if (rounded < -64'sd2048) round_q23_to_q8 = -12'sd2048;
            else round_q23_to_q8 = rounded[11:0];
        end
    endfunction

    function automatic [15:0] exp_lut_q15;
        input [6:0] index;
        begin
            case (index)
                7'd0: exp_lut_q15 = 16'd32768;   7'd1: exp_lut_q15 = 16'd28918;
                7'd2: exp_lut_q15 = 16'd25520;   7'd3: exp_lut_q15 = 16'd22521;
                7'd4: exp_lut_q15 = 16'd19875;   7'd5: exp_lut_q15 = 16'd17539;
                7'd6: exp_lut_q15 = 16'd15479;   7'd7: exp_lut_q15 = 16'd13660;
                7'd8: exp_lut_q15 = 16'd12055;   7'd9: exp_lut_q15 = 16'd10638;
                7'd10: exp_lut_q15 = 16'd9388;   7'd11: exp_lut_q15 = 16'd8285;
                7'd12: exp_lut_q15 = 16'd7312;   7'd13: exp_lut_q15 = 16'd6452;
                7'd14: exp_lut_q15 = 16'd5694;   7'd15: exp_lut_q15 = 16'd5025;
                7'd16: exp_lut_q15 = 16'd4435;   7'd17: exp_lut_q15 = 16'd3914;
                7'd18: exp_lut_q15 = 16'd3454;   7'd19: exp_lut_q15 = 16'd3048;
                7'd20: exp_lut_q15 = 16'd2690;   7'd21: exp_lut_q15 = 16'd2374;
                7'd22: exp_lut_q15 = 16'd2095;   7'd23: exp_lut_q15 = 16'd1849;
                7'd24: exp_lut_q15 = 16'd1631;   7'd25: exp_lut_q15 = 16'd1440;
                7'd26: exp_lut_q15 = 16'd1271;   7'd27: exp_lut_q15 = 16'd1121;
                7'd28: exp_lut_q15 = 16'd990;    7'd29: exp_lut_q15 = 16'd873;
                7'd30: exp_lut_q15 = 16'd771;    7'd31: exp_lut_q15 = 16'd680;
                7'd32: exp_lut_q15 = 16'd600;    7'd33: exp_lut_q15 = 16'd530;
                7'd34: exp_lut_q15 = 16'd468;    7'd35: exp_lut_q15 = 16'd414;
                7'd36: exp_lut_q15 = 16'd366;    7'd37: exp_lut_q15 = 16'd323;
                7'd38: exp_lut_q15 = 16'd286;    7'd39: exp_lut_q15 = 16'd253;
                7'd40: exp_lut_q15 = 16'd223;    7'd41: exp_lut_q15 = 16'd198;
                7'd42: exp_lut_q15 = 16'd175;    7'd43: exp_lut_q15 = 16'd155;
                7'd44: exp_lut_q15 = 16'd137;    7'd45: exp_lut_q15 = 16'd121;
                7'd46: exp_lut_q15 = 16'd107;    7'd47: exp_lut_q15 = 16'd95;
                7'd48: exp_lut_q15 = 16'd84;     7'd49: exp_lut_q15 = 16'd74;
                7'd50: exp_lut_q15 = 16'd66;     7'd51: exp_lut_q15 = 16'd58;
                7'd52: exp_lut_q15 = 16'd52;     7'd53: exp_lut_q15 = 16'd46;
                7'd54: exp_lut_q15 = 16'd41;     7'd55: exp_lut_q15 = 16'd36;
                7'd56: exp_lut_q15 = 16'd32;     7'd57: exp_lut_q15 = 16'd28;
                7'd58: exp_lut_q15 = 16'd25;     7'd59: exp_lut_q15 = 16'd22;
                7'd60: exp_lut_q15 = 16'd20;     7'd61: exp_lut_q15 = 16'd17;
                7'd62: exp_lut_q15 = 16'd15;     7'd63: exp_lut_q15 = 16'd14;
                default: exp_lut_q15 = 16'd0;
            endcase
        end
    endfunction

    function automatic load_index_valid;
        input [3:0] kind;
        input [15:0] index;
        begin
            case (kind)
                LOAD_X: load_index_valid = index < 16'd6336;
                LOAD_WQ, LOAD_WK, LOAD_WV, LOAD_WO: load_index_valid = index < 16'd4096;
                LOAD_BQ, LOAD_BK, LOAD_BV, LOAD_BO: load_index_valid = index < 16'd64;
                default: load_index_valid = 1'b0;
            endcase
        end
    endfunction

    wire load_data_ok = (load_data[15:12] == {4{load_data[11]}});
    wire load_word_ok = load_data_ok && load_index_valid(load_kind, load_index);

    wire signed [15:0] x_s  = $signed(x_q);
    wire signed [15:0] wq_s = $signed(wq_q);
    wire signed [15:0] wk_s = $signed(wk_q);
    wire signed [15:0] wv_s = $signed(wv_q);
    wire signed [15:0] wo_s = $signed(wo_q);
    wire signed [15:0] q_s  = $signed(q_q);
    wire signed [15:0] k_s  = $signed(k_q);
    wire signed [15:0] v_s  = $signed(v_q);
    wire signed [15:0] ct_s = $signed(ct_q);
    wire signed [15:0] sc_s = $signed(sc_q);
    wire signed [15:0] pr_s = $signed(pr_q);
    wire [15:0] pr_u = pr_q;
    wire signed [16:0] score_delta = {row_max[15], row_max} - {sc_s[15], sc_s};
    wire [8:0] exp_raw = score_delta[16] ? 9'd511 : score_delta[15:7];
    wire [6:0] exp_index = (exp_raw > 9'd63) ? 7'd64 : exp_raw[6:0];
    wire [31:0] norm_term = (pr_q * 32'd32768) / row_sum;

    wire signed [15:0] wsel = (state == ST_K) ? wk_s : (state == ST_V) ? wv_s : wq_s;
    wire signed [15:0] in_sel = (state == ST_CONTEXT) ? pr_s :
                                (state == ST_SCORE)   ? q_s  :
                                (state == ST_OUT_PROJ) ? ct_s : x_s;
    wire signed [15:0] wsel2 = (state == ST_SCORE)   ? k_s  :
                               (state == ST_CONTEXT) ? v_s  :
                               (state == ST_OUT_PROJ) ? wo_s : wsel;

    wire signed [32:0] context_prod = $signed({1'b0, pr_u}) * v_s;
    wire signed [63:0] prod = (state == ST_CONTEXT) ? context_prod : (in_sel * wsel2);
    wire signed [63:0] sum_now = acc + prod;
    wire signed [11:0] q20_result = round_q20_to_q8(sum_now);
    wire signed [11:0] qkv_result = round_q19_to_q6(sum_now);
    wire signed [11:0] q23_result = round_q23_to_q8(sum_now);
    wire signed [15:0] om_s_ext = {{4{om_q[11]}}, om_q[11:0]};

    wire [12:0] row64   = {row, 6'b000000} + col;
    wire [13:0] sc_idx  = {7'd0, row} * 14'd99 + {7'd0, ph};
    wire [13:0] pr_idx  = {7'd0, row} * 14'd99 + {7'd0, ph};
    wire [11:0] w_idx   = {5'd0, ph} * 12'd64 + {5'd0, col};
    wire        last_ph = (state == ST_CONTEXT || state == ST_SNORM) ? (ph == 7'd99) : (ph == 7'd64);

    always @(*) begin
        x_we = 0; x_a = 13'd0; x_d = 16'd0;
        q_we = 0; q_a = 13'd0; q_d = 16'd0;
        k_we = 0; k_a = 13'd0; k_d = 16'd0;
        v_we = 0; v_a = 13'd0; v_d = 16'd0;
        ct_we = 0; ct_a = 13'd0; ct_d = 16'd0;
        om_we = 0; om_a = 13'd0; om_d = 16'd0;
        wq_we = 0; wq_a = 12'd0; wq_d = 16'd0;
        wk_we = 0; wk_a = 12'd0; wk_d = 16'd0;
        wv_we = 0; wv_a = 12'd0; wv_d = 16'd0;
        wo_we = 0; wo_a = 12'd0; wo_d = 16'd0;
        sc_we = 0; sc_a = 14'd0; sc_d = 16'd0;
        pr_we = 0; pr_a = 14'd0; pr_d = 16'd0;

        if (load_valid && load_ready && load_word_ok) begin
            case (load_kind)
                LOAD_X:  begin x_we = 1; x_a  = load_index[12:0]; x_d = {{4{load_data[11]}}, load_data[11:0]}; end
                LOAD_WQ: begin wq_we = 1; wq_a = load_index[11:0]; wq_d = {{4{load_data[11]}}, load_data[11:0]}; end
                LOAD_WK: begin wk_we = 1; wk_a = load_index[11:0]; wk_d = {{4{load_data[11]}}, load_data[11:0]}; end
                LOAD_WV: begin wv_we = 1; wv_a = load_index[11:0]; wv_d = {{4{load_data[11]}}, load_data[11:0]}; end
                LOAD_WO: begin wo_we = 1; wo_a = load_index[11:0]; wo_d = {{4{load_data[11]}}, load_data[11:0]}; end
                default: ;
            endcase
        end else begin
            case (state)
                ST_Q, ST_K, ST_V: begin
                    if (ph < 7'd64) begin
                        x_a  = {row, 6'b000000} + ph;
                        wq_we = 0; wk_we = 0; wv_we = 0;
                        wq_a = w_idx; wk_a = w_idx; wv_a = w_idx;
                    end
                    if (last_ph & (ph == 7'd64)) begin
                        if (state == ST_Q) begin q_we = 1; q_a = row64; q_d = {{4{qkv_result[11]}}, qkv_result}; end
                        else if (state == ST_K) begin k_we = 1; k_a = row64; k_d = {{4{qkv_result[11]}}, qkv_result}; end
                        else begin v_we = 1; v_a = row64; v_d = {{4{qkv_result[11]}}, qkv_result}; end
                    end
                end
                ST_SCORE: begin
                    if (ph < 7'd64) begin
                        q_a = {row, 6'b000000} + ph;
                        k_a = {col, 6'b000000} + ph;
                    end
                    if (last_ph && ph == 7'd64) begin
                        sc_we = 1; sc_a = {7'd0, row} * 14'd99 + {7'd0, col}; sc_d = round_q16_to_q13(sum_now);
                    end
                end
                ST_SMAX: begin
                    if (ph < 7'd99) sc_a = sc_idx;
                end
                ST_SEXP: begin
                    if (ph < 7'd99) sc_a = sc_idx;
                    if (ph >= 7'd1 && ph <= 7'd99) begin
                        pr_we = 1;
                        pr_a = {7'd0, row} * 14'd99 + {7'd0, (ph - 7'd1)};
                        pr_d = exp_lut_q15(exp_index);
                    end
                end
                ST_SNORM: begin
                    if (ph < 7'd99) begin
                        pr_a = pr_idx;
                        if (half && ph != row_max_col) begin
                            pr_we = 1;
                            pr_d = norm_term[15:0];
                        end
                    end else begin
                        pr_we = 1;
                        pr_a = {7'd0, row} * 14'd99 + {7'd0, row_max_col};
                        pr_d = 16'd32768 - norm_sum[15:0];
                    end
                end
                ST_CONTEXT: begin
                    if (ph < 7'd99) begin
                        pr_a = {7'd0, row} * 14'd99 + {7'd0, ph};
                        v_a  = {5'd0, ph} * 12'd64 + {5'd0, col};
                    end
                    if (ph == 7'd99) begin
                        ct_we = 1; ct_a = row64; ct_d = {{4{q23_result[11]}}, q23_result};
                    end
                end
                ST_OUT_PROJ: begin
                    if (ph < 7'd64) begin
                        ct_a = {row, 6'b000000} + ph;
                        wo_a = w_idx;
                    end
                    if (ph == 7'd64) begin
                        om_we = 1; om_a = row64; om_d = {{4{q20_result[11]}}, q20_result};
                    end
                end
                ST_OUTPUT: begin
                    if (!out_valid && !out_pend) om_a = out_index[12:0];
                    else if (out_valid && out_ready && out_index != 16'd6335)
                        om_a = out_index[12:0] + 13'd1;
                end
                default: ;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            row <= 7'd0; col <= 7'd0; ph <= 7'd0; half <= 1'b0;
            acc <= 64'sd0;
            out_valid <= 1'b0; out_index <= 16'd0; out_data <= 16'sd0;
            done <= 1'b0; error <= 1'b0; out_pend <= 1'b0;
            row_max <= 16'sd0; row_max_col <= 7'd0;
            row_sum <= 32'd0; norm_sum <= 32'd0;
        end else begin
            done <= 1'b0;
            error <= 1'b0;

            if (load_valid && load_ready) begin
                if (!load_word_ok) error <= 1'b1;
                else case (load_kind)
                    LOAD_BQ: bq_r[load_index[5:0]] <= load_data[11:0];
                    LOAD_BK: bk_r[load_index[5:0]] <= load_data[11:0];
                    LOAD_BV: bv_r[load_index[5:0]] <= load_data[11:0];
                    LOAD_BO: bo_r[load_index[5:0]] <= load_data[11:0];
                    default: ;
                endcase
            end else if ((state == ST_IDLE) && start_valid && start_ready) begin
                state <= ST_Q;
                row <= 7'd0; col <= 7'd0; ph <= 7'd0;
                acc <= $signed(bq_r[0]) <<< 8;
                out_valid <= 1'b0;
            end else begin
                case (state)
                    ST_Q, ST_K, ST_V: begin
                        if (ph < 7'd64) begin
                            if (ph != 7'd0) acc <= sum_now;
                            ph <= ph + 1'b1;
                        end else begin
                            ph <= 7'd0;
                            acc <= 64'sd0;
                            if (col == 7'd63) begin
                                col <= 7'd0;
                                if (row == 7'd98) begin
                                    row <= 7'd0;
                                    if (state == ST_Q) begin state <= ST_K; acc <= $signed(bk_r[0]) <<< 8; end
                                    else if (state == ST_K) begin state <= ST_V; acc <= $signed(bv_r[0]) <<< 8; end
                                    else state <= ST_SCORE;
                                end else begin
                                    row <= row + 1'b1;
                                    acc <= (state == ST_Q) ? ($signed(bq_r[0]) <<< 8) :
                                           (state == ST_K) ? ($signed(bk_r[0]) <<< 8) :
                                                             ($signed(bv_r[0]) <<< 8);
                                end
                            end else begin
                                col <= col + 1'b1;
                                acc <= (state == ST_Q) ? ($signed(bq_r[col + 1'b1]) <<< 8) :
                                       (state == ST_K) ? ($signed(bk_r[col + 1'b1]) <<< 8) :
                                                         ($signed(bv_r[col + 1'b1]) <<< 8);
                            end
                        end
                    end

                    ST_SCORE: begin
                        if (ph < 7'd64) begin
                            if (ph != 7'd0) acc <= sum_now;
                            ph <= ph + 1'b1;
                        end else begin
                            ph <= 7'd0;
                            acc <= 64'sd0;
                            if (col == 7'd98) begin
                                col <= 7'd0;
                                if (row == 7'd98) begin row <= 7'd0; state <= ST_SMAX; end
                                else row <= row + 1'b1;
                            end else col <= col + 1'b1;
                        end
                    end

                    ST_SMAX: begin
                        if (ph == 7'd0) begin
                            ph <= 7'd1;
                        end else if (ph < 7'd99) begin
                            if ((ph == 7'd1) || (sc_s > row_max)) begin
                                row_max <= sc_s;
                                row_max_col <= ph - 7'd1;
                            end
                            ph <= ph + 1'b1;
                        end else begin
                            if (sc_s > row_max) begin row_max <= sc_s; row_max_col <= 7'd98; end
                            ph <= 7'd0; col <= 7'd0; row_sum <= 32'd0;
                            state <= ST_SEXP;
                        end
                    end

                    ST_SEXP: begin
                        if (ph == 7'd0) begin
                            ph <= 7'd1;
                        end else if (ph <= 7'd99) begin
                            row_sum <= row_sum + exp_lut_q15(exp_index);
                            if (ph == 7'd99) begin
                                ph <= 7'd0; col <= 7'd0; norm_sum <= 32'd0; half <= 1'b0;
                                state <= ST_SNORM;
                            end else ph <= ph + 1'b1;
                        end
                    end

                    ST_SNORM: begin
                        if (ph < 7'd99 && !half) begin
                            half <= 1'b1;
                        end else if (ph < 7'd99) begin
                            if (ph != row_max_col) norm_sum <= norm_sum + norm_term;
                            half <= 1'b0;
                            ph <= ph + 1'b1;
                        end else begin
                            ph <= 7'd0; col <= 7'd0; row_sum <= 32'd0; norm_sum <= 32'd0;
                            if (row == 7'd98) begin
                                row <= 7'd0; acc <= 64'sd0; state <= ST_CONTEXT;
                            end else begin
                                row <= row + 1'b1;
                                state <= ST_SMAX;
                            end
                        end
                    end

                    ST_CONTEXT: begin
                        if (ph < 7'd99) begin
                            if (ph != 7'd0) acc <= sum_now;
                            ph <= ph + 1'b1;
                        end else begin
                            ph <= 7'd0; acc <= 64'sd0;
                            if (col == 7'd63) begin
                                col <= 7'd0;
                                if (row == 7'd98) begin
                                    row <= 7'd0;
                                    acc <= $signed(bo_r[0]) <<< 8;
                                    state <= ST_OUT_PROJ;
                                end else row <= row + 1'b1;
                            end else col <= col + 1'b1;
                        end
                    end

                    ST_OUT_PROJ: begin
                        if (ph < 7'd64) begin
                            if (ph != 7'd0) acc <= sum_now;
                            ph <= ph + 1'b1;
                        end else begin
                            ph <= 7'd0;
                            if (col == 7'd63) begin
                                col <= 7'd0;
                                if (row == 7'd98) begin
                                    row <= 7'd0; out_index <= 16'd0; out_pend <= 1'b0;
                                    state <= ST_OUTPUT;
                                end else begin
                                    row <= row + 1'b1;
                                    acc <= $signed(bo_r[0]) <<< 8;
                                end
                            end else begin
                                col <= col + 1'b1;
                                acc <= $signed(bo_r[col + 1'b1]) <<< 8;
                            end
                        end
                    end

                    ST_OUTPUT: begin
                        if (!out_valid) begin
                            if (!out_pend) begin
                                out_pend <= 1'b1;
                            end else begin
                                out_pend <= 1'b0;
                                out_valid <= 1'b1;
                                out_data <= om_s_ext;
                            end
                        end else if (out_ready) begin
                            out_pend <= 1'b0;
                            if (out_index == 16'd6335) begin
                                out_valid <= 1'b0;
                                done <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                out_valid <= 1'b0;
                                out_index <= out_index + 1'b1;
                                out_pend <= 1'b1;
                            end
                        end
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule