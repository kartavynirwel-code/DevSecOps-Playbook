# Kubeadm se Kubernetes Cluster Setup Guide (EC2 par)

> Ye guide bilkul basics se start hoti hai. Agar Kubernetes ka concept weak hai, pehle "Kyun" wale section zaroor padhna, phir steps follow karna.

---

## 1. Pehle samjho: Cluster me kaun kaun hota hai?

Kubernetes cluster do type ke nodes se milkar banta hai:

| Node Type | Kaam kya hai |
|---|---|
| **Control Plane (Master)** | Cluster ka "dimaag" — decide karta hai kya, kahan, kaise run hoga. Scheduling, API requests handle karna, cluster ka state maintain karna. |
| **Worker Node** | Cluster ke "haath-pair" — yahan par actual me tumhare containers/pods run hote hain. |

Chhoti testing setup me minimum: **1 Control Plane + 1 Worker Node** (dono alag EC2 instances hone chahiye).

### Kyun alag machine chahiye control plane aur worker ke liye?
Technically ek hi machine par dono role de sakte ho (single-node cluster), lekin real-world simulate karne ke liye aur samajhne ke liye ki traffic/pods kaise distribute hote hain, 2 separate EC2 instances lena best hai.

---

## 2. EC2 Instances Ready Karna (Dono Nodes Ke Liye Common)

### Instance Requirements
| Cheez | Recommendation |
|---|---|
| OS | Ubuntu 22.04 LTS (sabse smooth experience deta hai) |
| Control Plane RAM | Minimum 2GB (4GB better) |
| Worker Node RAM | Minimum 2GB |
| vCPU | Minimum 2 |
| Storage | 20GB+ |

### Security Group me ye Ports Kholna Zaroori Hai

**Control Plane par:**
| Port | Kis liye |
|---|---|
| 6443 | Kubernetes API server — worker isi se baat karta hai |
| 2379-2380 | etcd server client API |
| 10250 | Kubelet API |
| 10259 | kube-scheduler |
| 10257 | kube-controller-manager |

**Worker Node par:**
| Port | Kis liye |
|---|---|
| 10250 | Kubelet API |
| 30000-32767 | NodePort Services range |

**Dono par:** SSH (22) khula hona chahiye taaki tum connect kar sako.

> ⚠️ Problem jo log face karte hain: Security group me ports open nahi karte aur phir `kubeadm join` fail hota hai ya nodes "NotReady" reh jaate hain. Isliye ye step skip mat karna.

---

## 3. Common Setup — Dono Nodes (Control Plane + Worker) Par Karna Hai

Ye saare steps **dono machines par same** chalane hain, kyunki dono ko kubelet chalana hota hai aur container run karne hote hain.

### Step 3.1: System Update
```bash
sudo apt-get update && sudo apt-get upgrade -y
```
**Kyun:** Purane packages ki wajah se dependency conflicts aate hain.

---

### Step 3.2: Swap Disable Karna
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```
**Kyun:** Kubernetes scheduler resources (RAM/CPU) predict karke pods schedule karta hai. Agar swap on hoga, to memory management unpredictable ho jaata hai. Isliye **kubelet swap ke saath start hi nahi hota** (until explicitly configured, jo advanced hai).

**Problem:** Agar swapoff nahi kiya to `kubeadm init` ya `kubelet` service start hone par error dega: `"running with swap on is not supported"`.

---

### Step 3.3: Kernel Modules Load Karna
```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```
**Kyun:**
- `overlay` — container runtime ko layered filesystem chahiye hota hai images ke liye.
- `br_netfilter` — ye module bridge network traffic ko iptables rules ke through pass karne deta hai, jo Pod-to-Pod aur Pod-to-Service networking ke liye zaroori hai.

---

### Step 3.4: Networking Sysctl Params Set Karna
```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```
**Kyun:** Ye settings kernel ko bolti hain ki bridge traffic ko iptables rules follow karne do, aur IP forwarding enable karo (taaki packets ek interface se dusre tak jaa sakein — Pods ke beech communication ke liye zaroori).

**Problem:** Agar ye set nahi kiya, to Pods aapas me communicate nahi kar payenge, aur CNI plugin (jaise Calico/Flannel) sahi se kaam nahi karega.

---

### Step 3.5: Container Runtime Install Karna (containerd)

Kubernetes ko containers chalane ke liye ek "Container Runtime" chahiye. 2020 ke baad se Docker directly support nahi hota (dockershim hat gaya), isliye **containerd** use karte hain.

```bash
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
```

Ab config.toml me ek important change karna hai — `SystemdCgroup` ko `true` karna:
```bash
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

**Kyun ye SystemdCgroup change zaroori hai:**
Ubuntu system `systemd` cgroup driver use karta hai resource management (CPU/Memory limits) ke liye. Agar containerd aur kubelet alag-alag cgroup drivers use karein (ek `cgroupfs`, dusra `systemd`), to cluster unstable ho jaata hai — ye **sabse common problem** hai jo naye log face karte hain (`"cgroup driver mismatch"`).

```bash
sudo systemctl restart containerd
sudo systemctl enable containerd
```

---

### Step 3.6: kubeadm, kubelet, kubectl Install Karna

```bash
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

**Teeno cheezon ka kaam samjho (yahi sabse zyada confuse karta hai):**

| Tool | Kya karta hai | Kahan chahiye |
|---|---|---|
| **kubelet** | Har node par background me chalne wala agent — control plane se instructions leke actual containers start/stop karta hai | Control Plane + Worker dono |
| **kubeadm** | Cluster **bootstrap** karne ka tool — cluster banana (`init`) aur usme join karna (`join`) isi se hota hai | Control Plane + Worker dono |
| **kubectl** | Cluster se **baat karne ka CLI tool** — commands chalane ke liye (`kubectl get pods` etc.) | Mainly Control Plane par (worker par optional hai) |

`apt-mark hold` isliye kiya taaki accidental `apt upgrade` se version mismatch na ho jaaye — Kubernetes version mismatch se cluster break ho sakta hai.

---

## 4. Ab Yahan Se Alag Ho Jaate Hain — Control Plane Specific Steps

Ye steps **sirf Control Plane (Master) node par** karne hain.

### Step 4.1: Cluster Initialize Karna
```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=<CONTROL_PLANE_PRIVATE_IP>
```

**Kyun `--pod-network-cidr` diya:** Ye range Pods ko internal IP address dene ke liye reserve hoti hai. `10.244.0.0/16` Flannel CNI ka default hai (agar Calico use karoge to unka apna range hoga).

**Kyun `--apiserver-advertise-address`:** EC2 me multiple network interfaces/IPs ho sakti hain, isliye explicitly bata do ki API server kis private IP par advertise ho, warna wrong IP pick ho sakti hai jisse worker connect nahi kar payenge.

Command complete hone ke baad terminal me ek `kubeadm join ...` command milegi with a token — **isko copy karke safe rakh lena**, worker node par yahi chalani hai.

---

### Step 4.2: kubectl Config Set Karna (taaki cluster ko control kar sako)
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```
**Kyun:** `kubectl` ko pata hona chahiye kis cluster se, kaunse credentials se baat karni hai — ye info `admin.conf` me hoti hai. Ye copy karke default location par daal rahe hain.

---

### Step 4.3: CNI (Container Network Interface) Install Karna

Bina CNI ke tumhara cluster **"NotReady"** state me atka rahega. Ye bahut common confusion hai — log `kubeadm init` ke baad expect karte hain ki node ready ho jaayega, lekin CNI plugin install karna ek separate zaroori step hai.

**Kyun CNI chahiye:** Kubernetes khud Pod networking implement nahi karta — ye kaam CNI plugin (Flannel/Calico/Weave) ka hai jo Pods ko IP address deta hai aur unke beech communication set up karta hai.

Flannel install karne ke liye (agar upar wala `10.244.0.0/16` CIDR use kiya tha):
```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

Check karo:
```bash
kubectl get nodes
```
Status `Ready` aana chahiye control plane node ke liye.

---

## 5. Worker Node Specific Step

Ye sirf **Worker node par** karna hai — Section 3 ke saare common steps complete karne ke baad.

### Step 5.1: Cluster Join Karna
```bash
sudo kubeadm join <CONTROL_PLANE_IP>:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```
Ye wahi command hai jo `kubeadm init` ke output me mili thi.

**Kyun:** Ye command worker ko batati hai ki kis control plane se connect hona hai, aur token/hash security verification ke liye hain (taaki koi random machine cluster me join na kar le).

**Problem — Token expire ho gaya to?**
Kubeadm join token by default **24 hours** me expire ho jaata hai. Agar expire ho gaya:
```bash
# Control plane par naya token generate karo
kubeadm token create --print-join-command
```

---

## 6. Verify Karna Ki Sab Sahi Chal Raha Hai

Control plane par:
```bash
kubectl get nodes
```
Dono nodes (`control-plane` + `worker`) **Ready** status me dikhne chahiye.

```bash
kubectl get pods -A
```
System pods (`kube-system` namespace) sab **Running** state me hone chahiye.

---

## 7. Common Problems & Fixes (Cheat Sheet)

| Problem | Wajah | Fix |
|---|---|---|
| Node "NotReady" reh jaata hai | CNI plugin install nahi kiya | Flannel/Calico apply karo |
| `kubeadm init` fail: "swap is enabled" | Swap off nahi kiya | `sudo swapoff -a` |
| Worker join fail — connection timeout | Security group me port 6443 closed | SG me port 6443 allow karo |
| "cgroup driver mismatch" error | containerd aur kubelet ke cgroup driver alag | containerd config me `SystemdCgroup = true` set karo |
| Join token invalid/expired | 24hrs se zyada time ho gaya | `kubeadm token create --print-join-command` se naya token lo |
| Pods "Pending" state me atke | Worker node hi nahi joined, ya resources kam hain | `kubectl get nodes` check karo, resources badhao |
| `kubectl` command not found ya "connection refused" | kubeconfig set nahi kiya | Section 4.2 wale steps dobara karo |

---

## 8. Quick Summary — Kahan Kya Install Hota Hai

| Component | Control Plane | Worker Node |
|---|---|---|
| containerd | ✅ | ✅ |
| kubelet | ✅ | ✅ |
| kubeadm | ✅ | ✅ |
| kubectl | ✅ (zaroori) | Optional |
| `kubeadm init` | ✅ (sirf yahan) | ❌ |
| `kubeadm join` | ❌ | ✅ (sirf yahan) |
| CNI plugin apply | ✅ (yahan se apply hota hai) | Automatically effect hota hai |
| kubeconfig (`~/.kube/config`) | ✅ | Optional |

---

**Bas itna karne ke baad tumhara fully functional 2-node kubeadm cluster ready hoga.** Agar aage koi specific error aaye to wo error message share karna, us hisaab se debug kar sakte hain.
