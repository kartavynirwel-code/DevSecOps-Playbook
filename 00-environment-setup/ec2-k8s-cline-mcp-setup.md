# EC2 Kubernetes Cluster + Cline MCP Setup (Prod Read-Only + Staging)

> Ye guide un logon ke liye hai jinhone pehle kabhi ye setup nahi kiya.
> Har step ke saath likha hai **kya ho raha hai** aur **kyun**.

---

## 0. Goal: hum kya bana rahe hain

Cluster **EC2** par chal raha hai. Hum chahte hain ki laptop par **Cline** (VS Code) ke through AI cluster ki state dekh sake:

- **Prod** ke liye: sirf **read-only** access (dekh sakta hai, badal nahi sakta)
- **Staging** ke liye: debugging ke liye thoda zyada access (par delete nahi)

```
 Laptop                                   EC2 (AWS)
┌─────────────────────────┐              ┌──────────────────────────┐
│ VS Code + Cline         │              │ Control plane            │
│   │                     │              │   API server :6443       │
│   ▼                     │   SSH tunnel │      ▲                   │
│ MCP server (npx)        │◄════════════►│      │                   │
│   │  uses kubeconfig    │  (encrypted) │  Prod namespace          │
│   ▼  + token            │              │  Staging namespace       │
│ 127.0.0.1:6443          │              └──────────────────────────┘
└─────────────────────────┘
```

**Important idea:** port 6443 ko internet par open nahi karte. SSH tunnel se laptop ka `127.0.0.1:6443` EC2 ke API server se jud jata hai.

---

## 1. Pehle ye shabd samajh lo

| Shabd | Matlab (simple) |
|---|---|
| **API server** | Cluster ka "darwaza". `kubectl` aur MCP isi se baat karte hain (port 6443) |
| **kubeconfig** | Ek file jisme likha hota hai: kaunse cluster se judna hai, kis user/token se |
| **context** | kubeconfig ke andar ek combo: cluster + user + namespace |
| **ServiceAccount** | Ek "robot user" jo Kubernetes ke andar banta hai |
| **Token** | Us robot user ka password (ek lambi string) |
| **RBAC** | Rules: kaun kya kar sakta hai |
| **Role / ClusterRole** | Permissions ka set (jaise "sirf dekh sakta hai") |
| **RoleBinding** | Role ko kisi user se jodna (ek namespace ke andar) |
| **ClusterRoleBinding** | Role ko poore cluster ke liye jodna |
| **SSH tunnel** | Laptop ke ek port ko EC2 ke port se secure tareeke se jodna |
| **MCP server** | Chhota program jo AI ko `kubectl` jaise tools deta hai |

**Sabse zaroori baat:** safety RBAC se aati hai (Kubernetes ke andar). MCP ke flags extra layer hain, un par akele bharosa mat karo.

---

## 2. Pehle ye ready rakho (Checklist)

- [ ] EC2 control plane ka SSH access (`.pem` key + public IP)
- [ ] Laptop par **VS Code + Cline extension**
- [ ] Laptop par **Node.js** (`node -v` chalao, version dikhna chahiye. `npx` isi ke saath aata hai)
- [ ] Laptop par **kubectl** (`kubectl version --client`)
- [ ] EC2 Security Group mein **SSH (port 22)** allow ho (sirf apne IP se)
- [ ] Windows ho to **Git Bash ya WSL** use karo (ye guide bash commands ke liye hai)

---

## 3. Step 1: Control plane par access banao (EC2 par)

### 3.1 EC2 mein SSH karo

```bash
ssh -i key.pem ubuntu@<CONTROL-PLANE-PUBLIC-IP>
```

Ab tum EC2 ke andar ho. Check karo `kubectl` chal raha hai:

```bash
kubectl get nodes
```

### 3.2 Cluster ka CA certificate nikalo

Ye certificate **public** hota hai (isse laptop verify karta hai ki wo sahi cluster se baat kar raha hai). Isse safe tareeke se nikalo:

```bash
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
cat ca.crt
```

`-----BEGIN CERTIFICATE-----` se shuru hona chahiye. Is file ko laptop par copy karna hai (Step 3 mein).

### 3.3 Prod ke liye READ-ONLY user banao

```bash
kubectl create serviceaccount mcp-readonly -n kube-system
kubectl create clusterrolebinding mcp-readonly --clusterrole=view --serviceaccount=kube-system:mcp-readonly
```

- `view` role: pods, services, deployments, logs, events dekh sakta hai.
- **Secrets nahi dekh sakta** (ye achhi baat hai).
- Kuch badal ya delete nahi kar sakta.

**Optional (nodes dekhne ke liye):** `view` role nodes nahi dikhata, jo debugging mein kaam aate hain:

```bash
kubectl create clusterrole node-reader --verb=get,list,watch --resource=nodes
kubectl create clusterrolebinding mcp-readonly-nodes --clusterrole=node-reader --serviceaccount=kube-system:mcp-readonly
```

### 3.4 Staging ke liye user banao

Staging agar **usi cluster ke `staging` namespace** mein hai:

```bash
kubectl create serviceaccount mcp-staging -n staging
kubectl create rolebinding mcp-staging-edit --clusterrole=edit --serviceaccount=staging:mcp-staging -n staging
```

- `RoleBinding` sirf `staging` namespace mein kaam karta hai. Ye user **prod namespace ko chhu hi nahi sakta**.
- `edit` role: create/update/delete, pod mein exec, logs.
- Dhyan do: `edit` role us namespace ke **Secrets bhi padh sakta hai**. Staging mein **real/prod secrets mat rakho**, sirf dummy values.

> Agar staging **alag cluster/EC2** par hai: Step 3.1 se 3.4 us cluster par bhi karo, aur tunnel ke liye alag local port use karo (Section 8 dekho).

### 3.5 Tokens banao

```bash
kubectl create token mcp-readonly -n kube-system --duration=24h
kubectl create token mcp-staging -n staging --duration=24h
```

Har command ek **bahut lambi string** (`eyJhbGci...`) print karti hai. Wahi token hai.

**Dono ko alag-alag copy karke kisi private jagah (notepad) mein rakh lo. Label laga do: PROD-TOKEN aur STAGING-TOKEN.**

> **Kya ye token laptop par chala sakte ho? Haan.** Token banane ka command control plane par chalta hai (kyunki wahan admin access hai), aur jo token milta hai wo laptop par use hota hai. Ye token 24 ghante baad expire ho jata hai (Section 9).

**Token ka dhyan:**
- Token ko kabhi Git mein, chat mein, ya screenshot mein mat daalo.
- Isse jiske paas ho, wo is user ke barabar access paa leta hai.
- Isiliye prod ka token read-only user ka hai aur 24h ka hai.

Ab `exit` likh ke EC2 se bahar aao. Phir CA certificate laptop par copy karo:

```bash
scp -i key.pem ubuntu@<CONTROL-PLANE-PUBLIC-IP>:~/ca.crt ./ca.crt
```

---

## 4. Step 2: Laptop par SSH tunnel chalao

Ek **naya terminal** kholo aur ye command chalake **khula chhod do**:

```bash
ssh -i key.pem -N -L 6443:127.0.0.1:6443 ubuntu@<CONTROL-PLANE-PUBLIC-IP>
```

- `-L 6443:127.0.0.1:6443` → laptop ka port 6443 → EC2 ka API server.
- `-N` → koi shell nahi kholta, sirf tunnel.
- Output kuch nahi dikhega. Ye normal hai. Terminal band karoge to tunnel band.

Ek hi tunnel prod aur staging dono ke liye kaafi hai (agar dono usi cluster mein hain).

---

## 5. Step 3: Laptop par kubeconfig files banao

**Kyun alag files?** Ek hi `~/.kube/config` mein dono rakhne se galti ho sakti hai (galat context active ho jaye). Isliye **prod ke liye alag file, staging ke liye alag file**. Prod wali file mein staging ka token hi nahi hoga, aur ulta bhi.

`ca.crt` wale folder mein ye commands chalao. `PASTE_TOKEN` ki jagah apna token daalo.

### 5.1 Prod (read-only) file

```bash
kubectl config --kubeconfig=$HOME/.kube/mcp-prod-readonly.yaml set-cluster ec2-k8s --server=https://127.0.0.1:6443 --certificate-authority=./ca.crt --embed-certs=true --tls-server-name=kubernetes

kubectl config --kubeconfig=$HOME/.kube/mcp-prod-readonly.yaml set-credentials mcp-readonly --token=PASTE_PROD_TOKEN

kubectl config --kubeconfig=$HOME/.kube/mcp-prod-readonly.yaml set-context ec2-readonly --cluster=ec2-k8s --user=mcp-readonly

kubectl config --kubeconfig=$HOME/.kube/mcp-prod-readonly.yaml use-context ec2-readonly
```

### 5.2 Staging file

```bash
kubectl config --kubeconfig=$HOME/.kube/mcp-staging.yaml set-cluster ec2-k8s --server=https://127.0.0.1:6443 --certificate-authority=./ca.crt --embed-certs=true --tls-server-name=kubernetes

kubectl config --kubeconfig=$HOME/.kube/mcp-staging.yaml set-credentials mcp-staging --token=PASTE_STAGING_TOKEN

kubectl config --kubeconfig=$HOME/.kube/mcp-staging.yaml set-context ec2-staging --cluster=ec2-k8s --user=mcp-staging --namespace=staging

kubectl config --kubeconfig=$HOME/.kube/mcp-staging.yaml use-context ec2-staging
```

**`--tls-server-name=kubernetes` kyun?** Kubeadm ka certificate `127.0.0.1` ke liye valid nahi hota, par `kubernetes` naam ke liye hota hai. Is flag ke bina TLS error aata hai.

> Token terminal history mein save ho sakta hai. Ye sirf tumhara laptop hai aur token 24h mein expire hota hai, isliye risk kam hai. Phir bhi shared computer par ye mat karo.

---

## 6. Step 4: Pehle terminal se test karo (Cline se pehle)

**Hamesha pehle terminal se test karo.** Agar yahan chal gaya to Cline mein bhi chalega.

```bash
# Prod (read-only)
kubectl --kubeconfig=$HOME/.kube/mcp-prod-readonly.yaml get pods -A
kubectl --kubeconfig=$HOME/.kube/mcp-prod-readonly.yaml get nodes

# Ye FAIL hona chahiye (read-only hai, "forbidden" error aayega) 
kubectl --kubeconfig=$HOME/.kube/mcp-prod-readonly.yaml delete pod <koi-pod> -n prod

# Staging
kubectl --kubeconfig=$HOME/.kube/mcp-staging.yaml get pods
```

Delete ka **fail hona achha hai**: ye proof hai ki read-only sach mein read-only hai.

---

## 7. Step 5: Cline mein MCP add karo

1. VS Code mein Cline kholo.
2. Upar **MCP** tab → **Installed** → **Edit Configuration** par click karo (ye local server hai, isliye "Add Remote Server" nahi).
3. JSON file khulegi. Usme ye daalo.

**Apna username aur path badlo.** Windows par path aisa hoga: `C:\\Users\\<naam>\\.kube\\mcp-prod-readonly.yaml` (double backslash).

```json
{
  "mcpServers": {
    "k8s-prod-readonly": {
      "command": "npx",
      "args": ["mcp-server-kubernetes@latest"],
      "env": {
        "KUBECONFIG_PATH": "/home/<username>/.kube/mcp-prod-readonly.yaml",
        "K8S_CONTEXT": "ec2-readonly",
        "ALLOW_ONLY_READONLY_TOOLS": "true"
      }
    },
    "k8s-staging": {
      "command": "npx",
      "args": ["mcp-server-kubernetes@latest"],
      "env": {
        "KUBECONFIG_PATH": "/home/<username>/.kube/mcp-staging.yaml",
        "K8S_CONTEXT": "ec2-staging",
        "ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS": "true"
      }
    }
  }
}
```

**Har line ka matlab:**

| Setting | Kaam |
|---|---|
| `KUBECONFIG_PATH` | Kaunsi kubeconfig file use karni hai (ye alag-alag files safety deti hain) |
| `K8S_CONTEXT` | File ke andar kaunsa context |
| `ALLOW_ONLY_READONLY_TOOLS` | Sirf get/describe/logs jaise tools (prod ke liye) |
| `ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS` | Delete wale tools band, baaki chalenge (staging ke liye) |
| `@latest` | Hamesha naya version. Purane versions mein in access-control flags se jude security issues report hue the (CVE-2026-46519, version 3.6.0 se pehle) |

4. Save karo. **Installed** tab mein dono servers dikhenge. Green indicator = chal raha hai. Red = error (Section 10 dekho).

---

## 8. Agar staging ALAG cluster par hai

- Us cluster par Step 3.1 se 3.5 dohrao.
- Tunnel ke liye **alag local port** (6443 pehle se prod use kar raha hai):

```bash
ssh -i key2.pem -N -L 6444:127.0.0.1:6443 ubuntu@<STAGING-CONTROL-PLANE-IP>
```

- Staging kubeconfig ke `set-cluster` mein `--server=https://127.0.0.1:6444` aur **staging cluster ka apna `ca.crt`** use karo.

---

## 9. Token expire ho jaye to (24h baad)

Symptom: "Unauthorized" error.

1. Control plane par SSH karo.
2. Naya token banao (Step 3.5 wala command).
3. Laptop par update karo:

```bash
kubectl config --kubeconfig=$HOME/.kube/mcp-prod-readonly.yaml set-credentials mcp-readonly --token=NAYA_TOKEN
```

4. Cline mein MCP server ko **restart/toggle** karo.

---

## 10. Cline se kaise use karein

**Ek baar mein ek hi environment ON rakho.** Staging debug kar rahe ho to Cline ke MCP tab mein `k8s-prod-readonly` ko **toggle OFF** kar do. Isse galti se galat cluster par kaam nahi hota.

Cline mein ye likh ke try karo:

- "staging namespace ke saare pods ki state batao, jo Running nahi hain unka reason dhoondo"
- "pod `<name>` ke logs dekho aur error ka reason batao"
- "`kubectl describe` se events dekh ke batao pod kyun crash ho raha hai"
- "staging ki deployment config aur prod ki config ka farak batao"

Cline har tool call se pehle **permission maangta hai**. **Auto-approve on mat karna.** Har call khud padh ke approve karo.

---

## 11. Troubleshooting

| Problem | Kaaran | Fix |
|---|---|---|
| `connection refused 127.0.0.1:6443` | SSH tunnel band hai | Section 4 wala tunnel dobara chalao |
| `x509: certificate is valid for ... not 127.0.0.1` | `--tls-server-name` nahi lagaya | Section 5 ka `set-cluster` flag ke saath dobara chalao |
| `Unauthorized` | Token expire ya galat paste | Section 9 |
| `forbidden: ... cannot list resource "nodes"` | Node-reader role nahi banaya | Section 3.3 ka optional step |
| `forbidden ... delete` (prod par) | Sahi hai! Read-only kaam kar raha hai | Kuch mat karo |
| Cline mein server red | Node.js nahi, ya path galat | `node -v` check, JSON ka path check |
| `npx` command nahi mila | Node.js install nahi | Node.js LTS install karo |
| Dono server same cluster dikha rahe | Kubeconfig path/context galat | Section 7 JSON dobara check, dono ke path alag ho |

**Error aaye to debug karne ka sabse accha tareeka:** pehle `kubectl --kubeconfig=<file> get pods` terminal se chalao. Wahan fail ho raha ho to problem Cline mein nahi, kubeconfig ya tunnel mein hai.

---

## 12. Safety rules (hamesha yaad rakho)

1. **Prod = read-only.** Prod mein debug nahi karte. Rollback karo, debug staging mein.
2. **Rollback se pehle evidence save karo:**
   ```bash
   kubectl logs <pod> --previous > crash.log
   kubectl describe pod <pod> > describe.txt
   kubectl get events -n prod --sort-by=.lastTimestamp > events.txt
   ```
3. **Token Git/chat mein kabhi nahi.**
4. **`admin.conf` kabhi MCP ko mat do.** Wo full admin hai.
5. **Cline mein auto-approve OFF.**
6. **Staging mein real secrets/data nahi.**
7. **Port 6443 ko internet par open mat karo.** Tunnel use karo.
8. MCP secrets masking sirf `kubectl get secrets` output par hoti hai, logs mein secrets aa sakte hain. Isliye app logs mein secrets print mat karo.

---

## 13. Access hataana ho to (cleanup)

Control plane par:

```bash
kubectl delete clusterrolebinding mcp-readonly mcp-readonly-nodes
kubectl delete serviceaccount mcp-readonly -n kube-system
kubectl delete rolebinding mcp-staging-edit -n staging
kubectl delete serviceaccount mcp-staging -n staging
```

ServiceAccount delete karte hi uske saare tokens kaam karna band kar dete hain.

Laptop par: `~/.kube/mcp-prod-readonly.yaml` aur `~/.kube/mcp-staging.yaml` delete kar do.

---

## 14. Quick cheat-sheet

```bash
# 1. Tunnel (alag terminal, khula rakho)
ssh -i key.pem -N -L 6443:127.0.0.1:6443 ubuntu@<IP>

# 2. Naya token (control plane par)
kubectl create token mcp-readonly -n kube-system --duration=24h
kubectl create token mcp-staging  -n staging     --duration=24h

# 3. Test (laptop par)
kubectl --kubeconfig=$HOME/.kube/mcp-prod-readonly.yaml get pods -A
kubectl --kubeconfig=$HOME/.kube/mcp-staging.yaml get pods

# 4. Cline: Staging debug karte waqt prod server OFF
```

**Flow yaad rakho:**
`Prod fail → evidence save → Git revert/purana tag se rollback → staging mein failing image deploy → Cline (staging MCP) se debug → fix branch → PR → staging test → prod`
