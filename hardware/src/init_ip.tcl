# Select the correct ILA IP for the target architecture.
# NOTE: On Versal (e.g. V80) the IP is called axis_ila instead of ila,
#       and the versioned -version flag of the UltraScale+ ila core does not apply.
if {$cfg(fpga_arch) eq "ultrascale_plus"} {
    set ila_ip_name "ila"
    set ila_create_args [list -name ila -vendor xilinx.com -library ip -version 6.2]
} elseif {$cfg(fpga_arch) eq "versal"} {
    set ila_ip_name "axis_ila"
    set ila_create_args [list -name axis_ila -vendor xilinx.com -library ip]
} else {
    puts "ERROR: Unsupported FPGA architecture: $cfg(fpga_arch)"
    exit 1
}

create_ip {*}$ila_create_args -module_name ila_read
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {18} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {128} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {76} \
    CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {76} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {64} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {1} \
    CONFIG.C_PROBE14_WIDTH {64} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {1} \
    CONFIG.C_PROBE17_WIDTH {1} \
] [get_ips ila_read]
