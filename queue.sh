#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Run the job scripts in queue/ one after the other, in name order. Start
# it once inside the benchmark partition, so that the jobs can use its
# CPUs without sudo:
#
#   sudo setsid -f ./bench-mode.sh run ./queue.sh < /dev/null > queue/start.log 2>&1
#
# Without the redirections, sudo with use_pty ends the queue when it exits.
# A job is any bash script, e.g. queue/01-pktgen.sh with a vng.sh command.
# It moves to queue/done/ when it starts, and its output goes to
# queue/<name>.log. touch queue/stop ends the queue after the running job.

set -u

Q=$(cd "$(dirname "$0")" && pwd)/queue
mkdir -p "$Q/done"
rm -f "$Q/stop"
echo "queue: started, pid $$" > "$Q/queue.log"

while [ ! -e "$Q/stop" ]; do
	job=$(find "$Q" -maxdepth 1 -name '*.sh' | sort | head -1)
	if [ -z "$job" ]; then
		sleep 5
		continue
	fi
	name=$(basename "$job" .sh)
	mv "$job" "$Q/done/$name.sh"
	echo "queue: $(date +%T) start $name" >> "$Q/queue.log"
	bash "$Q/done/$name.sh" > "$Q/$name.log" 2>&1
	echo "queue: $(date +%T) end $name rc=$?" >> "$Q/queue.log"
done
rm -f "$Q/stop"
echo "queue: $(date +%T) stopped" >> "$Q/queue.log"
