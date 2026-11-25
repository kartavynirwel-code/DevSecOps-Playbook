# HashiCorp Vault + External Secrets Operator (ESO): Secret Management

A bank locker for secrets: passwords, API keys, DB credentials, certificates.

This guide has two tracks:

- **Part A: Learning track.** Dev-mode Vault + ESO on a lab cluster (fast, disposable).
- **Part B: Production track.** HA Vault on Kubernetes (Raft + TLS + auto-unseal), a Vault on a VM, sealed-pod handling, backups, upgrades and a best-practices checklist.

> Companion file: `vault-values.yaml` (production Helm values used in Part B).

## Contents

1. [Problem Vault solves](#1-problem-vault-solves)
2. [Architecture](#2-architecture)
3. [Dev mode vs production](#3-dev-mode-vs-production)

**Part A: Learning track**

4. [Install and run Vault (dev mode)](#4-install-and-run-vault-dev-mode)
5. [KV secret engine](#5-kv-secret-engine)
6. [Kubernetes auth method](#6-kubernetes-auth-method-dev-setup)
7. [Policy and role](#7-policy-and-role-least-privilege)
8. [Install ESO](#8-install-external-secrets-operator)
9. [ServiceAccount, ClusterSecretStore, ExternalSecret](#9-serviceaccount-clustersecretstore-externalsecret)
10. [Deployment](#10-deployment-reference-the-auto-created-secret)
11. [Verification checklist](#11-verification-checklist)

**Part B: Production track**

12. [Production on Kubernetes (HA Raft)](#12-production-on-kubernetes-ha-raft)
13. [Sealed pod and how to unseal](#13-sealed-pod-and-how-to-unseal)
14. [Production on a single VM/EC2](#14-production-on-a-single-vmec2-systemd)
15. [Backups, disaster recovery, upgrades](#15-backups-disaster-recovery-upgrades)
16. [Dynamic secrets for PostgreSQL (RDS)](#16-dynamic-secrets-for-postgresql-rds)
17. [Production best practices](#17-production-best-practices)
18. [Vault vs K8s Secrets vs .env](#18-vault-vs-k8s-secrets-vs-env)
19. [Troubleshooting](#19-troubleshooting)
20. [Interview questions](#20-interview-questions)

---

## 1. Problem Vault solves

| Without Vault | With Vault |
|---|---|
| Passwords in `.env` files | Secrets stored in Vault |
| Secrets in Git repo | Apps fetch secrets at runtime |
| Same secret for everyone | Dynamic secrets per app |
| No audit trail | Full audit log |
| Manual rotation | Automatic rotation |
| Secrets never expire | TTL-based expiry |

---

## 2. Architecture

- **Storage backend:** where Vault's own data is stored (always encrypted). Options: integrated Raft (recommended), Consul, cloud storage, file. File and single-node Raft are for learning only.
- **Auth methods:** how clients prove who they are (Token, Userpass, AppRole, Kubernetes, JWT/OIDC, AWS IAM).
- **Secret engines:** where secrets live or are generated (KV, Database, AWS, PKI, Transit).
- **Policies:** what an authenticated identity may do (path + capabilities).
- **Audit devices:** tamper-evident log of every request and response.
- **Seal/unseal mechanism:** Vault storage is always encrypted at rest. Vault starts **sealed**: it cannot read its own storage until the root key is reconstructed. `vault server -dev` hides this by auto-unsealing with a throwaway key. See [Section 13](#13-sealed-pod-and-how-to-unseal).

**Key hierarchy (why sealing exists):**

```
Data in storage  --encrypted by-->  Encryption key  --encrypted by-->  Root key  --protected by-->  Unseal method
                                                                                                    (Shamir shares OR cloud KMS)
```

**Secret flow in this project (K8s + ESO, not Agent Injector):**

```
Vault (secret store)
   |
ClusterSecretStore   -> Vault connection + auth config
   |
ExternalSecret        -> which Vault path, which keys
   |
ESO controller auto-creates a normal Kubernetes Secret
   |
Deployment references that K8s Secret (normal secretKeyRef syntax)
```

> Agent Injector (sidecar that writes secrets as files) is a different Vault-on-K8s pattern. We use **ESO**, which produces a normal `Secret` object, so application code and Deployment YAML stay unchanged.

**Who talks to whom:** only ESO talks to Vault. Application pods never talk to Vault; they read the synced Kubernetes Secret.

---

## 3. Dev mode vs production

| Area | Dev mode (`-dev`) | Production |
|---|---|---|
| Storage | In-memory (lost on restart) | Raft on persistent volumes |
| Seal | Auto-unsealed, throwaway key | Auto-unseal (KMS/HSM) or Shamir |
| TLS | Disabled | Required everywhere (clients, cluster port, ESO) |
| Root token | Handed to you, fixed | Used once for bootstrap, then revoked |
| Replicas | 1 | 3 or 5 (odd), spread across nodes/AZs |
| Auth | Root token | Kubernetes/OIDC/AppRole, short TTLs |
| Audit | Off | On, shipped off-box |
| Backups | None | Scheduled Raft snapshots, tested restores |
| Exposure | Often open to the internet | Private network only |

---

# Part A: Learning track

## 4. Install and run Vault (dev mode)

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install vault -y
vault -version
```

Run the dev server (listening on all interfaces so the cluster can reach it):

```bash
vault server -dev -dev-listen-address="0.0.0.0:8200"
```

In a **new terminal**:

```bash
export VAULT_ADDR='http://<EC2-private-ip-or-localhost>:8200'
export VAULT_TOKEN='<root-token-printed-when-server-started>'
vault status
```

> **Warning.** Dev mode has in-memory storage (data lost on restart), auto-unseal, a root token, and no TLS. Binding to `0.0.0.0` on a public EC2 means anyone who gets the token controls Vault over plain HTTP. In the Security Group, allow port 8200 **only from the cluster nodes' CIDR or your own IP**, and never use dev mode for real data. Production setup is in Part B.

---

## 5. KV secret engine

```bash
# Dev mode already mounts kv-v2 at secret/. Enabling it again fails with "path is already in use".
vault secrets enable -path=secret kv-v2

vault kv put secret/notes-app/db \
  username='notesuser' \
  password='SuperSecret123!' \
  api_key='dummy-api-key-123'

vault kv get secret/notes-app/db
vault kv get -field=password secret/notes-app/db
```

Other useful commands:

```bash
vault kv list secret/notes-app/
vault kv get -version=1 secret/notes-app/db     # KV v2 keeps version history
vault kv patch secret/notes-app/db api_key='new-value'   # update one field, keep others
vault kv delete secret/notes-app/db             # soft delete (latest version)
vault kv undelete -versions=1 secret/notes-app/db
vault kv metadata put -max-versions=10 secret/notes-app/db   # cap stored versions
```

> **Never put real secrets on the command line.** They land in shell history and process lists. Use `password=-` (reads stdin) or `@file.json`, and in real environments prefer writing secrets through a CI job or the UI.

---

## 6. Kubernetes auth method (dev setup)

Vault is outside the cluster in this setup, so it needs a credential to call the Kubernetes **TokenReview API**.

```bash
vault auth enable kubernetes
```

```bash
# ServiceAccount whose token Vault uses to validate other tokens (token reviewer)
kubectl create serviceaccount vault-auth -n default

# Allow it to call TokenReview
kubectl create clusterrolebinding vault-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount=default:vault-auth

# Long-lived token Secret (since K8s 1.24 tokens are no longer auto-created)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: default
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
EOF

SA_JWT_TOKEN=$(kubectl get secret vault-auth-token -n default -o jsonpath="{.data.token}" | base64 --decode)
K8S_HOST=$(kubectl config view --raw --minify --flatten -o jsonpath="{.clusters[0].cluster.server}")
K8S_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath="{.clusters[0].cluster.certificate-authority-data}" | base64 --decode)
```

```bash
vault write auth/kubernetes/config \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert="$K8S_CA_CERT" \
  token_reviewer_jwt="$SA_JWT_TOKEN"
```

> **If this errors:** check `kubectl get secret vault-auth-token -n default -o yaml` (the `token` field must be populated) before debugging further.

**The four moving parts, so they stop being confusing:**

| Component | What it is | Job |
|---|---|---|
| `notes-app-sa` (or `eso-vault`) | Client identity | Its JWT is what ESO sends to log in |
| `vault-auth` | Token reviewer | Vault uses its token to call K8s TokenReview |
| Vault **role** | Mapping inside Vault | Binds ServiceAccount name + namespace to policies |
| Vault **policy** | Authorization | Which paths and capabilities are allowed |

**Login flow:**

1. ESO sends the ServiceAccount JWT + role name to `auth/kubernetes/login`.
2. Vault asks the Kubernetes API (TokenReview) whether the JWT is valid, using the reviewer token.
3. Vault checks the SA name and namespace against the role's bindings.
4. Vault returns a short-lived client token carrying the role's policies.
5. ESO reads the secret with that token.

---

## 7. Policy and role (least privilege)

```bash
vault policy write notes-app-policy - <<EOF
path "secret/data/notes-app/*" {
  capabilities = ["read"]
}
path "secret/metadata/notes-app/*" {
  capabilities = ["read", "list"]
}
EOF
```

```bash
vault write auth/kubernetes/role/notes-app-role \
  bound_service_account_names=notes-app-sa \
  bound_service_account_namespaces=default \
  policies=notes-app-policy \
  ttl=1h
```

> KV v2 inserts `data/` into API paths: `vault kv put secret/notes-app/db` is really `secret/data/notes-app/db`, so the policy must say `secret/data/...`. Metadata (`secret/metadata/...`) is needed for listing.

Never bind a role to the `default` ServiceAccount or use wildcards like `bound_service_account_names=*` unless you truly mean "any pod in that namespace".

---

## 8. Install External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --set installCRDs=true

kubectl get pods -n external-secrets   # all pods Running
kubectl get crd | grep external-secrets
```

> Newer ESO versions serve `external-secrets.io/v1`. If you get `no matches for kind "SecretStore" in version "external-secrets.io/v1beta1"`, switch `apiVersion` to `external-secrets.io/v1`.

---

## 9. ServiceAccount, ClusterSecretStore, ExternalSecret

```yaml
# notes-app-sa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: notes-app-sa
  namespace: default
```

```yaml
# cluster-secret-store.yaml  (learning setup: plain HTTP to dev Vault)
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://<vault-private-ip>:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "notes-app-role"
          serviceAccountRef:
            name: "notes-app-sa"
            namespace: "default"
```

```yaml
# external-secret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: notes-app-external-secret
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: notes-app-db-secret      # <- this K8s Secret is auto-created
  data:
    - secretKey: username
      remoteRef: { key: notes-app/db, property: username }
    - secretKey: password
      remoteRef: { key: notes-app/db, property: password }
    - secretKey: api_key
      remoteRef: { key: notes-app/db, property: api_key }
```

```bash
kubectl apply -f notes-app-sa.yaml -f cluster-secret-store.yaml -f external-secret.yaml
kubectl get clustersecretstore vault-backend     # STATUS: Valid
kubectl get externalsecret                       # STATUS: SecretSynced
kubectl get secret notes-app-db-secret -o jsonpath='{.data}' | tr ',' '\n' | cut -d'"' -f2   # key names
```

**Adopting an existing Secret name:** to keep a Deployment unchanged, set `target.name` to the existing Secret and map keys with `data:` so key names match what the Deployment expects. ESO's default `creationPolicy: Owner` takes ownership and overwrites the data; `Merge` requires the Secret to exist already.

**Proving the Secret really comes from Vault:**

```bash
kubectl get secret notes-app-db-secret -o jsonpath='{.metadata.ownerReferences[*].kind}'   # ExternalSecret
kubectl delete secret notes-app-db-secret ; sleep 10 ; kubectl get secret notes-app-db-secret   # recreated by ESO
```

If the Secret reappears with all keys, its only possible source is Vault.

---

## 10. Deployment: reference the auto-created Secret

```yaml
spec:
  template:
    spec:
      containers:
        - name: notes-app
          env:
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: notes-app-db-secret   # must equal ExternalSecret target.name
                  key: username
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: notes-app-db-secret
                  key: password
            - name: API_KEY
              valueFrom:
                secretKeyRef:
                  name: notes-app-db-secret
                  key: api_key
```

> In this ESO pattern the application pod does **not** need a special ServiceAccount for Vault: ESO authenticates, not the app. A dedicated ServiceAccount per app is still good practice for RBAC.

**Known trap:** `secretKeyRef.name` must exactly equal `ExternalSecret.spec.target.name`, not the Vault path and not the ExternalSecret's own `metadata.name`. If pods start with empty or missing env vars, check this first.

**Rotation caveat:** env vars are read when the container starts. When Vault data changes, ESO updates the K8s Secret, but running pods keep old values until restarted. Use [Stakater Reloader](https://github.com/stakater/Reloader) (annotation `reloader.stakater.com/auto: "true"`) or `kubectl rollout restart`.

---

## 11. Verification checklist

Run in this order when debugging:

```bash
vault status                                    # Sealed = false?
vault kv get secret/notes-app/db                # secret in Vault?
kubectl get clustersecretstore vault-backend    # Valid?
kubectl get externalsecret                      # SecretSynced?
kubectl describe externalsecret <name>          # events/errors
kubectl get secret notes-app-db-secret -o yaml  # keys present?
kubectl describe pod <notes-app-pod>            # env populated? CreateContainerConfigError?
kubectl logs -n external-secrets deploy/external-secrets   # auth/permission errors
```

---

# Part B: Production track

## 12. Production on Kubernetes (HA Raft)

**Target architecture:** 3 Vault pods using integrated Raft storage, one per node/AZ, TLS on API and cluster ports, AWS KMS auto-unseal, audit logs on a persistent volume, Kubernetes auth for ESO, root token revoked after bootstrap.

```
          +-------------------- namespace: vault --------------------+
          |   vault-0 (active)  <--Raft-->  vault-1  <--Raft-->  vault-2   |
          |        |  TLS :8200/:8201               PVC per pod (data+audit)  |
          +--------|-----------------------------------------------------+
                   |  AWS KMS (auto-unseal)
   ESO (namespace external-secrets) --Kubernetes auth over TLS--> Vault
```

### 12.1 Prerequisites

| Need | Why |
|---|---|
| 3 worker nodes (or 3 AZs) | Raft needs a quorum (2 of 3). One node = no HA |
| StorageClass with expansion (e.g. gp3) | Raft data and audit logs live on PVCs |
| cert-manager (or your PKI) | TLS certificates for Vault |
| AWS KMS key + IAM permissions | Auto-unseal (`kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey`) |
| Private networking | Vault must not be reachable from the internet |
| Helm 3 | Chart install |

**KMS access:** on EKS use IRSA or Pod Identity (annotate the Vault ServiceAccount, see `vault-values.yaml`). On self-managed clusters (kubeadm/k3s on EC2) attach an instance profile to the nodes, or use a dedicated IAM user key stored as a Kubernetes Secret as a last resort.

### 12.2 Create the namespace and TLS

```bash
kubectl create namespace vault
```

cert-manager example (self-signed CA for learning; use your real PKI in production):

```yaml
# vault-tls.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vault-ca
  namespace: vault
spec:
  isCA: true
  commonName: vault-ca
  secretName: vault-ca
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { name: selfsigned, kind: ClusterIssuer }
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-ca-issuer
  namespace: vault
spec:
  ca:
    secretName: vault-ca
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vault-tls
  namespace: vault
spec:
  secretName: vault-tls          # contains tls.crt, tls.key, ca.crt
  duration: 2160h                # 90 days
  renewBefore: 360h
  privateKey: { algorithm: ECDSA, size: 256 }
  usages: [server auth, client auth]
  dnsNames:
    - vault
    - vault.vault
    - vault.vault.svc
    - vault.vault.svc.cluster.local
    - "*.vault-internal"
    - "*.vault-internal.vault.svc.cluster.local"
  ipAddresses:
    - 127.0.0.1
  issuerRef: { name: vault-ca-issuer, kind: Issuer }
```

```bash
kubectl apply -f vault-tls.yaml
kubectl get certificate -n vault          # READY=True
```

> Vault reads certificates at startup. After renewal, reload with `kill -HUP` on the Vault process (or restart pods one at a time).

### 12.3 Create the KMS key

```bash
aws kms create-key --description "vault-auto-unseal" --region us-east-1
aws kms create-alias --alias-name alias/vault-unseal --target-key-id <key-id> --region us-east-1
```

Put the key ID in `vault-values.yaml` (`kms_key_id`) and the role ARN in the ServiceAccount annotation. The IAM policy for Vault:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"],
    "Resource": "arn:aws:kms:us-east-1:<account-id>:key/<key-id>"
  }]
}
```

### 12.4 Install Vault with the production values

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm search repo hashicorp/vault --versions | head      # pick and pin a version

helm install vault hashicorp/vault -n vault -f vault-values.yaml --version <chart-version>
kubectl get pods -n vault -L vault-initialized,vault-sealed,vault-active
```

Pods start **uninitialized** (and show `vault-initialized=false`); that is normal until the next step.

### 12.5 Initialize (once, ever)

With **auto-unseal** you get *recovery keys*, not unseal keys:

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -recovery-shares=5 -recovery-threshold=3 \
  -format=json > vault-init.json
```

`vault-init.json` contains the **initial root token** and the **recovery keys**.

> **Handle this file like a nuclear launch code.**
> 1. Split the 5 recovery keys among 5 different trusted people, each stored in a password manager or safe.
> 2. Store the root token temporarily; you will revoke it in 12.8.
> 3. Delete `vault-init.json` from disk once distributed (`shred -u vault-init.json`).
> 4. Never commit it, paste it into chat, or leave it on a shared server.

With auto-unseal, `vault-0` unseals itself right after init. `vault-1` and `vault-2` join via `retry_join` and also unseal automatically.

### 12.6 Verify the cluster

```bash
kubectl get pods -n vault -L vault-sealed,vault-active
kubectl exec -n vault vault-0 -- vault status                 # Sealed false, HA Enabled true
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=<root-token> vault operator raft list-peers
```

Expect three peers: one `leader`, two `follower`, all voters. If a pod is missing, see [Section 13](#13-sealed-pod-and-how-to-unseal) and [Section 19](#19-troubleshooting).

### 12.7 Enable auditing first

Turn on auditing **before** anything else so every later action is recorded.

```bash
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=<root-token> \
  vault audit enable file file_path=/vault/audit/vault_audit.log
```

> Vault **refuses to serve requests if it cannot write to any audit device** (fail-closed). Keep at least two audit devices in mature setups (for example file + syslog/socket) so one failing doesn't block Vault, and ship logs off the pod with a log agent (Fluent Bit, Vector) to your SIEM. Audit logs hash sensitive values, but treat them as sensitive anyway.

### 12.8 Create admin access, then revoke the root token

The root token has no expiry and unlimited power. Use it only to bootstrap.

```bash
# 1) An admin policy (scoped, not root)
vault policy write admin - <<EOF
path "sys/*"      { capabilities = ["create","read","update","delete","list","sudo"] }
path "auth/*"     { capabilities = ["create","read","update","delete","list","sudo"] }
path "secret/*"   { capabilities = ["create","read","update","delete","list"] }
path "identity/*" { capabilities = ["create","read","update","delete","list"] }
EOF

# 2) A human login method. Prefer OIDC/SSO; userpass shown for simplicity:
vault auth enable userpass
vault write auth/userpass/users/kartavya password=- policies=admin token_ttl=1h token_max_ttl=8h
#   (type the password, then Ctrl+D)

# 3) Test the admin login in a NEW terminal BEFORE revoking root
vault login -method=userpass username=kartavya

# 4) Revoke the root token
vault token revoke <root-token>
```

When root is truly needed (break-glass), generate one temporarily using recovery keys and revoke it right after:

```bash
vault operator generate-root -init
# then the quorum of recovery-key holders each run: vault operator generate-root
# ... do the task ... then: vault token revoke <temporary-root-token>
```

### 12.9 Kubernetes auth with in-cluster Vault

Vault runs **inside** the cluster now, so no manual reviewer JWT is needed. The chart already binds the Vault ServiceAccount to `system:auth-delegator`.

```bash
kubectl exec -it -n vault vault-0 -- sh
# inside the pod (logged in as admin):
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"
```

Create the secret engine, policy, and role (one role per consumer, least privilege):

```bash
vault secrets enable -path=secret kv-v2

vault policy write eso-notes-app - <<EOF
path "secret/data/notes-app/*"     { capabilities = ["read"] }
path "secret/metadata/notes-app/*" { capabilities = ["read","list"] }
EOF

vault write auth/kubernetes/role/eso-notes-app \
  bound_service_account_names=eso-vault \
  bound_service_account_namespaces=external-secrets \
  policies=eso-notes-app \
  ttl=15m max_ttl=1h
```

### 12.10 Point ESO at production Vault (TLS + Kubernetes auth)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-vault
  namespace: external-secrets
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "https://vault.vault.svc:8200"
      path: "secret"
      version: "v2"
      caProvider:
        type: Secret
        name: vault-tls
        key: ca.crt
        namespace: vault
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "eso-notes-app"
          serviceAccountRef:
            name: "eso-vault"
            namespace: "external-secrets"
```

> `vault-tls` lives in namespace `vault`. For a ClusterSecretStore, `caProvider.namespace` is required. Copy only `ca.crt` (public CA cert) to wherever ESO needs it, never the private key.

### 12.11 Lock down the network

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vault-ingress
  namespace: vault
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: vault
  policyTypes: [Ingress]
  ingress:
    - from:                                # API: only ESO and operators
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: external-secrets }
      ports: [{ port: 8200, protocol: TCP }]
    - from:                                # Raft + cluster traffic: only Vault pods
        - podSelector:
            matchLabels: { app.kubernetes.io/name: vault }
      ports:
        - { port: 8200, protocol: TCP }
        - { port: 8201, protocol: TCP }
```

NetworkPolicy needs a CNI that enforces it (Calico, Cilium). Flannel alone does not.

---

## 13. Sealed pod and how to unseal

### 13.1 What "sealed" means

A sealed Vault is a **running process that cannot decrypt its own storage**. The root key is not in memory, so it can't read secrets, auth requests, or policies. While sealed, almost every API call returns **HTTP 503**; only status, health, init and unseal endpoints work.

Vault seals when:

- It **starts or restarts** (pod rescheduled, node reboot, upgrade, OOM kill, crash).
- An operator runs `vault operator seal` (deliberate break-glass).
- It loses access to the auto-unseal KMS/HSM and restarts (cannot fetch the key).
- It detects certain storage/quorum failures.

> Sealing is a feature: a stolen disk or snapshot is useless without the key material.

### 13.2 How to detect a sealed pod

```bash
# 1) Labels set by service_registration "kubernetes"
kubectl get pods -n vault -L vault-initialized,vault-sealed,vault-active

# 2) Ask Vault directly
kubectl exec -n vault vault-0 -- vault status
#   Sealed          true      <-- the thing you're looking for
#   Unseal Progress 0/3       (Shamir only)

# 3) HTTP health codes
kubectl exec -n vault vault-0 -- wget -qO- --no-check-certificate -S \
  "https://127.0.0.1:8200/v1/sys/health" 2>&1 | head -1
#   200 active | 429 standby | 472 DR secondary | 473 perf standby | 501 uninitialized | 503 SEALED

# 4) Logs
kubectl logs -n vault vault-0 | grep -i -E "seal|unseal|barrier|kms"
```

**Other symptoms outside Vault:**

- `ClusterSecretStore` shows `InvalidProviderConfig` / not ready, and `ExternalSecret` shows `SecretSyncedError` with `503` or "Vault is sealed" in `kubectl describe`.
- Existing Kubernetes Secrets and running pods keep working (ESO does not delete synced Secrets). New or rotated secrets stop flowing until Vault is unsealed.

> With the chart's default readiness path, a sealed pod can still show `1/1 Ready` (see comments in `vault-values.yaml`). Don't rely on `READY` alone; check the `vault-sealed` label or `vault status`.

### 13.3 Unseal option A: auto-unseal (what production should use)

With a `seal "awskms"` (or Azure Key Vault, GCP KMS, Transit, HSM) stanza, each pod unseals itself on startup by asking the KMS to decrypt its key. **You do nothing**; pods come back unsealed after any restart.

If a pod is **sealed despite auto-unseal**, the unseal call to KMS is failing. Check, in this order:

```bash
kubectl logs -n vault vault-0 | grep -i -E "kms|awskms|seal|error"
```

| Log hint | Likely cause | Fix |
|---|---|---|
| `AccessDeniedException` | IAM role missing `kms:Decrypt`/`DescribeKey` | Fix IAM policy; check IRSA annotation or instance profile |
| `NoCredentialProviders` | Pod has no AWS credentials | Annotate ServiceAccount (IRSA) or fix instance profile/IMDS hop limit (2 for containers) |
| `KMSInvalidStateException` / key disabled or pending deletion | KMS key disabled/deleted | Re-enable the key (cancel deletion). If the key is gone, the data is **unrecoverable** except via snapshot restore into a new cluster |
| Timeout / `dial tcp` | No egress to KMS endpoint | Allow outbound 443 to `kms.<region>.amazonaws.com` or add a VPC endpoint |
| Wrong region / key ID | Config typo | Fix `seal "awskms"` stanza, restart pod |

After fixing the cause, restart the pod: `kubectl delete pod -n vault vault-0` (StatefulSet recreates it, and it auto-unseals).

**Recovery keys are not unseal keys.** With auto-unseal, recovery keys authorize sensitive operations (generate root token, rekey, seal migration). They cannot unseal Vault by themselves.

### 13.4 Unseal option B: manual Shamir unseal (lab, or no KMS available)

Without a `seal` stanza, `vault operator init` splits the root key into **key shares** (Shamir's Secret Sharing). A threshold of them is required to unseal.

**Initialize (once):**

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-init.json
```

Distribute the 5 unseal keys to 5 different people. No one person should hold 3.

**Unseal each pod.** Run the command **3 times per pod**, each time entering a *different* key. Use the interactive prompt so keys don't land in shell history:

```bash
kubectl exec -it -n vault vault-0 -- vault operator unseal     # prompts: Unseal Key (will be hidden)
kubectl exec -it -n vault vault-0 -- vault operator unseal
kubectl exec -it -n vault vault-0 -- vault operator unseal
#   Unseal Progress goes 1/3 -> 2/3 -> Sealed false
```

Repeat for `vault-1` and `vault-2`. In Raft, followers rejoin the cluster automatically but **each pod must be unsealed individually**.

**Verify:**

```bash
kubectl get pods -n vault -L vault-sealed,vault-active          # sealed=false on all, one active
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=<admin-token> vault operator raft list-peers
```

**Lab-only helper** (never in production: it puts keys in an environment and history):

```bash
for pod in vault-0 vault-1 vault-2; do
  for k in "$KEY1" "$KEY2" "$KEY3"; do
    kubectl exec -n vault "$pod" -- vault operator unseal "$k" >/dev/null
  done
done
```

**Unseal progress stuck or reset?** `vault operator unseal -reset` clears partial progress (use it if someone entered a wrong key).

### 13.5 Migrating between seal types

**Shamir to auto-unseal** (recommended upgrade path):

1. Add the `seal "awskms"` stanza to the config; restart standbys one by one, then the leader.
2. Pods come up sealed, in migration mode. Unseal each with the **old Shamir keys** and the migrate flag:

```bash
kubectl exec -it -n vault vault-0 -- vault operator unseal -migrate    # enter threshold keys
```

3. After migration, the old Shamir keys become **recovery keys**.

Reverse migration (auto to Shamir) works the same way with the stanza marked `disabled = "true"`.

### 13.6 Manually sealing Vault (break-glass)

If you suspect a compromise, seal immediately. It blocks all secret access:

```bash
vault operator seal            # needs 'sudo' on sys/seal; run against the active node
```

Then investigate, rotate credentials, and unseal (auto-unseal pods need a restart to unseal again; Shamir needs the key quorum).

### 13.7 Things that look like "sealed" but are not

| Symptom | Real cause | Check |
|---|---|---|
| Pod `0/1`, `vault status` says unsealed | Probe failing (TLS cert mismatch, wrong path) | `kubectl describe pod`; `curl -k https://127.0.0.1:8200/v1/sys/health` |
| `no leader` / 500 errors, unsealed | Raft quorum lost (2 of 3 pods down) | Bring pods back; if data lost, restore snapshot ([Section 15](#15-backups-disaster-recovery-upgrades)) |
| `x509: certificate signed by unknown authority` | Client missing CA | Set `VAULT_CACERT` or `caProvider` in ESO |
| 403 `permission denied`, unsealed | Policy/role mismatch | `vault token capabilities`, check role bindings |
| Pod `uninitialized` (`vault-initialized=false`) | Fresh install, `operator init` not run | Run init once (12.5) |

### 13.8 What if keys are lost?

- **Shamir keys lost below threshold:** the data is **permanently unrecoverable**. That is by design. Prevention: distribute keys wisely, document custody, test the unseal drill.
- **Recovery keys lost (auto-unseal):** Vault keeps working; you lose the ability to generate root tokens or do seal migration. Use `vault operator rekey -target=recovery` while you still have a quorum.

### 13.9 Practice drill (do this in your lab)

1. `kubectl delete pod -n vault vault-1` and watch: `kubectl get pods -n vault -w -L vault-sealed`.
2. With auto-unseal it comes back unsealed alone; with Shamir it comes back sealed and you unseal it.
3. Run `vault operator seal` on the active node, watch ESO go unhealthy (`kubectl describe externalsecret`), restart/unseal, and confirm ESO recovers by itself on the next refresh.
4. Break KMS access on purpose (remove the IAM permission), restart a pod, read the error in the logs, then restore the permission.

---

## 14. Production on a single VM/EC2 (systemd)

For a VM-based Vault (not on Kubernetes). One node is **not** highly available; use 3 nodes in 3 AZs for real production.

```bash
sudo apt install vault -y
sudo mkdir -p /opt/vault/data /opt/vault/tls /var/log/vault
sudo chown -R vault:vault /opt/vault /var/log/vault
sudo chmod 700 /opt/vault/data /opt/vault/tls
```

`/etc/vault.d/vault.hcl`:

```hcl
ui            = true
api_addr      = "https://<private-ip>:8200"
cluster_addr  = "https://<private-ip>:8201"
# mlock stays enabled on VMs (default). The apt package's systemd unit grants CAP_IPC_LOCK.

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/opt/vault/tls/vault.crt"
  tls_key_file    = "/opt/vault/tls/vault.key"
  tls_min_version = "tls12"
}

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-1"
}

seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "<KMS_KEY_ID>"          # EC2 instance profile provides credentials
}

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}
```

```bash
sudo systemctl enable --now vault
export VAULT_ADDR=https://<private-ip>:8200
export VAULT_CACERT=/opt/vault/tls/ca.crt
vault operator init -recovery-shares=5 -recovery-threshold=3
vault status
```

**VM hardening checklist:**

- Security Group: 8200 from app/operator CIDRs only; 8201 only between Vault nodes. No public exposure.
- Dedicated `vault` user, no shell; swap disabled (`swapoff -a` and remove from fstab); core dumps disabled (`ulimit -c 0`, systemd `LimitCORE=0`).
- Encrypted EBS volumes; IMDSv2 required with hop limit as needed.
- Run nothing else on the host; keep OS patched.
- For HA: add 2 more nodes with `retry_join` blocks and distinct `node_id` values.

---

## 15. Backups, disaster recovery, upgrades

### 15.1 Raft snapshots

```bash
vault operator raft snapshot save /tmp/vault-$(date +%F-%H%M).snap
# Restore (to a new/empty or broken cluster, same seal config or with recovery keys):
vault operator raft snapshot restore /tmp/vault-2026-11-25-1200.snap
```

Production rules:

- **Schedule it** (CronJob in K8s or cron on VM) using a limited token or Kubernetes auth role with `sys/storage/raft/snapshot` capability.
- Encrypt snapshots, copy to S3 in another region with versioning + lifecycle rules.
- Snapshots contain all secrets, encrypted with the barrier key; restoring needs the unseal/recovery capability for the *same* seal. Losing the KMS key means the snapshot is useless.
- **Test a restore** into a scratch cluster at least quarterly. An untested backup is a hope, not a backup.
- Enterprise adds automated snapshots and DR replication; open source relies on your own jobs.

Example policy for the backup job:

```hcl
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
```

### 15.2 Upgrades (rolling, zero downtime)

1. Take a snapshot. Read the release notes and upgrade guide.
2. Upgrade **standbys first**, one at a time; wait until each is unsealed and a healthy `follower`.
3. Step down the leader (`vault operator step-down`), then upgrade that pod.
4. Verify `vault status` version on all nodes and `raft list-peers`.

With the Helm chart use `updateStrategy` `OnDelete` for control:

```bash
helm upgrade vault hashicorp/vault -n vault -f vault-values.yaml --version <new>
kubectl delete pod -n vault vault-2      # a standby; wait healthy
kubectl delete pod -n vault vault-1
kubectl exec -n vault vault-0 -- vault operator step-down
kubectl delete pod -n vault vault-0
```

### 15.3 Failure scenarios

| Failure | Result | Action |
|---|---|---|
| 1 of 3 pods down | Cluster healthy (quorum 2/3) | Pod rejoins automatically (and auto-unseals) |
| 2 of 3 down | **No quorum**, Vault unavailable | Restore pods/volumes; last resort: Raft peers recovery (`peers.json`) or snapshot restore |
| Whole AZ lost | Healthy if pods spread across AZs | Anti-affinity + topology spread |
| KMS key deleted | Cannot unseal | Cancel key deletion; otherwise data unrecoverable |
| Accidental secret delete | KV v2 soft-delete | `vault kv undelete`, or snapshot restore |

---

## 16. Dynamic secrets for PostgreSQL (RDS)

Instead of one long-lived DB password, Vault creates a **temporary DB user per request** that expires automatically.

```bash
vault secrets enable database

# Use a dedicated admin role for Vault (not the RDS master user)
vault write database/config/shop-db \
  plugin_name=postgresql-database-plugin \
  allowed_roles="shop-app" \
  connection_url="postgresql://{{username}}:{{password}}@<rds-endpoint>:5432/<db-name>?sslmode=require" \
  username="vault_admin" \
  password="<vault_admin_password>"

# Let Vault rotate vault_admin's own password so no human knows it
vault write -force database/rotate-root/shop-db

vault write database/roles/shop-app \
  db_name=shop-db \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" max_ttl="24h"

vault read database/creds/shop-app        # returns a fresh username/password valid for 1h
```

Policy for the consumer:

```hcl
path "database/creds/shop-app" { capabilities = ["read"] }
```

Notes:

- RDS security group must allow Vault (5432) from where Vault runs.
- Apps must reconnect when credentials expire (connection pools with refresh, or restart on lease renewal). Start with static KV secrets, move to dynamic once the app handles rotation.
- Revoke all credentials for a role at once: `vault lease revoke -prefix database/creds/shop-app`.

---

## 17. Production best practices

### Availability and storage
- [ ] 3 or 5 voters (odd number), **one per node and AZ** (pod anti-affinity / topology spread).
- [ ] Integrated **Raft** storage on persistent, encrypted volumes with expansion enabled.
- [ ] PodDisruptionBudget (`maxUnavailable: 1`); drain nodes one at a time.
- [ ] Resource requests/limits set; no CPU throttling surprises on the active node.
- [ ] Pin exact Vault and chart versions; upgrade deliberately (Section 15.2).

### Seal and key custody
- [ ] **Auto-unseal** with KMS/HSM/Transit. Do not rely on humans unsealing at 3 a.m.
- [ ] Recovery keys split among distinct people, stored offline; documented custody and rekey procedure.
- [ ] KMS key policy restricts who can disable or delete the key; enable deletion protection and alarms (CloudTrail alert on `ScheduleKeyDeletion`).
- [ ] Practice unseal and recovery drills (Section 13.9).

### Network and transport
- [ ] **TLS everywhere**: client API, cluster port 8201, ESO to Vault. `tls_min_version = "tls12"` or higher; never `tls_disable` in production.
- [ ] Vault never exposed publicly; ClusterIP/internal LB, VPN or private link for humans.
- [ ] NetworkPolicy and Security Groups restrict 8200/8201 to known sources.
- [ ] Certificates auto-renewed (cert-manager) with a tested reload procedure.

### Identity, auth and policies
- [ ] **Revoke the root token** after bootstrap; use `generate-root` only for break-glass, then revoke.
- [ ] Humans log in via **OIDC/SSO with MFA**; machines via **Kubernetes auth** or AppRole/cloud IAM, never shared static tokens.
- [ ] **Least privilege**: one policy per workload, no `secret/*` wildcards, no `sudo` outside admins.
- [ ] Short TTLs (`ttl=15m`, `max_ttl=1h` for machines) and non-renewable where possible; avoid long-lived periodic tokens unless required.
- [ ] Roles bound to specific ServiceAccount names **and** namespaces; never `*`.
- [ ] Use identity groups/entities for access reviews; review policies quarterly.

### Secrets lifecycle
- [ ] Prefer **dynamic secrets** (database, AWS, PKI) over static ones.
- [ ] Rotate static secrets on a schedule; rotate immediately after any suspected exposure.
- [ ] KV v2 with `max-versions` and `delete-version-after` set; know the difference between delete, undelete and destroy.
- [ ] Namespaced paths per team/app (`secret/<team>/<app>/<env>`), consistent naming.
- [ ] Never pass secrets on the command line, in Git, in CI logs, or in Terraform state without protection.

### Audit and monitoring
- [ ] **Audit devices enabled before go-live**, at least two, shipped to a central log store (SIEM).
- [ ] Prometheus metrics scraped (`/v1/sys/metrics` with a token or `unauthenticated_metrics_access` on a private listener); dashboards for request rate, latency, leader changes, Raft commit time, token/lease counts.
- [ ] Alerts: sealed node, no leader, Raft peers less than expected, audit write failures, certificate expiry within 14 days, snapshot job failures, KMS errors.
- [ ] Log pipeline for Vault server logs (JSON format via `log_format = "json"`).

### Operations
- [ ] Automated, off-site, encrypted **Raft snapshots**; quarterly restore tests.
- [ ] Runbooks: unseal, lost quorum, certificate expiry, KMS failure, compromised token, root token generation.
- [ ] Config and policies as code (Terraform Vault provider or Git-managed HCL), reviewed through pull requests.
- [ ] Separate Vault clusters (or at minimum namespaces and policies) per environment; never share dev and prod.
- [ ] Capacity and lease hygiene: avoid unbounded dynamic credential issuance; tune `max_lease_ttl`.

### Kubernetes and ESO specifics
- [ ] ESO runs in its own namespace with its own ServiceAccount; use **ClusterSecretStore** carefully (any namespace can reference it unless restricted with `conditions`/RBAC); prefer namespaced `SecretStore` for tenant isolation.
- [ ] Enable **etcd encryption at rest** (or KMS provider) because synced Secrets still live in etcd; restrict `get/list` on Secrets with RBAC.
- [ ] Use **Reloader** so pods pick up rotated secrets.
- [ ] Don't commit the `vault-token` Secret; with Kubernetes auth you don't need one.
- [ ] Mount secrets as env or files per app needs; avoid logging env dumps.
- [ ] Set `refreshInterval` deliberately (short enough for rotation, long enough not to hammer Vault).

### Process
- [ ] Break-glass procedure documented, access reviewed, and every use audited.
- [ ] Onboarding and offboarding checklist for Vault access (revoke tokens, remove from groups).
- [ ] Threat model reviewed: what if a node is compromised? What if a pod can read the Vault ServiceAccount token?

---

## 18. Vault vs K8s Secrets vs .env

| Feature | .env | K8s Secrets | Vault |
|---|---|---|---|
| Security | Very low | Medium | Very high |
| Encrypted at rest | No | Only if etcd encryption configured | Yes, always |
| Audit log | No | Basic API audit | Full request trail |
| Auto rotation | No | No | Yes |
| Dynamic secrets | No | No | Yes |
| Access control | None | RBAC | Fine-grained policies |
| Use for | Local dev | Basic K8s apps | Production |

---

## 19. Troubleshooting

| Problem | What to check |
|---|---|
| `path is already in use at secret/` | Dev mode already mounted `kv-v2` there. Skip `secrets enable` |
| `no matches for kind "SecretStore" in version ".../v1beta1"` | ESO not installed or newer version; use `external-secrets.io/v1`, check CRDs |
| `SecretMissing` on ExternalSecret | `creationPolicy: Merge` but target Secret doesn't exist; remove `Merge` or create it |
| `SecretSyncedError` with 403 | Role/policy mismatch: SA name/namespace in role, policy path uses `data/` |
| `SecretSyncedError` with 503 / sealed | Vault sealed ([Section 13](#13-sealed-pod-and-how-to-unseal)) |
| `x509: certificate signed by unknown authority` | Add `caProvider` to ESO store / `VAULT_CACERT` to CLI |
| `permission denied` on `auth/kubernetes/login` | Reviewer SA lacks `system:auth-delegator`; wrong `kubernetes_host`/CA |
| `CreateContainerConfigError` on app pod | Secret key name doesn't match `secretKeyRef.key`, or Secret missing |
| App has old password after rotation | Pod not restarted; use Reloader |
| Vault unreachable after EC2 stop/start | Public IP changed; dev-mode data lost; iptables rules lost (use Elastic IP, persistent storage, `netfilter-persistent`) |
| Raft pod won't join | `retry_join` addresses/TLS SANs wrong; check `vault-internal` DNS and certificate SANs |

Debug commands:

```bash
vault status ; vault token lookup ; vault token capabilities secret/data/notes-app/db
vault read auth/kubernetes/role/<role>
kubectl describe clustersecretstore vault-backend
kubectl describe externalsecret <name>
kubectl logs -n external-secrets deploy/external-secrets
kubectl logs -n vault vault-0
```

---

## 20. Interview questions

**What is HashiCorp Vault?**
A secrets management tool that securely stores and controls access to passwords, API keys and certificates. It provides audit logging, dynamic secrets, leasing/TTLs and automatic rotation.

**Why Vault over Kubernetes Secrets?**
K8s Secrets are only base64-encoded (and encrypted at rest only if etcd encryption is configured). Vault encrypts everything at rest, offers fine-grained policies, a full audit trail, short-lived dynamic credentials and central rotation.

**What is External Secrets Operator, and why use it instead of the Agent Injector?**
ESO is a controller that fetches secrets from external managers (Vault, AWS Secrets Manager, etc.) and creates native K8s Secrets. The Agent Injector puts secrets into pods as files via a sidecar, which requires file-reading logic in the app. With ESO the app and Deployment stay unchanged (`secretKeyRef`).

**What does seal/unseal mean?**
Vault always stores data encrypted. After a start it is sealed and cannot decrypt anything until the root key is available. With Shamir, `operator init` splits the root key into shares (for example 5 shares, threshold 3) that humans enter to unseal. In production, auto-unseal uses a cloud KMS/HSM so pods unseal themselves, and `init` returns recovery keys instead.

**What is a recovery key, and how is it different from an unseal key?**
Unseal keys (Shamir) reconstruct the root key to unseal Vault. With auto-unseal the KMS does that, and recovery keys only authorize privileged operations such as generating a root token, rekeying, or seal migration.

**A Vault pod is sealed after a restart. What do you do?**
Confirm with `vault status` and the `vault-sealed` label. With auto-unseal, read the logs for KMS errors (IAM, key state, network) and fix the cause, then restart the pod. With Shamir, run `vault operator unseal` with a threshold of different keys on each pod. Then verify Raft peers and that ESO recovers.

**How does ESO authenticate to Vault in Kubernetes?**
Through the Kubernetes auth method: ESO sends its ServiceAccount JWT to Vault; Vault validates it via the Kubernetes TokenReview API (using a reviewer token, or its own ServiceAccount when in-cluster); if the SA name and namespace match a role, Vault returns a short-lived token with that role's policies.

**Why revoke the root token?**
It has unlimited power and never expires. Use it to bootstrap, create admin policies and an SSO login, then revoke it; regenerate with recovery/unseal keys only for break-glass and revoke again.

**What is Raft and why use it?**
Vault's integrated storage using the Raft consensus protocol: replicated across nodes, needs a quorum (majority) to commit writes, supports snapshots, and removes the need for an external storage system like Consul.

**What happens if you lose quorum?**
Vault can't elect a leader and becomes unavailable (reads of secrets also stop). Bring failed nodes back; if data is lost, recover via Raft peers recovery or restore a snapshot.

**What are dynamic secrets?**
Credentials generated on demand with a TTL and a lease, for example a temporary Postgres user that expires after an hour and can be revoked immediately. No long-lived shared passwords.

**What is the AppRole auth method?**
Machine authentication using a Role ID plus a Secret ID, suited to CI/CD systems running outside the cluster (for example Jenkins). The Kubernetes method fits workloads inside the cluster.

**How would you back up and restore Vault?**
Scheduled `vault operator raft snapshot save` to encrypted off-site storage, and regular restore tests into a scratch cluster. Remember that restore requires access to the same seal mechanism (KMS key or recovery capability).

**How do you roll out a Vault upgrade without downtime?**
Snapshot first, upgrade standbys one at a time (wait for healthy follower), step down the leader, upgrade it last, and verify versions and peers.
