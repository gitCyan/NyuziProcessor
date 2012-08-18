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
// Queues pending memory stores and issues to L2 cache.
// Whenever there is a cache load, this checks to see if a store is pending
// for the same request and bypasses the data.
//
// This also tracks synchronized stores.  These get rolled back on the first
// request, since we must wait for a response from the L2 cache to make sure
// the L1 cache line has proper data in it.  When the strand is restarted, we 
// need to keep track of the fact that we already got an L2 ack and let the 
// strand continue lest we get into an infinite rollback loop.
//
// Cache operations like flushes are also enqueued here. 
//

`include "l2_cache.h"

module store_buffer
	(input 							clk,
	output reg[3:0]					store_resume_strands = 0,
	output							store_update,
	output reg[`L1_SET_INDEX_WIDTH - 1:0] store_update_set = 0,
	input [`L1_TAG_WIDTH - 1:0]		requested_tag,
	input [`L1_SET_INDEX_WIDTH - 1:0] requested_set,
	input [511:0]					data_to_dcache,
	input							dcache_store,
	input							dcache_flush,
	input							dcache_stbar,
	input							synchronized_i,
	input [63:0]					dcache_store_mask,
	input [1:0]						strand_i,
	output reg[511:0]				data_o = 0,
	output reg[63:0]				mask_o = 0,
	output 							rollback_o,
	output							pci_valid,
	input							pci_ack,
	output [1:0]					pci_unit,
	output [1:0]					pci_strand,
	output reg[2:0]					pci_op = 0,
	output [1:0]					pci_way,
	output [25:0]					pci_address,
	output [511:0]					pci_data,
	output [63:0]					pci_mask,
	input 							cpi_valid,
	input							cpi_status,
	input [1:0]						cpi_unit,
	input [1:0]						cpi_strand,
	input 							cpi_update);
	
	reg								store_enqueued[0:3];
	reg								store_acknowledged[0:3];
	reg[511:0]						store_data[0:3];
	reg[63:0]						store_mask[0:3];
	reg [`L1_TAG_WIDTH - 1:0] 		store_tag[0:3];
	reg [`L1_SET_INDEX_WIDTH - 1:0]	store_set[0:3];
	reg 							is_flush[0:3];
	reg								store_synchronized[0:3];
	reg[1:0]						issue_idx = 0;
	reg								wait_for_l2_ack = 0;
	wire[3:0]						issue_oh;
	reg[3:0]						store_wait_strands = 0;
	integer							i;
	reg[3:0]						store_finish_strands = 0;
	integer							j;
	reg[63:0]						raw_mask_nxt = 0;
	reg[511:0]						raw_data_nxt = 0;
	reg[3:0]						sync_store_wait = 0;
	reg[3:0]						sync_store_complete = 0;
	reg								stbuf_full = 0;
	reg[3:0]						sync_store_result = 0;
	reg[63:0] 						store_count = 0;	// Performance counter

	initial
	begin
		for (i = 0; i < 4; i = i + 1)
		begin
			store_enqueued[i] = 0;
			store_acknowledged[i] = 0;
			store_data[i] = 0;
			store_mask[i] = 0;
			store_tag[i] = 0;
			store_set[i] = 0;
			store_synchronized[i] = 0;
			is_flush[i] = 0;
		end
	end
		
	// Store RAW handling. We only bypass results from the same strand.
	always @*
	begin
		raw_mask_nxt = 0;		
		raw_data_nxt = 0;

		for (j = 0; j < 4; j = j + 1)
		begin
			if (store_enqueued[j] && requested_set == store_set[j] && requested_tag == store_tag[j]
				&& strand_i == j)
			begin
				raw_mask_nxt = store_mask[j];
				raw_data_nxt = store_data[j];
			end
		end
	end

	always @(posedge clk)
	begin
		if (synchronized_i && dcache_store)
		begin
			// Synchronized store
			mask_o <= #1 {64{1'b1}};
			data_o <= #1 {16{31'd0, sync_store_result[strand_i]}};
		end
		else
		begin
			mask_o <= #1 raw_mask_nxt;
			data_o <= #1 raw_data_nxt;
		end
	end

	assign store_update = |store_finish_strands && cpi_update;
	
	// We always delay this a cycle so it will occur after a suspend.
	always @(posedge clk)
	begin
		store_resume_strands <= #1 (store_finish_strands & store_wait_strands)
			| (l2_ack_mask & sync_store_wait);
	end
	
	// Check if we need to roll back a strand because the store buffer is 
	// full.  Track which strands are waiting and provide an output
	// signal.
	always @(posedge clk)
	begin
		if ((dcache_stbar || dcache_flush || dcache_store) && store_enqueued[strand_i] 
			&& !store_collision)
		begin
			// Buffer is full, strand needs to wait
			store_wait_strands <= #1 (store_wait_strands & ~store_finish_strands)
				| (4'b0001 << strand_i);
			stbuf_full <= #1 1;
		end
		else
		begin
			store_wait_strands <= #1 store_wait_strands & ~store_finish_strands;
			stbuf_full <= #1 0;
		end
	end

	arbiter next_issue(
		.clk(clk),
		.request({ store_enqueued[3] & !store_acknowledged[3],
			store_enqueued[2] & !store_acknowledged[2],
			store_enqueued[1] & !store_acknowledged[1],
			store_enqueued[0] & !store_acknowledged[0] }),
		.update_lru(!wait_for_l2_ack),
		.grant_oh(issue_oh));


	always @*
	begin
		if (is_flush[issue_idx])
			pci_op = `PCI_FLUSH;
		else if (store_synchronized[issue_idx])
			pci_op = `PCI_STORE_SYNC;
		else
			pci_op = `PCI_STORE;
	end

	assign pci_unit = `UNIT_STBUF;
	assign pci_strand = issue_idx;
	assign pci_data = store_data[issue_idx];
	assign pci_address = { store_tag[issue_idx], store_set[issue_idx] };
	assign pci_mask = store_mask[issue_idx];
	assign pci_way = 0;	// Ignored by L2 cache (It knows the way from its directory)
	assign pci_valid = wait_for_l2_ack;

	wire l2_store_complete = cpi_valid && cpi_unit == `UNIT_STBUF && store_enqueued[cpi_strand];
	wire store_collision = l2_store_complete && (dcache_stbar || dcache_store || dcache_flush) 
		&& strand_i == cpi_strand;

	assertion #("L2 responded to store buffer entry that wasn't issued") a0
		(.clk(clk), .test(cpi_valid && cpi_unit == `UNIT_STBUF
			&& !store_enqueued[cpi_strand]));
	assertion #("L2 responded to store buffer entry that wasn't acknowledged") a1
		(.clk(clk), .test(cpi_valid && cpi_unit == `UNIT_STBUF
			&& !store_acknowledged[cpi_strand]));

	// XXX is store_update_set "don't care" if store_finish_strands is 0?
	// if so, avoid instantiating a mux for it (optimization).
	always @*
	begin
		if (cpi_valid && cpi_unit == `UNIT_STBUF)
		begin
			store_finish_strands = 4'b0001 << cpi_strand;
			store_update_set = store_set[cpi_strand];
		end
		else
		begin
			store_finish_strands = 0;
			store_update_set = 0;
		end
	end

	wire[3:0] sync_req_mask = (synchronized_i & dcache_store & !store_enqueued[strand_i]) ? (4'b0001 << strand_i) : 4'd0;
	wire[3:0] l2_ack_mask = (cpi_valid && cpi_unit == `UNIT_STBUF) ? (4'b0001 << cpi_strand) : 4'd0;
	wire need_sync_rollback = (sync_req_mask & ~sync_store_complete) != 0;
	reg need_sync_rollback_latched = 0;

	assertion #("blocked strand issued sync store") a2(
		.clk(clk), .test((sync_store_wait & sync_req_mask) != 0));
	assertion #("store complete and store wait set simultaneously") a3(
		.clk(clk), .test((sync_store_wait & sync_store_complete) != 0));
	
	assign rollback_o = stbuf_full || need_sync_rollback_latched;

	always @(posedge clk)
	begin
		// Handle enqueueing new requests.  If a synchronized write has not
		// been acknowledged, queue it, but if we've already received an
		// acknowledgement, just return the proper value.
		if ((dcache_store || dcache_flush) && (!store_enqueued[strand_i] || store_collision)
			&& (!synchronized_i || need_sync_rollback))
		begin
			// Performance counter
			if (dcache_store)
				store_count <= #1 store_count + 1;

			store_tag[strand_i] <= #1 requested_tag;	
			store_set[strand_i] <= #1 requested_set;
			store_mask[strand_i] <= #1 dcache_store_mask;
			store_enqueued[strand_i] <= #1 1;
			store_data[strand_i] <= #1 data_to_dcache;
			store_synchronized[strand_i] <= #1 synchronized_i;
			is_flush[strand_i] <= #1 dcache_flush;
		end

		// Handle L2 responses/issue new requests
		if (wait_for_l2_ack)
		begin
			// L2 send is waiting for an ack
			if (pci_ack)
			begin
				store_acknowledged[issue_idx] <= #1 1;
				wait_for_l2_ack <= #1 0;	// Can now pick a new entry to issue
			end
		end
		else 
		begin
			// Nothing is currently pending
			if (|issue_oh)	
			begin
				// Note: technically we could issue another request in the same
				// cycle we get an ack, but this will wait until the next cycle.
				issue_idx <= #1 { issue_oh[3] || issue_oh[2], issue_oh[3] || issue_oh[1] };
				wait_for_l2_ack <= #1 1;
			end
		end

		if (l2_store_complete)
		begin
			if (!store_collision)
				store_enqueued[cpi_strand] <= #1 0;

			store_acknowledged[cpi_strand] <= #1 0;
		end

		// Keep track of synchronized stores
		sync_store_wait <= #1 (sync_store_wait | (sync_req_mask & ~sync_store_complete)) & ~l2_ack_mask;
		sync_store_complete <= #1 (sync_store_complete | (sync_store_wait & l2_ack_mask)) & ~sync_req_mask;
		if (l2_ack_mask & sync_store_wait)
			sync_store_result[cpi_strand] <= #1 cpi_status;

		need_sync_rollback_latched <= #1 need_sync_rollback;
	end
endmodule
