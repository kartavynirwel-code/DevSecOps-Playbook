# HashiCorp Vault + External Secrets Operator (ESO) — Secret Management

Bank locker for secrets — passwords, API keys, DB credentials, certificates.

---

## 1. Problem Vault Solves

| Without Vault | With Vault |
|---|---|
| Passwords in `.env` files | Secrets stored in Vault |
| Secrets in Git repo | Apps fetch secrets at runtime |
| Same secret for everyone | Dynamic secrets per app |
| No audit trail | Full audit log |
| Manual rotation | Automatic secret rotation |
| Secrets never expire | TTL-based secret expiry |

---

## 2. Architecture

- **Storage Backend** — where Vault's own data (encrypted) is stored (Raft integrated storage, Consul, S3, File — File/Raft-single-node is dev/learning only, never prod)
- **Auth Methods** — how clients authenticate (Token, Userpass, AppRole, Kubernetes, JWT/OIDC, AWS IAM)
- **Secret Engines** — where secrets live (KV store, Database, AWS, PKI)
- **Seal/Unseal Mechanism** — Vault storage is always encrypted at rest. Vault starts **sealed** — it cannot read its own storage until it has the encryption key. `vault server -dev` hides this by auto-unsealing with a throwaway key.

**How this project's flow will actually look (K8s + ESO, not Agent Injector):**

```
Vault (secret store)
   ↓
ClusterSecretStore   → Vault ka connection + auth config
   ↓
ExternalSecret        → kaunsa Vault path se kaunsa secret chahiye
   ↓
ESO controller auto-creates a normal Kubernetes Secret
   ↓
Deployment references that K8s Secret (normal secretKeyRef syntax — nothing new here)
```

> Note: Agent Injector (sidecar/init-container that injects secrets as files) is a *different* Vault-K8s integration pattern. We are using **ESO**, which produces a normal K8s `Secret` object instead — simpler, and app code / Deployment YAML stays exactly like what you already know.

---

## 3. Install & Run Vault (Dev Mode — learning only)

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install vault -y
vault -version
```

Run dev server (listen on all interfaces — k3s needs to reach it, not just localhost):

```bash
vault server -dev -dev-listen-address="0.0.0.0:8200"
```

In a **new terminal**:

```bash
export VAULT_ADDR='http://<EC2-private-ip-or-localhost>:8200'
export VAULT_TOKEN='<root-token-printed-when-server-started>'
vault status
```

⚠️ Dev mode: in-memory storage (data lost on restart), auto-unsealed, root token handed to you directly, TLS disabled. **Never use for anything real** — exists only to practice commands. Production setup (Raft storage, TLS, manual unseal with Shamir keys) is a separate hardening exercise — see Section 9.

---

## 4. KV Secret Engine — Store the Notes App Secrets

```bash
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
vault kv get -version=1 secret/notes-app/db   # KV v2 keeps version history
vault kv delete secret/notes-app/db
vault kv undelete -versions=1 secret/notes-app/db
```

---

## 5. Kubernetes Auth Method — Let k3s Authenticate to Vault

```bash
vault auth enable kubernetes
```

Vault needs to verify tokens against your k3s API server. Pull the required values **from your k3s cluster**:

```bash
# ServiceAccount that Vault will use to validate other tokens (token reviewer)
kubectl create serviceaccount vault-auth -n default

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

> **k3s 1.24+ note:** ServiceAccount tokens no longer auto-generate a Secret by default — that's why we manually created `vault-auth-token` above with the annotation. If this step errors out, check `kubectl get secret vault-auth-token -n default -o yaml` first before debugging further.

---

## 6. Policy + Role — Least-Privilege Access for the Notes App

```bash
vault policy write notes-app-policy - <<EOF
path "secret/data/notes-app/*" {
  capabilities = ["read"]
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

> Note: KV v2 paths internally prefix with `data/` — `vault kv put secret/notes-app/db` maps to actual API path `secret/data/notes-app/db`, hence the policy path above says `secret/data/notes-app/*`.

`notes-app-sa` is the ServiceAccount that will be bound to the Notes app's Deployment (created in Step 8).

---

## 7. Install External Secrets Operator (Helm)

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

kubectl get pods -n external-secrets   # all pods should be Running
```

---

## 8. ServiceAccount for the Notes App

```yaml
# notes-app-sa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: notes-app-sa
  namespace: default
```

```bash
kubectl apply -f notes-app-sa.yaml
```

---

## 9. ClusterSecretStore — Vault Connection Config

```yaml
# cluster-secret-store.yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://<vault-ip>:8200"
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

```bash
kubectl apply -f cluster-secret-store.yaml
kubectl get clustersecretstore vault-backend
# STATUS column should show: Valid
```

---

## 10. ExternalSecret — What to Fetch, Where to Put It

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
    name: notes-app-db-secret     # <- this K8s Secret gets auto-created
  data:
    - secretKey: username
      remoteRef:
        key: notes-app/db
        property: username
    - secretKey: password
      remoteRef:
        key: notes-app/db
        property: password
    - secretKey: api_key
      remoteRef:
        key: notes-app/db
        property: api_key
```

```bash
kubectl apply -f external-secret.yaml
kubectl get externalsecret          # STATUS: SecretSynced
kubectl get secret notes-app-db-secret -o yaml   # verify it exists with the right keys
```

---

## 11. Deployment — Reference the Auto-Created Secret

Nothing new in syntax here — this is the same `secretKeyRef` pattern already used across DevHub 2.0 / QuickCart / Terra & Oak.

```yaml
spec:
  template:
    spec:
      serviceAccountName: notes-app-sa   # <-- required, or ESO auth fails
      containers:
        - name: notes-app
          env:
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: notes-app-db-secret   # must match target.name from Step 10
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

**Known trap (matches the Secret-naming-mismatch bug already hit once before):** `Deployment.secretKeyRef.name` must exactly equal `ExternalSecret.spec.target.name` from Step 10 — not the Vault path, not the ExternalSecret's own `metadata.name`. If pods start with empty env vars, this mismatch is the first thing to check.

---

## 12. Verification Checklist (run in this order when debugging)

```bash
vault status                                   # Sealed = false?
vault kv get secret/notes-app/db               # secret actually in Vault?
kubectl get clustersecretstore vault-backend   # Valid?
kubectl get externalsecret                     # SecretSynced?
kubectl get secret notes-app-db-secret -o yaml # keys present & correct?
kubectl describe pod <notes-app-pod>           # env vars populated? auth errors in events?
kubectl logs -n external-secrets deploy/external-secrets   # ESO controller logs — auth/permission errors show here
```

---

## 13. Vault vs K8s Secrets vs .env

| Feature | .env | K8s Secrets | Vault |
|---|---|---|---|
| Security | Very Low | Medium | Very High |
| Encrypted at rest | No | Only if etcd encryption configured | Yes, always |
| Audit Log | No | Basic | Full trail |
| Auto Rotation | No | No | Yes |
| Dynamic Secrets | No | No | Yes |
| Access Control | None | RBAC | Fine-grained policies |
| Use for | Local dev | Basic K8s apps | Production |

---

## 14. Production Hardening Checklist (for later — not needed for dev-mode project)

- [ ] TLS enabled on listener (never `tls_disable = "true"` in real prod)
- [ ] Raft (integrated storage) or Consul as storage backend — not File
- [ ] Unseal keys distributed among multiple trusted people (Shamir's Secret Sharing) — no single person holds all keys
- [ ] Root token revoked after initial admin setup (`vault token revoke <root-token>`); day-to-day access via policy-scoped tokens/AppRole
- [ ] Audit logging enabled: `vault audit enable file file_path=/var/log/vault_audit.log`
- [ ] Auto-unseal configured for real clusters (AWS/cloud KMS) so a human isn't manually unsealing after every restart
- [ ] Least-privilege policies per service/team — never blanket `path "secret/*" { capabilities = ["read","list","create","update","delete"] }`

---

## Interview Questions

**Q: What is HashiCorp Vault?**
Secret management tool — securely stores and controls access to passwords, API keys, certificates. Audit logging, dynamic secrets, auto rotation deta hai.

**Q: Why Vault over Kubernetes Secrets?**
K8s Secrets base64-encoded hain — encrypted nahi by default. Vault encryption at rest, fine-grained policies, full audit trail, aur dynamic secret generation deta hai. Production-grade.

**Q: What is External Secrets Operator (ESO), and why use it over Agent Injector?**
ESO ek K8s controller hai jo external secret managers (Vault, AWS Secrets Manager, etc.) se secrets fetch karke native K8s `Secret` objects bana deta hai. Agent Injector secrets ko file ke form me pod ke andar inject karta hai (sidecar pattern), jisse app code ko file-read logic chahiye hota hai. ESO se app code me zero change hota hai — Deployment same purana `secretKeyRef` pattern use karta hai, sirf Secret ka source ab Vault ban jata hai.

**Q: What is seal/unseal in Vault, and why does it matter?**
Vault apna storage hamesha encrypted rakhta hai; fresh start ya restart ke baad Vault "sealed" state me hota hai aur data read nahi kar sakta jab tak use decryption key na mile. `vault operator init` root key ko Shamir's Secret Sharing se multiple unseal keys me split kar deta hai (default 5 keys, threshold 3) — koi single person ke paas poora access nahi hota. Production me ye manual process auto-unseal (cloud KMS) se automate kiya jaata hai.

**Q: How does ESO authenticate to Vault in Kubernetes?**
Kubernetes auth method ke through — ESO ek ServiceAccount token use karta hai (`ClusterSecretStore` me `serviceAccountRef` specify hota hai), Vault us token ko apne configured Kubernetes API server ke against verify karta hai (`token_reviewer_jwt` setup), aur agar role/policy match kare to short-lived Vault token issue hota hai.

**Q: What are dynamic secrets?**
Vault on-demand credentials generate karta hai with a TTL. Jaise ek temporary DB user create hota hai jo 1 hour baad expire ho jaata hai — no long-lived credentials.

**Q: What is AppRole auth method?**
Machine-to-machine authentication — CI/CD pipeline ko Role ID + Secret ID milta hai Vault se authenticate karne ke liye. (Alternative to Kubernetes auth — useful for Jenkins running outside the cluster.)
