# veth txq wake testing

Benchmark and stress check for the veth series that changes how the NAPI
consumer wakes the sender's txq and how the sender stops it.

| File            | Description                                                     |
|-----------------|-----------------------------------------------------------------|
| `veth_wake.sh`  | The test. Runs as root on the kernel under test                 |
| `vng.sh`        | Boots one or more kernel trees under virtme-ng and runs it      |
| `bench-mode.sh` | Fixed frequency, no idle states and isolated CPUs for the host  |
| `queue.sh`      | Runs queued jobs inside the isolated CPUs                       |

`veth_wake.sh` creates a veth pair with GRO on and TSO off, so every
packet takes the NAPI ptr_ring path. When the ring is full, veth stops
the sender's txq and its NAPI wakes it again. pktgen floods the qdisc,
and iptables rules in the peer netns slow down the consumer.

It has three modes:

- benchmark (default): pktgen flood with threaded and softirq NAPI,
  goodput, qdisc drops and requeues
- `--iperf`: iperf3 TCP and 64 byte UDP throughput with noqueue in
  softirq NAPI and with the qdisc in softirq and threaded NAPI. Also the
  sender rate, UDP loss and TCP retransmits
- `--stress`: qdisc, channel and NAPI changes under traffic, then link
  deletion with packets in flight

At the end of every benchmark and iperf run the peer's NAPI is deleted and
re-added under a pktgen flood (GRO off and on, peer down and up), and ping
must still get through after each step, so a txq that stays stopped
fails the run. All modes fail on a stall or a kernel BUG/WARNING.

Producer, iperf3 server, NAPI threads and ping are pinned to their own
CPUs, which needs 4 CPUs, or 2N+2 with `--queues N`. `--no-pin` turns
that off. With softirq NAPI the consumer runs on the producer's CPU, so
the ring rarely fills there. Those cases check for regressions.

`--queues N` gives the pair N queues with an mq root and `--qdisc` per
queue, and uses N pktgen threads or iperf3 streams.

It needs only bash, iproute2, ethtool, iptables, ping, procps, util-linux
and a kernel with `CONFIG_VETH`, `CONFIG_NET_PKTGEN`, the qdisc under test
and iptables support. `--iperf` also needs iperf3.

## In a VM

Copy `veth_wake.sh` into the VM and run it as root:

```bash
./veth_wake.sh                                  # fq_codel, 0 rules, 20 s
./veth_wake.sh --runs 5 --nrules "0 1000" --napi threaded --csv out.csv
./veth_wake.sh --iperf --duration 10 --runs 5 --csv iperf.csv
./veth_wake.sh --stress
./veth_wake.sh --summary out.csv
```

To compare two kernels, boot each in turn with the same `--csv` file and
a `--label`, then print `--summary`.

## Under virtme-ng

`vng.sh` takes one or more built kernel trees. With several trees the boots
alternate, which evens out drift on the host. `--host-cpus` pins the VM to
host CPUs and warns if they do not use the performance governor. Give it
more host CPUs than `--cpus` (4 by default). Otherwise qemu's own threads
preempt busy vCPUs for milliseconds:

```bash
./vng.sh ~/net-next -- --stress
./vng.sh --boots 10 --host-cpus 8-15 ~/base ~/wake ~/stop -- --runs 2 --nrules "0 1000"
./vng.sh --boots 10 --host-cpus 8-15 ~/base ~/wake ~/stop -- --iperf --duration 10
```

Results and the log of every boot go to `results/<timestamp>/`, together
with `kernels` (tree, `git describe` and `.config` hash of each kernel) and
`summary.txt`. The logs include kernel warnings and worse from the console,
and a boot fails if one shows a BUG, WARNING, Oops or panic.

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
`queue.sh` once inside the partition and put job scripts into `queue/`:

```bash
sudo setsid -f ./bench-mode.sh run ./queue.sh
echo './vng.sh --boots 10 --host-cpus 8-15 ~/base ~/wake' > queue/01-pktgen.sh
touch queue/stop                 # ends the queue after the running job
```

`nohz_full` and `rcu_nocbs` need the kernel command line and are not used.

## Debug kernel

For the stress check, build the same commit a second time with debug
options and run it there. KASAN reports and lockdep splats show up as
`BUG:` or `WARNING:` and fail the run:

```bash
cd ~/wake-debug
vng --kconfig
./scripts/config -e NET_PKTGEN -e NET_SCH_FQ_CODEL -e NET_SCH_SFQ \
	-e KASAN -e KASAN_INLINE -e PROVE_LOCKING -e DEBUG_ATOMIC_SLEEP \
	-e DEBUG_NET -e DEBUG_LIST -e DEBUG_OBJECTS
make olddefconfig && make -j$(nproc)
cd - && ./vng.sh ~/wake-debug -- --stress --duration 60
```

## Results

One line per run:

| Column       | Meaning                                                      |
|--------------|--------------------------------------------------------------|
| pps          | packets received by the peer per second (goodput)            |
| drops        | qdisc drops                                                  |
| requeues     | skbs the driver refused with NETDEV_TX_BUSY, counted per GSO segment |
| Mbit/s       | iperf3 receiver throughput                                   |
| tx Mbit/s    | iperf3 sender throughput                                     |
| lost%        | iperf3 UDP datagrams lost                                    |
| retr         | iperf3 TCP retransmits                                       |

`--summary` gives the mean per kernel and the difference to the first
kernel in the file with a 95% confidence interval (Welch). Each boot
counts as one sample when both kernels have two or more boots, otherwise
each run does. iperf3 throughput moves by a few percent with nothing but
the code layout of a kernel, so compare many alternating boots.

## License

GPL-2.0
