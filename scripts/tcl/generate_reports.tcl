open_checkpoint ./checkpoints/shell_routed.dcp
report_timing -delay_type min_max -max_paths 1000 -sort_by group -input_pins -routable_nets -file ./timing_report.txt
report_utilization -hierarchical -file ./utilization_report.txt
quit
