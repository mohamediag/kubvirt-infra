# kubevirt-infra

Code for a single-node **management cluster** that runs virtual machines with
KubeVirt and (phase 2) provisions **workload Kubernetes clusters** on those VMs
through a Crossplane API.

```
                       Hetzner host (Ubuntu 26.04, enp5s0)
┌──────────────────────────────────────────────────────────────────────────┐
│  k3s (embedded etcd)  ─ Cilium CNI + kube-proxy replacement + Hubble     │
│   ├─ Multus ─ NAD default/vm-net ──► br-vms 192.168.100.1/24 ──NAT──► internet
│   ├─ KubeVirt + CDI ─ golden image vm-images/ubuntu-2404                 │
│   └─ Crossplane 2 (+ function-go-templating, function-auto-ready)        │
│                                                                          │
│   VMs (bridge on br-vms, static IP via cloud-init)                       │
│     cluster-a: cp + 2 workers      cluster-b: cp + 2 workers   (phase 2) │
└──────────────────────────────────────────────────────────────────────────┘
```

## Quick start

On the management host, as root:

```bash
apt-get install -y make ansible     # or: make deps (needs make)
make all                            # host + k3s + platform
make test-vm                        # smoke test: clone, boot, static IP, SSH, internet
make test-vm-delete
make status
```

`make help` lists every target. All playbooks are idempotent; re-running a
target converges the host back to the code.

| Target | What it does |
|---|---|
| `host` | Package upgrades, sysctls, CNI plugins, VM bridge `br-vms`, NAT (`vm-nat.service`), UFW rules, helm/virtctl, host SSH key for VMs |
| `k3s` | k3s with `ansible/templates/k3s-config.yaml.j2` (no flannel, kube-proxy, traefik, servicelb) and Cilium |
| `platform` | Multus, KubeVirt, CDI, VM network, golden image, Crossplane + functions + RBAC |
| `vendor` | Re-download pinned upstream manifests into `platform/*/upstream` |
| `validate` | Render every kustomization without touching the cluster |
| `k3s-uninstall` | **Destructive.** Removes k3s and every VM (`CONFIRM=yes`) |

## Layout

```
ansible/
  group_vars/all/versions.yml   pinned versions (single place to upgrade)
  group_vars/all/site.yml       host IP/interface, CIDRs, VM network, admin IPs
  playbooks/                    host, k3s, platform, vendor, test-vm
  templates/                    k3s config, cloud-init user/network data
platform/
  cilium/values.yaml            Helm values
  multus/                       vendored thick-plugin manifest + patches
  kubevirt/{operator,config}/   vendored operator + KubeVirt CR
  cdi/{operator,config}/        vendored operator + CDI CR
  vm-network/                   NetworkAttachmentDefinition for br-vms
  images/                       golden image DataVolume + clone RBAC
  crossplane/                   Helm values, functions, RBAC
vms/test-vm/                    smoke-test VM
crossplane/                     workload-cluster API (phase 2)
```

## Versions

Edit `ansible/group_vars/all/versions.yml`, then run `make vendor` (for Multus,
KubeVirt, CDI) and the matching target. Two pins live next to what they pin:
the Crossplane function packages (`platform/crossplane/functions.yaml`) and the
Ubuntu image build (`platform/images/ubuntu-2404.yaml`).

## Networking

* **Pods:** Cilium, `10.42.0.0/16`; services `10.43.0.0/16`.
* **VMs:** one NIC on `br-vms` (Multus secondary network `default/vm-net`,
  KubeVirt bridge binding). The virt-launcher pod keeps its Cilium pod network;
  the VM does not use it. Addresses are static, set by cloud-init from the
  VM's fixed MAC. Gateway `192.168.100.1`, NAT out of `enp5s0`.
* **Firewall (UFW):** inbound to the host only from `admin_sources`; VMs may
  reach the internet and each other but not services on the host; pods may
  reach VMs.
* The host reaches VMs directly: `ssh -i /root/.ssh/vm_ed25519 ubuntu@<vm-ip>`.
  From a workstation: `ssh -J root@<host> ubuntu@<vm-ip>`.

## Security notes

* Nothing secret is committed. Kubeconfigs, private keys and cloud-init secrets
  are generated on the host (see `.gitignore`).
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
