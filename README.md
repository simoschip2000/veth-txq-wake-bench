# veth-bench

The code in this repository was written with Claude Code (Claude Opus 5.5)
and checked by the author.

Benchmark and stress check for veth with a qdisc, written for the veth
series that changes how the NAPI consumer wakes the sender's txq and how
the sender stops it.

| File            | Description                                                     |
|-----------------|-----------------------------------------------------------------|
| `veth_bench.sh` | The test. Runs as root on the kernel under test                 |
| `vng.sh`        | Boots one or more kernel trees under virtme-ng and runs it      |
| `bench-mode.sh` | Fixed frequency, no idle states and isolated CPUs for the host  |
| `queue.sh`      | Runs queued jobs inside the isolated CPUs                       |

`veth_bench.sh` creates a veth pair with GRO on and TSO off, so every
packet takes the NAPI ptr_ring path. When the ring is full, veth stops
the sender's txq and its NAPI wakes it again. pktgen floods the qdisc.

It has three modes:

- benchmark (default): pktgen flood with threaded and softirq NAPI,
  goodput, qdisc drops and requeues
- `--iperf`: iperf3 TCP and 64 byte UDP throughput with noqueue in
  softirq NAPI and with the qdisc in softirq and threaded NAPI. Also the
  sender rate, UDP loss and TCP retransmits
- `--stress`: qdisc, channel and NAPI changes under traffic, then link
  deletion with packets in flight

`--napi` limits the benchmark and iperf modes to threaded or softirq NAPI.

At the end of every benchmark and iperf run the peer's NAPI is deleted and
re-added under a pktgen flood (GRO off and on, peer down and up), and ping
must still get through after each step, so a txq that stays stopped
fails the run. The log then shows the peer's receive rate, the qdisc
backlog, the neighbor entries and whether ping gets through within
another 20 s. All modes fail on a stall or a kernel BUG/WARNING.

Producers, iperf3 servers, NAPI threads and ping are pinned to their own
CPUs: ping on CPU 0, then the producers, the iperf3 servers and the NAPI
threads of the peer. With N queues and S iperf3 streams that needs 2S+N+1
CPUs for `--iperf` and 3N+1 for pktgen, 4 for the defaults. `--no-pin`
turns that off. With softirq NAPI and a single sender the consumer runs on
the sender's CPU, so the ring rarely fills there. Those cases check for
regressions.

`--queues N` gives the pair N queues with an mq root and `--qdisc` per
queue, and uses N pktgen threads. `--streams S` runs S iperf3 clients
and servers, one per CPU, by default one per queue. With several queues
XPS sends stream i through queue i modulo N. With one queue all streams
share its qdisc, ring and NAPI, so the ring fills with softirq NAPI too:

```bash
./vng.sh --cpus 6 --host-cpus 8-15 ~/base ~/wake -- --iperf --streams 2
```

It needs only bash, iproute2, ethtool, ping, procps, util-linux and a
kernel with `CONFIG_VETH`, `CONFIG_NET_PKTGEN` and the qdisc under test.
`--iperf` also needs iperf3.

## In a VM

Copy `veth_bench.sh` into the VM and run it as root:

```bash
./veth_bench.sh                                 # fq_codel, 20 s
./veth_bench.sh --runs 5 --napi threaded --csv out.csv
./veth_bench.sh --iperf --duration 10 --runs 5 --csv iperf.csv
./veth_bench.sh --stress
./veth_bench.sh --summary out.csv
```

To compare two kernels, boot each in turn with the same `--csv` file and
a `--label`, then print `--summary`.

## Under virtme-ng

`vng.sh` takes one or more built kernel trees. With several trees the boots
alternate, which evens out drift on the host. `--host-cpus` pins the VM to
host CPUs and warns if they do not use the performance governor. The first
`--cpus` of them (4 by default) run one vCPU each, and the rest run qemu's
own threads, which otherwise preempt busy vCPUs for milliseconds. So give
it more host CPUs than `--cpus`, best all on one CCX. `--memory` sets the
memory of the VM, 2G by default:

```bash
./vng.sh ~/net-next -- --stress
./vng.sh --boots 10 --host-cpus 8-15 ~/base ~/wake ~/stop -- --runs 2
./vng.sh --boots 10 --host-cpus 8-15 ~/base ~/wake ~/stop -- --iperf --duration 10
```

Results and the log of every boot go to `results/<timestamp>/`, together
with `kernels` (tree, `git describe` and `.config` hash of each kernel),
`cmdline` (the full command and the `git describe` of this repository)
and `summary.txt`. The logs include kernel warnings and worse from the
console, and a boot fails if one shows a BUG, WARNING, Oops, panic or
the OOM killer.

## Benchmark mode

`bench-mode.sh` prepares the host and undoes it again, without a reboot:

```bash
sudo ./bench-mode.sh on          # CPUs 8-15, FREQ=4300000 kHz by default
sudo ./bench-mode.sh status
sudo ./bench-mode.sh off
```

`on` turns SMT off, fixes the frequency of the benchmark CPUs, disables
their idle states and puts them into a cpuset root partition. All other
tasks, IRQs and unbound workqueues then stay on the other CPUs. Only
processes inside the partition can use its CPUs, so start the benchmark
through it:

```bash
sudo ./bench-mode.sh run ./vng.sh --boots 10 --host-cpus 8-15 ~/base ~/wake -- --iperf
```

`run` drops back to the calling user. To queue jobs without sudo, start
`queue.sh` once inside the partition and put job scripts into `queue/`.
Write a job under another name first and rename it, so that the queue
does not pick it up half written:

```bash
sudo setsid -f ./bench-mode.sh run ./queue.sh
echo './vng.sh --boots 10 --host-cpus 8-15 ~/base ~/wake' > queue/01-pktgen.tmp
mv queue/01-pktgen.tmp queue/01-pktgen.sh
touch queue/stop                 # ends the queue after the running job
```

The jobs run in name order. Their output goes to `queue/<name>.log`, and
`queue/queue.log` shows when each one started and ended. `off` refuses
while the queue still runs, so wait a few seconds after `touch queue/stop`.

`nohz_full` and `rcu_nocbs` need the kernel command line and are not used.

## Debug kernel

For the stress check, build the same commit a second time with debug
options and run it there. KASAN reports and lockdep splats show up as
`BUG:` or `WARNING:` and fail the run. In 2G of memory, KASAN kernels
with and without the series ran out of memory under the pktgen flood of
`--stress`, so give the VM more with `--memory`:

```bash
cd ~/wake-debug
vng --kconfig
./scripts/config -e VETH -e NET_PKTGEN -e NET_SCH_FQ_CODEL -e NET_SCH_SFQ \
	-e KASAN -e KASAN_INLINE -e PROVE_LOCKING -e DEBUG_ATOMIC_SLEEP \
	-e DEBUG_NET -e DEBUG_LIST -e DEBUG_OBJECTS
make olddefconfig && make -j$(nproc)
cd - && ./vng.sh --memory 4G ~/wake-debug -- --stress --duration 60
```

## Results

One line per run:

| Column       | Meaning                                                      |
|--------------|--------------------------------------------------------------|
| q            | queues of the veth pair                                      |
| s            | iperf3 streams                                               |
| pps          | packets received by the peer per second (goodput)            |
| drops        | qdisc drops during `--duration`                              |
| requeues     | qdisc requeues during `--duration`, skbs that went back to the qdisc, counted per GSO segment |
| Mbit/s       | iperf3 receiver throughput, summed over all streams          |
| tx Mbit/s    | iperf3 sender throughput, summed over all streams            |
| lost%        | iperf3 UDP datagrams lost                                    |
| retr         | iperf3 TCP retransmits                                       |

`--summary` gives the mean per kernel and the difference to the first
kernel in the file with a 95% confidence interval (Welch). Each boot
counts as one sample when both kernels have two or more boots, otherwise
each run does. Throughput moves by a few percent with nothing but the
code layout of a kernel, as a change in one file can move all code linked
after it. So compare many alternating boots, and distrust differences of
1 to 2%.

## License

GPL-2.0
