# kubevirt-infra

Code for a single-node **management cluster** that runs virtual machines with
KubeVirt and provisions **workload Kubernetes clusters** (k3s + Cilium) on those
VMs through a Crossplane API, one VLAN per cluster.

```
                       Hetzner host (Ubuntu 26.04, enp5s0)
┌──────────────────────────────────────────────────────────────────────────────┐
│  k3s (embedded etcd) ─ Cilium CNI + kube-proxy replacement + Hubble          │
│   ├─ Gateway API (Cilium, host network) ─ Gateway gateway/homelab on :80     │
│   ├─ Multus, KubeVirt + CDI ─ golden image vm-images/ubuntu-2404             │
│   └─ Crossplane 2 ─ KubernetesCluster API (crossplane/)                      │
│                                                                              │
│  br-vms (VLAN-aware bridge)                         NAT ──► internet         │
│   ├─ untagged   192.168.100.0/24  gw br-vms      test-vm                     │
│   ├─ VLAN 110   192.168.110.0/24  gw br-vms.110  cluster-a: cp .10, wk .11-.12│
│   └─ VLAN 120   192.168.120.0/24  gw br-vms.120  cluster-b: cp .10, wk .11-.12│
└──────────────────────────────────────────────────────────────────────────────┘
```

## Quick start

On the management host, as root:

```bash
apt-get install -y make ansible     # or: make deps (needs make)
make all                            # host + k3s + platform
make test-vm                        # smoke test: clone, boot, static IP, SSH, internet
make test-vm-delete
make clusters                       # workload clusters from clusters/*/cluster.yaml
make network-test                   # allowed + blocked network paths
make status
```

`make help` lists every target. All playbooks are idempotent; re-running a
target converges the host back to the code.

| Target | What it does |
|---|---|
| `host` | Package upgrades, sysctls, CNI plugins, VM bridge `br-vms`, NAT (`vm-nat.service`), UFW rules, helm/virtctl, host SSH key for VMs |
| `k3s` | k3s with `ansible/templates/k3s-config.yaml.j2` (no flannel, kube-proxy, traefik, servicelb), Gateway API CRDs and Cilium |
| `platform` | Multus, KubeVirt, CDI, VM network, golden image, Crossplane + functions + RBAC, Gateway |
| `vendor` | Re-download pinned upstream manifests into `platform/*/upstream` |
| `validate` | Render every kustomization without touching the cluster |
| `crossplane-api` | Apply the `KubernetesCluster` XRD + Composition only |
| `clusters` | Check clusters against `site.yml`, apply API + clusters (SSH keys injected), wait Ready |
| `kubeconfig CLUSTER=…` | Write `~/.kube/<cluster>.kubeconfig` |
| `network-test` | From each control plane: internet + other clusters reachable, host/management blocked |
| `clusters-delete` | **Destructive.** Delete all workload clusters and their disks (`CONFIRM=yes`) |
| `k3s-uninstall` | **Destructive.** Removes k3s and every VM (`CONFIRM=yes`) |

## Layout

```
ansible/
  group_vars/all/versions.yml   pinned versions (single place to upgrade)
  group_vars/all/site.yml       host IP/interface, CIDRs, VM network, admin IPs
  playbooks/                    host, k3s, platform, vendor, test-vm, clusters, network-test
  templates/                    k3s config, cloud-init user/network data, network check
platform/
  cilium/values.yaml            Helm values
  gateway-api/                  vendored Gateway API CRDs (standard channel)
  gateway/                      shared Gateway (HTTP :80)
  multus/                       vendored thick-plugin manifest + patches
  kubevirt/{operator,config}/   vendored operator + KubeVirt CR
  cdi/{operator,config}/        vendored operator + CDI CR
  vm-network/                   NetworkAttachmentDefinition for br-vms
  images/                       golden image DataVolume + clone RBAC
  crossplane/                   Helm values, functions, RBAC
vms/test-vm/                    smoke-test VM
crossplane/                     KubernetesCluster XRD + Composition
clusters/<name>/                namespace + quota, KubernetesCluster
```

## Workload clusters

A cluster is one namespaced `KubernetesCluster` (`clusters/cluster-a/cluster.yaml`):

```yaml
apiVersion: platform.kubvirt-infra.io/v1alpha1
kind: KubernetesCluster
metadata: {name: cluster-a, namespace: cluster-a}
spec:
  running: true                     # false: stop the VMs, keep the disks
  network:
    vlanId: 110
    subnet: 192.168.110.0/24        # host is .1; nodes from nodeIPStart (10)
    loadBalancerRange: {start: 200, stop: 220}
    podCIDR: 10.110.0.0/16
    serviceCIDR: 10.111.0.0/16
  cilium: {clusterId: 1}            # unique per cluster (Cluster Mesh-ready)
  controlPlane: {replicas: 1, cpu: 2, memory: 4Gi, diskSize: 20Gi}
  workers: {replicas: 2, cpu: 4, memory: 8Gi, diskSize: 40Gi}
```

`kubectl get kubernetescluster -A` shows phase, API endpoint and nodes.
`make clusters` writes each kubeconfig to `/root/.kube/<name>.kubeconfig` and
merges them with the management cluster's into `/root/.kube/config` (login
shells' `KUBECONFIG`), so `kubectx cluster-a` / `kubectl --context cluster-a`
work; the management context is `default`. `kubeconfig-merge.path` rebuilds the
file when k3s rewrites `/etc/rancher/k3s/k3s.yaml`. The
composition (`crossplane/composition.yaml`, function-go-templating) creates, in
the cluster's namespace:

* `vm-net`: bridge CNI on `br-vms` with the cluster's VLAN and MAC spoof check.
* the k3s join token (generated once) and a cloud-init Secret per node: static
  IP/MAC derived from the subnet, k3s server or agent.
* one `VirtualMachine` per node, disk cloned from the golden image, single NIC
  on `vm-net` (the guest is not on the pod network).
* a Job that waits until all nodes are Ready, then stores the kubeconfig in
  `<name>-kubeconfig`. The XR is Ready once that Job completes.

Inside the VMs, k3s runs without flannel/kube-proxy/traefik/servicelb. k3s's
helm-controller installs Cilium at boot (kube-proxy replacement, Hubble, LB IPAM
with L2 announcements from `loadBalancerRange`).

Validation (CEL in `crossplane/xrd.yaml`): /24 subnet, node IPs and LB range in
the subnet and not overlapping, `vlanId`/`subnet`/CIDRs/`clusterId` immutable.
Scaling `workers.replicas` (0-8) is supported.

**Adding a cluster:** add its VLAN to `vm_vlans` in `site.yml`, `make host`,
add `clusters/<name>/{namespace,cluster}.yaml`, `make clusters`.

## Exposing apps (Gateway API)

Cilium implements Gateway API in **host network mode**: Envoy listens on the
host's port 80 for `Gateway gateway/homelab`, so UFW applies (only
`admin_sources` can connect; VMs cannot). An app is exposed with an
`HTTPRoute` in its own namespace:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: my-app, namespace: my-app}
spec:
  parentRefs: [{name: homelab, namespace: gateway, sectionName: http}]
  hostnames: [my-app.homelab.local]
  rules: [{backendRefs: [{name: my-app, port: 8080}]}]
```

`*.homelab.local` is not in public DNS: add `<node_ip>  my-app.homelab.local`
to `/etc/hosts` on the workstation.

## Versions

Edit `ansible/group_vars/all/versions.yml`, then run `make vendor` (for Multus,
KubeVirt, CDI) and the matching target. Two pins live next to what they pin:
the Crossplane function packages (`platform/crossplane/functions.yaml`) and the
Ubuntu image build (`platform/images/ubuntu-2404.yaml`).

## Networking

* **Pods:** Cilium, `10.42.0.0/16`; services `10.43.0.0/16`.
* **VMs:** one NIC on `br-vms` (Multus secondary network, KubeVirt bridge
  binding), one bridge port per VM. The virt-launcher pod keeps its Cilium pod
  network; the VM does not use it. Addresses are static, set by cloud-init from
  the VM's fixed MAC.
* **VLANs:** `br-vms` filters VLANs. Each workload cluster's VM ports are
  access ports of its VLAN; the host has a gateway interface `br-vms.<id>` on
  `.1` per VLAN (`vm_vlans` in `site.yml`). The untagged network (PVID 1,
  `192.168.100.0/24`) is used by the test VM.
* **Firewall (UFW):** inbound to the host only from `admin_sources`.

  | From | To | |
  |---|---|---|
  | VMs | internet | allowed, NAT via `enp5s0` |
  | VMs | VMs in the same VLAN | allowed (bridged) |
  | cluster VLAN | other cluster VLANs | allowed, routed without NAT |
  | VMs | host services, management pods/services | **blocked** (explicit deny first) |
  | management pods | VMs | allowed |
* The host reaches VMs directly: `ssh -i /root/.ssh/vm_ed25519 ubuntu@<vm-ip>`.
  From a workstation: `ssh -J root@<host> ubuntu@<vm-ip>`.

## Security notes

* Nothing secret is committed. Kubeconfigs, private keys and cloud-init secrets
  are generated on the host (see `.gitignore`).
* Expose HTTP apps through the Gateway (above), not Services.
* Cilium's kube-proxy replacement handles NodePort/LoadBalancer traffic in eBPF
  **before UFW sees it**. Do not create NodePort or LoadBalancer services on the
  management cluster unless they are meant to be public.
* k3s's API (6443) is not opened in UFW; add it to `admin_tcp_ports` to use
  kubectl from a workstation.

## Gotchas encoded here

* With `flannel-backend: none`, k3s's containerd uses the standard CNI paths
  (`/etc/cni/net.d`, `/opt/cni/bin`), so the upstream CNI plugins are installed
  there for Multus' `bridge` delegate.
* `kubernetes.core.helm` does not support Helm 4 yet; playbooks call
  `helm upgrade --install` directly.
* `local-path` is `WaitForFirstConsumer`; the golden image requests immediate
  binding so it imports without a VM.
