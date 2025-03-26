Simulate network delays with local containers
=============================================

Some real world use cases can be challenging to test as a developer. With limited resources and permissions sometimes we can't reproduce issues that we face in a QA or production environments, which makes debugging and fixing them cumbersome. In this post we'll take a look how to use containers to simulate the impact of network latency on a distributed database cluster using only a single laptop.

Generally, it's a good idea to utilize containers on a local environment - inner loop - to test how your application works in a production like environment in certain situations (e.g. limited resource availability, network issues...).

If you have a Linux host, you can use `podman` or `docker` directly to spin up containers. On Mac or Windows you'll need [Podman Desktop](https://podman-desktop.io/) or [Docker Desktop](https://www.docker.com/products/docker-desktop/) that creates a Linux VM under the hood to run containers. See [Troubleshooting](#troubleshooting) below how to prepare the host. Here we'll use `podman` commands, but they work interchangeably with `docker`.


## Add delay to an interface

Use Linux traffic control `tc` and _NetEm_ to add delay or simulate other network issues on an interface. The `tc` operations require the `NET_ADMIN` capability to be added to the container when it's created (otherwise getting `RTNETLINK answers: Operation not permitted`). See details at https://srtlab.github.io/srt-cookbook/how-to-articles/using-netem-to-emulate-networks.html

### Install `tc`
Install the `tc` tool within the container. We can build a whole new image with a `Dockerfile` or simply add the installation steps to the container's entrypoint if its user is `root` or it can `sudo`.
* On a Red Hat or Fedora based image (excluding UBI): `dnf update -y && dnf install -y iproute-tc`
* On a Debian based image: `apt update && apt-get install -y iproute2`

### Use `tc`
A container running locally usually have two interfaces: `lo` and `eth0`. Add delay to the `lo` interface to have an impact on a port published to the host:
* Run `tc qdisc add dev lo root netem delay 50ms` - as root - inside the container

Use interface `eth0` to add delay between containers attached to the same internal network:
* Run `tc qdisc add dev eth0 root netem delay 50ms` - as root - inside the container

> [!NOTE]
> With Docker Desktop use `eth0` in both case.

Also:
* Check status: `tc qdisc show`
* Remove delay: `tc qdisc del dev lo root`

### Try with PostgreSQL

Start the container with published database port `5432`:

`podman run -d --name mypostgres --cap-add NET_ADMIN -p 5432:5432 -e POSTGRES_PASSWORD=secret postgres:17.4`

Check that a `SELECT 1` is quick (<1ms) by default. We enable `\timing`, so `psql` logs the execution time:

* If you have `psql` installed on your laptop:<br>
`PGPASSWORD=secret psql -h localhost -p 5432 -U postgres postgres -c "\timing" -c "SELECT 1"`

* Or use `psql` within the container:<br>
`podman exec -it mypostgres sh -c 'psql -h 127.0.0.1 -p 5432 -U postgres postgres -c "\timing" -c "SELECT 1"'`

Let's install `tc` and add delay to the `lo` interface:

`podman exec -it mypostgres sh -c 'apt update && apt-get install -y iproute2 && tc qdisc add dev lo root netem delay 50ms'`

Run `SELECT 1` again, it should report ~100ms execution time because of the added network delay. 

### Try two containers on the same network

Run a container with delay on `eth0` and ping it from another container on the same internal network:

```
$ podman run -d --name fedora --net mynetwork --cap-add NET_ADMIN fedora:42 sh -c 'dnf install -y iproute-tc && tc qdisc add dev eth0 root netem delay 50ms && sleep infinity'

$ podman run --rm -it --name ping --net mynetwork fedora:42 sh -c 'dnf install iputils -y && ping fedora'
```
Expect to see the configured ~50ms ping time.

### Try a whole YugabyteDB cluster

[YugabyteDB](https://www.yugabyte.com/) is a distributed PostgreSQL-compatible database. The [yugabytedb-cluster.sh](yugabytedb-cluster.sh) script creates a whole db cluster in containers simulating a five node database distributed in two different regions/datacenters with network latency in between:
* Bash script uses `podman` commands, run `alias podman=docker` to use Docker 
* Region-A has `db-node1-2`. Region-B has `db-node3-5` with network latency.
* Port of `db-node1` are published to host, to connect with `psql` or a test app
* `SELECT` is quick as there is no latency on `db-node1`
* `INSERT` is slow because we enforced replication to the nodes "in the other region"

_Thanks to [Gus Reyna](https://github.com/gr-yb) for all the contribution._

#### Original use case

Here is a quick note about a real world problem we managed to replicate and resolve using local containers as explained above. We experienced significant performance degradation with a Spring Boot application caused by longer than expected execution time for inserting hundreds of rows in a database.

Creating a YugabyteDB cluster with network delays matching the production environment in containers made it possible to do an in depth analysis and debugging on our local laptops. The tools available in development _inner loop_ accelerates investigation and results in a quick feedback loop for developers trying different approaches to fix the root cause of the problem.

In this special case we found that enabling [batch inserts](https://www.baeldung.com/spring-data-jpa-batch-inserts) was not enough to achieve performance improvement due to the distributed nature of the database, but we had to add `reWriteBatchedInserts=true` in our [`postgresql` JDBC connection string](https://jdbc.postgresql.org/documentation/use/#connection-parameters) to merge `INSERT` statements.

## <a name="troubleshooting">Troubleshooting</a>

The `tc qdisc` commands above require the `sch_netem` [Network Emulator](https://man7.org/linux/man-pages/man8/tc-netem.8.html) kernel module to add delay to network interfaces. It's a common problem to run into `Specified qdisc not found` error first if this kernel module is not available on your host. As the kernel is shared between containers, you need to enable the kernel module on your Linux host or within the Linux VM on Mac/Windows as explained below.

### Podman Desktop

On Windows you need to use Podman with _Hyper-V_ backend instead of _Windows Subsystem for Linux - WSL2_. Make sure that [Hyper-V is enabled on your machine](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/install-hyper-v?pivots=windows) and select _Hyper-V_ as the virtualization provider during installation. You need local admin permissions.

The Linux VM [machine](https://github.com/containers/podman-machine-os/tree/main) used by Podman Desktop is based on _Fedora CoreOS_. See available [images](https://quay.io/repository/podman/machine-os?tab=tags) and [repo](https://github.com/containers/podman-machine-os/tree/main) for details. Currently image `v5.3` is used by default, but you can enforce a specific version as `podman machine init --image docker://quay.io/podman/machine-os:5.5`.

To enable the `sch_netem` kernel module, get a shell inside the VM with `podman machine ssh`. 
* The `sudo modprobe sch_netem` command will probably drop an error indicating that the module is missing. 
* Install it via `sudo rpm-ostree install kernel-modules-extra`.
* Remove the default config blocking auto-load for this kernel module (this is a dangerous module if you think about it): `sudo rm /etc/modprobe.d/sch_netem-blacklist.conf`
* Enable loading kernel module on startup: `sudo sh -c 'echo sch_netem >/etc/modules-load.d/sch_netem.conf'`

Exit and restart the VM with `podman machine stop; podman machine start`. The `sch_netem` kernel module should be running now, check `lsmod | grep sch_netem`.

### Docker Desktop

On Windows you need to use Docker Desktop with _Hyper-V_ backend instead of _Windows Subsystem for Linux - WSL2_. Make sure that [Hyper-V is enabled on your machine](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/install-hyper-v?pivots=windows) and turn off [Use WSL 2 based engine](https://docs.docker.com/desktop/features/wsl/) in `Settings/General`. You need local admin permissions.

The Linux VM machine created by Docker Desktop - on Mac or Windows - should have the `sch_netem` kernel module by default, so no additional steps are needed to enable it. To verify, [get a shell in the VM](https://gist.github.com/BretFisher/5e1a0c7bcca4c735e716abf62afad389). The easiest seems to be to run `docker run -it --rm --privileged --pid=host justincormack/nsenter1`. Try `modprobe sch_netem`, no error message indicates that the module is available.

## Using Pods instead of a single container

If we can't install the `tc` tool directly in the main container image (e.g. using Red Hat Universal Base Image), we can run the `tc` command in another container attached to the same container network namespace. Podman supports the concept of _Pods_ for such purposes, similarly to Kubernetes. Containers in the same Pod share the same network interface, so the network latency set in one container has an impact on the whole Pod. 

For example, add latency to a published port:

```
# Create a Pod with published port
podman pod create -p 5432:5432 mypod

# Run a container with "tc" tool in the Pod
podman run --pod mypod -it --rm --cap-add NET_ADMIN fedora:42 sh -c 'dnf install -y iproute-tc && tc qdisc add dev lo root netem delay 50ms'

# Run the main container in the Pod
podman run --pod mypod -d -e POSTGRES_PASSWORD=secret postgres:17.4

# Check longer query time
PGPASSWORD=secret psql -h localhost -p 5432 -U postgres postgres -c "\timing" -c "SELECT 1"
```

Similarly, increase ping between containers:

```
# Create a Pod
podman pod create --network mynetwork mypod

# Run a container with "tc" tool in the Pod
podman run --pod mypod -it --rm --cap-add NET_ADMIN fedora:42 sh -c 'dnf install -y iproute-tc && tc qdisc add dev eth0 root netem delay 50ms'

# Run the main container in the Pod
podman run --pod mypod -d redhat/ubi9 sh -c 'sleep infinity'

# Hostname to ping is the Pod's name in this case
podman run --rm -it --name ping --net mynetwork fedora:42 sh -c 'dnf install iputils -y && ping mypod'
```

Docker doesn't support Pods the same way, but we can achieve a similar result with `--network container:[name]`:

```
# Run main container
docker run -d --name mypostgres -p 5432:5432 -e POSTGRES_PASSWORD=secret postgres:17.4

# Run another container attached to first container's network namespace
docker run -it --rm --network container:mypostgres --cap-add NET_ADMIN fedora:42 sh -c 'dnf install -y iproute-tc && tc qdisc add dev eth0 root netem delay 50ms'
```

Ping example with Docker:

```
# Run main container
docker run --network mynetwork --name ubi -d redhat/ubi9 sh -c 'sleep infinity'

# Run another container attached to the first container's network namespace
docker run --network container:ubi -it --rm --cap-add NET_ADMIN fedora:42 sh -c 'dnf install -y iproute-tc && tc qdisc add dev eth0 root netem delay 50ms'

# Test ping time on the same local network
docker run --network mynetwork --rm -it fedora:42 sh -c 'dnf install iputils -y && ping ubi'
```
