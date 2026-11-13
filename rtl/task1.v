`timescale 1ns/1ps

module task1_round_sat (
    input  wire signed [31:0] acc,
    output reg  signed [15:0] y,
    output reg               saturated
);

    wire signed [32:0] extended_acc = {acc[31], acc};
    wire [32:0] magnitude = acc[31] ? -extended_acc : extended_acc;
    wire [32:0] rounded_magnitude = (magnitude + 33'd512) >> 10;
    wire signed [32:0] rounded = acc[31] ? -$signed(rounded_magnitude)
                                                   : $signed(rounded_magnitude);

    always @* begin
        saturated = 1'b0;
        if (rounded > 33'sd32767) begin
            y = 16'sd32767;
            saturated = 1'b1;
        end else if (rounded < -33'sd32768) begin
            y = -16'sd32768;
            saturated = 1'b1;
        end else begin
            y = rounded[15:0];
        end
    end
endmodule

module task1 (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               start_valid,
    output wire               start_ready,
    input  wire signed [11:0] bias,
    input  wire               in_valid,
    output wire               in_ready,
    input  wire signed [11:0] x,
    input  wire signed [11:0] weight,
    output wire               out_valid,
    input  wire               out_ready,
    output reg  signed [15:0] y,
    output reg                saturated,
    output reg         [6:0]  overflow_count
);
    localparam [1:0] IDLE = 2'd0, MAC = 2'd1, ROUND = 2'd2, HOLD = 2'd3;
    reg [1:0] state;
    reg [5:0] count;
    reg signed [31:0] accumulator;
    wire signed [23:0] product = x * weight;
    wire signed [32:0] sum = {accumulator[31], accumulator}
                          + {{9{product[23]}}, product};
    wire signed [15:0] rounded_y;
    wire rounded_saturated;

    assign start_ready = rst_n && ((state == IDLE) || ((state == HOLD) && out_ready));
    assign in_ready = rst_n && (state == MAC);
    assign out_valid = rst_n && (state == HOLD);

    task1_round_sat quantizer (
        .acc(accumulator), .y(rounded_y), .saturated(rounded_saturated)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            count <= 6'd0;
            accumulator <= 32'sd0;
            y <= 16'sd0;
            saturated <= 1'b0;
            overflow_count <= 7'd0;
        end else if (start_valid && start_ready) begin
            accumulator <= {{12{bias[11]}}, bias, 8'b0};
            count <= 6'd0;
            overflow_count <= 7'd0;
            state <= MAC;
        end else begin
            case (state)
                MAC: begin
                    if (in_valid && in_ready) begin
                        accumulator <= sum[31:0];
                        if (sum[32] != sum[31])
                            overflow_count <= overflow_count + 7'd1;
                        if (count == 6'd63)
                            state <= ROUND;
                        else
                            count <= count + 6'd1;
                    end
                end
                ROUND: begin
                    y <= rounded_y;
                    saturated <= rounded_saturated;
                    state <= HOLD;
                end
                HOLD: begin
                    if (out_ready)
                        state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
