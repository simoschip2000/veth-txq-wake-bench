# veth: earlier txq wake and stop under backpressure

`patches/` holds the series
"[PATCH net-next 0/3] veth: earlier txq wake and stop under backpressure",
on net-next 612848d37e68.

## Runs

The numbers in the commit messages come from these runs, started with
`queue.sh` inside the isolated CPUs (see the main README):

    ./vng.sh --boots 50 --host-cpus 8-15 BASE WAKE FULL -- --duration 10
    ./vng.sh --boots 50 --host-cpus 8-15 BASE WAKE FULL -- --iperf --duration 10
    ./vng.sh --boots 40 --cpus 6 --host-cpus 8-15 BASE WAKE FULL -- \
        --iperf --streams 2 --duration 10
    ./vng.sh --memory 4G --host-cpus 8-15 DEBUG -- --stress --duration 120

BASE is a build of net-next c2621b518b38, WAKE adds patches 1-2 and FULL
patches 1-3, all from the same config. DEBUG is a KASAN and lockdep build
of BASE or FULL.

The series was rebased onto 612848d37e68 after the runs, without
conflicts and with no changes to veth.c or ptr_ring.h in between. In the
runs, patch 3 checked the ring with `__ptr_ring_full()`, and the sent
patch uses `__ptr_ring_check_produce()`, which tests the same slot.

`summary.txt` compares every kernel to the first one. For one patch
against the previous one, filter `results.csv` to two kernels, e.g.
patch 3:

    awk -F, 'NR == 1 || $1 == "wake" || $1 == "full"' \
        results/<run>/results.csv > p3.csv
    ./veth_bench.sh --summary p3.csv

## Host

AMD Ryzen 9 9950X, with CPUs 8-15 (one CCX) isolated by `bench-mode.sh`.
SMT was off and the frequency fixed at 4.3 GHz. The vCPUs were pinned 1:1.

## Debug stress

The DEBUG builds of BASE and FULL each passed two of three `--stress`
runs. The third run of both ran out of memory in the 4G VM at the same
step, with no KASAN or lockdep reports.
