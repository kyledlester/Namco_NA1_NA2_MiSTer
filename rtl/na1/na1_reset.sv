module na1_reset(
    input wire clk_sys, input wire reset_async,
    // Synchronous clk_sys event from a future MCU interface; not a port model.
    input wire maincpu_reset_release,
    output wire reset_system, output wire reset_mcu,
    output wire reset_maincpu
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [1:0] reset_sync = 2'b11;
    always @(posedge clk_sys or posedge reset_async) begin
        if (reset_async) reset_sync <= 2'b11;
        else reset_sync <= {reset_sync[0], 1'b0};
    end
    assign reset_system = reset_sync[1];
    assign reset_mcu = reset_system;
    reg maincpu_released = 1'b0;
    always @(posedge clk_sys or posedge reset_async) begin
        if (reset_async) maincpu_released <= 1'b0;
        else if (reset_system) maincpu_released <= 1'b0;
        else if (maincpu_reset_release) maincpu_released <= 1'b1;
    end
    assign reset_maincpu = reset_system || !maincpu_released;
endmodule
