//======================================================================
//
// montprod.v
// ---------
// Montgomery product calculator for the modular exponentiantion core.
//
//
// Author: Peter Magnusson, Joachim Strombergson
// Copyright (c) 2015 Assured AB
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or
// without modification, are permitted provided that the following
// conditions are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in
//    the documentation and/or other materials provided with the
//    distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
// FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
// COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
// BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
// STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
// ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//======================================================================

module montprod(
                input wire           clk,
                input wire           reset_n,

                input wire           calculate,
                output wire          ready,

                input   [7 : 0]      length,

                output wire [7 : 0]  opa_addr,
                input wire [31 : 0]  opa_data,

                output wire [7 : 0]  opb_addr,
                input wire [31 : 0]  opb_data,

                output wire [7 : 0]  opm_addr,
                input wire [31 : 0]  opm_data,

                output wire [7 : 0]  result_addr,
                output wire [31 : 0] result_data,
                output wire          result_we
               );


  //----------------------------------------------------------------
  // Internal constant and parameter definitions.
  //----------------------------------------------------------------
  localparam CTRL_IDLE         = 4'h0;
  localparam CTRL_INIT_S       = 4'h1;
  localparam CTRL_LOOP_INIT    = 4'h2;
  localparam CTRL_LOOP_ITER    = 4'h3;
  localparam CTRL_L_CALC_SM    = 4'h4;
  localparam CTRL_L_CALC_SA    = 4'h5;
  localparam CTRL_L_CALC_SDIV2 = 4'h6;
  localparam CTRL_EMIT_S       = 4'h7;
  localparam CTRL_DONE         = 4'h8;


  //----------------------------------------------------------------
  // Registers including update variables and write enable.
  //----------------------------------------------------------------

  reg [07 : 0] opa_addr_reg;
  reg [07 : 0] opb_addr_reg;
  reg [07 : 0] opm_addr_reg;

  reg [07 : 0] result_addr_reg;
  reg [31 : 0] result_data_reg;
  reg          result_we_reg;

  reg          ready_reg;
  reg          ready_new;
  reg          ready_we;

  reg [3 : 0]  montprod_ctrl_reg;
  reg [3 : 0]  montprod_ctrl_new;
  reg          montprod_ctrl_we;

  reg [31 : 0] s_mem [0 : 255];
  reg [31 : 0] s_mem_new;
  reg          s_mem_we;
  reg [07 : 0] s_mem_addr;
  reg [31 : 0] s_mem_read_data;

  reg          q; //q = (s - b * A) & 1
  reg          q_reg;
  reg          b; //b: bit of B
  reg          b_reg;

  reg [12 : 0] loop_counter;
  reg [12 : 0] loop_counter_new;
  reg [12 : 0] loop_counter_dec;
  reg [07 : 0] B_word_index; //loop counter as a word index
  reg [04 : 0] B_bit_index; //loop counter as a bit index

  reg [07 : 0] word_index;
  reg [07 : 0] word_index_new;
  reg [07 : 0] word_index_dec;


  reg [31 : 0] add_argument1;
  reg [31 : 0] add_argument2;
  reg          add_carry_in;
  reg          add_carry_new;

  reg          reset_word_index;

  //----------------------------------------------------------------
  // Wires.
  //----------------------------------------------------------------
  reg           tmp_result_we;
  wire [31 : 0] add_result;
  wire          add_carry_out;


  //----------------------------------------------------------------
  // Concurrent connectivity for ports etc.
  //----------------------------------------------------------------
  assign opa_addr    = opa_addr_reg;
  assign opb_addr    = opb_addr_reg;
  assign opm_addr    = opm_addr_reg;

  assign result_addr = result_addr_reg;
  assign result_data = result_data_reg;
  assign result_we   = tmp_result_we;

  assign ready       = ready_reg;

  adder32 s_adder(
    .a(add_argument1),
    .b(add_argument2),
    .carry_in(add_carry_in),
    .sum(add_result),
    .carry_out(add_carry_out)
  );

  always @*
    begin : adder
      s_mem_new = add_result;
      add_carry_new = add_carry_out;
    end


  //----------------------------------------------------------------
  // reg_update
  //
  // Update functionality for all registers in the core.
  // All registers are positive edge triggered with asynchronous
  // active low reset. All registers have write enable.
  //----------------------------------------------------------------
  always @ (posedge clk or negedge reset_n)
    begin : reg_update
      if (!reset_n)
        begin
          ready_reg         <= 1'b0;
          loop_counter      <= 13'h0;
          word_index        <= 8'h0;
          add_carry_in      <= 1'b0;
          montprod_ctrl_reg <= CTRL_IDLE;
          b_reg             <= 1'b0;
          q_reg             <= 1'b0;
        end
      else
        begin
          if (ready_we)
            ready_reg <= ready_new;

          if (montprod_ctrl_we)
              montprod_ctrl_reg <= montprod_ctrl_new;

          if (s_mem_we)
            s_mem[s_mem_addr] <= s_mem_new;

          word_index <= word_index_new;
          loop_counter <= loop_counter_new;
          add_carry_in <= add_carry_new & !montprod_ctrl_we; //no carry over between different operations

          if (montprod_ctrl_reg == CTRL_LOOP_ITER)
            begin
              q_reg <= q;
              b_reg <= b;
            end
      end
    end // reg_update

  //----------------------------------------------------------------
  // prodcalc
  //----------------------------------------------------------------
  always @*
    begin : prodcalc
      B_word_index     = loop_counter[12:5];

      B_bit_index      = 5'h1f - loop_counter[4:0];

      b                = opb_data[ B_bit_index ];

      case (montprod_ctrl_reg)
        CTRL_LOOP_ITER:
          s_mem_addr = length-1;
        default:
          s_mem_addr = word_index;
      endcase

      s_mem_read_data = s_mem[ s_mem_addr ];


      //opa_addr will point to length-1 to get A LSB.
      //s_read_addr will point to length-1
      q                = s_mem_read_data[0] ^ (opa_data[0] & b);
      word_index_dec   = word_index - 1'b1;
      loop_counter_dec = loop_counter - 1'b1;

      result_addr_reg  = word_index;
      result_data_reg  = s_mem_read_data;

      case (montprod_ctrl_reg)
        CTRL_EMIT_S:
           tmp_result_we = 1'b1;
        default:
           tmp_result_we = 1'b0;
      endcase

      case (montprod_ctrl_reg)
        CTRL_LOOP_ITER:
          //q = (s[length-1] ^ A[length-1]) & 1;
          opa_addr_reg = length - 1'b1;

        default:
          opa_addr_reg = word_index;
       endcase

       opb_addr_reg = word_index;
       opm_addr_reg = word_index;


      case (montprod_ctrl_reg)
        CTRL_LOOP_INIT:
          loop_counter_new = {length, 5'b00000} - 1'b1;

        CTRL_LOOP_ITER:
          loop_counter_new = loop_counter_dec;

        default:
          loop_counter_new = loop_counter;
      endcase

      if (reset_word_index == 1'b1)
          word_index_new = length - 1'b1;

      else
          word_index_new = word_index - 1'b1;


      case (montprod_ctrl_reg)
        CTRL_INIT_S:
          begin
            // write 0 to initilize s.
            add_argument1 = 32'b0;
            add_argument2 = 32'b0;
          end

        CTRL_L_CALC_SM:
          begin
            add_argument1 = s_mem_read_data;
            add_argument2 = opm_data;
          end

        CTRL_L_CALC_SA:
          begin
            add_argument1 = s_mem_read_data;
            add_argument2 = opa_data;
          end

        default:
          begin
            // output is not directly used, but it is important
            // that carry out will be zero.
            add_argument1 = 32'b0;
            add_argument2 = 32'b0;
          end
      endcase
    end // prodcalc


  //----------------------------------------------------------------
  // montprod_ctrl
  //
  // Control FSM for the montgomery product calculator.
  //----------------------------------------------------------------
  always @*
    begin : montprod_ctrl
      ready_new         = 1'b0;
      ready_we          = 1'b0;
      reset_word_index  = 1'b0;
      s_mem_we          = 1'b0;
      montprod_ctrl_new = CTRL_IDLE;
      montprod_ctrl_we  = 1'b0;

      case (montprod_ctrl_reg)
        CTRL_IDLE:
          begin
            if (calculate)
              begin
                ready_new = 1'b0;
                ready_we  = 1'b1;
                montprod_ctrl_new = CTRL_INIT_S;
                montprod_ctrl_we = 1'b1;
                reset_word_index = 1'b1;
              end
          end

        CTRL_INIT_S:
          begin
            if (word_index == 0)
              begin
                 montprod_ctrl_new = CTRL_LOOP_INIT;
                 montprod_ctrl_we = 1'b1;
              end
          end


        CTRL_LOOP_INIT:
          begin
            montprod_ctrl_new = CTRL_LOOP_ITER;
            montprod_ctrl_we  = 1'b1;
          end

        //calculate q = (s - b * A) & 1;.
        // Also abort loop if done.
        CTRL_LOOP_ITER:
          begin
            reset_word_index  = 1'b1;
            if (loop_counter == 0)
              begin
                montprod_ctrl_new = CTRL_EMIT_S;
                montprod_ctrl_we = 1'b1;
              end
            else
              begin
                montprod_ctrl_new = CTRL_L_CALC_SM;
                montprod_ctrl_we  = 1'b1;
              end
          end

        //s = (s + q*M + b*A) >>> 1;, if(q==1) S+= M.
        // Takes (1..length) cycles.
        CTRL_L_CALC_SM:
          begin
            s_mem_we = q_reg;
            if (word_index == 0)
              begin
                reset_word_index  = 1'b1;
                montprod_ctrl_we  = 1'b1;
                montprod_ctrl_new = CTRL_L_CALC_SA;
              end
          end

        //s = (s + q*M + b*A) >>> 1;, if(b==1) S+= A.
        // Takes (1..length) cycles.
        CTRL_L_CALC_SA:
          begin
            s_mem_we = b_reg;
            if (word_index == 0)
              begin
                montprod_ctrl_new = CTRL_L_CALC_SDIV2;
                montprod_ctrl_we = 1'b1;
                reset_word_index = 1'b1;
              end
          end

        //s = (s + q*M + b*A) >>> 1; s>>=1.
        // Takes (1..length) cycles.
        CTRL_L_CALC_SDIV2:
          begin
            s_mem_we = 1'b1;
            if (word_index == 8'h0)
              begin
                montprod_ctrl_new = CTRL_LOOP_ITER; //loop
                montprod_ctrl_we = 1'b1;
              end
          end

        CTRL_EMIT_S:
           begin
            if (word_index == 8'h0)
                montprod_ctrl_new = CTRL_DONE;
                montprod_ctrl_we  = 1'b1;
           end

        CTRL_DONE:
          begin
            ready_new         = 1'b1;
            ready_we          = 1'b1;
            montprod_ctrl_new = CTRL_IDLE;
            montprod_ctrl_we  = 1'b1;
          end

        default:
          begin
          end

      endcase // case (montprod_ctrl_reg)
    end // montprod_ctrl

endmodule // montprod

//======================================================================
// EOF montprod.v
//======================================================================
