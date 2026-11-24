#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Benchmark mode for the host. Run it with sudo.
#
# Usage: bench-mode.sh on [CPUS] | off | status | run CMD [ARGS...]
#
# on [CPUS]   SMT off, CPUS (default 8-15) at a fixed frequency (FREQ in
#             kHz, default 4300000) with all idle states off, and CPUS in
#             a cpuset root partition. All other tasks, IRQs and unbound
#             workqueues stay on the remaining CPUs.
# off         restore everything that "on" changed
# status      show the current state
# run CMD     run CMD as the user who called sudo, inside the partition,
#             so that it and its children can use CPUS. Nothing outside
#             the partition can run there.
#
# Example:
#   sudo ./bench-mode.sh on
#   sudo ./bench-mode.sh run ./vng.sh --boots 10 --host-cpus 8-15 ~/a ~/b
#   sudo ./bench-mode.sh off

set -u

CG=/sys/fs/cgroup/veth-bench
STATE=/run/veth-bench
SYS=/sys/devices/system/cpu
WQ=/sys/devices/virtual/workqueue/cpumask
FREQ=${FREQ:-4300000}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

usage() {
	sed -n 's/^# Usage: //p' "$0"
	exit 1
}

# Expand a CPU list like 0-3,8 into one CPU per line
expand() {
	local c

	for c in ${1//,/ }; do
		case $c in
		*-*)	seq "${c%-*}" "${c#*-}" ;;
		*)	echo "$c" ;;
		esac
	done
}

# Hex mask of the CPUs on stdin, in comma separated words of 32 CPUs as
# the kernel prints and parses cpumasks, so any number of CPUs works
mask() {
	local c i n=1 out=
	local -a w=()

	while read -r c; do
		i=$((c / 32))
		w[i]=$(( ${w[i]:-0} | 1 << (c % 32) ))
		[ "$i" -lt "$n" ] || n=$((i + 1))
	done
	for ((i = n - 1; i >= 0; i--)); do
		out+=$(printf %08x "${w[i]:-0}")
		[ "$i" -eq 0 ] || out+=,
	done
	echo "$out"
}

# Online CPUs that are not in the partition
housekeeping() {
	expand "$(cat $SYS/online)" | grep -vxF -f <(expand "$CPUS")
}

save() {
	echo "$2" > "$STATE/$1"
}

on() {
	local c d s hk_list hk_mask irq

	[ -e "$STATE" ] && die "already on, see status"
	expand "$CPUS" | grep -qx 0 && die "CPU 0 must stay for the rest"
	mkdir -p "$STATE" || exit 1
	save cpus "$CPUS"

	# Save everything first, then change it
	save smt "$(cat $SYS/smt/control)"
	save wq "$(cat $WQ)"
	save irq_default "$(cat /proc/irq/default_smp_affinity)"
	for irq in /proc/irq/[0-9]*; do
		echo "${irq##*/} $(cat "$irq/smp_affinity_list")"
	done > "$STATE/irq"
	for c in $(expand "$CPUS"); do
		d=$SYS/cpu$c
		echo "$c $(cat $d/cpufreq/scaling_governor) $(cat $d/cpufreq/scaling_min_freq)" \
		     "$(cat $d/cpufreq/scaling_max_freq)" \
		     "$(cat $d/cpufreq/energy_performance_preference 2>/dev/null || echo -)" \
		     "$(cat $d/cpuidle/state*/disable | tr -d '\n')"
	done > "$STATE/cpu"

	echo off > $SYS/smt/control || die "cannot turn SMT off"

	for c in $(expand "$CPUS"); do
		d=$SYS/cpu$c
		[ -d "$d/cpufreq" ] || die "CPU $c is offline, is it an SMT sibling?"
		echo performance > $d/cpufreq/scaling_governor || die "governor of CPU $c"
		# min first, max is still higher
		echo "$FREQ" > $d/cpufreq/scaling_min_freq &&
			echo "$FREQ" > $d/cpufreq/scaling_max_freq || die "frequency of CPU $c"
		for s in $d/cpuidle/state*/disable; do
			echo 1 > "$s"
		done
	done

	# A root partition takes CPUS away from all other cgroups
	grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control ||
		echo +cpuset > /sys/fs/cgroup/cgroup.subtree_control || die "no cpuset controller"
	mkdir -p "$CG" || exit 1
	echo "$CPUS" > "$CG/cpuset.cpus" || die "cpuset.cpus"
	[ -e "$CG/cpuset.cpus.exclusive" ] && echo "$CPUS" > "$CG/cpuset.cpus.exclusive"
	echo root > "$CG/cpuset.cpus.partition"
	[ "$(cat "$CG/cpuset.cpus.partition")" = root ] ||
		die "partition: $(cat "$CG/cpuset.cpus.partition"), turn it off again with: $0 off"

	hk_list=$(housekeeping | paste -sd,)
	hk_mask=$(housekeeping | mask)
	echo "$hk_mask" > /proc/irq/default_smp_affinity
	# Managed IRQs refuse, they stay where the kernel put them
	for irq in /proc/irq/[0-9]*; do
		echo "$hk_list" > "$irq/smp_affinity_list"
	done 2>/dev/null
	echo "$hk_mask" > $WQ || echo "warning: cannot set the workqueue cpumask" >&2

	status
}

off() {
	local c gov min max epp idle i s irq list procs

	[ -e "$STATE" ] || die "not on"
	CPUS=$(cat "$STATE/cpus")
	if [ -d "$CG" ]; then
		# cgroup files have size 0, so read them instead of test -s
		procs=$(paste -sd' ' "$CG/cgroup.procs")
		[ -n "$procs" ] &&
			die "still running in the partition: $procs, for the queue: touch queue/stop"
		echo member > "$CG/cpuset.cpus.partition"
		rmdir "$CG" || die "cannot remove $CG"
	fi

	echo "$(cat "$STATE/smt")" > $SYS/smt/control 2>/dev/null
	cat "$STATE/wq" > $WQ
	cat "$STATE/irq_default" > /proc/irq/default_smp_affinity
	while read -r irq list; do
		echo "$list" > "/proc/irq/$irq/smp_affinity_list"
	done < "$STATE/irq" 2>/dev/null

	while read -r c gov min max epp idle; do
		d=$SYS/cpu$c
		echo "$gov" > $d/cpufreq/scaling_governor
		# max first, min may be below the current max
		echo "$max" > $d/cpufreq/scaling_max_freq
		echo "$min" > $d/cpufreq/scaling_min_freq
		# EPP is fixed while the governor is performance
		[ "$epp" != - ] && echo "$epp" > $d/cpufreq/energy_performance_preference
		i=0
		for s in $d/cpuidle/state*/disable; do
			echo "${idle:i:1}" > "$s"
			i=$((i + 1))
		done
	done < "$STATE/cpu"

	rm -r "$STATE"
	status
}

status() {
	local c d

	echo "SMT: $(cat $SYS/smt/control), online CPUs: $(cat $SYS/online)"
	if [ -d "$CG" ]; then
		echo "partition $CG: CPUs $(cat "$CG/cpuset.cpus.effective")," \
		     "$(cat "$CG/cpuset.cpus.partition"), tasks: $(wc -l < "$CG/cgroup.procs")"
	else
		echo "partition: none"
	fi
	echo "workqueue cpumask: $(cat $WQ), default IRQ affinity: $(cat /proc/irq/default_smp_affinity)"
	for c in $(expand "$CPUS"); do
		d=$SYS/cpu$c
		[ -d "$d/cpufreq" ] || { echo "CPU $c: offline"; continue; }
		echo "CPU $c: $(cat $d/cpufreq/scaling_governor)" \
		     "$(cat $d/cpufreq/scaling_min_freq)-$(cat $d/cpufreq/scaling_max_freq) kHz," \
		     "idle states disabled: $(cat $d/cpuidle/state*/disable | tr -d '\n')"
	done
}

run() {
	local u home

	[ -d "$CG" ] || die "not on"
	u=${SUDO_USER:-}
	[ -n "$u" ] && [ "$u" != root ] || die "run it with sudo as the benchmark user"
	home=$(getent passwd "$u" | cut -d: -f6)
	echo $$ > "$CG/cgroup.procs" || die "cannot enter the partition"
	# A login shell gives the user's PATH, sudo resets it
	exec setpriv --reuid="$u" --regid="$(id -g "$u")" --init-groups \
		env -i HOME="$home" USER="$u" LOGNAME="$u" TERM="${TERM:-dumb}" \
		bash -lc 'cd "$0" && exec "$@"' "$PWD" "$@"
}

[ $# -ge 1 ] || usage
[ "$(id -u)" -eq 0 ] || die "must run as root"
cmd=$1
shift
CPUS=8-15
[ -s "$STATE/cpus" ] && CPUS=$(cat "$STATE/cpus")
case $cmd in
on)	CPUS=${1:-8-15}; on ;;
off)	off ;;
status)	status ;;
run)	[ $# -ge 1 ] || usage; run "$@" ;;
*)	usage ;;
esac
