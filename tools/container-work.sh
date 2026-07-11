#!/usr/bin/env bash
# PoC workload for the container observer: containers doing real work so the
# observer has something to capture. Labeled containers pass through the
# NX_TASK_TARGET_* env vars nx sets on every task as cloud.nx.task.* labels,
# so the observer attributes them to this exact task. One container stays
# unlabeled on purpose to show the unattributed bucket.
set -euo pipefail

variant="${1:-a}"

echo "docker server: $(docker version --format '{{.Server.Version}}')"

labels=(
  --label "cloud.nx.task.project=${NX_TASK_TARGET_PROJECT:-unknown}"
  --label "cloud.nx.task.target=${NX_TASK_TARGET_TARGET:-unknown}"
)

# 1. labeled: memory staircase + cpu burn for ~12s (background)
docker run --rm --shm-size=256m "${labels[@]}" --name "staircase-$variant" alpine sh -c '
  i=0
  while [ $i -lt 12 ]; do
    dd if=/dev/zero of=/dev/shm/ballast.$i bs=1M count=16 2>/dev/null
    md5sum /dev/shm/ballast.* > /dev/null
    i=$((i+1))
    sleep 1
  done' &
staircase=$!

# 2. labeled: postgres taking inserts (testcontainers-style service sidecar)
docker run -d --rm "${labels[@]}" --name "pg-$variant" \
  -e POSTGRES_PASSWORD=poc postgres:16-alpine >/dev/null
for _ in $(seq 1 30); do
  docker exec "pg-$variant" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec "pg-$variant" psql -U postgres -q -c 'create table load (id serial, data text);'
for _ in $(seq 1 10); do
  docker exec "pg-$variant" psql -U postgres -q \
    -c "insert into load(data) select md5(random()::text) from generate_series(1,20000);"
done
docker stop "pg-$variant" >/dev/null

# 3. env-passed: no labels — forwards the NX_TASK_TARGET_* vars nx set on
#    this task process; the observer attributes from the container's env
docker run --rm --shm-size=128m --name "envpass-$variant" \
  -e NX_TASK_TARGET_PROJECT -e NX_TASK_TARGET_TARGET \
  alpine sh -c 'dd if=/dev/zero of=/dev/shm/x bs=1M count=32 2>/dev/null; md5sum /dev/shm/x >/dev/null; sleep 4; echo envpass done'

# 4. unlabeled short-lived container
docker run --rm --name "unlabeled-$variant" alpine sh -c 'sleep 3; echo unlabeled done'

wait "$staircase"
echo "container work ($variant) complete"
