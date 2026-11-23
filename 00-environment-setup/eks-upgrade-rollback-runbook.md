# Amazon EKS Upgrade and Rollback Runbook

A practical runbook for upgrading an EKS cluster's Kubernetes version, updating every dependent component, rolling back if something breaks, and handling emergencies.

> **How to use this runbook**
> 1. Read Sections 1–2 once, calmly, well before the upgrade day.
> 2. On upgrade day, follow Sections 3–5 in order and tick the checkboxes.
> 3. If something breaks, go to Section 6 (rollback) or Section 7 (emergency commands).
>
> All commands come from the AWS EKS documentation. Flags and versions change over time, so **verify against the current docs before running anything in production**, and always rehearse in staging first. Values in `<angle brackets>` are placeholders.

---

## 0. Set your variables (do this first in every terminal)

```bash
export CLUSTER=<cluster-name>
export REGION=<region-code>            # e.g. ap-south-1
export CURRENT_VERSION=<current-k8s>   # e.g. 1.35
export TARGET_VERSION=<target-k8s>     # exactly ONE minor above current, e.g. 1.36
export NODEGROUP=<managed-nodegroup-name>

aws sts get-caller-identity            # confirm you are in the right AWS account
aws eks update-kubeconfig --name $CLUSTER --region $REGION
kubectl config current-context         # confirm you are pointing at the right cluster
```

> **Safety habit:** run the last two commands every time. Most production accidents are "wrong cluster, right command".

---

## 1. Rules you must know before upgrading

| Rule | Detail |
|---|---|
| **One minor version at a time** | You can upgrade the control plane only one minor version per upgrade (1.34 → 1.35 → 1.36). To jump three versions, run the process three times. |
| **Order matters** | Control plane → nodes → apps on the cluster (e.g. cluster-autoscaler) → EKS add-ons (VPC CNI, CoreDNS, kube-proxy) → clients (`kubectl`). |
| **Upgrade cannot be paused** | Once started, you cannot pause or stop a control plane upgrade. If EKS's own health checks fail, it reverts the infrastructure change and the cluster stays on the old version. |
| **Rollback window** | You can roll the control plane back by **one minor version within 7 days** of the upgrade completing. After 7 days, the only way back is a new cluster on the old version plus workload migration. |
| **Add-ons are not auto-updated** | EKS does not update add-ons after a cluster version upgrade. You initiate each one. |
| **Version skew** | Nodes (kubelet) may be up to 3 minor versions older than the control plane (Kubernetes 1.28+). Nodes can never be newer than the control plane. `kubectl` must be within one minor version of the control plane. |
| **Lifecycle** | A version gets 14 months of standard support, then 12 months of extended support (extra charge). After 26 months the cluster is auto-upgraded. About three minor versions release per year. |
| **IP addresses** | The control plane upgrade needs up to 5 free IP addresses in your cluster subnets. |

---

## 2. Pre-upgrade checklist (T-30 days to T-1 hour)

### 2.1 Planning (days before)

- [ ] Check the EKS release calendar and your cluster's end-of-standard-support date.
- [ ] Read the Kubernetes release notes for the target version (removed APIs, behaviour changes).
- [ ] Read the EKS version page for the target version (platform notes).
- [ ] Schedule a maintenance window, notify the team, name an owner and a backup person.
- [ ] Upgrade **dev → staging first**, wait several days, then prod.

### 2.2 Current state

```bash
# Control plane version, status, and platform version
aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query "cluster.{version:version,status:status,platform:platformVersion}"

# Cluster must be ACTIVE (not UPDATING / FAILED)
aws eks describe-cluster --name $CLUSTER --query "cluster.status" --output text

# Kubernetes versions: client, control plane, nodes
kubectl version
kubectl get nodes -o wide

# Everything healthy before we touch anything?
kubectl get pods -A | grep -v -E "Running|Completed"
kubectl get nodes | grep -v " Ready"
```

All pods should be healthy and all nodes `Ready`. **Do not upgrade an unhealthy cluster.**

### 2.3 Upgrade insights (deprecated API usage and other blockers)

```bash
# List upgrade-readiness insights
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter '{"categories": ["UPGRADE_READINESS"]}'

# Details of one insight
aws eks describe-insight --cluster-name $CLUSTER --region $REGION --id <insight-id>

# Force a refresh after fixing issues (insights refresh every 24h by default)
aws eks start-insights-refresh --cluster-name $CLUSTER --region $REGION
```

Notes:
- Fix every `ERROR` insight before upgrading.
- Insights scan deprecated API usage over a rolling **30-day window**, so a fixed issue can take time to clear. Confirm the actual cause in your manifests.
- Optional third-party tools to scan manifests/Helm releases for removed APIs: `kubent` (kube-no-trouble) and `pluto`.

Check deprecated API calls directly on the API server (needs permission):

```bash
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
```

### 2.4 Node and add-on versions

```bash
# Managed node groups and their versions
aws eks list-nodegroups --cluster-name $CLUSTER --region $REGION
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP \
  --query "nodegroup.{version:version,release:releaseVersion,status:status}"

# Are the nodes on the same minor version as the control plane? (best practice)
kubectl get nodes

# Installed EKS add-ons
aws eks list-addons --cluster-name $CLUSTER --region $REGION
eksctl get addon --cluster $CLUSTER --region $REGION

# Which add-on versions are compatible with the TARGET Kubernetes version?
for A in vpc-cni coredns kube-proxy; do
  echo "== $A =="
  aws eks describe-addon-versions --kubernetes-version $TARGET_VERSION --addon-name $A \
    --query "addons[0].addonVersions[].addonVersion" --output text
done
```

Find out whether each add-on is the **EKS-managed** type or **self-managed**:

```bash
aws eks describe-addon --cluster-name $CLUSTER --addon-name vpc-cni    --query addon.addonVersion --output text
aws eks describe-addon --cluster-name $CLUSTER --addon-name coredns    --query addon.addonVersion --output text
aws eks describe-addon --cluster-name $CLUSTER --addon-name kube-proxy --query addon.addonVersion --output text
```

- A version number is returned → it is the **EKS add-on type** (use Section 4.1).
- An error is returned → it is **self-managed** (use Section 4.2).

### 2.5 Workload readiness

```bash
# Pod Disruption Budgets: a too-strict PDB can block node drains
kubectl get pdb -A

# Single-replica deployments will have downtime during node drains
kubectl get deploy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,REPLICAS:.spec.replicas

# Pods without a controller (bare pods) are NOT rescheduled after a drain
kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.ownerReferences==null) | "\(.metadata.namespace)/\(.metadata.name)"'
```

- [ ] Critical apps run **2+ replicas** spread across nodes/AZs.
- [ ] PDBs exist for critical apps and do not block draining (for example `minAvailable` equal to the replica count blocks it).
- [ ] Readiness and liveness probes are configured.
- [ ] No important bare pods.

### 2.6 Backups and safety nets

```bash
# Save the cluster state as manifests (not a full backup, but a useful snapshot)
mkdir -p backup-$(date +%F) && cd backup-$(date +%F)
kubectl get all,cm,ingress,pvc,pv,sa,networkpolicy,pdb -A -o yaml > cluster-resources.yaml
kubectl get daemonset aws-node -n kube-system -o yaml > aws-node-before.yaml
kubectl get deployment coredns -n kube-system -o yaml > coredns-before.yaml
kubectl get daemonset kube-proxy -n kube-system -o yaml > kube-proxy-before.yaml
helm list -A > helm-releases-before.txt
aws eks describe-cluster --name $CLUSTER > cluster-before.json
```

- [ ] Application manifests are in Git (source of truth).
- [ ] Database snapshot taken (RDS manual snapshot), and persistent volume snapshots if you have stateful apps.
- [ ] Optional: back up the cluster with **AWS Backup for EKS** (restores cluster state and persistent storage).
- [ ] Note the current add-on versions (you may need them for a rollback).

### 2.7 Upgrade policy and cost

```bash
# STANDARD = auto-upgrade at end of standard support; EXTENDED = stay, but pay extra
aws eks describe-cluster --name $CLUSTER --query "cluster.upgradePolicy.supportType" --output text
```

To change the policy (verify the exact syntax in the current docs):

```bash
aws eks update-cluster-config --name $CLUSTER --upgrade-policy supportType=EXTENDED
aws eks update-cluster-config --name $CLUSTER --upgrade-policy supportType=STANDARD
```

### 2.8 Infrastructure as Code

If the cluster is managed by Terraform, CloudFormation or eksctl config files, plan to **update the version in code to match** right after the upgrade, otherwise the next apply may try to revert or fail. A CloudFormation stack rollback does **not** roll back the cluster version.

---

## 3. Upgrade procedure

### Step 1. Upgrade the control plane

Pick one method.

**Option A: eksctl** (requires a recent eksctl; check with `eksctl version`)

```bash
eksctl upgrade cluster --name $CLUSTER --region $REGION --version $TARGET_VERSION --approve
```

**Option B: AWS CLI**

```bash
aws eks update-cluster-version --name $CLUSTER --region $REGION --kubernetes-version $TARGET_VERSION
# Copy the "id" from the output, then watch it:
aws eks describe-update --name $CLUSTER --region $REGION --update-id <update-id>
```

**Option C: Console:** EKS → Clusters → your cluster → **Upgrade now** → choose the version → Upgrade.

It takes several minutes. Monitor:

```bash
aws eks list-updates --name $CLUSTER --region $REGION
aws eks describe-update --name $CLUSTER --region $REGION --update-id <update-id>
# Done when status = Successful

aws eks describe-cluster --name $CLUSTER --query "cluster.{version:version,status:status}"
kubectl version
```

During the upgrade, the API server endpoint stays available (rolling replacement), but clients may need to reconnect. Recent `kubectl` and client libraries handle this.

> ### ⏱ Decision point: start of the 7-day rollback window
> Rolling back is simplest while nodes are still on the **old** version, because you will not have to roll nodes back. A sensible approach is to observe the new control plane for a while (with monitoring open) before upgrading nodes. Decide this with your team. Do not leave nodes behind indefinitely, and finish within your support and skew limits.

### Step 2. Upgrade the nodes (data plane)

The node version cannot be greater than the control plane version. Upgrade nodes to the **same minor version as the control plane.**

**Managed node groups (eksctl)**

```bash
eksctl upgrade nodegroup --name=$NODEGROUP --cluster=$CLUSTER --region=$REGION --kubernetes-version=$TARGET_VERSION
```

**Managed node groups (AWS CLI)**

```bash
aws eks update-nodegroup-version --cluster-name $CLUSTER --nodegroup-name $NODEGROUP \
  --kubernetes-version $TARGET_VERSION --region $REGION

# Watch it (node group updates have their own update ID)
aws eks describe-update --name $CLUSTER --nodegroup-name $NODEGROUP --update-id <update-id>
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --query "nodegroup.status"
```

How it works: nodes are replaced in a rolling fashion; each old node is cordoned and drained, so pods are evicted gracefully and **PDBs are respected**. If a PDB prevents draining, the update fails. Only as a last resort, re-run with `--force` (see Section 7).

Other node types:
- **Update to the latest AMI of the same Kubernetes version:** run the same command without changing the version, or use `--release-version <ami-release-version>`.
- **Self-managed nodes:** update the AMI / launch template / Auto Scaling Group to the new version's EKS-optimized AMI, then roll the instances (this is your responsibility).
- **Fargate:** delete the Fargate pods so they are recreated on the new version: `kubectl delete pod <pod> -n <ns>` (then redeploy if they are not managed by a controller).
- **EKS Auto Mode:** after the control plane upgrade, EKS updates the managed nodes incrementally and respects PDBs. Nothing to run.

Verify:

```bash
kubectl get nodes -o wide        # all nodes Ready, on the new version
kubectl get pods -A | grep -v -E "Running|Completed"
```

### Step 3. Upgrade applications that run on the cluster

See Section 4.3 (cluster-autoscaler, AWS Load Balancer Controller, and others).

### Step 4. Upgrade EKS add-ons (VPC CNI, CoreDNS, kube-proxy)

See Section 4.1 (EKS-managed) or 4.2 (self-managed).

### Step 5. Upgrade clients

Update your local `kubectl` to be within one minor version of the control plane. Update `eksctl` and AWS CLI if needed.

---

## 4. Component-by-component update commands

**Recommended order for add-ons:** VPC CNI → kube-proxy → CoreDNS (then other add-ons). Always check each add-on's version compatibility with your Kubernetes version first, and update **one component at a time**, verifying after each.

### 4.1 EKS-managed add-ons (recommended type)

General pattern (works for any managed add-on such as `vpc-cni`, `coredns`, `kube-proxy`, `aws-ebs-csi-driver`):

```bash
# 1. What is installed now
aws eks describe-addon --cluster-name $CLUSTER --addon-name <addon> --region $REGION

# 2. What versions are available for the target Kubernetes version
aws eks describe-addon-versions --kubernetes-version $TARGET_VERSION --addon-name <addon> \
  --query "addons[0].addonVersions[].addonVersion" --output text

# 3. Update
aws eks update-addon --cluster-name $CLUSTER --addon-name <addon> \
  --addon-version <version-eksbuild.N> --resolve-conflicts PRESERVE --region $REGION

# 4. Track and verify
aws eks describe-addon --cluster-name $CLUSTER --addon-name <addon> --query "addon.{status:status,version:addonVersion}"
```

`--resolve-conflicts` options:
- `NONE`: EKS does not change any value you modified; the update may fail if there is a conflict.
- `OVERWRITE`: EKS resets modified fields to the EKS defaults (you lose custom settings).
- `PRESERVE`: keeps your custom settings (the usual choice).

#### Amazon VPC CNI (pod networking)

```bash
# Current version
aws eks describe-addon --cluster-name $CLUSTER --addon-name vpc-cni --query "addon.addonVersion" --output text

# Save the current configuration (for rollback and comparison)
kubectl get daemonset aws-node -n kube-system -o yaml > aws-k8s-cni-old.yaml

# See the configuration schema if you use custom settings
aws eks describe-addon-configuration --addon-name vpc-cni --addon-version <version-eksbuild.N>

# Update (add --service-account-role-arn if your add-on uses an IRSA role)
aws eks update-addon --cluster-name $CLUSTER --addon-name vpc-cni \
  --addon-version <version-eksbuild.N> \
  --service-account-role-arn arn:aws:iam::<account-id>:role/<AmazonEKSVPCCNIRole> \
  --resolve-conflicts PRESERVE

# Verify
aws eks describe-addon --cluster-name $CLUSTER --addon-name vpc-cni
kubectl get daemonset aws-node -n kube-system
kubectl rollout status daemonset/aws-node -n kube-system
```

If you pass custom settings, use `--configuration-values`, for example: `--configuration-values '{"env":{"AWS_VPC_K8S_CNI_EXTERNALSNAT":"true"}}'`. Remember `PRESERVE` keeps what is already set; only include values you actually need.

#### kube-proxy

```bash
aws eks describe-addon --cluster-name $CLUSTER --addon-name kube-proxy --query "addon.addonVersion" --output text
kubectl get daemonset kube-proxy -n kube-system -o yaml > kube-proxy-old.yaml

aws eks update-addon --cluster-name $CLUSTER --addon-name kube-proxy \
  --addon-version <version-eksbuild.N> --resolve-conflicts PRESERVE

kubectl rollout status daemonset/kube-proxy -n kube-system
```

#### CoreDNS

```bash
aws eks describe-addon --cluster-name $CLUSTER --addon-name coredns --query "addon.addonVersion" --output text
kubectl get deployment coredns -n kube-system -o yaml > coredns-old.yaml

aws eks update-addon --cluster-name $CLUSTER --addon-name coredns \
  --addon-version <version-eksbuild.N> --resolve-conflicts PRESERVE

kubectl rollout status deployment/coredns -n kube-system

# DNS smoke test
kubectl run dnstest --rm -it --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default
```

#### With eksctl (alternative for any managed add-on)

```bash
eksctl update addon --name <addon> --version <version> --cluster $CLUSTER --region $REGION

# or with a config file
cat > update-addon.yaml <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $CLUSTER
  region: $REGION
addons:
  - name: vpc-cni
    version: latest
    resolveConflicts: preserve
EOF
eksctl update addon -f update-addon.yaml
```

### 4.2 Self-managed add-ons (only if you did NOT install the EKS add-on type)

AWS recommends moving to the EKS add-on type. These steps are for clusters that still self-manage.

#### VPC CNI (self-managed)

```bash
kubectl describe daemonset aws-node --namespace kube-system | grep amazon-k8s-cni: | cut -d : -f 3   # current version
kubectl get daemonset aws-node -n kube-system -o yaml > aws-k8s-cni-old.yaml                          # backup

# No custom settings: apply the release manifest (see "To apply this release" in the GitHub release notes)
curl -O https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/<vX.Y.Z>/config/master/aws-k8s-cni.yaml
# Custom settings: edit the downloaded file to re-apply your settings from aws-k8s-cni-old.yaml first
kubectl apply -f aws-k8s-cni.yaml

kubectl describe daemonset aws-node --namespace kube-system | grep amazon-k8s-cni: | cut -d : -f 3    # confirm
```

If your nodes cannot pull from the EKS ECR registry, copy the image to your own registry and edit the `image:` lines in the manifest.

#### kube-proxy (self-managed)

```bash
kubectl describe daemonset kube-proxy -n kube-system | grep Image
# Example: 602401143452.dkr.ecr.<region>.amazonaws.com/eks/kube-proxy:v1.xx.x-eksbuild.N

kubectl set image daemonset.apps/kube-proxy -n kube-system \
  kube-proxy=<account-id>.dkr.ecr.<region>.amazonaws.com/eks/kube-proxy:<version>

kubectl describe daemonset kube-proxy -n kube-system | grep Image | cut -d ":" -f 3   # confirm
```

Important: use the **same image type** (default or minimal) as the current one. The two types have different entrypoints and are not interchangeable.

#### CoreDNS (self-managed)

```bash
kubectl describe deployment coredns -n kube-system | grep Image | cut -d ":" -f 3     # current version

kubectl set image deployment.apps/coredns -n kube-system \
  coredns=<account-id>.dkr.ecr.<region>.amazonaws.com/eks/coredns:<version>

kubectl describe deployment coredns -n kube-system | grep Image | cut -d ":" -f 3     # confirm
kubectl rollout status deployment/coredns -n kube-system
```

If you move to CoreDNS 1.8.3 or later and your cluster is old, the `system:coredns` ClusterRole needs the `endpointslices` permission (`kubectl edit clusterrole system:coredns`). Check the current CoreDNS self-managed docs for the exact rules.

### 4.3 Other components (if installed)

**Cluster Autoscaler**: match its version to your Kubernetes **minor** version (for 1.36, use a 1.36.x release):

```bash
kubectl -n kube-system set image deployment.apps/cluster-autoscaler \
  cluster-autoscaler=registry.k8s.io/autoscaling/cluster-autoscaler:v<X.Y.Z>
kubectl -n kube-system rollout status deployment/cluster-autoscaler
```

**AWS Load Balancer Controller** (Helm; check its compatibility matrix first):

```bash
helm repo update
helm list -n kube-system
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --version <chart-version> --reuse-values
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system
```

**Anything else** (ingress controllers, EBS/EFS CSI drivers, metrics-server, service mesh, Karpenter, monitoring agents): look up its compatibility matrix for the target Kubernetes version, upgrade in staging first, upgrade one at a time. Managed add-ons such as `aws-ebs-csi-driver` use the Section 4.1 pattern.

**GPU nodes only:** update the NVIDIA device plugin DaemonSet to a version compatible with the new Kubernetes version.

---

## 5. Post-upgrade verification

```bash
# Versions
aws eks describe-cluster --name $CLUSTER --query "cluster.{version:version,status:status}"
kubectl version
kubectl get nodes -o wide

# Cluster health
kubectl get nodes | grep -v " Ready"
kubectl get pods -A | grep -v -E "Running|Completed"
kubectl get events -A --sort-by=.lastTimestamp | tail -30

# System components
kubectl get pods -n kube-system -o wide
kubectl rollout status daemonset/aws-node -n kube-system
kubectl rollout status daemonset/kube-proxy -n kube-system
kubectl rollout status deployment/coredns -n kube-system

# Add-ons
aws eks list-addons --cluster-name $CLUSTER
for A in $(aws eks list-addons --cluster-name $CLUSTER --query "addons[]" --output text); do
  aws eks describe-addon --cluster-name $CLUSTER --addon-name $A --query "addon.{name:addonName,version:addonVersion,status:status}"
done

# DNS and service connectivity
kubectl run dnstest --rm -it --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default
```

Also check:
- [ ] Application health endpoints, error rate and latency in Grafana/CloudWatch (compare with the pre-upgrade baseline).
- [ ] Ingress / load balancers serving traffic; a test deploy works; HPA and autoscaler behave normally.
- [ ] Logs and metrics are still flowing.
- [ ] IaC code updated to the new version; runbook notes updated.
- [ ] Record the **upgrade completion time** (your 7-day rollback window starts here).

---

## 6. Rollback procedure (control plane)

### 6.1 Roll back or fix forward?

- **Roll back** if the new Kubernetes version causes an application incompatibility, a removed or changed API breaks workloads, or you see unexpected cluster behaviour and cannot fix it quickly.
- **Fix forward** (often better) if the problem is a single add-on, a misconfigured manifest, or a node issue. Rolling back the control plane is a bigger operation than fixing one component.
- **Always** preserve evidence first: logs, events, `describe` output.

### 6.2 Prerequisites (all must be true)

| Requirement | Detail |
|---|---|
| Within 7 days | The rollback must start within 7 days of the upgrade completing. |
| In-place upgraded | The cluster must have reached its current version through an in-place upgrade. A cluster created at the current version cannot be rolled back. |
| One minor version only | N → N-1 only. After 1.34 → 1.35 → 1.36 you can only go back to 1.35. |
| Supported version | The target (older) version must still be supported. To roll back to an extended-support version, set the upgrade policy to `EXTENDED` first. |
| Cluster ACTIVE | No other update may be in progress. |
| No end-of-extended-support auto-upgrade | If the cluster was auto-upgraded at the end of extended support, you cannot roll back. |
| Feature compatibility | If an enabled EKS feature is not supported on the older version, the rollback fails (`--force` cannot bypass this). |

### 6.3 What is and is not rolled back

| Rolled back by EKS | NOT rolled back (you must handle) |
|---|---|
| API server version, control plane components, platform version | etcd data (preserved, nothing is lost) |
| EKS Auto Mode nodes (automatically, before the control plane) | EKS add-on versions |
| | Managed node groups (use `update-nodegroup-version`) |
| | Self-managed and hybrid nodes |
| | Fargate (rollback unsupported; delete pods and redeploy) |

Workloads, pods and persistent volumes keep running. **You** remain responsible for confirming that your applications work on the older Kubernetes version.

### 6.4 Rollback steps

**Step 1. Save evidence**

```bash
kubectl get events -A --sort-by=.lastTimestamp > events-$(date +%F-%H%M).txt
kubectl get pods -A -o wide > pods-$(date +%F-%H%M).txt
kubectl logs <failing-pod> -n <ns> --previous > crash-$(date +%F-%H%M).log
kubectl describe pod <failing-pod> -n <ns> > describe-$(date +%F-%H%M).txt
```

**Step 2. Check rollback readiness**

```bash
aws eks list-insights --cluster-name $CLUSTER --region $REGION \
  --filter '{"categories": ["ROLLBACK_READINESS"]}'
aws eks describe-insight --cluster-name $CLUSTER --region $REGION --id <insight-id>

# Refresh after fixing issues
aws eks start-insights-refresh --cluster-name $CLUSTER --region $REGION
```

Status meanings: `PASSING` and `WARNING` allow rollback; `ERROR` and `UNKNOWN` block it until resolved (or bypassed with `--force`).

**Step 3. Roll back nodes first (only if they were already upgraded)**

Worker nodes cannot be newer than the control plane. Managed node groups:

```bash
aws eks update-nodegroup-version --cluster-name $CLUSTER --nodegroup-name $NODEGROUP \
  --kubernetes-version $CURRENT_VERSION --region $REGION
aws eks describe-update --name $CLUSTER --nodegroup-name $NODEGROUP --update-id <update-id>
```

> The EKS rollback documentation says to use this API for managed node group rollback, but the CLI reference page for this command still carries an older note saying a node group cannot be rolled back to an earlier version. **Confirm the current behaviour in the docs before relying on this**, and be prepared to create a new node group on the old version if the update is rejected.

Self-managed nodes: switch the AMI/launch template to the old version's AMI and roll the instances. Fargate: delete the Fargate pods that run the newer version, then roll back the control plane; redeploy afterwards.

**Step 4. Downgrade incompatible add-ons (only if needed)**

```bash
aws eks update-addon --cluster-name $CLUSTER --addon-name vpc-cni \
  --addon-version <older-compatible-version-eksbuild.N> --resolve-conflicts PRESERVE
```

Readiness insights check only EKS-managed add-ons. For self-managed add-ons you must verify compatibility yourself (use the `*-before.yaml` backups from Section 2.6).

**Step 5. Roll back the control plane**

CLI (use the previous N-1 version):

```bash
aws eks update-cluster-version --name $CLUSTER --region $REGION --kubernetes-version $CURRENT_VERSION
```

Console: EKS → your cluster → **Actions** → **Rollback cluster version** → review the summary → **Rollback version**.

Only if you accept the risk (see 6.5):

```bash
aws eks update-cluster-version --name $CLUSTER --region $REGION --kubernetes-version $CURRENT_VERSION --force
```

**Step 6. Monitor**

```bash
aws eks describe-update --name $CLUSTER --region $REGION --update-id <update-id>   # type: VersionRollback
aws eks describe-cluster --name $CLUSTER --query "cluster.{version:version,status:status}"
```

Status goes `InProgress` → `Successful` (or `Failed`).

**Step 7. Verify**

Repeat Section 5 checks. Then update IaC back to the old version so that code and cluster match.

### 6.5 Warnings

- `--force` bypasses **insight checks only**. It does not bypass the 7-day window, the creation-version check, or the one-version-at-a-time rule. AWS cannot guarantee safety when insight checks are bypassed, and you accept the responsibility for resulting problems.
- Insights are point-in-time. If you create resources using new APIs after the check, they may break after rollback. Freeze deployments during rollback.
- If you roll back from a standard-support version to an extended-support version, **extended support charges start** for that cluster.
- A CloudFormation stack rollback does not roll back the cluster version. Rollback must be requested through the API, CLI or console.
- After 7 days, rollback is gone. The remaining option is a new cluster on the old version and workload migration.

---

## 7. Emergency commands

> ⚠️ **Order of operations in an incident:** (1) stabilise users, (2) save evidence, (3) fix, (4) write the postmortem. Do not experiment on prod. Anything marked **DANGEROUS** needs a second person's approval.

### 7.1 Where am I, what is the state?

```bash
aws sts get-caller-identity
kubectl config current-context
aws eks describe-cluster --name $CLUSTER --query "cluster.{version:version,status:status,endpoint:endpoint}"
aws eks list-updates --name $CLUSTER --region $REGION
aws eks describe-update --name $CLUSTER --region $REGION --update-id <update-id>   # read the "errors" field
kubectl get nodes
kubectl get pods -A | grep -v -E "Running|Completed"
kubectl get events -A --sort-by=.lastTimestamp | tail -50
```

### 7.2 Control plane upgrade seems stuck or failed

- You cannot pause or cancel a running upgrade. EKS reverts its own infrastructure change if its health checks fail, and the cluster stays on the old version.
- Read `errors` in `describe-update`. Common causes: not enough free IPs in the cluster subnets, a deleted subnet, or security group rules that block required communication.
- If the status stays unclear for a long time, open an **AWS Support** case (production-impacting) with the cluster name, region, and update ID.

### 7.3 Node group update stuck or failing

```bash
aws eks describe-update --name $CLUSTER --nodegroup-name $NODEGROUP --update-id <update-id>
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NODEGROUP \
  --query "nodegroup.{status:status,health:health}"

kubectl get pdb -A                            # a PDB blocking the drain is the usual cause
kubectl get nodes
kubectl describe node <node>                  # look at Conditions and Events
kubectl get pods -A -o wide --field-selector spec.nodeName=<node>
```

Preferred fixes: scale the blocked app up, correct the PDB, or move the stuck pod. **DANGEROUS (last resort):** force the update, which ignores PDBs and restarts nodes regardless:

```bash
aws eks update-nodegroup-version --cluster-name $CLUSTER --nodegroup-name $NODEGROUP \
  --kubernetes-version $TARGET_VERSION --force --region $REGION
```

### 7.4 Pods cannot start or have no networking (VPC CNI)

```bash
kubectl get pods -n kube-system -l k8s-app=aws-node -o wide
kubectl logs -n kube-system -l k8s-app=aws-node -c aws-node --tail=100
kubectl describe pod <stuck-pod> -n <ns>      # look for "failed to assign an IP address" / sandbox errors
kubectl rollout restart daemonset/aws-node -n kube-system
kubectl rollout status daemonset/aws-node -n kube-system
```

If a recent VPC CNI update caused it, roll back to the previous add-on version:

```bash
aws eks update-addon --cluster-name $CLUSTER --addon-name vpc-cni \
  --addon-version <previous-version-eksbuild.N> --resolve-conflicts PRESERVE
# self-managed: re-apply the old manifest saved earlier
kubectl apply -f aws-k8s-cni-old.yaml
```

Also check for IP exhaustion in the subnets (AWS console: VPC → Subnets → available IPv4 addresses).

### 7.5 DNS broken (CoreDNS)

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=100
kubectl run dnstest --rm -it --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system
```

Roll back CoreDNS the same way as VPC CNI: `update-addon` with the previous version (managed) or `kubectl set image` with the previous image (self-managed).

### 7.6 Service routing broken (kube-proxy)

```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
kubectl logs -n kube-system -l k8s-app=kube-proxy --tail=100
kubectl rollout restart daemonset/kube-proxy -n kube-system
```

Roll back via `update-addon` with the previous version, or `kubectl set image` with the previous image (same image type as before).

### 7.7 An application broke after the upgrade

```bash
kubectl rollout undo deployment/<name> -n <ns>                 # previous ReplicaSet (use only if the app change caused it)
kubectl rollout status deployment/<name> -n <ns>
kubectl logs <pod> -n <ns> --previous
kubectl describe pod <pod> -n <ns>
kubectl scale deployment/<name> -n <ns> --replicas=<n>         # add capacity while debugging
kubectl get hpa -A
```

If the cause is a removed or changed Kubernetes API in your manifests, fix the manifest in Git and redeploy through the pipeline (Git → PR → pipeline), not by manual edits.

### 7.8 A bad or unhealthy node

```bash
kubectl cordon <node>                                          # stop new pods landing here
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data   # evict pods safely (respects PDBs)
kubectl uncordon <node>                                        # allow scheduling again once healthy
kubectl describe node <node>
```

`--delete-emptydir-data` deletes data in `emptyDir` volumes on that node, so check what the pods store before using it. With managed node groups, the usual fix is terminating the bad instance and letting the Auto Scaling Group replace it.

### 7.9 Break-glass access reminders

- Use read-only access for investigation. Elevated access should be approved, time-limited and logged (company policy).
- Never paste prod logs, tokens or secrets into external tools. Redact first and follow your company's AI-tool policy.
- Tell the team what you are doing in the incident channel *before* you do it.

---

## 8. Suggested prod timeline

| When | What |
|---|---|
| **T-60 to T-30 days** | Check the release calendar. Read release notes. Create the upgrade ticket. |
| **T-30 to T-14** | Run upgrade insights, fix deprecated APIs, update Helm charts and manifests. Check add-on and third-party compatibility. |
| **T-14 to T-7** | Upgrade **dev**, then **staging**. Run tests, load tests, a full deploy cycle. Note issues. |
| **T-3 to T-1** | Backups and snapshots. Confirm replicas and PDBs. Announce the maintenance window. Review this runbook with the on-call person. |
| **T-0** | Prod: control plane → observe → nodes → add-ons → apps → verify. Monitoring dashboards open the whole time. |
| **T+1 to T+7** | Watch metrics and errors. **Rollback window open.** Decide by day 6 whether anything requires rollback. |
| **T+7** | Rollback no longer possible. Update IaC and docs. Hold a short retrospective and fix this runbook where it was wrong. |

---

## 9. Cheat sheet

```bash
# Versions and state
aws eks describe-cluster --name $CLUSTER --query "cluster.{version:version,status:status}"
kubectl version && kubectl get nodes

# Pre-checks
aws eks list-insights --cluster-name $CLUSTER --filter '{"categories": ["UPGRADE_READINESS"]}'
kubectl get pdb -A
aws eks describe-addon-versions --kubernetes-version $TARGET_VERSION --addon-name <addon> --query "addons[0].addonVersions[].addonVersion" --output text

# Upgrade
aws eks update-cluster-version --name $CLUSTER --kubernetes-version $TARGET_VERSION
aws eks update-nodegroup-version --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --kubernetes-version $TARGET_VERSION
aws eks update-addon --cluster-name $CLUSTER --addon-name vpc-cni --addon-version <v> --resolve-conflicts PRESERVE
aws eks update-addon --cluster-name $CLUSTER --addon-name kube-proxy --addon-version <v> --resolve-conflicts PRESERVE
aws eks update-addon --cluster-name $CLUSTER --addon-name coredns --addon-version <v> --resolve-conflicts PRESERVE

# Watch
aws eks list-updates --name $CLUSTER
aws eks describe-update --name $CLUSTER --update-id <id>

# Rollback (within 7 days, N -> N-1)
aws eks list-insights --cluster-name $CLUSTER --filter '{"categories": ["ROLLBACK_READINESS"]}'
aws eks update-nodegroup-version --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --kubernetes-version $CURRENT_VERSION
aws eks update-cluster-version --name $CLUSTER --kubernetes-version $CURRENT_VERSION

# Emergency
kubectl get pods -A | grep -v -E "Running|Completed"
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout undo deployment/<name> -n <ns>
kubectl cordon <node> && kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
```

**Golden rules:** one minor version at a time. Staging first. Evidence before rollback. Nodes cannot be newer than the control plane. Add-ons are never automatic. Rollback window is 7 days. When in doubt, ask a second person before touching prod.

---

## 10. Sources to verify against (AWS documentation)

- Update existing cluster to new Kubernetes version (Amazon EKS User Guide)
- Roll back a cluster to a previous Kubernetes version (Amazon EKS User Guide)
- Update a managed node group for your cluster
- Update an Amazon EKS add-on; Update the Amazon VPC CNI; CoreDNS and kube-proxy update pages (managed and self-managed)
- Best Practices for Cluster Upgrades (EKS Best Practices Guide)
- Understand the Kubernetes version lifecycle on EKS (release calendar)
