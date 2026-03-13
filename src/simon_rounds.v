//`timescale 1ns/1ps

/*
implementation of a Feistel cipher with the SIMON 32/64 round function
the advantage of a Feistel cipher is that decryption is only the inverse run of encryption
-> only one mechanism is enough, but inverse key order must be generated
*/

module simon_rounds (
    input wire clk,
    input wire rst,
    input wire mode,         // 0=Encrypt, 1=Decrypt
    input wire [31:0] block, // plaintext
    input wire [63:0] key,   // main key
    output reg [31:0] ciphertext,
    output reg done          // 1=done
);
    reg [5:0] round_ctr;
    reg [15:0] Lx, Rx;       // plaintext block split
    wire [15:0] subkey;

    localparam S_IDLE = 0, S_PRECOMP = 1, S_CALC = 2;
    reg [1:0] state;
    
    reg key_dir; //subkey generation control
    
    //instance of the subkey generator
    simon_key key_gen_inst (
        .clk(clk),
        .rst(rst),
        .key(key),
        .round_ctr(round_ctr),
        .dir(key_dir),
        .subkey(subkey)
    );

    // combinational logic for SIMON
    wire [15:0] Lx_rol1 = {Lx[14:0], Lx[15]};
    wire [15:0] Lx_rol8 = {Lx[7:0], Lx[15:8]};
    wire [15:0] Lx_rol2 = {Lx[13:0], Lx[15:14]};   
    wire [15:0] f_out = (Lx_rol1 & Lx_rol8) ^ Lx_rol2;

    // right and left side after a round
    wire [15:0] next_Lx = Rx ^ f_out ^ subkey;
    wire [15:0] next_Rx = Lx;

    always @(posedge clk) begin
        if (rst) begin
            // Initialization 
            //for decrypt we must precompute the last subkey in PRECOMP
            state <= (mode) ? S_PRECOMP : S_CALC;
            done <= 0;
            round_ctr <= 0;
            key_dir <= 0; 
            ciphertext <= 0;

            // load input into registers
            if (mode) begin Lx <= block[15:0];  Rx <= block[31:16]; end
            else      begin Lx <= block[31:16]; Rx <= block[15:0];  end

        end else begin
            case (state)
                S_IDLE: begin
                    // wait for reset
                    done <= 1; 
                end

                S_PRECOMP: begin
                    // precomputation of the last subkey
                    if (round_ctr < 27) begin
                        round_ctr <= round_ctr + 1;
                    end else begin
                        state <= S_CALC; // subkey precomputed -> we can decrypt 
                        round_ctr <= 31; // we start from the last round
                        key_dir <= 1;    // generate keys backwards
                    end
                end

                S_CALC: begin
                    if (!mode) begin // encryption 0 -> 31
                        if (round_ctr < 31) begin
                            Lx <= next_Lx;
                            Rx <= next_Rx;
                            round_ctr <= round_ctr + 1;
                        end else begin
                            done <= 1;
                            ciphertext <= {next_Lx, next_Rx}; 
                            state <= S_IDLE; // stop
                        end
                    end else begin   // decryption 31 -> 0
                        if (round_ctr > 0) begin
                            Lx <= next_Lx;
                            Rx <= next_Rx;
                            round_ctr <= round_ctr - 1;
                        end else begin
                            done <= 1;
                            ciphertext <= {next_Rx, next_Lx}; 
                            state <= S_IDLE; // stop
                        end
                    end
                end
            endcase
        end
    end
endmodule