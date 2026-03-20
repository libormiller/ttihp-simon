////////////////////////////////////////////////////////////////////////////////
////                                                                        ////
//// Project Name: SPI (Verilog)                                            ////
////                                                                        ////
//// Module Name: spi_slave                                                ////
////                                                                        ////
////                                                                        ////
////  This file is part of the Ethernet IP core project                     ////
////  http://opencores.com/project,spi_verilog_master_slave                 ////
////                                                                        ////
////  Author(s):                                                            ////
////      Santhosh G (santhg@opencores.org)                                 ////
////                                                                        ////
////  Refer to Readme.txt for more information                              ////
////                                                                        ////
////////////////////////////////////////////////////////////////////////////////
////                                                                        ////
//// Copyright (C) 2014, 2015 Authors                                       ////
////                                                                        ////
//// This source file may be used and distributed without                   ////
//// restriction provided that this copyright statement is not              ////
//// removed from the file and that any derivative work contains            ////
//// the original copyright notice and the associated disclaimer.           ////
////                                                                        ////
//// This source file is free software; you can redistribute it             ////
//// and/or modify it under the terms of the GNU Lesser General             ////
//// Public License as published by the Free Software Foundation;           ////
//// either version 2.1 of the License, or (at your option) any             ////
//// later version.                                                         ////
////                                                                        ////
//// This source is distributed in the hope that it will be                 ////
//// useful, but WITHOUT ANY WARRANTY; without even the implied             ////
//// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR                ////
//// PURPOSE.  See the GNU Lesser General Public License for more           ////
//// details.                                                               ////
////                                                                        ////
//// You should have received a copy of the GNU Lesser General              ////
//// Public License along with this source; if not, download it             ////
//// from http://www.opencores.org/lgpl.shtml                               ////
////                                                                        ////
////////////////////////////////////////////////////////////////////////////////
/* SPI MODE 3
		CHANGE DATA (sdout) @ NEGEDGE SCK
		read data (sdin) @posedge SCK
*/		
module spi_slave (clk, rstb,ten,tdata,mlb,ss,sck,sdin, sdout,done,rdata);
  input clk;
  input rstb,ss,sck,sdin,ten,mlb;
  input [7:0] tdata;
  output sdout;           //slave out   master in 
  output reg done;
  output reg [7:0] rdata;

  reg [3:0] sck_sync;
  reg [3:0] ss_sync;
  reg [2:0] sdin_sync;

  always @(posedge clk or negedge rstb) begin
      if (!rstb) begin
          sck_sync <= 4'b1111;
          ss_sync <= 4'b1111;
          sdin_sync <= 3'b000;
      end else begin
          sck_sync <= {sck_sync[2:0], sck};
          ss_sync <= {ss_sync[2:0], ss};
          sdin_sync <= {sdin_sync[1:0], sdin};
      end
  end

  // Implementation of debouncing (signal has to be the same three clocks in a row)
  reg sck_debounced;
  reg ss_debounced;
  reg sdin_debounced;

  always @(posedge clk or negedge rstb) begin
      if (!rstb) begin
          sck_debounced <= 1'b1;
          ss_debounced <= 1'b1;
          sdin_debounced <= 1'b0;
      end else begin
          if (sck_sync[3:1] == 3'b000) sck_debounced <= 1'b0;
          else if (sck_sync[3:1] == 3'b111) sck_debounced <= 1'b1;

          if (ss_sync[3:1] == 3'b000) ss_debounced <= 1'b0;
          else if (ss_sync[3:1] == 3'b111) ss_debounced <= 1'b1;

          if (sdin_sync[2:0] == 3'b000) sdin_debounced <= 1'b0;
          else if (sdin_sync[2:0] == 3'b111) sdin_debounced <= 1'b1;
      end
  end

  reg sck_debounced_prev;
  always @(posedge clk or negedge rstb) begin
      if (!rstb) sck_debounced_prev <= 1'b1;
      else       sck_debounced_prev <= sck_debounced;
  end

  wire sck_rise = (sck_debounced == 1'b1 && sck_debounced_prev == 1'b0);
  wire sck_fall = (sck_debounced == 1'b0 && sck_debounced_prev == 1'b1);
  wire ss_active = ~ss_debounced;
  wire sdin_val = sdin_debounced;

  reg [7:0] treg, rreg;
  reg [2:0] bit_cnt;
  
  assign sdout = (ss_active && ten) ? (mlb ? treg[7] : treg[0]) : 1'bz;

  always @(posedge clk or negedge rstb) begin
      if (!rstb) begin
          rreg <= 8'h00;
          rdata <= 8'h00;
          done <= 1'b0;
          bit_cnt <= 3'd0;
          treg <= 8'hFF;
      end else begin
          done <= 1'b0; // default pulse
          if (!ss_active) begin
              bit_cnt <= 3'd0;
              treg <= 8'hFF;
          end else begin
              // Shift out on falling edge
              if (sck_fall) begin
                  if (bit_cnt == 3'd0) begin
                      treg <= tdata; // Load first byte
                  end else begin
                      if (mlb) treg <= {treg[6:0], 1'b1};
                      else     treg <= {1'b1, treg[7:1]};
                  end
              end
              
              // Sample on rising edge
              if (sck_rise) begin
                  if (mlb) rreg <= {rreg[6:0], sdin_val};
                  else     rreg <= {sdin_val, rreg[7:1]};
                  
                  bit_cnt <= bit_cnt + 3'd1;
                  if (bit_cnt == 3'd7) begin
                      done <= 1'b1;
                      if (mlb) rdata <= {rreg[6:0], sdin_val};
                      else     rdata <= {sdin_val, rreg[7:1]};
                  end
              end
          end
      end
  end

endmodule
      
/*
			if(mlb==0)  //LSB first, out=lsb -> right shift
					begin treg = {treg[7],treg[7:1]}; end
			else     //MSB first, out=msb -> left shift
					begin treg = {treg[6:0],treg[0]}; end	
*/


/*
force -freeze sim:/SPI_slave/sck 0 0, 1 {25 ns} -r 50 -can 410
run 405ns
noforce sim:/SPI_slave/sck
force -freeze sim:/SPI_slave/sck 1 0
*/
