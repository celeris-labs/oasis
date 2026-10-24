# Decoder floorplan for `scripts/synthesize.sh --http --decoders 4` (TOE receive bypass, handler_multi).
#
# Pins whole ColumnChunkDecoders to SLRs: decoders 1 and 2 in SLR2, decoder 3 in SLR0, decoder 0 in
# SLR1. Left to itself the placer's SLR partitioner packs more of the decoders' crossbars into SLR1
# than its routing can carry, and the route fails there. The normalizers, the handler, the network
# stack and the output writer stay unconstrained.
#
# Every pblock is a child of Coyote's shell pblock pblock_inst_shell (en_shell_pblock) and lists only
# sites that pblock_inst_shell holds in that SLR, so no decoder cell can leave the shell partition.
# xcu55c: SLR0 = clock regions Y0-Y3, SLR1 = Y4-Y7, SLR2 = Y8-Y11. In rows Y3 and Y11 the shell owns
# columns X0-X3 whole and, from X4 on, only the SLICE/RAMB/DSP/URAM ranges listed second.
# Hard pblocks, no CONTAIN_ROUTING. Sourced by decoder_pblocks.tcl after opt_design.

# SLR2: decoders 1 and 2
create_pblock pblock_dec12_slr2
set_property PARENT pblock_inst_shell [get_pblocks pblock_dec12_slr2]
resize_pblock [get_pblocks pblock_dec12_slr2] -add {CLOCKREGION_X0Y8:CLOCKREGION_X7Y10 CLOCKREGION_X0Y11:CLOCKREGION_X3Y11}
resize_pblock [get_pblocks pblock_dec12_slr2] -add {SLICE_X117Y660:SLICE_X232Y719 RAMB18_X8Y264:RAMB18_X13Y287 RAMB36_X8Y132:RAMB36_X13Y143 DSP48E2_X16Y258:DSP48E2_X31Y281 URAM288_X2Y176:URAM288_X4Y191}
add_cells_to_pblock [get_pblocks pblock_dec12_slr2] [get_cells {inst_shell/inst_dynamic/inst_user_wrapper_0/inst_user_c0_0/gen_http_decoders[1].inst_decoder inst_shell/inst_dynamic/inst_user_wrapper_0/inst_user_c0_0/gen_http_decoders[2].inst_decoder}]
set_property IS_SOFT FALSE [get_pblocks pblock_dec12_slr2]

# SLR0: decoder 3
create_pblock pblock_dec3_slr0
set_property PARENT pblock_inst_shell [get_pblocks pblock_dec3_slr0]
resize_pblock [get_pblocks pblock_dec3_slr0] -add {CLOCKREGION_X0Y0:CLOCKREGION_X5Y2 CLOCKREGION_X0Y3:CLOCKREGION_X3Y3}
resize_pblock [get_pblocks pblock_dec3_slr0] -add {SLICE_X117Y180:SLICE_X175Y239 RAMB18_X8Y72:RAMB18_X10Y95 RAMB36_X8Y36:RAMB36_X10Y47 DSP48E2_X16Y66:DSP48E2_X24Y89 URAM288_X2Y48:URAM288_X3Y63}
add_cells_to_pblock [get_pblocks pblock_dec3_slr0] [get_cells {inst_shell/inst_dynamic/inst_user_wrapper_0/inst_user_c0_0/gen_http_decoders[3].inst_decoder}]
set_property IS_SOFT FALSE [get_pblocks pblock_dec3_slr0]

# SLR1: decoder 0
create_pblock pblock_dec0_slr1
set_property PARENT pblock_inst_shell [get_pblocks pblock_dec0_slr1]
resize_pblock [get_pblocks pblock_dec0_slr1] -add {CLOCKREGION_X0Y4:CLOCKREGION_X5Y5 CLOCKREGION_X0Y6:CLOCKREGION_X7Y7}
add_cells_to_pblock [get_pblocks pblock_dec0_slr1] [get_cells {inst_shell/inst_dynamic/inst_user_wrapper_0/inst_user_c0_0/gen_http_decoders[0].inst_decoder}]
set_property IS_SOFT FALSE [get_pblocks pblock_dec0_slr1]
