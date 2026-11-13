`timescale 1ns/1ps

module tb_task2_sram_functional;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start_valid = 1'b0;
    wire start_ready;
    reg [3:0] layer_id = 4'd0;
    reg full_ffn = 1'b0;
    reg load_valid = 1'b0;
    wire load_ready;
    reg [15:0] load_data = 16'd0;
    wire write_valid;
    reg write_ready = 1'b1;
    wire [14:0] write_addr;
    wire signed [15:0] write_data;
    wire write_saturated;
    wire [6:0] write_overflow_count;
    wire busy;
    wire done;
    wire error;
    wire [3:0] active_layer;

    integer full_arg = 0;
    integer output_count = 0;
    integer expected_count;
    integer i;

    integer nostop_arg = 0;
    reg     nostop = 1'b0;
    integer mis_count = 0;
    integer mis_first = -1;
    integer mis_last  = -1;
    integer row_mis [0:98];
    integer col_mis [0:255];
    integer adiff_hist [0:3];
    integer adiff;
    integer rr, cc;
    reg [15:0] weights [0:16383];
    reg [15:0] biases [0:255];
    reg [15:0] inputs [0:6335];
    reg [15:0] weights2 [0:16383];
    reg [15:0] biases2 [0:63];
    reg [15:0] expected [0:25343];
    reg [1023:0] weights_file, biases_file, inputs_file, expected_file;
    reg [1023:0] weights2_file, biases2_file;

    task2 dut (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_valid), .start_ready(start_ready),
        .layer_id(layer_id), .full_ffn(full_ffn),
        .load_valid(load_valid), .load_ready(load_ready), .load_data(load_data),
        .write_valid(write_valid), .write_ready(write_ready),
        .write_addr(write_addr), .write_data(write_data),
        .write_saturated(write_saturated), .write_overflow_count(write_overflow_count),
        .busy(busy), .done(done), .error(error), .active_layer(active_layer)
    );

    always #5 clk = ~clk;

`ifdef SDF_ANNOTATE
`ifndef SDF_FILE
`define SDF_FILE "task2.sdf"
`endif
    initial begin
        $display("SDF_ANNOTATE: annotating %s onto dut", `SDF_FILE);
        $sdf_annotate(`SDF_FILE, dut, , "sdf_annotate.log", "MAXIMUM");
    end
`endif

    task send_load(input [15:0] value);
        begin
            @(negedge clk);
            load_data = value;
            load_valid = 1'b1;
            while (load_ready !== 1'b1)
                @(negedge clk);
            @(negedge clk);
            load_valid = 1'b0;
            if (error)
                $fatal(1, "task2 rejected a canonical load word %h", value);
        end
    endtask

    initial begin
        #100_000_000;
        $fatal(1, "task2 SRAM functional test timed out");
    end

    integer bp_arg = 0;
    reg [2:0] bp_cyc = 3'd0;

    integer bph_arg = 0;
    reg [15:0] bph_cnt = 16'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bp_cyc <= 3'd0;
            bph_cnt <= 16'd0;
            write_ready <= 1'b1;
        end else if (bp_arg != 0) begin
            bp_cyc <= bp_cyc + 3'd1;
            write_ready <= (bp_cyc >= bp_arg[2:0]);
        end else if (bph_arg != 0) begin
            if (bph_cnt >= bph_arg) begin
                bph_cnt <= 16'd0;
                write_ready <= 1'b1;
            end else begin
                bph_cnt <= bph_cnt + 16'd1;
                write_ready <= 1'b0;
            end
        end else begin
            write_ready <= 1'b1;
        end
    end

    initial begin
        if (!$value$plusargs("FULL_FFN=%d", full_arg))
            full_arg = 0;
        full_ffn = (full_arg != 0);
        if (!$value$plusargs("BP=%d", bp_arg))
            bp_arg = 0;
        if (!$value$plusargs("BPH=%d", bph_arg))
            bph_arg = 0;
        if (bp_arg != 0)
        if (bph_arg != 0)
        if (!$value$plusargs("NOSTOP=%d", nostop_arg))
            nostop_arg = 0;
        nostop = (nostop_arg != 0);
        if (nostop) begin
            for (i = 0; i < 99;  i = i + 1) row_mis[i] = 0;
            for (i = 0; i < 256; i = i + 1) col_mis[i] = 0;
            for (i = 0; i < 4;   i = i + 1) adiff_hist[i] = 0;
        end
        if (!$value$plusargs("WEIGHTS=%s", weights_file) ||
            !$value$plusargs("BIASES=%s", biases_file) ||
            !$value$plusargs("INPUTS=%s", inputs_file) ||
            !$value$plusargs("EXPECTED=%s", expected_file))
            $fatal(1, "Pass +WEIGHTS +BIASES +INPUTS +EXPECTED vector paths");
        $readmemh(weights_file, weights);
        $readmemh(biases_file, biases);
        $readmemh(inputs_file, inputs);
        $readmemh(expected_file, expected);
        if (full_ffn) begin
            if (!$value$plusargs("WEIGHTS2=%s", weights2_file) ||
                !$value$plusargs("BIASES2=%s", biases2_file))
                $fatal(1, "Full FFN needs +WEIGHTS2 and +BIASES2");
            $readmemh(weights2_file, weights2);
            $readmemh(biases2_file, biases2);
            expected_count = 6336;
        end else begin
            expected_count = 25344;
        end

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        while (start_ready !== 1'b1)
            @(negedge clk);
        start_valid = 1'b1;
        @(negedge clk);
        start_valid = 1'b0;

        for (i = 0; i < 16384; i = i + 1) send_load(weights[i]);
        for (i = 0; i < 256; i = i + 1) send_load(biases[i]);
        if (full_ffn) begin
            for (i = 0; i < 16384; i = i + 1) send_load(weights2[i]);
            for (i = 0; i < 64; i = i + 1) send_load(biases2[i]);
        end
        for (i = 0; i < 6336; i = i + 1) send_load(inputs[i]);

        while (output_count < expected_count) begin
            @(negedge clk);
            if (error)
                $fatal(1, "task2 asserted error during compute");

            if (write_valid && write_ready) begin
                if (write_addr !== output_count[14:0])
                    $fatal(1, "output address %0d was %0d", output_count, write_addr);
                if (write_data !== $signed(expected[output_count])) begin
                    if (nostop) begin

                        if (mis_count < 24)
                        mis_count = mis_count + 1;
                        mis_first = (mis_count == 1) ? output_count : mis_first;
                        mis_last  = output_count;
                        rr = output_count / 256;
                        cc = output_count % 256;
                        row_mis[rr] = row_mis[rr] + 1;
                        col_mis[cc] = col_mis[cc] + 1;
                        adiff = $signed(write_data) - $signed({{4{expected[output_count][11]}},
                                                              expected[output_count][11:0]});
                        if (adiff < 0) adiff = -adiff;
                        if      (adiff <  16) adiff_hist[0] = adiff_hist[0] + 1;
                        else if (adiff <  32) adiff_hist[1] = adiff_hist[1] + 1;
                        else if (adiff <  64) adiff_hist[2] = adiff_hist[2] + 1;
                        else                  adiff_hist[3] = adiff_hist[3] + 1;
                    end else begin
                        $fatal(1, "output %0d got %h expected %h", output_count,
                               write_data, expected[output_count]);
                    end
                end
                output_count = output_count + 1;
            end
        end
        @(negedge clk);
        if (!done || busy)
            $fatal(1, "task2 did not finish cleanly: done=%b busy=%b", done, busy);
        if (nostop) begin

            for (i = 0; i < 99; i = i + 1) $write(" %0d", row_mis[i]);
            $write("\n");

            for (i = 0; i < 128; i = i + 1) $write(" %0d", col_mis[i]);
            $write("\n");
            for (i = 128; i < 256; i = i + 1) $write(" %0d", col_mis[i]);
            $write("\n");

            for (i = 0; i < 4; i = i + 1) $write(" %0d", adiff_hist[i]);
            $write("\n");
        end

`ifndef TASK2_USE_EXTERNAL_SMIC40_SRAM_MODELS
        if (mis_count != 0)
            $display("TASK2_SRAM_%0s_FAIL outputs=%0d mismatches=%0d",
                     full_ffn ? "FULL_FFN" : "FC1", output_count, mis_count);
        else if (full_ffn)
            $display("TASK2_SRAM_FULL_FFN_PASS outputs=%0d", output_count);
        else
            $display("TASK2_SRAM_FC1_PASS outputs=%0d", output_count);
`else
        if (mis_count != 0)
            $display("TASK2_SRAM_%0s_FAIL outputs=%0d mismatches=%0d external_models=1",
                     full_ffn ? "FULL_FFN" : "FC1", output_count, mis_count);
        else if (full_ffn)
            $display("TASK2_SRAM_FULL_FFN_PASS outputs=%0d external_models=1", output_count);
        else
            $display("TASK2_SRAM_FC1_PASS outputs=%0d external_models=1", output_count);
`endif
        if (mis_count != 0)
            $fatal(1, "%0d output mismatches; PASS must not be claimed",
                   mis_count);
        $finish;
    end
endmodule

`ifndef TASK2_USE_EXTERNAL_SMIC40_SRAM_MODELS

module RAMSP1024X16 (
    input wire [9:0] A,
    input wire CLK,
    input wire [15:0] D,
    output reg [15:0] Q,
    input wire CEN,
    input wire [15:0] WEN,
    input wire GWEN,
    input wire RET1N,
    input wire [2:0] EMA,
    input wire [1:0] EMAW
);
    reg [15:0] mem [0:1023];
    integer bit_index;

    always @(posedge CLK) begin
        if (CEN === 1'b0 && RET1N === 1'b1) begin
            if (GWEN === 1'b0) begin
                for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1)
                    if (WEN[bit_index] === 1'b0)
                        mem[A][bit_index] <= D[bit_index];
            end else if (GWEN === 1'b1) begin
                Q <= mem[A];
            end
        end
    end
endmodule

module RAMSP4096X16 (
    input wire [11:0] A,
    input wire CLK,
    input wire [15:0] D,
    output reg [15:0] Q,
    input wire CEN,
    input wire [15:0] WEN,
    input wire GWEN,
    input wire RET1N,
    input wire [2:0] EMA,
    input wire [1:0] EMAW
);
    reg [15:0] mem [0:4095];
    integer bit_index;

    always @(posedge CLK) begin
        if (CEN === 1'b0 && RET1N === 1'b1) begin
            if (GWEN === 1'b0) begin
                for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1)
                    if (WEN[bit_index] === 1'b0)
                        mem[A][bit_index] <= D[bit_index];
            end else if (GWEN === 1'b1) begin
                Q <= mem[A];
            end
        end
    end
endmodule

module RAMSP128X16 (
    input wire [6:0] A,
    input wire CLK,
    input wire [15:0] D,
    output reg [15:0] Q,
    input wire CEN,
    input wire [15:0] WEN,
    input wire GWEN,
    input wire RET1N,
    input wire [2:0] EMA,
    input wire [1:0] EMAW
);
    reg [15:0] mem [0:127];
    integer bit_index;

    always @(posedge CLK) begin
        if (CEN === 1'b0 && RET1N === 1'b1) begin
            if (GWEN === 1'b0) begin
                for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1)
                    if (WEN[bit_index] === 1'b0)
                        mem[A][bit_index] <= D[bit_index];
            end else if (GWEN === 1'b1) begin
                Q <= mem[A];
            end
        end
    end
endmodule
`endif
