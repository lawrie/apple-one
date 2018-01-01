module top(
    input  clk12,

    input  uart_rx,
    output uart_tx,
    output uart_cts,

    output tm_cs,
    output tm_clk,
    inout  tm_dio,

    output reg [7:0] led
);

    //////////////////////////////////////////////////////////////////////////
    // CLK DIVIDER

    wire clk;
    clk_div u_clk_div(
        .clk     (clk12),
        .clk_out (clk)
    );

    //////////////////////////////////////////////////////////////////////////
    // 6502 reset

    reg [7:0] start;
    always @(posedge clk)
        if (~start[7]) start <= start + 1;

    assign res = start[7];

    //////////////////////////////////////////////////////////////////////////
    // 6502 phi0 clock

    reg [3:0] div;
    always @(posedge clk)
        div <= div + 1;

    assign phi0 = div[3];

    wire clk_phi;
    SB_GB bg_phi (
        .USER_SIGNAL_TO_GLOBAL_BUFFER(phi0),
        .GLOBAL_BUFFER_OUTPUT(clk_phi)
    );

    //////////////////////////////////////////////////////////////////////////
    // 6502

    wire        rw, res, irq, nmi, phi0;
    wire [15:0] ab;
    wire [7:0]  dbo;
    reg  [7:0]  dbi;

    chip_6502 chip_6502 (
        .clk    (clk),
        .phi    (phi0),
        .res    (res),
        .so     (1'b0),
        .rdy    (1'b1),
        .nmi    (nmi),
        .irq    (irq),
        .rw     (rw),
        .dbi    (dbi),
        .dbo    (dbo),
        .sync   (),
        .ab     (ab)
    );

    //////////////////////////////////////////////////////////////////////////
    // USB UART
    
    wire received, is_receiving, rx_error, is_transmitting, transmit;
    reg  [7:0] tx_byte;
    wire [7:0] rx_byte;

    uart #(.CLOCK_DIVIDE( 625 )) my_uart (
        clk12,              // master clock for this component
        ~res,               // synchronous reset line (resets if high)
        uart_rx,            // receive data on this line
        uart_tx,            // transmit data on this line
        transmit,           // signal to indicate that the UART should start a transmission
        tx_byte,            // 8-bit bus with byte to be transmitted when transmit is raised high
        received,           // output flag raised high for one cycle of clk when a byte is received
        rx_byte,            // byte which has just been received when received is raise
        is_receiving,       // indicates that we are currently receiving data on the rx lin
        is_transmitting,    // indicates that we are currently sending data on the tx line
        rx_error            // rx packet corrupt
    );

    // sync the TX latch to the clk12 domain
    reg apple_tx;
    Flag_CrossDomain tx_flag (
        .clkA(clk_phi),
        .FlagIn_clkA(apple_tx),
        .clkB(clk12),
        .FlagOut_clkB(transmit)
    );

    // sync the RX flag, using flag and ack
    reg [6:0] apple_rx_buf;
    reg apple_rx_ack;
    reg apple_rx_flag;

    always @(posedge clk12)
    begin
        if (received && !apple_rx_flag && !apple_rx_ack) begin
            apple_rx_flag <= 1;
            apple_rx_buf <= rx_byte[6:0];
        end

        if (apple_rx_flag && apple_rx_ack)
            apple_rx_flag <= 0;
    end
    
    // implement basic hardware flow control so 6502 can catch up
    assign uart_cts = is_receiving || apple_rx_flag;

    //////////////////////////////////////////////////////////////////////////
    // TM1638 Display

    reg  [3:0] display;
    reg  [7:0] digits[7:0];
    reg  [7:0] leds;
    wire [7:0] keys;

    ledAndKey my_led_and_keys (
        .clk        (clk12),
        .rst        (~res),
        .display    (display),
        .digit1     (digits[0]),
        .digit2     (digits[1]),
        .digit3     (digits[2]),
        .digit4     (digits[3]),
        .digit5     (digits[4]),
        .digit6     (digits[5]),
        .digit7     (digits[6]),
        .digit8     (digits[7]),
        .leds       (leds),
        .keys       (keys),
        .tm_cs      (tm_cs),
        .tm_clk     (tm_clk),
        .tm_dio     (tm_dio)
    );
    
    //////////////////////////////////////////////////////////////////////////
    // I/O locations

    localparam UART_RX =    16'hD010; // PIA.A register on Apple 1 - RX byte
    localparam UART_RXCR =  16'hD011; // PIA.A register on Apple 1 - RX control
    localparam UART_TX =    16'hD012; // PIA.B register on Apple 1 - TX byte
    localparam LED_KEYS =   16'hD020; // Start address of the Led&Keys module
    localparam LED =        16'hD000; // Breakout board LEDs
  
    /*
    0x77 - A
    0X73 - P
    0X73 - P
    0X38 - L
    0X79 - E
    0X40 - -
    0X06 - 1
    */

    //////////////////////////////////////////////////////////////////////////
    // RAM and ROM

    reg [7:0] ram[0:8191];
    initial begin
        $readmemh("../ram.hex", ram,        0, 8191);
        $readmemh("../rom.hex", ram, 8192-256, 8191);
    end

    always @(posedge clk_phi)
    begin
        // clear the UART RX ack if set
        if (apple_rx_ack)
            apple_rx_ack <= 0;

        // clear the UART TX latch if set
        if (apple_tx)
            apple_tx <= 0;

        if (res)
        begin
            case(ab)
                // UART TX control and TX register
                UART_TX:
                begin
                    if (rw)
                        dbi <= {is_transmitting, 7'd0};
                    else
                    begin
                        // Apple 1 terminal only uses 7 bits, MSB indicates
                        // terminal has ack'd RX
                        tx_byte <= {1'b0, dbo[6:0]};
                        apple_tx <= 1;
                    end
                end

                // UART RX control register
                UART_RXCR:
                begin
                    if (rw)
                        dbi <= {apple_rx_flag, 7'b0};
                end

                // UART RX register
                UART_RX:
                begin
                    if (rw)
                    begin
                        // Apple 1 terminal only uses 7 bits, MSB tied high
                        // Wozmon checks for MSB being high
                        dbi <= apple_rx_flag ? {1'b1, apple_rx_buf} : 8'b0;
                        apple_rx_ack <= 1;
                    end
                end

                // LED&KEYS registers
                LED_KEYS:      if (rw) dbi <= {4'b0, display}; else display <= dbo[3:0];
                LED_KEYS + 1:  if (rw) dbi <= digits[0]; else digits[0] <= dbo;
                LED_KEYS + 2:  if (rw) dbi <= digits[1]; else digits[1] <= dbo;
                LED_KEYS + 3:  if (rw) dbi <= digits[2]; else digits[2] <= dbo;
                LED_KEYS + 4:  if (rw) dbi <= digits[3]; else digits[3] <= dbo;
                LED_KEYS + 5:  if (rw) dbi <= digits[4]; else digits[4] <= dbo;
                LED_KEYS + 6:  if (rw) dbi <= digits[5]; else digits[5] <= dbo;
                LED_KEYS + 7:  if (rw) dbi <= digits[6]; else digits[6] <= dbo;
                LED_KEYS + 8:  if (rw) dbi <= digits[7]; else digits[7] <= dbo;
                LED_KEYS + 9:  if (rw) dbi <= leds; else leds <= dbo;
                LED_KEYS + 10: if (rw) dbi <= keys;

                // breakout board LED registers
                LED: if (rw) dbi <= led; else led <= dbo;

                default:
                begin
                    // RAM 0x0000 -> 0x1FFF, ROM 0xFF00 -> 0xFFFF
                    //
                    // !!!! ROM also at 0x1F00 -> 0x1FFF but writeable!!!!
                    //
                    // All other addresses return zero.
                    //
                    if (ab[15:13] == 3'b0 || ab[15:8] == 8'b11111111)
                    begin
                        // handle RAM/ROM address
                        dbi <= ram[ab[12:0]];
                        if (~rw && ~ab[15]) ram[ab[12:0]] <= dbo;
                    end
                    else
                        // unknown address return zero
                        dbi <= 8'b0;
                end

            endcase
        end
    end

    // set irq and nmi high. for later use
    assign irq = 1;
    assign nmi = 1;

endmodule