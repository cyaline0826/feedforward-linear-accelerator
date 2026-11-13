`timescale 1ns/1ps

module t4_ram4096 (
    input  wire        clk,
    input  wire        we,
    input  wire [11:0] addr,
    input  wire [15:0] wdata,
    output wire [15:0] rdata
);
    wire [15:0] q;
    assign rdata = q;
    RAMSP4096X16 u_mem (
        .A(addr), .CLK(clk), .D(wdata), .Q(q),
        .CEN(1'b0), .WEN({16{~we}}), .GWEN(~we),
        .RET1N(1'b1), .EMA(3'b000), .EMAW(2'b00)
    );
`ifndef SYNTHESIS
    function [15:0] peek(input [11:0] a); peek = u_mem.mem[a]; endfunction
`endif
endmodule

module t4_ram6336 (
    input  wire        clk,
    input  wire        we,
    input  wire [12:0] addr,
    input  wire [15:0] wdata,
    output wire [15:0] rdata
);
    wire        bank = addr[12];
    wire [11:0] off  = addr[11:0];
    wire [15:0] q0, q1;
    RAMSP4096X16 u_m0 (
        .A(off), .CLK(clk), .D(wdata), .Q(q0),
        .CEN(~((!we) | (we & (!bank)))), .WEN({16{~we}}), .GWEN(~we),
        .RET1N(1'b1), .EMA(3'b000), .EMAW(2'b00)
    );
    RAMSP4096X16 u_m1 (
        .A(off), .CLK(clk), .D(wdata), .Q(q1),
        .CEN(~((!we) | (we &   bank ))), .WEN({16{~we}}), .GWEN(~we),
        .RET1N(1'b1), .EMA(3'b000), .EMAW(2'b00)
    );
    reg q_bank;
    always @(posedge clk) if (!we) q_bank <= bank;
    assign rdata = q_bank ? q1 : q0;
`ifndef SYNTHESIS
    function [15:0] peek(input [12:0] a);
        peek = a[12] ? u_m1.mem[a[11:0]] : u_m0.mem[a[11:0]];
    endfunction
`endif
endmodule

module t4_ram9801 (
    input  wire        clk,
    input  wire        we,
    input  wire [13:0] addr,
    input  wire [15:0] wdata,
    output wire [15:0] rdata
);
    wire [1:0]  bank = addr[13:12];
    wire [11:0] off  = addr[11:0];
    wire [15:0] q0, q1, q2;
    RAMSP4096X16 u_m0 (
        .A(off), .CLK(clk), .D(wdata), .Q(q0),
        .CEN(~((!we) | (we & (bank == 2'd0)))), .WEN({16{~we}}), .GWEN(~we),
        .RET1N(1'b1), .EMA(3'b000), .EMAW(2'b00)
    );
    RAMSP4096X16 u_m1 (
        .A(off), .CLK(clk), .D(wdata), .Q(q1),
        .CEN(~((!we) | (we & (bank == 2'd1)))), .WEN({16{~we}}), .GWEN(~we),
        .RET1N(1'b1), .EMA(3'b000), .EMAW(2'b00)
    );
    RAMSP4096X16 u_m2 (
        .A(off), .CLK(clk), .D(wdata), .Q(q2),
        .CEN(~((!we) | (we & (bank == 2'd2)))), .WEN({16{~we}}), .GWEN(~we),
        .RET1N(1'b1), .EMA(3'b000), .EMAW(2'b00)
    );
    reg [1:0] bank_q;
    always @(posedge clk) if (!we) bank_q <= bank;
    assign rdata = (bank_q == 2'd0) ? q0 : (bank_q == 2'd1) ? q1 : q2;
`ifndef SYNTHESIS
    function [15:0] peek(input [13:0] a);
        peek = (a[13:12] == 2'd0) ? u_m0.mem[a[11:0]] :
               (a[13:12] == 2'd1) ? u_m1.mem[a[11:0]] : u_m2.mem[a[11:0]];
    endfunction
`endif
endmodule

module t4_ram128 (
    input  wire        clk,
    input  wire        we,
    input  wire [6:0]  addr,
    input  wire [15:0] wdata,
    output wire [15:0] rdata
);
    wire [15:0] q;
    assign rdata = q;
    RAMSP128X16 u_mem (
        .A(addr), .CLK(clk), .D(wdata), .Q(q),
        .CEN(1'b0), .WEN({16{~we}}), .GWEN(~we),
        .RET1N(1'b1), .EMA(3'b000), .EMAW(2'b00)
    );
`ifndef SYNTHESIS
    function [15:0] peek(input [6:0] a); peek = u_mem.mem[a]; endfunction
`endif
endmodule
