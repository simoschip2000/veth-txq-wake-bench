#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# veth-bench: veth benchmark and stress check. Run as root on the kernel
# under test, in a VM or under virtme-ng (see vng.sh).
#
# Sets up a veth pair with GRO on and TSO off, so that every packet takes
# the NAPI ptr_ring path. When the ring is full, veth stops the txq of the
# sender and its NAPI wakes it again. pktgen floods the qdisc of veth_tw0.
#
# Every --napi mode is run --runs times and gives one result line.
# --iperf measures iperf3 TCP and 64 byte UDP throughput instead, with
# noqueue in softirq NAPI and with --qdisc in each --napi mode. At the end
# of every run the peer's NAPI is deleted and re-added under traffic, and
# ping must still get through.
#
# --queues N gives the pair N queues, an mq root with --qdisc per queue and
# one pktgen thread per queue. --streams S runs S iperf3 clients and
# servers, by default one per queue.
#
# --stress changes qdisc, channels and the peer's NAPI under traffic, then
# deletes the link with packets in flight.
#
# All modes fail on a stall or a kernel BUG/WARNING.

set -u
# vng loses stderr without a terminal
exec 2>&1

DURATION=20
QDISC=fq_codel
NAPI="threaded softirq"
RUNS=1
QUEUES=1
STREAMS=
PKT_SIZE=64
LABEL=$(uname -r)
CSV=
MODE=benchmark
PIN=1

NS=tw_ns
A=veth_tw0
B=veth_tw1
IP_B=10.99.0.2
PG=/proc/net/pktgen
TMP=
BOOT=$(cut -c1-8 /proc/sys/kernel/random/boot_id)
PG_PID=
FAIL=0

# CPUs when pinned, for N queues and S iperf3 streams: ping and the NAPI
# of veth_tw0 (replies) on 0, the producers on 1..S (pktgen: 1..N), the
# iperf3 servers on S+1..2S and the NAPI threads of veth_tw1 on 2S+1..2S+N.
# Softirq NAPI runs on the producer's CPU.
CPU_PING=0
CPU_TX=1

usage() {
	cat <<EOF
Usage: $0 [options]
  --duration SEC      traffic time per run (default $DURATION)
  --qdisc NAME        qdisc on both ends (default $QDISC)
  --napi "MODE ..."   threaded and/or softirq NAPI (default "$NAPI")
  --runs N            runs of every combination (default $RUNS)
  --queues N          queues and pktgen threads (default 1)
  --streams N         iperf3 streams, each with its own client and server
                      (default: one per queue)
  --size N            pktgen packet size (default $PKT_SIZE)
  --no-pin            do not pin producer, consumer and ping to CPUs
  --label STR         kernel name in the results (default uname -r)
  --csv FILE          append one line per run to FILE
  --iperf             iperf3 throughput instead of pktgen
  --stress            stress check instead of benchmark
  --summary FILE      print the averages of a CSV file and exit
EOF
	exit 1
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

nsx() {
	ip netns exec "$NS" "$@"
}

# Mean of every metric per kernel, and the difference to the first kernel
# in the file with its 95% confidence interval (Welch). The boots are the
# samples when both sides have two or more, else the runs.
summary() {
	[ -s "$1" ] || die "no results in $1"
	awk -F, '
	function stats(k, boots,    i, b, s, q, x) {
		if (boots) {
			N = nb[k]; s = q = 0
			for (i = 1; i <= N; i++) {
				b = bl[k, i]; x = bs[b] / bc[b]
				s += x; q += x * x
			}
		} else {
			N = rn[k]; s = rs[k]; q = rq[k]
		}
		M = s / N
		V = N > 1 ? (q - N * M * M) / (N - 1) : 0
		if (V < 0)
			V = 0
	}
	function tq(df) {
		if (df <= 30)
			return tt[df < 1 ? 1 : int(df)]
		return df <= 60 ? 2.0 : df <= 120 ? 1.98 : 1.96
	}
	function fmt(name, x) {
		if (name ~ /_pct$/)
			return sprintf("%.2f", x)
		return sprintf("%.0f", x)
	}
	BEGIN {
		split("pps mbps tx_mbps udp_lost_pct tcp_retr requeues", want, " ")
		split("12.706 4.303 3.182 2.776 2.571 2.447 2.365 2.306 2.262 2.228 " \
		      "2.201 2.179 2.160 2.145 2.131 2.120 2.110 2.101 2.093 2.086 " \
		      "2.080 2.074 2.069 2.064 2.060 2.056 2.052 2.048 2.045 2.042", tt, " ")
	}
	NR == 1 {
		for (i = 1; i <= NF; i++) {
			col[$i] = i; name[i] = $i
		}
		for (j = 1; j in want; j++)
			if (want[j] in col)
				mc[++nm] = col[want[j]]
		next
	}
	{
		g = $2
		for (i = 3; i < col["run"]; i++)
			g = g " " name[i] "=" $i
		v = $1
		if (!((g, v) in seen)) {
			seen[g, v]; nv[g]++; vo[g, nv[g]] = v
			if (!(g in gseen)) { gseen[g]; go[++ng] = g }
		}
		runs[g, v]++
		if (!((g, v, $col["boot"]) in bseen)) {
			bseen[g, v, $col["boot"]]; boots[g, v]++
		}
		for (j = 1; j <= nm; j++) {
			x = $mc[j]
			if (x == "")
				continue
			k = g SUBSEP v SUBSEP j
			rn[k]++; rs[k] += x; rq[k] += x * x
			b = k SUBSEP $col["boot"]
			if (!(b in bc)) { nb[k]++; bl[k, nb[k]] = b }
			bs[b] += x; bc[b]++
		}
	}
	END {
		for (gi = 1; gi <= ng; gi++) {
			g = go[gi]
			printf "%s\n  %-20s %5s %4s", g, "kernel", "boots", "runs"
			for (j = 1; j <= nm; j++)
				printf "  %-22s", name[mc[j]]
			printf "\n"
			ref = vo[g, 1]
			for (vi = 1; vi <= nv[g]; vi++) {
				v = vo[g, vi]
				printf "  %-20s %5d %4d", v, boots[g, v], runs[g, v]
				for (j = 1; j <= nm; j++) {
					k = g SUBSEP v SUBSEP j; r = g SUBSEP ref SUBSEP j
					if (!rn[k]) { printf "  %-22s", "-"; continue }
					cell = ""
					if (vi > 1 && rn[r]) {
						ub = nb[k] > 1 && nb[r] > 1
						stats(r, ub); m1 = M; v1 = V; n1 = N
						stats(k, ub); m2 = M; v2 = V; n2 = N
						if (m1 != 0) {
							cell = sprintf(" %+.1f", 100 * (m2 - m1) / m1)
							a = v1 / n1; c = v2 / n2
							if (n1 > 1 && n2 > 1 && a + c > 0) {
								df = (a + c) ^ 2 / (a * a / (n1 - 1) + c * c / (n2 - 1))
								cell = cell sprintf("±%.1f", 100 * tq(df) * sqrt(a + c) / (m1 < 0 ? -m1 : m1))
							}
							cell = cell "%"
						}
					}
					stats(k, 0)
					printf "  %-22s", fmt(name[mc[j]], M) cell
				}
				printf "\n"
			}
			printf "\n"
		}
		printf "Differences are to the first kernel with a 95%% confidence interval.\n"
	}' "$1"
}

# Write the CSV header, or check that an existing file has the same one
csv_header() {
	[ -n "$CSV" ] || return 0
	if [ -s "$CSV" ]; then
		[ "$(head -1 "$CSV")" = "$1" ] ||
			die "$CSV holds results of another mode"
	else
		echo "$1" > "$CSV"
	fi
}

pg() {
	echo "$2" > "$PG/$1" || die "pktgen: $1: $2"
}

pktgen_start() {
	local mac t dev c

	modprobe pktgen 2>/dev/null
	[ -d "$PG" ] || die "pktgen not available (CONFIG_NET_PKTGEN)"
	pg pgctrl reset
	mac=$(nsx cat /sys/class/net/$B/address)
	for ((t = CPU_TX; t < CPU_TX + QUEUES; t++)); do
		dev=$A@$t
		pg kpktgend_$t rem_device_all
		pg kpktgend_$t "add_device $dev"
		# Inject into the qdisc like samples/pktgen queue_xmit, one
		# flow per thread
		for c in "flag QUEUE_MAP_CPU" "flag NO_TIMESTAMP" "count 0" \
			 "pkt_size $PKT_SIZE" "delay 0" "dst_mac $mac" \
			 "dst $IP_B" "udp_dst_min $((9000 + t))" \
			 "udp_dst_max $((9000 + t))" "xmit_mode queue_xmit"; do
			pg "$dev" "$c"
		done
	done
	# Blocks until stopped
	echo start > "$PG/pgctrl" &
	PG_PID=$!
	# A stop before a thread runs is lost and it would never end, so wait
	for ((t = CPU_TX; t < CPU_TX + QUEUES; t++)); do
		for ((c = 0; c < 200; c++)); do
			grep -q "^Running:.* $A@$t " "$PG/kpktgend_$t" && break
			sleep 0.01
		done
	done
}

pktgen_stop() {
	[ -n "$PG_PID" ] || return 0
	echo stop > "$PG/pgctrl" 2>/dev/null
	wait "$PG_PID" 2>/dev/null
	PG_PID=
	echo reset > "$PG/pgctrl" 2>/dev/null
}

# Each NAPI thread on its CPU. Threads come and go with threaded NAPI.
pin_napi() {
	local t c=$CPU_NAPI

	[ "$PIN" -eq 1 ] || return 0
	for t in $(pgrep '^napi/veth_tw0'); do taskset -pc $CPU_PING "$t"; done
	for t in $(pgrep '^napi/veth_tw1'); do
		taskset -pc $c "$t"
		c=$((c + 1))
	done
} >/dev/null

# usage: set_qdisc <dev> <qdisc> [netns]. More than one queue gets an mq
# root with the qdisc per queue.
set_qdisc() {
	local n=${3:+-n $3} i

	[ "$2" = noqueue ] && return 0
	if [ "$QUEUES" -eq 1 ]; then
		tc $n qdisc replace dev "$1" root $2
		return
	fi
	tc $n qdisc replace dev "$1" root handle 1: mq || return 1
	for ((i = 1; i <= QUEUES; i++)); do
		tc $n qdisc replace dev "$1" parent 1:$i $2 || return 1
	done
}

# usage: setup <queues> <threaded|softirq> [qdisc]
setup() {
	local qdisc=${3:-$QDISC} threaded=0

	[ "$2" = threaded ] && threaded=1
	ip netns add "$NS" || die "cannot create netns"
	ip link add "$A" numtxqueues "$1" numrxqueues "$1" type veth \
		peer name "$B" numtxqueues "$1" numrxqueues "$1" netns "$NS" ||
		die "cannot create veth pair"
	ip addr add 10.99.0.1/24 dev "$A"
	ip -n "$NS" addr add "$IP_B/24" dev "$B"
	ip link set "$A" up
	ip -n "$NS" link set "$B" up

	# GRO enables veth NAPI. Without TSO every skb is eligible for it.
	ethtool -K "$A" gro on tso off >/dev/null || die "ethtool -K $A"
	nsx ethtool -K "$B" gro on tso off >/dev/null || die "ethtool -K $B"
	echo "$threaded" > /sys/class/net/$A/threaded
	nsx sh -c "echo $threaded > /sys/class/net/$B/threaded"
	pin_napi

	set_qdisc "$A" "$qdisc" || die "cannot install $qdisc"
	set_qdisc "$B" "$qdisc" "$NS"
}

teardown() {
	pktgen_stop
	for f in "$TMP"/iperf*.pid; do
		[ -s "$f" ] && kill "$(cat "$f")" 2>/dev/null
		rm -f "$f"
	done
	ip link del "$A" 2>/dev/null
	ip netns del "$NS" 2>/dev/null
}

dmesg_mark() {
	DMESG_LINES=$(dmesg | wc -l)
}

dmesg_check() {
	local bad

	bad=$(dmesg | tail -n +$((DMESG_LINES + 1)) |
	      grep -E 'BUG|WARNING|Oops|Out of memory|NETDEV WATCHDOG|asks to queue packet')
	[ -z "$bad" ] && return 0
	echo "FAIL: kernel reported:" >&2
	echo "$bad" | head -20 >&2
	FAIL=1
	return 1
}

tx_packets() {
	cat /sys/class/net/$A/statistics/tx_packets 2>/dev/null || echo 0
}

# Changes to the peer that delete and re-add its NAPI
peer_gro() {
	nsx ethtool -K "$B" gro "$1" >/dev/null
}

peer_threaded() {
	nsx sh -c "echo $1 > /sys/class/net/$B/threaded" && pin_napi
}

# The carrier goes off with the peer, which stops pktgen
peer_bounce() {
	ip -n "$NS" link set "$B" down && ip -n "$NS" link set "$B" up || return 1
	pktgen_stop
	pktgen_start
}

# Change channels under traffic. pktgen stops itself while veth has the
# carrier off for that, so start it again.
channels() {
	ethtool -L "$A" rx "$1" tx "$1" || return 1
	pktgen_stop
	pktgen_start
}

pktgen_sofar() {
	sed -n 's/.*pkts-sofar: \([0-9]*\).*/\1/p' "$PG/$A@$CPU_TX" 2>/dev/null |
		head -1
}

# Why ping failed. If pktgen still sends but the peer receives nothing
# while the qdisc holds a backlog, the txq stays stopped. If the peer
# still receives, look at the neighbor entries for ping and its replies.
ping_diag() {
	local rx0 rx1 pg0 pg1

	rx0=$(nsx cat /sys/class/net/$B/statistics/rx_packets)
	pg0=$(pktgen_sofar)
	sleep 1
	rx1=$(nsx cat /sys/class/net/$B/statistics/rx_packets)
	pg1=$(pktgen_sofar)
	echo "  peer rx: $((rx1 - rx0)) packets/s," \
	     "pktgen sent: $(( ${pg1:-0} - ${pg0:-0} )) packets/s"
	echo "  link: $(ip -br link show dev "$A" | awk '{print $1, $2}')," \
	     "peer $(nsx ip -br link show dev "$B" | awk '{print $1, $2}')"
	tc -s qdisc show dev "$A" | sed 's/^/  qdisc: /'
	ip neigh show dev "$A" | sed 's/^/  neigh: /'
	nsx ip neigh show dev "$B" | sed 's/^/  peer neigh: /'
	echo "  peer NAPI threads: $(pgrep -c '^napi/veth_tw1')"
	if ping -n -q -c 1 -i 0.05 -w 20 "$IP_B" >/dev/null 2>&1; then
		echo "  ping got a reply within another 20 s"
	else
		echo "  still no ping reply after another 20 s"
	fi
}

# Delete and re-add the peer's NAPI under a pktgen flood. Ping must still
# get a reply within 10 s after every step, so the txq must not stay
# stopped. A tail drop qdisc like pfifo drops most pings and the ARP after
# peer down, so a short burst is not enough.
end_checks() {
	local step

	[ -n "$PG_PID" ] || pktgen_start
	for step in "peer_gro off" "peer_gro on" "peer_bounce"; do
		# shellcheck disable=SC2086
		$step || echo "  (failed: $step)"
		if ! ping -n -q -c 1 -i 0.05 -w 10 "$IP_B" >/dev/null 2>&1; then
			echo "FAIL: no ping reply after $step" >&2
			ping_diag >&2
			FAIL=1
		fi
	done
	pktgen_stop
}

# Requeues of the root qdisc of veth_tw0 so far. Each one is an skb that
# the driver refused with NETDEV_TX_BUSY, or a GSO segment behind it.
qdisc_requeues() {
	tc -s qdisc show dev "$A" | sed -n 's/.* requeues \([0-9]*\)).*/\1/p' | head -1
}

# Drops of the root qdisc of veth_tw0 so far
qdisc_drops() {
	tc -s qdisc show dev "$A" | sed -n 's/.*(dropped \([0-9]*\),.*/\1/p' | head -1
}

# usage: run_one <run> <threaded|softirq>
run_one() {
	local rx0 rx1 t0 t1 pps dr0 drops rq0 requeues

	setup "$QUEUES" "$2"
	dmesg_mark
	pktgen_start
	sleep 1
	# Drops and requeues of the same --duration as pps, without the start
	rx0=$(nsx cat /sys/class/net/$B/statistics/rx_packets)
	t0=$(date +%s%N)
	dr0=$(qdisc_drops)
	rq0=$(qdisc_requeues)
	sleep "$DURATION"
	rx1=$(nsx cat /sys/class/net/$B/statistics/rx_packets)
	t1=$(date +%s%N)
	drops=$(qdisc_drops)
	requeues=$(qdisc_requeues)
	[ -n "$dr0" ] && [ -n "$drops" ] && drops=$((drops - dr0))
	[ -n "$rq0" ] && [ -n "$requeues" ] && requeues=$((requeues - rq0))
	end_checks
	teardown
	dmesg_check

	pps=$(( (rx1 - rx0) * 1000000000 / (t1 - t0) ))
	printf "%-20s %-9s %2s %-8s %4s %10s %10s %9s\n" \
		"$LABEL" "$QDISC" "$QUEUES" "$2" "$1" "$pps" \
		"${drops:--}" "${requeues:--}"
	[ -n "$CSV" ] && echo "$LABEL,$QDISC,$QUEUES,$2,$1,$BOOT,$pps,$drops,$requeues" >> "$CSV"
	return 0
}

benchmark() {
	local r n

	csv_header "kernel,qdisc,queues,napi,run,boot,pps,qdisc_drops,requeues"
	printf "%-20s %-9s %2s %-8s %4s %10s %10s %9s\n" \
		kernel qdisc q napi run pps drops requeues
	for ((r = 1; r <= RUNS; r++)); do
		for n in $NAPI; do
			run_one "$r" "$n"
		done
	done
}

# usage: xps <dev> <queue> <cpu>, dev may be in the netns
xps() {
	local f=/sys/class/net/$1/queues/tx-$2/xps_cpus m

	m=$(printf %x $((1 << $3)))
	if [ "$1" = "$B" ]; then
		nsx sh -c "echo $m > $f"
	else
		echo "$m" > "$f"
	fi
}

# Sum over the iperf3 outputs of all streams: receiver and sender Mbit/s,
# lost UDP datagrams in percent and TCP retransmits. Prints nothing when
# a stream has no result.
iperf_sum() {
	awk -v n=$# '
	function mb(line,   f, i, k) {
		k = split(line, f)
		for (i = 2; i <= k; i++)
			if (f[i] == "Mbits/sec")
				return i
		return 0
	}
	/receiver$/ { rx[FILENAME] = $0 }
	/sender$/ { txl[FILENAME] = $0 }
	END {
		for (file in rx) {
			got++
			k = split(rx[file], f); i = mb(rx[file])
			mbps += f[i - 1]
			for (j = i + 1; j <= k; j++)
				if (f[j] ~ /^[0-9]+\/[0-9]+$/) {
					split(f[j], lt, "/"); lost += lt[1]; total += lt[2]; udp = 1
				}
			k = split(txl[file], f); i = mb(txl[file])
			tx += f[i - 1]
			if (f[i + 2] == "sender") {
				retr += f[i + 1]; tcp = 1
			}
		}
		if (got < n)
			exit
		printf "%.0f %.0f %s %s\n", mbps, tx,
			udp ? sprintf("%.4g", total ? 100 * lost / total : 0) : "-",
			tcp ? retr : "-"
	}' "$@"
}

# usage: iperf_one <run> <qdisc> <threaded|softirq>
#
# One iperf3 server and client per stream. When pinned, each client and
# server has its own CPU. With several queues XPS sends stream i through
# txq i modulo the queues, so that it reaches the peer's rq and NAPI
# thread of that queue. The replies take the same queue back from the
# server's CPU.
iperf_one() {
	local proto opts mbps tx lost retr rq0 requeues i pin res pids

	setup "$QUEUES" "$3" "$2"
	for ((i = 0; i < STREAMS; i++)); do
		pin=
		if [ "$PIN" -eq 1 ]; then
			pin="-A $((CPU_SRV + i))"
			if [ "$QUEUES" -gt 1 ]; then
				xps "$A" $((i % QUEUES)) $((CPU_TX + i))
				xps "$B" $((i % QUEUES)) $((CPU_SRV + i))
			fi
		fi
		# shellcheck disable=SC2086
		nsx iperf3 -s -D -p $((5201 + i)) $pin -I "$TMP/iperf$i.pid" ||
			die "cannot start iperf3 server"
	done
	sleep 0.5
	dmesg_mark
	for proto in tcp udp; do
		opts=
		[ $proto = udp ] && opts="-u -b 0 -l 64"
		rq0=$(qdisc_requeues)
		pids=()
		rm -f "$TMP"/out*
		for ((i = 0; i < STREAMS; i++)); do
			pin=
			[ "$PIN" -eq 1 ] && pin="-A $((CPU_TX + i))"
			# shellcheck disable=SC2086
			iperf3 -c "$IP_B" -p $((5201 + i)) -t "$DURATION" -f m $pin \
				$opts > "$TMP/out$i" 2>&1 &
			pids+=($!)
		done
		wait "${pids[@]}"
		requeues=$(qdisc_requeues)
		[ -n "$rq0" ] && [ -n "$requeues" ] && requeues=$((requeues - rq0))
		res=$(iperf_sum "$TMP"/out*)
		read -r mbps tx lost retr <<< "${res:-- - - -}"
		[ "$proto" = udp ] && retr=
		[ "$proto" = tcp ] && lost=
		if [ -z "$res" ]; then
			echo "FAIL: iperf3 $proto:" >&2
			tail -n 3 "$TMP"/out* >&2
			mbps= tx=
			FAIL=1
		fi
		printf "%-20s %-9s %2s %2s %-8s %-5s %4s %10s %10s %6s %6s %9s\n" \
			"$LABEL" "$2" "$QUEUES" "$STREAMS" "$3" $proto "$1" "${mbps:--}" \
			"${tx:--}" "${lost:--}" "${retr:--}" "${requeues:--}"
		[ -n "$CSV" ] && echo "$LABEL,$2,$QUEUES,$STREAMS,$3,$proto,$1,$BOOT,$mbps,$tx,$lost,$retr,$requeues" >> "$CSV"
	done
	end_checks
	teardown
	dmesg_check
	return 0
}

iperf() {
	local r c

	command -v iperf3 >/dev/null || die "iperf3 not found"
	csv_header "kernel,qdisc,queues,streams,napi,proto,run,boot,mbps,tx_mbps,udp_lost_pct,tcp_retr,requeues"
	printf "%-20s %-9s %2s %2s %-8s %-5s %4s %10s %10s %6s %6s %9s\n" kernel \
		qdisc q s napi proto run Mbit/s "tx Mbit/s" lost% retr requeues
	for ((r = 1; r <= RUNS; r++)); do
		for c in "noqueue softirq" "$QDISC softirq" "$QDISC threaded"; do
			[[ " $NAPI " == *" ${c#* } "* ]] || continue
			# shellcheck disable=SC2086
			iperf_one "$r" $c
		done
	done
}

# Apply one change under traffic, then check that traffic still flows
stress_step() {
	local tx

	echo "stress: $*"
	"$@" >/dev/null 2>&1 || echo "  (failed: $*)"
	sleep 1
	tx=$(tx_packets)
	sleep 0.5
	if [ "$(tx_packets)" -le "$tx" ]; then
		echo "FAIL: traffic stalled after: $*" >&2
		FAIL=1
	fi
	dmesg_check
}

stress() {
	local end i steps

	# Not a measurement, so four queues and no pinning
	PIN=0
	CPU_TX=0
	QUEUES=$(( $(nproc) < 4 ? $(nproc) : 4 ))
	setup 4 threaded
	dmesg_mark
	pktgen_start
	end=$((SECONDS + DURATION))
	steps=("tc qdisc replace dev $A root sfq"
	       "tc qdisc replace dev $A root pfifo"
	       "tc qdisc del dev $A root"
	       "tc qdisc replace dev $A root $QDISC"
	       "channels 1" "channels 4"
	       "peer_gro off" "peer_gro on" "peer_threaded 0" "peer_threaded 1"
	       "peer_bounce")
	while [ "$SECONDS" -lt "$end" ] && [ "$FAIL" -eq 0 ]; do
		for i in "${steps[@]}"; do
			# shellcheck disable=SC2086
			stress_step $i
		done
	done

	echo "stress: ip link del $A under traffic"
	ip link del "$A"
	for ((i = 0; i < 50; i++)); do
		kill -0 "$PG_PID" 2>/dev/null || break
		sleep 0.1
	done
	kill -0 "$PG_PID" 2>/dev/null && { echo "FAIL: pktgen hangs" >&2; FAIL=1; }
	pktgen_stop
	ip netns del "$NS"
	sleep 1
	dmesg_check
	[ "$FAIL" -eq 0 ] && echo "stress: PASS" || echo "stress: FAIL"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--duration)	DURATION=$2; shift ;;
	--qdisc)	QDISC=$2; shift ;;
	--napi)		NAPI=$2; shift ;;
	--runs)		RUNS=$2; shift ;;
	--queues)	QUEUES=$2; shift ;;
	--streams)	STREAMS=$2; shift ;;
	--size)		PKT_SIZE=$2; shift ;;
	--no-pin)	PIN=0 ;;
	--label)	LABEL=$2; shift ;;
	--csv)		CSV=$2; shift ;;
	--iperf)	MODE=iperf ;;
	--stress)	MODE=stress ;;
	--summary)	summary "$2"; exit ;;
	*)		usage ;;
	esac
	shift
done

for n in $NAPI; do
	case $n in
	threaded|softirq) ;;
	*) die "--napi: unknown mode $n" ;;
	esac
done
[ "$(id -u)" -eq 0 ] || die "must run as root"
for c in ip tc ethtool ping modprobe pgrep taskset; do
	command -v $c >/dev/null || die "$c not found"
done
STREAMS=${STREAMS:-$QUEUES}
[ "$MODE" = iperf ] && NPROD=$STREAMS || NPROD=$QUEUES
CPU_SRV=$((CPU_TX + NPROD))
CPU_NAPI=$((CPU_SRV + NPROD))
if [ "$PIN" -eq 1 ] && [ "$MODE" != stress ]; then
	[ "$(nproc)" -ge $((CPU_NAPI + QUEUES)) ] ||
		die "pinning $QUEUES queue(s) needs $((CPU_NAPI + QUEUES)) CPUs, use --no-pin"
fi
[ "$PIN" -eq 1 ] || [ "$(nproc)" -ge $((CPU_TX + QUEUES)) ] ||
	die "$QUEUES pktgen threads need $((CPU_TX + QUEUES)) CPUs"
TMP=$(mktemp -d) || die "mktemp failed"
trap 'teardown; rm -rf "$TMP"' EXIT
teardown

[ "$MODE" = stress ] && PIN=0
echo "kernel $(uname -r), $(nproc) CPUs, $QDISC, ${DURATION}s per run, pinning $([ "$PIN" -eq 1 ] && echo on || echo off)"
$MODE
exit $FAIL
