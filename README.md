Simulate network delays using containers
========================================

Some real world use cases can be challenging to test as a developer. With limited resources and permissions sometimes we can't reproduce issues that we face in a QA or production environments, which makes debugging and fixing them cumbersome. In this post we'll take a look how to use containers to simulate the impact of network latency on a distributed database cluster using only a single laptop.

Generally, it's a good idea to utilize containers on a local environment - inner loop - to test how your application works in a production like environment in certain situations (e.g. limited resource availability, network issues...).

If you have a Linux host, you can use `podman` or `docker` directly to spin up containers, on Mac or Windows you'll need [Podman Desktop](https://podman-desktop.io/) or [Docker Desktop](https://www.docker.com/products/docker-desktop/) that creates a Linux VM under to hood run containers.

See https://srtlab.github.io/srt-cookbook/how-to-articles/using-netem-to-emulate-networks.html


## Troubleshooting

The `tc qdisc` commands above require the `sch_netem` [Network Emulator](https://man7.org/linux/man-pages/man8/tc-netem.8.html) kernel module to add delay to network interfaces. It's a common problem to run into `Specified qdisc not found` error first if this kernel module is not available on your host. As the kernel is shared between containers, you need to enable the kernel module on your Linux host or within the Linux VM on Mac/Windows as explained below.

### Podman Desktop

On Windows you need to use Podman with _Hyper-V_ backend instead of _Windows Subsystem for Linux - WSL2_. Make sure that [Hyper-V is enabled on your machine](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/install-hyper-v?pivots=windows) and select _Hyper-V_ as the virtualization provider during installation. You need local admin permissions.

The Linux VM [machine](https://github.com/containers/podman-machine-os/tree/main) used by Podman Desktop is based on _Fedora CoreOS_. See available [images](https://quay.io/repository/podman/machine-os?tab=tags) and [repo](https://github.com/containers/podman-machine-os/tree/main) for details. Currently image `v5.3` is used by default, but you can enforce a specific version as `podman machine init --image docker://quay.io/podman/machine-os:5.5`.

To enable the `sch_netem` kernel module, get a shell inside the VM with `podman machine ssh`. The `sudo modprobe sch_netem` command will probably drop an error indicating that the module is missing. Install it via `sudo rpm-ostree install kernel-modules-extra`, exit and restart the VM with `podman machine stop; podman machine start`. The `sch_netem` kernel module should be available now.

### Docker Desktop

On Windows you need to use Docker Desktop with _Hyper-V_ backend instead of _Windows Subsystem for Linux - WSL2_. Make sure that [Hyper-V is enabled on your machine](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/install-hyper-v?pivots=windows) and turn off [Use WSL 2 based engine](https://docs.docker.com/desktop/features/wsl/) in `Settings/General`. You need local admin permissions.

The Linux VM machine created by Docker Desktop - on Mac or Windows - should have the `sch_netem` kernel module by default, so no additional steps are needed to enable it. To verify, [get a shell in the VM](https://gist.github.com/BretFisher/5e1a0c7bcca4c735e716abf62afad389). The easiest seems to be to run `docker run -it --rm --privileged --pid=host justincormack/nsenter1`. Try `modprobe sch_netem`, no error message indicates that the module is available.