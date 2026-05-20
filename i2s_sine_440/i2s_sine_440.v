// =============================================================================
// i2s_sine_440.v — I2S передавач, генерує синус 440 Hz на CS4344 DAC
// v2: hardcoded sine ROM (без $readmemh — гарантована ініціалізація)
//
// Піни:
//   clk   → PIN_24   (50 MHz)
//   mclk  → PIN_110  (CS4344 MCLK, 12.5 MHz)
//   lrclk → PIN_111  (CS4344 LRCLK, ~48.8 kHz)
//   sclk  → PIN_112  (CS4344 SCLK, 3.125 MHz)
//   sdin  → PIN_113  (CS4344 SDIN)
// =============================================================================

module i2s_sine_440 (
    input  wire clk,
    output wire mclk,
    output wire lrclk,
    output wire sclk,
    output wire sdin
);

// ── MCLK : 50 MHz / 4 = 12.5 MHz ────────────────────────────────────────────
reg mclk_r = 0;
reg m_cnt  = 0;
always @(posedge clk) begin
    m_cnt  <= m_cnt + 1;
    if (m_cnt == 1'd1) mclk_r <= ~mclk_r;
end
assign mclk = mclk_r;

// ── SCLK : 50 MHz / 16 = 3.125 MHz ──────────────────────────────────────────
reg        sclk_r = 0;
reg [2:0]  s_cnt  = 0;
always @(posedge clk) begin
    s_cnt <= s_cnt + 1;
    if (s_cnt == 3'd7) sclk_r <= ~sclk_r;
end
assign sclk = sclk_r;

// ── SCLK falling edge ────────────────────────────────────────────────────────
reg sclk_d = 0;
always @(posedge clk) sclk_d <= sclk_r;
wire sclk_fall = sclk_d & ~sclk_r;

// ── Bit counter 0..63 ────────────────────────────────────────────────────────
reg [5:0] bit_cnt = 0;
always @(posedge clk)
    if (sclk_fall)
        bit_cnt <= (bit_cnt == 6'd63) ? 6'd0 : bit_cnt + 1;

// ── LRCLK ────────────────────────────────────────────────────────────────────
// Standard I2S: LRCLK змінюється за 1 SCLK ДО першого біта (MSB)
// MSB лівого  → sclk_rise при bit_cnt=0  → LRCLK міняємо при bit_cnt=63
// MSB правого → sclk_rise при bit_cnt=32 → LRCLK міняємо при bit_cnt=31
reg lrclk_r = 0;
always @(posedge clk)
    if (sclk_fall) begin
        if      (bit_cnt == 6'd63) lrclk_r <= 1'b0;
        else if (bit_cnt == 6'd31) lrclk_r <= 1'b1;
    end
assign lrclk = lrclk_r;

// ── Phase accumulator — 440 Hz @ fs ≈ 48828 Hz ───────────────────────────────
localparam [31:0] PHASE_INC = 32'd38_720_270;
reg [31:0] phase = 0;
wire new_sample = sclk_fall & (bit_cnt == 6'd63);
always @(posedge clk)
    if (new_sample) phase <= phase + PHASE_INC;

// ── Sine ROM — 256 × 16-bit, hardcoded (гарантована ініціалізація) ───────────
function [15:0] sine_val;
    input [7:0] idx;
    case (idx)
        8'd0: sine_val = 16'h0000;
        8'd1: sine_val = 16'h0324;
        8'd2: sine_val = 16'h0648;
        8'd3: sine_val = 16'h096A;
        8'd4: sine_val = 16'h0C8C;
        8'd5: sine_val = 16'h0FAB;
        8'd6: sine_val = 16'h12C8;
        8'd7: sine_val = 16'h15E2;
        8'd8: sine_val = 16'h18F9;
        8'd9: sine_val = 16'h1C0B;
        8'd10: sine_val = 16'h1F1A;
        8'd11: sine_val = 16'h2223;
        8'd12: sine_val = 16'h2528;
        8'd13: sine_val = 16'h2826;
        8'd14: sine_val = 16'h2B1F;
        8'd15: sine_val = 16'h2E11;
        8'd16: sine_val = 16'h30FB;
        8'd17: sine_val = 16'h33DF;
        8'd18: sine_val = 16'h36BA;
        8'd19: sine_val = 16'h398C;
        8'd20: sine_val = 16'h3C56;
        8'd21: sine_val = 16'h3F17;
        8'd22: sine_val = 16'h41CE;
        8'd23: sine_val = 16'h447A;
        8'd24: sine_val = 16'h471C;
        8'd25: sine_val = 16'h49B4;
        8'd26: sine_val = 16'h4C3F;
        8'd27: sine_val = 16'h4EBF;
        8'd28: sine_val = 16'h5133;
        8'd29: sine_val = 16'h539B;
        8'd30: sine_val = 16'h55F5;
        8'd31: sine_val = 16'h5842;
        8'd32: sine_val = 16'h5A82;
        8'd33: sine_val = 16'h5CB3;
        8'd34: sine_val = 16'h5ED7;
        8'd35: sine_val = 16'h60EB;
        8'd36: sine_val = 16'h62F1;
        8'd37: sine_val = 16'h64E8;
        8'd38: sine_val = 16'h66CF;
        8'd39: sine_val = 16'h68A6;
        8'd40: sine_val = 16'h6A6D;
        8'd41: sine_val = 16'h6C23;
        8'd42: sine_val = 16'h6DC9;
        8'd43: sine_val = 16'h6F5E;
        8'd44: sine_val = 16'h70E2;
        8'd45: sine_val = 16'h7254;
        8'd46: sine_val = 16'h73B5;
        8'd47: sine_val = 16'h7504;
        8'd48: sine_val = 16'h7641;
        8'd49: sine_val = 16'h776B;
        8'd50: sine_val = 16'h7884;
        8'd51: sine_val = 16'h7989;
        8'd52: sine_val = 16'h7A7C;
        8'd53: sine_val = 16'h7B5C;
        8'd54: sine_val = 16'h7C29;
        8'd55: sine_val = 16'h7CE3;
        8'd56: sine_val = 16'h7D89;
        8'd57: sine_val = 16'h7E1D;
        8'd58: sine_val = 16'h7E9C;
        8'd59: sine_val = 16'h7F09;
        8'd60: sine_val = 16'h7F61;
        8'd61: sine_val = 16'h7FA6;
        8'd62: sine_val = 16'h7FD8;
        8'd63: sine_val = 16'h7FF5;
        8'd64: sine_val = 16'h7FFF;
        8'd65: sine_val = 16'h7FF5;
        8'd66: sine_val = 16'h7FD8;
        8'd67: sine_val = 16'h7FA6;
        8'd68: sine_val = 16'h7F61;
        8'd69: sine_val = 16'h7F09;
        8'd70: sine_val = 16'h7E9C;
        8'd71: sine_val = 16'h7E1D;
        8'd72: sine_val = 16'h7D89;
        8'd73: sine_val = 16'h7CE3;
        8'd74: sine_val = 16'h7C29;
        8'd75: sine_val = 16'h7B5C;
        8'd76: sine_val = 16'h7A7C;
        8'd77: sine_val = 16'h7989;
        8'd78: sine_val = 16'h7884;
        8'd79: sine_val = 16'h776B;
        8'd80: sine_val = 16'h7641;
        8'd81: sine_val = 16'h7504;
        8'd82: sine_val = 16'h73B5;
        8'd83: sine_val = 16'h7254;
        8'd84: sine_val = 16'h70E2;
        8'd85: sine_val = 16'h6F5E;
        8'd86: sine_val = 16'h6DC9;
        8'd87: sine_val = 16'h6C23;
        8'd88: sine_val = 16'h6A6D;
        8'd89: sine_val = 16'h68A6;
        8'd90: sine_val = 16'h66CF;
        8'd91: sine_val = 16'h64E8;
        8'd92: sine_val = 16'h62F1;
        8'd93: sine_val = 16'h60EB;
        8'd94: sine_val = 16'h5ED7;
        8'd95: sine_val = 16'h5CB3;
        8'd96: sine_val = 16'h5A82;
        8'd97: sine_val = 16'h5842;
        8'd98: sine_val = 16'h55F5;
        8'd99: sine_val = 16'h539B;
        8'd100: sine_val = 16'h5133;
        8'd101: sine_val = 16'h4EBF;
        8'd102: sine_val = 16'h4C3F;
        8'd103: sine_val = 16'h49B4;
        8'd104: sine_val = 16'h471C;
        8'd105: sine_val = 16'h447A;
        8'd106: sine_val = 16'h41CE;
        8'd107: sine_val = 16'h3F17;
        8'd108: sine_val = 16'h3C56;
        8'd109: sine_val = 16'h398C;
        8'd110: sine_val = 16'h36BA;
        8'd111: sine_val = 16'h33DF;
        8'd112: sine_val = 16'h30FB;
        8'd113: sine_val = 16'h2E11;
        8'd114: sine_val = 16'h2B1F;
        8'd115: sine_val = 16'h2826;
        8'd116: sine_val = 16'h2528;
        8'd117: sine_val = 16'h2223;
        8'd118: sine_val = 16'h1F1A;
        8'd119: sine_val = 16'h1C0B;
        8'd120: sine_val = 16'h18F9;
        8'd121: sine_val = 16'h15E2;
        8'd122: sine_val = 16'h12C8;
        8'd123: sine_val = 16'h0FAB;
        8'd124: sine_val = 16'h0C8C;
        8'd125: sine_val = 16'h096A;
        8'd126: sine_val = 16'h0648;
        8'd127: sine_val = 16'h0324;
        8'd128: sine_val = 16'h0000;
        8'd129: sine_val = 16'hFCDC;
        8'd130: sine_val = 16'hF9B8;
        8'd131: sine_val = 16'hF696;
        8'd132: sine_val = 16'hF374;
        8'd133: sine_val = 16'hF055;
        8'd134: sine_val = 16'hED38;
        8'd135: sine_val = 16'hEA1E;
        8'd136: sine_val = 16'hE707;
        8'd137: sine_val = 16'hE3F5;
        8'd138: sine_val = 16'hE0E6;
        8'd139: sine_val = 16'hDDDD;
        8'd140: sine_val = 16'hDAD8;
        8'd141: sine_val = 16'hD7DA;
        8'd142: sine_val = 16'hD4E1;
        8'd143: sine_val = 16'hD1EF;
        8'd144: sine_val = 16'hCF05;
        8'd145: sine_val = 16'hCC21;
        8'd146: sine_val = 16'hC946;
        8'd147: sine_val = 16'hC674;
        8'd148: sine_val = 16'hC3AA;
        8'd149: sine_val = 16'hC0E9;
        8'd150: sine_val = 16'hBE32;
        8'd151: sine_val = 16'hBB86;
        8'd152: sine_val = 16'hB8E4;
        8'd153: sine_val = 16'hB64C;
        8'd154: sine_val = 16'hB3C1;
        8'd155: sine_val = 16'hB141;
        8'd156: sine_val = 16'hAECD;
        8'd157: sine_val = 16'hAC65;
        8'd158: sine_val = 16'hAA0B;
        8'd159: sine_val = 16'hA7BE;
        8'd160: sine_val = 16'hA57E;
        8'd161: sine_val = 16'hA34D;
        8'd162: sine_val = 16'hA129;
        8'd163: sine_val = 16'h9F15;
        8'd164: sine_val = 16'h9D0F;
        8'd165: sine_val = 16'h9B18;
        8'd166: sine_val = 16'h9931;
        8'd167: sine_val = 16'h975A;
        8'd168: sine_val = 16'h9593;
        8'd169: sine_val = 16'h93DD;
        8'd170: sine_val = 16'h9237;
        8'd171: sine_val = 16'h90A2;
        8'd172: sine_val = 16'h8F1E;
        8'd173: sine_val = 16'h8DAC;
        8'd174: sine_val = 16'h8C4B;
        8'd175: sine_val = 16'h8AFC;
        8'd176: sine_val = 16'h89BF;
        8'd177: sine_val = 16'h8895;
        8'd178: sine_val = 16'h877C;
        8'd179: sine_val = 16'h8677;
        8'd180: sine_val = 16'h8584;
        8'd181: sine_val = 16'h84A4;
        8'd182: sine_val = 16'h83D7;
        8'd183: sine_val = 16'h831D;
        8'd184: sine_val = 16'h8277;
        8'd185: sine_val = 16'h81E3;
        8'd186: sine_val = 16'h8164;
        8'd187: sine_val = 16'h80F7;
        8'd188: sine_val = 16'h809F;
        8'd189: sine_val = 16'h805A;
        8'd190: sine_val = 16'h8028;
        8'd191: sine_val = 16'h800B;
        8'd192: sine_val = 16'h8001;
        8'd193: sine_val = 16'h800B;
        8'd194: sine_val = 16'h8028;
        8'd195: sine_val = 16'h805A;
        8'd196: sine_val = 16'h809F;
        8'd197: sine_val = 16'h80F7;
        8'd198: sine_val = 16'h8164;
        8'd199: sine_val = 16'h81E3;
        8'd200: sine_val = 16'h8277;
        8'd201: sine_val = 16'h831D;
        8'd202: sine_val = 16'h83D7;
        8'd203: sine_val = 16'h84A4;
        8'd204: sine_val = 16'h8584;
        8'd205: sine_val = 16'h8677;
        8'd206: sine_val = 16'h877C;
        8'd207: sine_val = 16'h8895;
        8'd208: sine_val = 16'h89BF;
        8'd209: sine_val = 16'h8AFC;
        8'd210: sine_val = 16'h8C4B;
        8'd211: sine_val = 16'h8DAC;
        8'd212: sine_val = 16'h8F1E;
        8'd213: sine_val = 16'h90A2;
        8'd214: sine_val = 16'h9237;
        8'd215: sine_val = 16'h93DD;
        8'd216: sine_val = 16'h9593;
        8'd217: sine_val = 16'h975A;
        8'd218: sine_val = 16'h9931;
        8'd219: sine_val = 16'h9B18;
        8'd220: sine_val = 16'h9D0F;
        8'd221: sine_val = 16'h9F15;
        8'd222: sine_val = 16'hA129;
        8'd223: sine_val = 16'hA34D;
        8'd224: sine_val = 16'hA57E;
        8'd225: sine_val = 16'hA7BE;
        8'd226: sine_val = 16'hAA0B;
        8'd227: sine_val = 16'hAC65;
        8'd228: sine_val = 16'hAECD;
        8'd229: sine_val = 16'hB141;
        8'd230: sine_val = 16'hB3C1;
        8'd231: sine_val = 16'hB64C;
        8'd232: sine_val = 16'hB8E4;
        8'd233: sine_val = 16'hBB86;
        8'd234: sine_val = 16'hBE32;
        8'd235: sine_val = 16'hC0E9;
        8'd236: sine_val = 16'hC3AA;
        8'd237: sine_val = 16'hC674;
        8'd238: sine_val = 16'hC946;
        8'd239: sine_val = 16'hCC21;
        8'd240: sine_val = 16'hCF05;
        8'd241: sine_val = 16'hD1EF;
        8'd242: sine_val = 16'hD4E1;
        8'd243: sine_val = 16'hD7DA;
        8'd244: sine_val = 16'hDAD8;
        8'd245: sine_val = 16'hDDDD;
        8'd246: sine_val = 16'hE0E6;
        8'd247: sine_val = 16'hE3F5;
        8'd248: sine_val = 16'hE707;
        8'd249: sine_val = 16'hEA1E;
        8'd250: sine_val = 16'hED38;
        8'd251: sine_val = 16'hF055;
        8'd252: sine_val = 16'hF374;
        8'd253: sine_val = 16'hF696;
        8'd254: sine_val = 16'hF9B8;
        default: sine_val = 16'hFCDC;
    endcase
endfunction

wire [7:0]  lut_idx = phase[31:24];
wire [15:0] sample  = sine_val(lut_idx);

// ── I2S shift register ────────────────────────────────────────────────────────
// Standard I2S: завантажуємо sample при bit_cnt=0 (лівий) і bit_cnt=32 (правий)
// Це на 1 SCLK пізніше ніж зміна LRCLK — саме так чекає CS4344
reg [31:0] shift_reg = 0;
always @(posedge clk) begin
    if (sclk_fall) begin
        if (bit_cnt == 6'd0 || bit_cnt == 6'd32)
            shift_reg <= {sample, 16'h0000};
        else
            shift_reg <= {shift_reg[30:0], 1'b0};
    end
end
assign sdin = shift_reg[31];

endmodule
