#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Boot one or more built kernel trees under virtme-ng and run veth_wake.sh
# in each boot. With several trees the boots alternate, so that drift on the
# host hits both kernels alike. Results and logs, with kernel warnings and
# worse from the console, go to results/<timestamp>/, followed by the
# averages of all boots.
#
# Usage: vng.sh [--boots N] [--cpus N] [--host-cpus LIST] TREE [TREE...] [-- veth_wake.sh options]
#
# --host-cpus pins the VM to host CPUs, e.g. 8-15, so that other load on
# the host disturbs it less. Give it more host CPUs than --cpus, as qemu's
# own threads otherwise preempt busy vCPUs for milliseconds, which shows
# up as ping spikes. Their frequency governor should be performance, see
# bench-mode.sh, which also keeps everything else off them.
#
# Examples:
#   ./vng.sh ~/net-next -- --stress
#   ./vng.sh --boots 10 --host-cpus 8-15 ~/base ~/patched -- --runs 2
#   ./vng.sh --boots 10 --host-cpus 8-15 ~/base ~/patched -- --iperf

set -u

BOOTS=1
CPUS=4
HOST_CPUS=
TREES=()

usage() {
	sed -n 's/^# Usage: //p' "$0"
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--boots)	BOOTS=$2; shift 2 ;;
	--cpus)		CPUS=$2; shift 2 ;;
	--host-cpus)	HOST_CPUS=$2; shift 2 ;;
	--)		shift; break ;;
	-*)		usage ;;
	*)		TREES+=("$(cd "$1" && pwd)") || exit 1; shift ;;
	esac
done
[ ${#TREES[@]} -ge 1 ] || usage
command -v vng >/dev/null || { echo "vng not found" >&2; exit 1; }

DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$DIR/results/$(date +%Y-%m-%dT%H-%M-%S)
CSV=$OUT/results.csv
ARGS=$(printf ' %q' "$@")
mkdir -p "$OUT"
echo "$0 $*" > "$OUT/cmdline"

for t in "${TREES[@]}"; do
	[ -f "$t/vmlinux" ] || { echo "$t: no vmlinux, build it first" >&2; exit 1; }
	for c in VETH NET_PKTGEN; do
		grep -q "^CONFIG_$c=[ym]" "$t/.config" ||
			echo "warning: $t: CONFIG_$c is not set" >&2
	done
done

if [ -n "$HOST_CPUS" ]; then
	taskset -c "$HOST_CPUS" true 2>/dev/null || {
		echo "cannot run on host CPUs $HOST_CPUS. If bench-mode.sh isolates" \
		     "them, start this with: sudo ./bench-mode.sh run $0 ..." >&2
		exit 1
	}
	HOST_LIST=$(for c in $(taskset -c "$HOST_CPUS" sh -c 'taskset -pc $$' |
			       sed 's/.*: //' | tr ',' ' '); do
		case $c in
		*-*)	seq "${c%-*}" "${c#*-}" ;;
		*)	echo "$c" ;;
		esac
	done)
	for c in $HOST_LIST; do
		g=/sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor
		[ -r "$g" ] && [ "$(cat "$g")" != performance ] &&
			echo "warning: host CPU $c uses the $(cat "$g") governor" >&2
	done
	[ "$(echo $HOST_LIST | wc -w)" -gt "$CPUS" ] ||
		echo "warning: --host-cpus should have more CPUs than --cpus $CPUS" >&2
	PIN_CMD=(taskset -c "$HOST_CPUS")
else
	PIN_CMD=()
	echo "warning: the VM is not pinned to host CPUs (--host-cpus)" >&2
fi

# Name the kernels after their trees, or A, B, ... if two names are equal
LABELS=()
for t in "${TREES[@]}"; do
	LABELS+=("$(basename "$t")")
done
if [ "$(printf '%s\n' "${LABELS[@]}" | sort -u | wc -l)" -ne ${#LABELS[@]} ]; then
	LABELS=()
	ABC=ABCDEFGHIJKLMNOPQRSTUVWXYZ
	for i in "${!TREES[@]}"; do
		LABELS+=("${ABC:i:1}")
	done
fi

# Record what was tested
for i in "${!TREES[@]}"; do
	t=${TREES[$i]}
	printf "%s %s %s config %s\n" "${LABELS[$i]}" "$t" \
		"$(git -C "$t" describe --always --dirty 2>/dev/null || echo -)" \
		"$(sha256sum < "$t/.config" | cut -c1-12)"
done | tee "$OUT/kernels"

KERNEL_BAD='BUG:|WARNING:|Oops|Kernel panic|NETDEV WATCHDOG'
FAIL=0

for ((b = 1; b <= BOOTS; b++)); do
	for i in "${!TREES[@]}"; do
		name=${LABELS[$i]}-$b
		echo "=== boot $b/$BOOTS: ${LABELS[$i]} (${TREES[$i]})"
		(cd "${TREES[$i]}" &&
		 "${PIN_CMD[@]}" vng --verbose --cpus "$CPUS" --memory 2G \
			--rwdir "$OUT" --append "panic=5 loglevel=5" \
			--exec "$DIR/veth_wake.sh --label ${LABELS[$i]} --csv $CSV$ARGS") \
			2>&1 | tee "$OUT/$name.log"
		rc=${PIPESTATUS[0]}
		# --verbose puts the console, warnings and worse, into the log
		if grep -qE "$KERNEL_BAD" "$OUT/$name.log"; then
			echo "kernel problems in $OUT/$name.log"
			FAIL=1
		fi
		[ "$rc" -eq 0 ] || { echo "boot failed (rc=$rc)"; FAIL=1; }
	done
done

if [ -s "$CSV" ]; then
	echo
	"$DIR/veth_wake.sh" --summary "$CSV" | tee "$OUT/summary.txt"
fi
echo "Results: $OUT"
exit $FAIL
