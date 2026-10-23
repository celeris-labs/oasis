# Decoder floorplan for `scripts/synthesize.sh --http --decoders 4 --toe-buffer` (TOE receive rings in
# card memory, handler_toe).
#
# Pins whole ColumnChunkDecoders to SLRs: decoders 1, 2 and 3 in SLR2, decoder 0 in SLR1. Left to
# itself the placer's SLR partitioner puts two whole decoders into SLR1, more than its routing can
# carry. The network stack of this configuration has no shared receive fifo and sits next to the HBM
# in SLR0, so SLR0 gets no decoder. The normalizers, the handler, the network stack and the output
# writer stay unconstrained.
#
# Every pblock is a child of Coyote's shell pblock pblock_inst_shell (en_shell_pblock) and lists only
# sites that pblock_inst_shell holds in that SLR, so no decoder cell can leave the shell partition.
# xcu55c: SLR1 = clock regions Y4-Y7, SLR2 = Y8-Y11. In row Y11 the shell owns columns X0-X3 whole
# and, from X4 on, only the SLICE/RAMB/DSP/URAM ranges listed second. The ranges are those of
# decoder_pblocks_bypass.xdc. Hard pblocks, no CONTAIN_ROUTING. Sourced by decoder_pblocks.tcl after
# opt_design.

# SLR2: decoders 1, 2 and 3
create_pblock pblock_dec123_slr2
set_property PARENT pblock_inst_shell [get_pblocks pblock_dec123_slr2]
resize_pblock [get_pblocks pblock_dec123_slr2] -add {CLOCKREGION_X0Y8:CLOCKREGION_X7Y10 CLOCKREGION_X0Y11:CLOCKREGION_X3Y11}
resize_pblock [get_pblocks pblock_dec123_slr2] -add {SLICE_X117Y660:SLICE_X232Y719 RAMB18_X8Y264:RAMB18_X13Y287 RAMB36_X8Y132:RAMB36_X13Y143 DSP48E2_X16Y258:DSP48E2_X31Y281 URAM288_X2Y176:URAM288_X4Y191}
add_cells_to_pblock [get_pblocks pblock_dec123_slr2] [get_cells {inst_shell/inst_dynamic/inst_user_wrapper_0/inst_user_c0_0/gen_http_decoders[1].inst_decoder inst_shell/inst_dynamic/inst_user_wrapper_0/inst_user_c0_0/gen_http_decoders[2].inst_decoder inst_shell/inst_dynamic/inst_user_wrapper_0/inst_user_c0_0/gen_http_decoders[3].inst_decoder}]
set_property IS_SOFT FALSE [get_pblocks pblock_dec123_slr2]

# SLR1: decoder 0
create_pblock pblock_dec0_slr1
set_property PARENT pblock_inst_shell [get_pblocks pblock_dec0_slr1]
resize_pblock [get_pblocks pblock_dec0_slr1] -add {CLOCKREGION_X0Y4:CLOCKREGION_X5Y5 CLOCKREGION_X0Y6:CLOCKREGION_X7Y7}
add_cells_to_pblock [get_pblocks pblock_dec0_slr1] [get_cells {inst_shell/inst_dynamic/inst_user_wrapper_0/inst_user_c0_0/gen_http_decoders[0].inst_decoder}]
set_property IS_SOFT FALSE [get_pblocks pblock_dec0_slr1]
