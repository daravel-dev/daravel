#!/bin/sh
# Starts the Redis Cluster and Sentinel the integration tests use, each in
# one container whose servers announce 127.0.0.1 (ports mapped 1:1):
#
#   cluster:  three masters on 17001-17003
#             DARAVEL_TEST_REDIS_CLUSTER=redis+cluster://127.0.0.1:17001,127.0.0.1:17002
#   sentinel: master 17010, replica 17011, sentinel 17020 (service mymaster)
#             DARAVEL_TEST_REDIS_SENTINEL=redis+sentinel://127.0.0.1:17020/mymaster
#
# Usage: tool/topologies.sh [image] (valkey/valkey:8.1 by default).
set -eu
image="${1:-valkey/valkey:8.1}"
case "$image" in
  redis*) bin=redis ;;
  *) bin=valkey ;;
esac

docker rm -f daravel-test-cluster daravel-test-sentinel >/dev/null 2>&1 || true

docker run -d --name daravel-test-cluster \
  -p 127.0.0.1:17001-17003:17001-17003 "$image" sh -c "
    for port in 17001 17002 17003; do
      $bin-server --port \$port --cluster-enabled yes --cluster-config-file nodes-\$port.conf \
        --cluster-announce-ip 127.0.0.1 --save '' --appendonly no --daemonize yes
    done
    sleep 1
    $bin-cli --cluster create 127.0.0.1:17001 127.0.0.1:17002 127.0.0.1:17003 \
      --cluster-replicas 0 --cluster-yes
    tail -f /dev/null" >/dev/null

docker run -d --name daravel-test-sentinel \
  -p 127.0.0.1:17010-17011:17010-17011 -p 127.0.0.1:17020:17020 "$image" sh -c "
    $bin-server --port 17010 --replica-announce-ip 127.0.0.1 --save '' --daemonize yes
    $bin-server --port 17011 --replicaof 127.0.0.1 17010 --replica-announce-ip 127.0.0.1 \
      --save '' --daemonize yes
    printf 'port 17020\nsentinel announce-ip 127.0.0.1\nsentinel monitor mymaster 127.0.0.1 17010 1\nsentinel down-after-milliseconds mymaster 1000\nsentinel failover-timeout mymaster 3000\n' > /tmp/sentinel.conf
    $bin-sentinel /tmp/sentinel.conf" >/dev/null

# Wait until the cluster serves every slot and the sentinel knows the master.
for _ in $(seq 1 30); do
  if docker exec daravel-test-cluster $bin-cli -p 17001 cluster info 2>/dev/null | grep -q 'cluster_state:ok' &&
    docker exec daravel-test-sentinel $bin-cli -p 17020 sentinel get-master-addr-by-name mymaster 2>/dev/null | grep -q 1701; then
    echo "cluster and sentinel ready"
    exit 0
  fi
  sleep 1
done
echo "topologies did not become ready" >&2
docker logs daravel-test-cluster >&2
exit 1
