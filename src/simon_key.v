//`timescale 1ns/1ps

/*
module generates and reconstructs subkeys
this is the most efficient possible approach in terms of the number of required logic gates
*/

module simon_key (
    input wire clk,
    input wire rst,
    input wire [63:0] key,      // main 64-bit key
    input wire [5:0] round_ctr, // current round number
    input wire dir,             // 0 = Encrypt, 1 = Decrypt
    output wire [15:0] subkey   // generated subkey for the given round
);

    wire [61:0] z_seq = 62'b11111010001001010110000111001101111101000100101011000011100110;
    
    //subkeys
    reg [15:0] k0, k1, k2, k3;
    
    // generation of K[i+4]
    wire [15:0] k3_ror3 = {k3[2:0], k3[15:3]};
    wire [15:0] tmp = k3_ror3 ^ k1;
    wire [15:0] tmp_ror1 = {tmp[0], tmp[15:1]};
    
    // which index of variable z_seq should be used
    wire [5:0] z_idx_calc = (dir) ? ((round_ctr >= 4) ? round_ctr - 4 : 0) : round_ctr;
    wire [5:0] z_idx_safe = (z_idx_calc > 61) ? 0 : (61 - z_idx_calc);
    wire z_bit = z_seq[z_idx_safe];

    // new subkey
    wire [15:0] k_next = 16'hFFFC ^ {15'b0, z_bit} ^ k0 ^ tmp ^ tmp_ror1;

    // Reconstruction of K[i-1]
    wire [15:0] k2_ror3 = {k2[2:0], k2[15:3]};
    wire [15:0] tmp_rev = k2_ror3 ^ k0; 
    wire [15:0] tmp_rev_ror1 = {tmp_rev[0], tmp_rev[15:1]};
    
    // previous key
    wire [15:0] k_prev = k3 ^ 16'hFFFC ^ {15'b0, z_bit} ^ tmp_rev ^ tmp_rev_ror1;

    always @(posedge clk) begin
        if (rst) begin
            // load the master key into registers for operations
            k0 <= key[15:0];
            k1 <= key[31:16];
            k2 <= key[47:32];
            k3 <= key[63:48];
        end else begin
            if (!dir) begin
                // LEFT shift, generate a new subkey
                k0 <= k1; k1 <= k2; k2 <= k3; k3 <= k_next;
            end else begin
                // RIGHT shift, reconstruct the old subkey
                k3 <= k2; k2 <= k1; k1 <= k0; k0 <= k_prev;
            end
        end
    end

    // output mux
    assign subkey = (dir) ? k3 : k0;

endmodule