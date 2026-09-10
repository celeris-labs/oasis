#!/bin/bash
# Is the FPGA card safe to use -- and, more importantly, safe to REPROGRAM?
#
# WHY THIS EXISTS
# ---------------
# A wedged query leaves a task uninterruptible inside vfpga_dev_ioctl. It cannot be
# signalled, so it holds a reference the driver's teardown waits on. If someone then runs
# the reprogram script, `rmmod coyote_driver` blocks forever and the module is left in
# state "going" -- mid-unload, which can neither finish nor be reloaded. From that moment
# EVERY operation touching the driver blocks in D state, including the PCI remove the
# reprogram script does, so the script hangs at:
#
#     Removing and re-scanning root port:
#     sudo echo 1 > /sys/bus/pci/devices/0000:c0:01.1/remove
#
# and will hang there on every retry. Observed 2026-09-10: an rmmod stuck 1h51m, module
# "going", and each new reprogram attempt adding another unkillable task.
#
# So the rule is: after a wedge, REBOOT -- do not reprogram. Reprogramming a poisoned
# driver converts one stuck process into three and still needs the reboot.
#
# Exit codes:  0 healthy   1 degraded (reprogram will fix)   2 REBOOT REQUIRED
set -u
rc=0
say() { printf '  %-22s %s\n' "$1" "$2"; }

echo "card health:"

# 1. The decisive one. "live" is fine; "going" means a dead unload and only a reboot clears it.
state=$(cat /sys/module/coyote_driver/initstate 2>/dev/null || echo "absent")
say "module initstate" "$state"
case "$state" in
    live)   ;;
    going)  echo "  !! coyote_driver is stuck mid-unload. REPROGRAMMING WILL HANG. Reboot."; rc=2 ;;
    absent) echo "  !! coyote_driver not loaded (reprogram should reload it)"; [ $rc -lt 1 ] && rc=1 ;;
esac

# 2. Uninterruptible tasks. These cannot be killed; they are what poisons rmmod.
dtasks=$(ps -eo pid,stat,comm | awk '$2 ~ /^D/ && $3 != "echo" {print $1"/"$3}' | tr '\n' ' ')
if [ -n "${dtasks// }" ]; then
    say "D-state tasks" "$dtasks"
    echo "  !! uninterruptible tasks present -- they hold the driver. Reboot, do not reprogram."
    rc=2
else
    say "D-state tasks" "none"
fi

# 3. Leftover holders that CAN still be terminated (TERM only -- KILL leaked the pool once).
stray=$(ps -eo pid,args | grep -E '[r]elease/duckdb|[b]enchmark_runner' | grep -v 'bash -c' | awk '{print $1}' | tr '\n' ' ')
say "stray holders" "${stray:-none}"
[ -n "${stray// }" ] && { echo "  -> kill -TERM these by PID before doing anything else"; [ $rc -lt 1 ] && rc=1; }

# 4. The device node the extension opens. Missing => reprogram (or reboot if state is going).
node=$(ls /dev/coyote_fpga_0_v0 2>/dev/null || echo "MISSING")
say "vfpga device node" "$node"
[ "$node" = "MISSING" ] && { echo "  -> extension will fail with 'cThread instance could not be obtained'"; [ $rc -lt 1 ] && rc=1; }

# 5. free_hugepages, never nr_hugepages: a LEAKED pool still reads 12 in nr, so the two
# numbers together are what distinguish the cases.
#   nr = 0            -> never provisioned (fresh boot). Needs sudo from a real tty.
#   nr > 0, free = 0  -> leaked by a wedge. Irrecoverable; only a reboot clears it.
hp=/sys/kernel/mm/hugepages/hugepages-1048576kB
free=$(cat $hp/free_hugepages 2>/dev/null || echo 0)
nr=$(cat $hp/nr_hugepages 2>/dev/null || echo 0)
say "free 1G hugepages" "$free of $nr"
if [ "$nr" -eq 0 ]; then
    echo "  -> pool not provisioned. From a real terminal, in TWO calls:"
    echo "       sudo hdev set hugepages --num-2m 0"
    echo "       sudo hdev set hugepages --num-1g 12"
    [ $rc -lt 1 ] && rc=1
elif [ "$free" -lt 2 ]; then
    echo "  !! pool populated but exhausted -- a wedge leaks it irrecoverably; reboot"
    rc=2
fi

case $rc in
    0) echo "VERDICT: healthy" ;;
    1) echo "VERDICT: degraded -- a reprogram should fix this" ;;
    2) echo "VERDICT: REBOOT REQUIRED -- reprogramming will hang" ;;
esac
exit $rc
