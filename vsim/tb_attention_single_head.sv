`timescale 1ns/1ps

module tb_attention_single_head;
    localparam [3:0] LOAD_X  = 4'd0;
    localparam [3:0] LOAD_WQ = 4'd1;
    localparam [3:0] LOAD_WK = 4'd2;
    localparam [3:0] LOAD_WV = 4'd3;
    localparam [3:0] LOAD_BQ = 4'd4;
    localparam [3:0] LOAD_BK = 4'd5;
    localparam [3:0] LOAD_BV = 4'd6;
    localparam [3:0] LOAD_WO = 4'd7;
    localparam [3:0] LOAD_BO = 4'd8;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg load_valid = 1'b0;
    reg [3:0] load_kind = 4'd0;
    reg [15:0] load_index = 16'd0;
    reg signed [15:0] load_data = 16'sd0;
    wire load_ready;
    reg start_valid = 1'b0;
    wire start_ready;
    reg out_ready = 1'b0;
    wire out_valid;
    wire [15:0] out_index;
    wire signed [15:0] out_data;
    wire busy;
    wire done;
    wire error;

    integer out_count;
    integer task_count;
    integer hold_index;
    reg signed [15:0] hold_data;
    reg hold_active;
    integer ready_phase;
    reg signed [15:0] expected_data;

    task automatic check_probability_rows;
        integer r;
        integer c;
        integer total;
        begin
            for (r = 0; r < 99; r = r + 1) begin
                total = 0;
                for (c = 0; c < 99; c = c + 1)
                    total = total + dut.dbg_prob(r * 99 + c);
                if (total != 32768)
                    $fatal(1, "probability row %0d sum %0d expected 32768", r, total);
            end
        end
    endtask

    attention_single_head dut (
        .clk(clk), .rst_n(rst_n),
        .load_valid(load_valid), .load_ready(load_ready),
        .load_kind(load_kind), .load_index(load_index), .load_data(load_data),
        .start_valid(start_valid), .start_ready(start_ready),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_index(out_index), .out_data(out_data),
        .busy(busy), .done(done), .error(error)
    );

    always #5 clk = ~clk;
    task automatic load_zero(input [3:0] kind, input integer count);
        integer i;
        begin
            for (i = 0; i < count; i = i + 1) begin
                @(negedge clk);
                load_valid = 1'b1;
                load_kind = kind;
                load_index = i[15:0];
                load_data = 16'sd0;
                while (!load_ready) @(posedge clk);
                @(posedge clk);
                @(negedge clk);
                load_valid = 1'b0;
            end
        end
    endtask

    task automatic load_constant(input [3:0] kind, input integer count, input signed [15:0] value);
        integer i;
        begin
            for (i = 0; i < count; i = i + 1) begin
                @(negedge clk);
                load_valid = 1'b1;
                load_kind = kind;
                load_index = i[15:0];
                load_data = value;
                while (!load_ready) @(posedge clk);
                @(posedge clk);
                @(negedge clk);
                load_valid = 1'b0;
            end
        end
    endtask

    task automatic load_diagonal(input [3:0] kind, input signed [15:0] value);
        integer r;
        integer c;
        begin
            for (r = 0; r < 64; r = r + 1) begin
                for (c = 0; c < 64; c = c + 1) begin
                    @(negedge clk);
                    load_valid = 1'b1;
                    load_kind = kind;
                    load_index = (r * 64 + c);
                    load_data = (r == c) ? value : 16'sd0;
                    while (!load_ready) @(posedge clk);
                    @(posedge clk);
                    @(negedge clk);
                    load_valid = 1'b0;
                end
            end
        end
    endtask

    task automatic start_task;
        begin
            @(negedge clk);
            start_valid = 1'b1;
            while (!start_ready) @(posedge clk);
            @(posedge clk);
            @(negedge clk);
            start_valid = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            out_count <= 0;
            hold_active <= 1'b0;
        end else begin
            if (busy && start_ready)
                $fatal(1, "start_ready asserted while busy");
            if (error)
                $fatal(1, "DUT reported error");
            if (out_valid && !out_ready) begin
                if (!hold_active) begin
                    hold_index <= out_index;
                    hold_data <= out_data;
                    hold_active <= 1'b1;
                end else if (out_index !== hold_index[15:0] || out_data !== hold_data) begin
                    $fatal(1, "output changed under backpressure");
                end
            end else begin
                hold_active <= 1'b0;
            end
            if (out_valid && out_ready) begin
                if (out_index !== out_count[15:0])
                    $fatal(1, "output index %0d expected %0d", out_index, out_count);
                if (out_data !== expected_data)
                    $fatal(1, "output %0d at index %0d expected %0d", out_data, out_index, expected_data);
                out_count <= out_count + 1;
            end
        end
    end

    initial begin
        task_count = 0;
        out_count = 0;
        hold_active = 1'b0;
        ready_phase = 0;
        expected_data = 16'sd0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        load_zero(LOAD_X, 6336);
        load_zero(LOAD_WQ, 4096);
        load_zero(LOAD_WK, 4096);
        load_zero(LOAD_WV, 4096);
        load_zero(LOAD_BQ, 64);
        load_zero(LOAD_BK, 64);
        load_zero(LOAD_BV, 64);
        load_zero(LOAD_WO, 4096);
        load_zero(LOAD_BO, 64);

        start_task();
        if (!busy) $fatal(1, "DUT did not enter busy state");
        @(negedge clk);
        load_valid = 1'b1;
        load_kind = LOAD_X;
        load_index = 16'd0;
        load_data = 16'sd0;
        start_valid = 1'b1;
        repeat (3) begin
            @(posedge clk);
            if (load_ready || start_ready)
                $fatal(1, "busy DUT accepted load or start");
        end
        @(negedge clk);
        load_valid = 1'b0;
        start_valid = 1'b0;
        while (!done) begin
            @(negedge clk);
            ready_phase = ready_phase + 1;
            out_ready = (ready_phase % 3) != 0;
        end
        check_probability_rows();
        @(posedge clk);
        if (out_count != 6336) $fatal(1, "first task output count %0d", out_count);
        task_count = task_count + 1;

        out_count = 0;
        ready_phase = 0;
        out_ready = 1'b1;
        load_constant(LOAD_X, 6336, 16'sd256);
        load_diagonal(LOAD_WQ, 16'sd256);
        load_diagonal(LOAD_WK, 16'sd256);
        load_diagonal(LOAD_WV, 16'sd256);
        load_diagonal(LOAD_WO, 16'sd1024);
        expected_data = 16'sd8;
        start_task();
        while (!done) @(posedge clk);
        if (dut.dbg_score(14'd0) !== 16'sd128)
            $fatal(1, "QK score %0d expected 128", dut.dbg_score(14'd0));
        check_probability_rows();
        @(posedge clk);
        if (out_count != 6336) $fatal(1, "second task output count %0d", out_count);
        task_count = task_count + 1;

        $display("ATTENTION_SINGLE_HEAD_TB_PASS tasks=%0d outputs_per_task=6336 zero_and_constant", task_count);
        $finish;
    end

    initial begin
        #100_000_000;
        $fatal(1, "testbench watchdog expired");
    end
endmodule
