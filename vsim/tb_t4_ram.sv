`timescale 1ns/1ps

module tb_t4_ram;
    reg clk = 0;
    always #5 clk = ~clk;

    reg        we4096 = 0, we6336 = 0, we9801 = 0, we128 = 0;
    reg [11:0] a4096 = 0;
    reg [12:0] a6336 = 0;
    reg [13:0] a9801 = 0;
    reg [6:0]  a128  = 0;
    reg [15:0] wd = 0;
    wire [15:0] rd4096, rd6336, rd9801, rd128;

    t4_ram4096 u4 (.clk(clk), .we(we4096), .addr(a4096), .wdata(wd), .rdata(rd4096));
    t4_ram6336 u6 (.clk(clk), .we(we6336), .addr(a6336), .wdata(wd), .rdata(rd6336));
    t4_ram9801 u9 (.clk(clk), .we(we9801), .addr(a9801), .wdata(wd), .rdata(rd9801));
    t4_ram128  u1 (.clk(clk), .we(we128),  .addr(a128),  .wdata(wd), .rdata(rd128));

    integer i, errors = 0;
    reg [15:0] expect_val;

    task automatic wr4(input [11:0] a, input [15:0] d);
        begin @(negedge clk); a4096 = a; wd = d; we4096 = 1; @(negedge clk); we4096 = 0; end
    endtask
    task automatic wr6(input [12:0] a, input [15:0] d);
        begin @(negedge clk); a6336 = a; wd = d; we6336 = 1; @(negedge clk); we6336 = 0; end
    endtask
    task automatic wr9(input [13:0] a, input [15:0] d);
        begin @(negedge clk); a9801 = a; wd = d; we9801 = 1; @(negedge clk); we9801 = 0; end
    endtask
    task automatic wr1(input [6:0] a, input [15:0] d);
        begin @(negedge clk); a128 = a; wd = d; we128 = 1; @(negedge clk); we128 = 0; end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        for (i = 0; i < 64; i = i + 1) begin
            wr4(i[11:0] * 12'd37, 16'h1000 + i);
            wr6(i * 99, 16'h2000 + i);
            wr9(i * 149, 16'h3000 + i);
            wr1(i[6:0], 16'h4000 + i);
        end
        for (i = 0; i < 64; i = i + 1) begin
            @(negedge clk); a4096 = i[11:0] * 12'd37; we4096 = 0;
            @(negedge clk); #1 expect_val = 16'h1000 + i;
            if (rd4096 !== expect_val) begin errors = errors + 1; $display("FAIL 4096 a=%0d got=%h exp=%h", i, rd4096, expect_val); end

            @(negedge clk); a6336 = i * 99; we6336 = 0;
            @(negedge clk); #1 expect_val = 16'h2000 + i;
            if (rd6336 !== expect_val) begin errors = errors + 1; $display("FAIL 6336 a=%0d got=%h exp=%h", i, rd6336, expect_val); end

            @(negedge clk); a9801 = i * 149; we9801 = 0;
            @(negedge clk); #1 expect_val = 16'h3000 + i;
            if (rd9801 !== expect_val) begin errors = errors + 1; $display("FAIL 9801 a=%0d got=%h exp=%h", i, rd9801, expect_val); end

            @(negedge clk); a128 = i[6:0]; we128 = 0;
            @(negedge clk); #1 expect_val = 16'h4000 + i;
            if (rd128 !== expect_val) begin errors = errors + 1; $display("FAIL 128 a=%0d got=%h exp=%h", i, rd128, expect_val); end
        end
        if (errors == 0) $display("T4RAM_TB_PASS");
        else $display("T4RAM_TB_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
