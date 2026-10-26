SHELL := /bin/bash
export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg
export KUBECONFIG ?= /etc/rancher/k3s/k3s.yaml

PLAY := ansible-playbook
PLAYBOOKS := ansible/playbooks

.DEFAULT_GOAL := help
.PHONY: help deps vendor validate host k3s platform all test-vm test-vm-delete crossplane-api clusters clusters-delete kubeconfig network-test status k3s-uninstall

help: ## Show this help
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

deps: ## Install Ansible and make on the host (Ubuntu)
	apt-get update && apt-get install -y ansible make

vendor: ## Refresh pinned upstream manifests in platform/*/upstream
	$(PLAY) $(PLAYBOOKS)/vendor.yml

validate: ## Render every kustomization (no cluster changes)
	@for d in $$(find platform vms crossplane -name kustomization.yaml -printf '%h\n' | sort); do \
	  kubectl kustomize $$d >/dev/null && echo "ok  $$d" || { echo "ERR $$d"; exit 1; }; done

host: ## Prepare the host: updates, VM bridge + NAT, firewall, tools
	$(PLAY) $(PLAYBOOKS)/host.yml

k3s: ## Install k3s and Cilium
	$(PLAY) $(PLAYBOOKS)/k3s.yml

platform: ## Install Multus, KubeVirt, CDI, VM network, images, Crossplane
	$(PLAY) $(PLAYBOOKS)/platform.yml

all: host k3s platform ## Build the whole management cluster

test-vm: ## Create the smoke-test VM and check it over SSH
	$(PLAY) $(PLAYBOOKS)/test-vm.yml

test-vm-delete: ## Delete the smoke-test VM
	$(PLAY) $(PLAYBOOKS)/test-vm.yml -e state=absent

crossplane-api: ## Install/update the KubernetesCluster XRD and Composition
	kubectl apply --server-side --force-conflicts -k crossplane

clusters: ## Create/update every cluster in clusters/ and wait until Ready
	$(PLAY) $(PLAYBOOKS)/clusters.yml

clusters-delete: ## DESTRUCTIVE: delete every cluster in clusters/ (CONFIRM=yes)
	@[ "$(CONFIRM)" = yes ] || { echo "This deletes all workload clusters and their disks. Run: make clusters-delete CONFIRM=yes"; exit 1; }
	$(PLAY) $(PLAYBOOKS)/clusters.yml -e state=absent

kubeconfig: ## Write ~/.kube/<CLUSTER>.kubeconfig (CLUSTER=cluster-a)
	@[ -n "$(CLUSTER)" ] || { echo "Usage: make kubeconfig CLUSTER=cluster-a"; exit 1; }
	@umask 077; mkdir -p $(HOME)/.kube
	@kubectl -n $(CLUSTER) get secret $(CLUSTER)-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d > $(HOME)/.kube/$(CLUSTER).kubeconfig
	@/usr/local/bin/kubeconfig-merge
	@echo "Wrote $(HOME)/.kube/$(CLUSTER).kubeconfig, merged into $(HOME)/.kube/config (context $(CLUSTER))"

network-test: ## Check workload-cluster connectivity (allowed and blocked paths)
	$(PLAY) $(PLAYBOOKS)/network-test.yml

status: ## Show cluster, platform and VM status
	@kubectl get nodes -o wide
	@echo; kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium status --brief 2>/dev/null | sed 's/^/cilium: /'
	@echo; kubectl get kubevirt -A; kubectl get cdi
	@echo; kubectl get function
	@echo; kubectl get kubernetescluster -A
	@echo; kubectl get vm,vmi -A

k3s-uninstall: ## DESTRUCTIVE: remove k3s and everything on it (CONFIRM=yes)
	@[ "$(CONFIRM)" = yes ] || { echo "This deletes the cluster and all VMs. Run: make k3s-uninstall CONFIRM=yes"; exit 1; }
	/usr/local/bin/k3s-uninstall.sh
