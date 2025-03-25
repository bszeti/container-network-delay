## Start a five node YugabyteDB cluster in containers

## Uncomment to use "docker" instead of "podman"
# alias podman=docker

## Delete existing nodes and volumes first if script was run before
echo "Cleanup..."
podman rm -f db-node{5..1}
for volume in data-db-node{1..5}; do
  podman volume exists $volume && podman volume rm $volume
done

## Crate an internal network if it doesn't exist
podman network exists db-network || podman network create db-network

## Node1 - region-a.az-1
## First node in the primary region, other nodes can join. UI and database port is published
podman run -it -d --name db-node1 --net db-network -v data-db-node1:/home/yugabyte/data -p 15433:15433  -p 5433:5433 \
  yugabytedb/yugabyte:2024.2.2.1-b6 \
  bin/yugabyted start --cloud_location=dc.region-a.az-1 --tserver_flags="ysql_max_connections=100" --base_dir=/home/yugabyte/data --background=false

## Wait for first node to come up
while true; do 
  echo "Waiting for first node to come up..."
  podman exec -it db-node1 /home/yugabyte/bin/yb-admin -master_addresses db-node1 list_all_tablet_servers | grep ALIVE | [ $(wc -l) == 1 ] && break
  sleep 2
done
# while true; do echo "Waiting for first node to come up..."; sleep 2; podman exec -it db-node1 /home/yugabyte/bin/yb-admin -master_addresses db-node1 list_all_tablet_servers | grep ALIVE | [ $(wc -l) == 1 ] && break; done


## Node2 - region-a.az-2
podman run -it -d --name db-node2 --net db-network -v data-db-node2:/home/yugabyte/data \
  yugabytedb/yugabyte:2024.2.2.1-b6 \
  bin/yugabyted start --join=db-node1 --cloud_location=dc.region-a.az-2 --tserver_flags="ysql_max_connections=100" --base_dir=/home/yugabyte/data --background=false

## Node3 - region-b.az-1
## Node in another region, adding 25ms delay to its network interface
podman run -it -d --name db-node3 --net db-network -v data-db-node3:/home/yugabyte/data --cap-add NET_ADMIN \
  yugabytedb/yugabyte:2024.2.2.1-b6 \
  sh -c "dnf update -y && dnf install -y iproute-tc && tc qdisc add dev eth0 root netem delay 25ms &&
         bin/yugabyted start --join=db-node1 --cloud_location=dc.region-b.az-1 --tserver_flags="ysql_max_connections=100" --base_dir=/home/yugabyte/data --background=false"

## Node4 - region-b.az-2
## Node in another region, adding 25ms delay to its network interface
podman run -it -d --name db-node4 --net db-network -v data-db-node4:/home/yugabyte/data --cap-add NET_ADMIN \
  yugabytedb/yugabyte:2024.2.2.1-b6 \
  sh -c "dnf update -y && dnf install -y iproute-tc && tc qdisc add dev eth0 root netem delay 25ms &&
         bin/yugabyted start --join=db-node1 --cloud_location=dc.region-b.az-2 --tserver_flags="ysql_max_connections=100" --base_dir=/home/yugabyte/data --background=false"

## Node5 - region-b.az-3
## Node in another region, adding 25ms delay to its network interface
podman run -it -d --name db-node5 --net db-network -v data-db-node5:/home/yugabyte/data --cap-add NET_ADMIN \
  yugabytedb/yugabyte:2024.2.2.1-b6 \
  sh -c "dnf update -y && dnf install -y iproute-tc && tc qdisc add dev eth0 root netem delay 25ms &&
         bin/yugabyted start --join=db-node1 --cloud_location=dc.region-b.az-3 --tserver_flags="ysql_max_connections=100" --base_dir=/home/yugabyte/data --background=false"

# Wait for cluster to come up
while true; do echo "Waiting for cluster to reach 5 nodes..."; sleep 2; podman exec -it db-node1 /home/yugabyte/bin/yb-admin -master_addresses db-node1 list_all_tablet_servers | grep ALIVE | [ $(wc -l) == 5 ] && break; done
# Should see all 5 nodes up
podman ps -f name=db-node --sort names

## Configure db cluster
## Set replication factor to 5
podman exec -it db-node1 /home/yugabyte/bin/yugabyted configure data_placement --rf 5 --base_dir=/home/yugabyte/data
## Addresses
podman exec -it db-node1 /home/yugabyte/bin/yb-admin -master_addresses db-node1,db-node2,db-node3,db-node4,db-node5 set_preferred_zones dc.region-a.az-1:1 dc.region-a.az-2:1
## Alter role to avoid "advisory locks are not yet implemented" error in SpringBoot apps
podman exec -it db-node1 ysqlsh -h db-node1 -U yugabyte -d yugabyte -c "alter role yugabyte set yb_silence_advisory_locks_not_supported_error=on"

## TEST
## Connect from host to db-node1
# psql "host=127.0.0.1 port=5433 user=yugabyte"
## or use ysqlsh in container
# podman exec -it db-node1 ysqlsh -h db-node1 -U yugabyte -d yugabyte

## SELECT is quick, there is no network delay for db-node1
echo "\nExecuting SELECT..."
# psql "host=127.0.0.1 port=5433 user=yugabyte" -c "\timing" -c "SELECT 1"
podman exec -it db-node1 ysqlsh -h db-node1 -U yugabyte -d yugabyte -c "\timing" -c "SELECT 1"

## CREATE TABLE mytable (id bigint NOT NULL, CONSTRAINT "mytable-pkey" PRIMARY KEY (id));
# psql "host=127.0.0.1 port=5433 user=yugabyte" -c 'CREATE TABLE mytable (id bigint NOT NULL, CONSTRAINT "mytable-pkey" PRIMARY KEY (id))'
podman exec -it db-node1 ysqlsh -h db-node1 -U yugabyte -d yugabyte -c 'CREATE TABLE mytable (id bigint NOT NULL, CONSTRAINT "mytable-pkey" PRIMARY KEY (id))'

## INSERT is slow (>25ms) because of the network delay between cluster nodes 
echo "\nExecuting INSERT..."
# psql "host=127.0.0.1 port=5433 user=yugabyte" -c "\timing" -c "INSERT INTO mytable (id) VALUES (1)"
podman exec -it db-node1 ysqlsh -h db-node1 -U yugabyte -d yugabyte -c "\timing" -c "INSERT INTO mytable (id) VALUES (1)"


