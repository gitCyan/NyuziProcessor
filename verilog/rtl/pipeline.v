// 
// Copyright 2011-2012 Jeff Bush
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//     http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// 

//
// Contains the 6 pipeline stages (instruction fetch, strand select,
// decode, execute, memory access, writeback), and the vector and scalar
// register files.
//

module pipeline
	#(parameter			CORE_ID = 30'd0)

	(input				clk,
	output [31:0]		icache_addr,
	input [31:0]		icache_data,
	output				icache_request,
	input				icache_hit,
	output [1:0]		icache_req_strand,
	input [3:0]			icache_load_complete_strands,
	input				icache_load_collision,
	output [31:0]		dcache_addr,
	output				dcache_load,
	output				dcache_req_sync,
	input				dcache_hit,
	input				stbuf_rollback,
	output				dcache_store,
	output				dcache_flush,
	output				dcache_stbar,
	output [1:0]		dcache_req_strand,
	output [63:0]		dcache_store_mask,
	output [511:0]		data_to_dcache,
	input [511:0]		data_from_dcache,
	input [3:0]			dcache_resume_strands,
	input				dcache_load_collision,
	output				halt_o);
	
	reg					rf_has_writeback = 0;
	reg[6:0]			rf_writeback_reg = 0;		// One cycle after writeback
	reg[511:0]			rf_writeback_value = 0;
	reg[15:0]			rf_writeback_mask = 0;
	reg					rf_writeback_is_vector = 0;
	reg[6:0]			vector_sel1_l = 0;
	reg[6:0]			vector_sel2_l = 0;
	reg[6:0]			scalar_sel1_l = 0;
	reg[6:0]			scalar_sel2_l = 0;

	assign halt_o = ma_strand_enable == 0;	// If all threads disabled, halt
	
	/*AUTOWIRE*/
	// Beginning of automatic wires (for undeclared instantiated-module outputs)
	wire [5:0]	ds_alu_op;		// From decode_stage of decode_stage.v
	wire		ds_has_writeback;	// From decode_stage of decode_stage.v
	wire [31:0]	ds_immediate_value;	// From decode_stage of decode_stage.v
	wire [31:0]	ds_instruction;		// From decode_stage of decode_stage.v
	wire [2:0]	ds_mask_src;		// From decode_stage of decode_stage.v
	wire		ds_op1_is_vector;	// From decode_stage of decode_stage.v
	wire [1:0]	ds_op2_src;		// From decode_stage of decode_stage.v
	wire [31:0]	ds_pc;			// From decode_stage of decode_stage.v
	wire [3:0]	ds_reg_lane_select;	// From decode_stage of decode_stage.v
	wire [6:0]	ds_scalar_sel1;		// From decode_stage of decode_stage.v
	wire [6:0]	ds_scalar_sel2;		// From decode_stage of decode_stage.v
	wire		ds_store_value_is_vector;// From decode_stage of decode_stage.v
	wire [1:0]	ds_strand;		// From decode_stage of decode_stage.v
	wire [31:0]	ds_strided_offset;	// From decode_stage of decode_stage.v
	wire [6:0]	ds_vector_sel1;		// From decode_stage of decode_stage.v
	wire [6:0]	ds_vector_sel2;		// From decode_stage of decode_stage.v
	wire		ds_writeback_is_vector;	// From decode_stage of decode_stage.v
	wire [6:0]	ds_writeback_reg;	// From decode_stage of decode_stage.v
	wire [31:0]	ex_base_addr;		// From execute_stage of execute_stage.v
	wire		ex_has_writeback;	// From execute_stage of execute_stage.v
	wire [31:0]	ex_instruction;		// From execute_stage of execute_stage.v
	wire [15:0]	ex_mask;		// From execute_stage of execute_stage.v
	wire [31:0]	ex_pc;			// From execute_stage of execute_stage.v
	wire [3:0]	ex_reg_lane_select;	// From execute_stage of execute_stage.v
	wire [511:0]	ex_result;		// From execute_stage of execute_stage.v
	wire [31:0]	ex_rollback_pc;		// From execute_stage of execute_stage.v
	wire		ex_rollback_request;	// From execute_stage of execute_stage.v
	wire [511:0]	ex_store_value;		// From execute_stage of execute_stage.v
	wire [1:0]	ex_strand;		// From execute_stage of execute_stage.v
	wire [1:0]	ex_strand1;		// From execute_stage of execute_stage.v
	wire [1:0]	ex_strand2;		// From execute_stage of execute_stage.v
	wire [1:0]	ex_strand3;		// From execute_stage of execute_stage.v
	wire [31:0]	ex_strided_offset;	// From execute_stage of execute_stage.v
	wire		ex_writeback_is_vector;	// From execute_stage of execute_stage.v
	wire [6:0]	ex_writeback_reg;	// From execute_stage of execute_stage.v
	wire		flush_ds;		// From rollback_controller of rollback_controller.v
	wire		flush_ex0;		// From rollback_controller of rollback_controller.v
	wire		flush_ex1;		// From rollback_controller of rollback_controller.v
	wire		flush_ex2;		// From rollback_controller of rollback_controller.v
	wire		flush_ex3;		// From rollback_controller of rollback_controller.v
	wire		flush_ma;		// From rollback_controller of rollback_controller.v
	wire [31:0]	if_instruction0;	// From instruction_fetch_stage of instruction_fetch_stage.v
	wire [31:0]	if_instruction1;	// From instruction_fetch_stage of instruction_fetch_stage.v
	wire [31:0]	if_instruction2;	// From instruction_fetch_stage of instruction_fetch_stage.v
	wire [31:0]	if_instruction3;	// From instruction_fetch_stage of instruction_fetch_stage.v
	wire		if_instruction_valid0;	// From instruction_fetch_stage of instruction_fetch_stage.v
	wire		if_instruction_valid1;	// From instruction_fetch_stage of instruction_fetch_stage.v
	wire		if_instruction_valid2;	// From instruction_fetch_stage of instruction_fetch_stage.v
	wire		if_instruction_valid3;	// From instruction_fetch_stage of instruction_fetch_stage.v
	wire [31:0]	if_pc0;			// From instruction_fetch_stage of instruction_fetch_stage.v
	wire [31:0]	if_pc1;			// From instruction_fetch_stage of instruction_fetch_stage.v
	wire [31:0]	if_pc2;			// From instruction_fetch_stage of instruction_fetch_stage.v
	wire [31:0]	if_pc3;			// From instruction_fetch_stage of instruction_fetch_stage.v
	wire [3:0]	ma_cache_lane_select;	// From memory_access_stage of memory_access_stage.v
	wire		ma_has_writeback;	// From memory_access_stage of memory_access_stage.v
	wire [31:0]	ma_instruction;		// From memory_access_stage of memory_access_stage.v
	wire [15:0]	ma_mask;		// From memory_access_stage of memory_access_stage.v
	wire [31:0]	ma_pc;			// From memory_access_stage of memory_access_stage.v
	wire [3:0]	ma_reg_lane_select;	// From memory_access_stage of memory_access_stage.v
	wire [511:0]	ma_result;		// From memory_access_stage of memory_access_stage.v
	wire [1:0]	ma_strand;		// From memory_access_stage of memory_access_stage.v
	wire [3:0]	ma_strand_enable;	// From memory_access_stage of memory_access_stage.v
	wire [31:0]	ma_strided_offset;	// From memory_access_stage of memory_access_stage.v
	wire		ma_was_load;		// From memory_access_stage of memory_access_stage.v
	wire		ma_writeback_is_vector;	// From memory_access_stage of memory_access_stage.v
	wire [6:0]	ma_writeback_reg;	// From memory_access_stage of memory_access_stage.v
	wire [31:0]	rb_rollback_pc0;	// From rollback_controller of rollback_controller.v
	wire [31:0]	rb_rollback_pc1;	// From rollback_controller of rollback_controller.v
	wire [31:0]	rb_rollback_pc2;	// From rollback_controller of rollback_controller.v
	wire [31:0]	rb_rollback_pc3;	// From rollback_controller of rollback_controller.v
	wire		rb_rollback_strand0;	// From rollback_controller of rollback_controller.v
	wire		rb_rollback_strand1;	// From rollback_controller of rollback_controller.v
	wire		rb_rollback_strand2;	// From rollback_controller of rollback_controller.v
	wire		rb_rollback_strand3;	// From rollback_controller of rollback_controller.v
	wire [3:0]	rollback_reg_lane0;	// From rollback_controller of rollback_controller.v
	wire [3:0]	rollback_reg_lane1;	// From rollback_controller of rollback_controller.v
	wire [3:0]	rollback_reg_lane2;	// From rollback_controller of rollback_controller.v
	wire [3:0]	rollback_reg_lane3;	// From rollback_controller of rollback_controller.v
	wire [31:0]	rollback_strided_offset0;// From rollback_controller of rollback_controller.v
	wire [31:0]	rollback_strided_offset1;// From rollback_controller of rollback_controller.v
	wire [31:0]	rollback_strided_offset2;// From rollback_controller of rollback_controller.v
	wire [31:0]	rollback_strided_offset3;// From rollback_controller of rollback_controller.v
	wire [31:0]	scalar_value1;		// From scalar_register_file of scalar_register_file.v
	wire [31:0]	scalar_value2;		// From scalar_register_file of scalar_register_file.v
	wire [31:0]	ss_instruction;		// From strand_select_stage of strand_select_stage.v
	wire		ss_instruction_req0;	// From strand_select_stage of strand_select_stage.v
	wire		ss_instruction_req1;	// From strand_select_stage of strand_select_stage.v
	wire		ss_instruction_req2;	// From strand_select_stage of strand_select_stage.v
	wire		ss_instruction_req3;	// From strand_select_stage of strand_select_stage.v
	wire [31:0]	ss_pc;			// From strand_select_stage of strand_select_stage.v
	wire [3:0]	ss_reg_lane_select;	// From strand_select_stage of strand_select_stage.v
	wire [1:0]	ss_strand;		// From strand_select_stage of strand_select_stage.v
	wire [31:0]	ss_strided_offset;	// From strand_select_stage of strand_select_stage.v
	wire		suspend_strand0;	// From rollback_controller of rollback_controller.v
	wire		suspend_strand1;	// From rollback_controller of rollback_controller.v
	wire		suspend_strand2;	// From rollback_controller of rollback_controller.v
	wire		suspend_strand3;	// From rollback_controller of rollback_controller.v
	wire [511:0]	vector_value1;		// From vector_register_file of vector_register_file.v
	wire [511:0]	vector_value2;		// From vector_register_file of vector_register_file.v
	wire		wb_has_writeback;	// From writeback_stage of writeback_stage.v
	wire [31:0]	wb_rollback_pc;		// From writeback_stage of writeback_stage.v
	wire		wb_rollback_request;	// From writeback_stage of writeback_stage.v
	wire		wb_suspend_request;	// From writeback_stage of writeback_stage.v
	wire		wb_writeback_is_vector;	// From writeback_stage of writeback_stage.v
	wire [15:0]	wb_writeback_mask;	// From writeback_stage of writeback_stage.v
	wire [6:0]	wb_writeback_reg;	// From writeback_stage of writeback_stage.v
	wire [511:0]	wb_writeback_value;	// From writeback_stage of writeback_stage.v
	// End of automatics

	instruction_fetch_stage instruction_fetch_stage(/*AUTOINST*/
							// Outputs
							.icache_addr	(icache_addr[31:0]),
							.icache_request	(icache_request),
							.icache_req_strand(icache_req_strand[1:0]),
							.if_instruction0(if_instruction0[31:0]),
							.if_instruction_valid0(if_instruction_valid0),
							.if_pc0		(if_pc0[31:0]),
							.if_instruction1(if_instruction1[31:0]),
							.if_instruction_valid1(if_instruction_valid1),
							.if_pc1		(if_pc1[31:0]),
							.if_instruction2(if_instruction2[31:0]),
							.if_instruction_valid2(if_instruction_valid2),
							.if_pc2		(if_pc2[31:0]),
							.if_instruction3(if_instruction3[31:0]),
							.if_instruction_valid3(if_instruction_valid3),
							.if_pc3		(if_pc3[31:0]),
							// Inputs
							.clk		(clk),
							.icache_data	(icache_data[31:0]),
							.icache_hit	(icache_hit),
							.icache_load_complete_strands(icache_load_complete_strands[3:0]),
							.icache_load_collision(icache_load_collision),
							.ss_instruction_req0(ss_instruction_req0),
							.rb_rollback_strand0(rb_rollback_strand0),
							.rb_rollback_pc0(rb_rollback_pc0[31:0]),
							.ss_instruction_req1(ss_instruction_req1),
							.rb_rollback_strand1(rb_rollback_strand1),
							.rb_rollback_pc1(rb_rollback_pc1[31:0]),
							.ss_instruction_req2(ss_instruction_req2),
							.rb_rollback_strand2(rb_rollback_strand2),
							.rb_rollback_pc2(rb_rollback_pc2[31:0]),
							.ss_instruction_req3(ss_instruction_req3),
							.rb_rollback_strand3(rb_rollback_strand3),
							.rb_rollback_pc3(rb_rollback_pc3[31:0]));

	wire resume_strand0 = dcache_resume_strands[0];
	wire resume_strand1 = dcache_resume_strands[1];
	wire resume_strand2 = dcache_resume_strands[2];
	wire resume_strand3 = dcache_resume_strands[3];

	strand_select_stage strand_select_stage(/*AUTOINST*/
						// Outputs
						.ss_instruction_req0(ss_instruction_req0),
						.ss_instruction_req1(ss_instruction_req1),
						.ss_instruction_req2(ss_instruction_req2),
						.ss_instruction_req3(ss_instruction_req3),
						.ss_pc		(ss_pc[31:0]),
						.ss_instruction	(ss_instruction[31:0]),
						.ss_reg_lane_select(ss_reg_lane_select[3:0]),
						.ss_strided_offset(ss_strided_offset[31:0]),
						.ss_strand	(ss_strand[1:0]),
						// Inputs
						.clk		(clk),
						.ma_strand_enable(ma_strand_enable[3:0]),
						.if_instruction0(if_instruction0[31:0]),
						.if_instruction_valid0(if_instruction_valid0),
						.if_pc0		(if_pc0[31:0]),
						.rb_rollback_strand0(rb_rollback_strand0),
						.suspend_strand0(suspend_strand0),
						.resume_strand0	(resume_strand0),
						.rollback_strided_offset0(rollback_strided_offset0[31:0]),
						.rollback_reg_lane0(rollback_reg_lane0[3:0]),
						.if_instruction1(if_instruction1[31:0]),
						.if_instruction_valid1(if_instruction_valid1),
						.if_pc1		(if_pc1[31:0]),
						.rb_rollback_strand1(rb_rollback_strand1),
						.suspend_strand1(suspend_strand1),
						.resume_strand1	(resume_strand1),
						.rollback_strided_offset1(rollback_strided_offset1[31:0]),
						.rollback_reg_lane1(rollback_reg_lane1[3:0]),
						.if_instruction2(if_instruction2[31:0]),
						.if_instruction_valid2(if_instruction_valid2),
						.if_pc2		(if_pc2[31:0]),
						.rb_rollback_strand2(rb_rollback_strand2),
						.suspend_strand2(suspend_strand2),
						.resume_strand2	(resume_strand2),
						.rollback_strided_offset2(rollback_strided_offset2[31:0]),
						.rollback_reg_lane2(rollback_reg_lane2[3:0]),
						.if_instruction3(if_instruction3[31:0]),
						.if_instruction_valid3(if_instruction_valid3),
						.if_pc3		(if_pc3[31:0]),
						.rb_rollback_strand3(rb_rollback_strand3),
						.suspend_strand3(suspend_strand3),
						.resume_strand3	(resume_strand3),
						.rollback_strided_offset3(rollback_strided_offset3[31:0]),
						.rollback_reg_lane3(rollback_reg_lane3[3:0]));

	decode_stage decode_stage(/*AUTOINST*/
				  // Outputs
				  .ds_instruction	(ds_instruction[31:0]),
				  .ds_strand		(ds_strand[1:0]),
				  .ds_pc		(ds_pc[31:0]),
				  .ds_immediate_value	(ds_immediate_value[31:0]),
				  .ds_mask_src		(ds_mask_src[2:0]),
				  .ds_op1_is_vector	(ds_op1_is_vector),
				  .ds_op2_src		(ds_op2_src[1:0]),
				  .ds_store_value_is_vector(ds_store_value_is_vector),
				  .ds_scalar_sel1	(ds_scalar_sel1[6:0]),
				  .ds_scalar_sel2	(ds_scalar_sel2[6:0]),
				  .ds_vector_sel1	(ds_vector_sel1[6:0]),
				  .ds_vector_sel2	(ds_vector_sel2[6:0]),
				  .ds_has_writeback	(ds_has_writeback),
				  .ds_writeback_reg	(ds_writeback_reg[6:0]),
				  .ds_writeback_is_vector(ds_writeback_is_vector),
				  .ds_alu_op		(ds_alu_op[5:0]),
				  .ds_reg_lane_select	(ds_reg_lane_select[3:0]),
				  .ds_strided_offset	(ds_strided_offset[31:0]),
				  // Inputs
				  .clk			(clk),
				  .ss_instruction	(ss_instruction[31:0]),
				  .ss_strand		(ss_strand[1:0]),
				  .ss_pc		(ss_pc[31:0]),
				  .ss_reg_lane_select	(ss_reg_lane_select[3:0]),
				  .flush_ds		(flush_ds),
				  .ss_strided_offset	(ss_strided_offset[31:0]));

	wire enable_scalar_reg_store = wb_has_writeback && ~wb_writeback_is_vector;
	wire enable_vector_reg_store = wb_has_writeback && wb_writeback_is_vector;

	scalar_register_file scalar_register_file(/*AUTOINST*/
						  // Outputs
						  .scalar_value1	(scalar_value1[31:0]),
						  .scalar_value2	(scalar_value2[31:0]),
						  // Inputs
						  .clk			(clk),
						  .ds_scalar_sel1	(ds_scalar_sel1[6:0]),
						  .ds_scalar_sel2	(ds_scalar_sel2[6:0]),
						  .wb_writeback_reg	(wb_writeback_reg[6:0]),
						  .wb_writeback_value	(wb_writeback_value[31:0]),
						  .enable_scalar_reg_store(enable_scalar_reg_store));
	
	vector_register_file vector_register_file(/*AUTOINST*/
						  // Outputs
						  .vector_value1	(vector_value1[511:0]),
						  .vector_value2	(vector_value2[511:0]),
						  // Inputs
						  .clk			(clk),
						  .ds_vector_sel1	(ds_vector_sel1[6:0]),
						  .ds_vector_sel2	(ds_vector_sel2[6:0]),
						  .wb_writeback_reg	(wb_writeback_reg[6:0]),
						  .wb_writeback_value	(wb_writeback_value[511:0]),
						  .wb_writeback_mask	(wb_writeback_mask[15:0]),
						  .enable_vector_reg_store(enable_vector_reg_store));
	
	always @(posedge clk)
	begin
		vector_sel1_l <= #1 ds_vector_sel1;
		vector_sel2_l <= #1 ds_vector_sel2;
		scalar_sel1_l <= #1 ds_scalar_sel1;
		scalar_sel2_l <= #1 ds_scalar_sel2;
	end
	
	execute_stage execute_stage(/*AUTOINST*/
				    // Outputs
				    .ex_instruction	(ex_instruction[31:0]),
				    .ex_strand		(ex_strand[1:0]),
				    .ex_pc		(ex_pc[31:0]),
				    .ex_store_value	(ex_store_value[511:0]),
				    .ex_has_writeback	(ex_has_writeback),
				    .ex_writeback_reg	(ex_writeback_reg[6:0]),
				    .ex_writeback_is_vector(ex_writeback_is_vector),
				    .ex_mask		(ex_mask[15:0]),
				    .ex_result		(ex_result[511:0]),
				    .ex_reg_lane_select	(ex_reg_lane_select[3:0]),
				    .ex_rollback_request(ex_rollback_request),
				    .ex_rollback_pc	(ex_rollback_pc[31:0]),
				    .ex_strand1		(ex_strand1[1:0]),
				    .ex_strand2		(ex_strand2[1:0]),
				    .ex_strand3		(ex_strand3[1:0]),
				    .ex_strided_offset	(ex_strided_offset[31:0]),
				    .ex_base_addr	(ex_base_addr[31:0]),
				    // Inputs
				    .clk		(clk),
				    .ds_instruction	(ds_instruction[31:0]),
				    .ds_strand		(ds_strand[1:0]),
				    .ds_pc		(ds_pc[31:0]),
				    .scalar_value1	(scalar_value1[31:0]),
				    .scalar_sel1_l	(scalar_sel1_l[6:0]),
				    .scalar_value2	(scalar_value2[31:0]),
				    .scalar_sel2_l	(scalar_sel2_l[6:0]),
				    .vector_value1	(vector_value1[511:0]),
				    .vector_sel1_l	(vector_sel1_l[6:0]),
				    .vector_value2	(vector_value2[511:0]),
				    .vector_sel2_l	(vector_sel2_l[6:0]),
				    .ds_immediate_value	(ds_immediate_value[31:0]),
				    .ds_mask_src	(ds_mask_src[2:0]),
				    .ds_op1_is_vector	(ds_op1_is_vector),
				    .ds_op2_src		(ds_op2_src[1:0]),
				    .ds_store_value_is_vector(ds_store_value_is_vector),
				    .ds_has_writeback	(ds_has_writeback),
				    .ds_writeback_reg	(ds_writeback_reg[6:0]),
				    .ds_writeback_is_vector(ds_writeback_is_vector),
				    .ds_alu_op		(ds_alu_op[5:0]),
				    .ds_reg_lane_select	(ds_reg_lane_select[3:0]),
				    .ma_writeback_reg	(ma_writeback_reg[6:0]),
				    .ma_has_writeback	(ma_has_writeback),
				    .ma_writeback_is_vector(ma_writeback_is_vector),
				    .ma_result		(ma_result[511:0]),
				    .ma_mask		(ma_mask[15:0]),
				    .wb_writeback_reg	(wb_writeback_reg[6:0]),
				    .wb_has_writeback	(wb_has_writeback),
				    .wb_writeback_is_vector(wb_writeback_is_vector),
				    .wb_writeback_value	(wb_writeback_value[511:0]),
				    .wb_writeback_mask	(wb_writeback_mask[15:0]),
				    .rf_writeback_reg	(rf_writeback_reg[6:0]),
				    .rf_has_writeback	(rf_has_writeback),
				    .rf_writeback_is_vector(rf_writeback_is_vector),
				    .rf_writeback_value	(rf_writeback_value[511:0]),
				    .rf_writeback_mask	(rf_writeback_mask[15:0]),
				    .flush_ex0		(flush_ex0),
				    .flush_ex1		(flush_ex1),
				    .flush_ex2		(flush_ex2),
				    .flush_ex3		(flush_ex3),
				    .ds_strided_offset	(ds_strided_offset[31:0]));

	assign dcache_req_strand = ex_strand;
		
	memory_access_stage #(CORE_ID) memory_access_stage(
		/*AUTOINST*/
							   // Outputs
							   .data_to_dcache	(data_to_dcache[511:0]),
							   .dcache_load		(dcache_load),
							   .dcache_store	(dcache_store),
							   .dcache_flush	(dcache_flush),
							   .dcache_stbar	(dcache_stbar),
							   .dcache_store_mask	(dcache_store_mask[63:0]),
							   .ma_instruction	(ma_instruction[31:0]),
							   .ma_strand		(ma_strand[1:0]),
							   .ma_pc		(ma_pc[31:0]),
							   .ma_has_writeback	(ma_has_writeback),
							   .ma_writeback_reg	(ma_writeback_reg[6:0]),
							   .ma_writeback_is_vector(ma_writeback_is_vector),
							   .ma_mask		(ma_mask[15:0]),
							   .ma_result		(ma_result[511:0]),
							   .ma_reg_lane_select	(ma_reg_lane_select[3:0]),
							   .ma_cache_lane_select(ma_cache_lane_select[3:0]),
							   .ma_strand_enable	(ma_strand_enable[3:0]),
							   .dcache_addr		(dcache_addr[31:0]),
							   .dcache_req_sync	(dcache_req_sync),
							   .ma_was_load		(ma_was_load),
							   .dcache_req_strand	(dcache_req_strand[1:0]),
							   .ma_strided_offset	(ma_strided_offset[31:0]),
							   // Inputs
							   .clk			(clk),
							   .ex_instruction	(ex_instruction[31:0]),
							   .ex_strand		(ex_strand[1:0]),
							   .flush_ma		(flush_ma),
							   .ex_pc		(ex_pc[31:0]),
							   .ex_store_value	(ex_store_value[511:0]),
							   .ex_has_writeback	(ex_has_writeback),
							   .ex_writeback_reg	(ex_writeback_reg[6:0]),
							   .ex_writeback_is_vector(ex_writeback_is_vector),
							   .ex_mask		(ex_mask[15:0]),
							   .ex_result		(ex_result[511:0]),
							   .ex_reg_lane_select	(ex_reg_lane_select[3:0]),
							   .ex_strided_offset	(ex_strided_offset[31:0]),
							   .ex_base_addr	(ex_base_addr[31:0]));

	writeback_stage writeback_stage(/*AUTOINST*/
					// Outputs
					.wb_writeback_is_vector(wb_writeback_is_vector),
					.wb_has_writeback(wb_has_writeback),
					.wb_writeback_reg(wb_writeback_reg[6:0]),
					.wb_writeback_value(wb_writeback_value[511:0]),
					.wb_writeback_mask(wb_writeback_mask[15:0]),
					.wb_rollback_request(wb_rollback_request),
					.wb_rollback_pc	(wb_rollback_pc[31:0]),
					.wb_suspend_request(wb_suspend_request),
					// Inputs
					.clk		(clk),
					.ma_instruction	(ma_instruction[31:0]),
					.ma_pc		(ma_pc[31:0]),
					.ma_writeback_reg(ma_writeback_reg[6:0]),
					.ma_writeback_is_vector(ma_writeback_is_vector),
					.ma_has_writeback(ma_has_writeback),
					.ma_mask	(ma_mask[15:0]),
					.dcache_hit	(dcache_hit),
					.ma_was_load	(ma_was_load),
					.data_from_dcache(data_from_dcache[511:0]),
					.dcache_load_collision(dcache_load_collision),
					.stbuf_rollback	(stbuf_rollback),
					.ma_result	(ma_result[511:0]),
					.ma_reg_lane_select(ma_reg_lane_select[3:0]),
					.ma_cache_lane_select(ma_cache_lane_select[3:0]));
	
	// Even though the results have already been committed to the
	// register file on this cycle, the new register values were
	// fetched a cycle before the bypass stage, so we may still
	// have stale results there.
	always @(posedge clk)
	begin
		rf_writeback_reg			<= #1 wb_writeback_reg;
		rf_writeback_value			<= #1 wb_writeback_value;
		rf_writeback_mask			<= #1 wb_writeback_mask;
		rf_writeback_is_vector		<= #1 wb_writeback_is_vector;
		rf_has_writeback			<= #1 wb_has_writeback;
	end

	rollback_controller rollback_controller(
		/*AUTOINST*/
						// Outputs
						.flush_ds	(flush_ds),
						.flush_ex0	(flush_ex0),
						.flush_ex1	(flush_ex1),
						.flush_ex2	(flush_ex2),
						.flush_ex3	(flush_ex3),
						.flush_ma	(flush_ma),
						.rb_rollback_strand0(rb_rollback_strand0),
						.rb_rollback_pc0(rb_rollback_pc0[31:0]),
						.rollback_strided_offset0(rollback_strided_offset0[31:0]),
						.rollback_reg_lane0(rollback_reg_lane0[3:0]),
						.suspend_strand0(suspend_strand0),
						.rb_rollback_strand1(rb_rollback_strand1),
						.rb_rollback_pc1(rb_rollback_pc1[31:0]),
						.rollback_strided_offset1(rollback_strided_offset1[31:0]),
						.rollback_reg_lane1(rollback_reg_lane1[3:0]),
						.suspend_strand1(suspend_strand1),
						.rb_rollback_strand2(rb_rollback_strand2),
						.rb_rollback_pc2(rb_rollback_pc2[31:0]),
						.rollback_strided_offset2(rollback_strided_offset2[31:0]),
						.rollback_reg_lane2(rollback_reg_lane2[3:0]),
						.suspend_strand2(suspend_strand2),
						.rb_rollback_strand3(rb_rollback_strand3),
						.rb_rollback_pc3(rb_rollback_pc3[31:0]),
						.rollback_strided_offset3(rollback_strided_offset3[31:0]),
						.rollback_reg_lane3(rollback_reg_lane3[3:0]),
						.suspend_strand3(suspend_strand3),
						// Inputs
						.ss_strand	(ss_strand[1:0]),
						.ex_rollback_request(ex_rollback_request),
						.ex_rollback_pc	(ex_rollback_pc[31:0]),
						.ds_strand	(ds_strand[1:0]),
						.ex_strand	(ex_strand[1:0]),
						.ex_strand1	(ex_strand1[1:0]),
						.ex_strand2	(ex_strand2[1:0]),
						.ex_strand3	(ex_strand3[1:0]),
						.wb_rollback_request(wb_rollback_request),
						.wb_rollback_pc	(wb_rollback_pc[31:0]),
						.ma_strided_offset(ma_strided_offset[31:0]),
						.ma_reg_lane_select(ma_reg_lane_select[3:0]),
						.ma_strand	(ma_strand[1:0]),
						.wb_suspend_request(wb_suspend_request));
endmodule
