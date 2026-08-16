# Kubernetes Networking / CNI — Interview Revision Notes

---

## 1. NAT (Network Address Translation)

**Definition:** Translating one IP address into another as a packet moves between networks — typically when a private IP device communicates with the public internet.

**Example:** Your laptop has private IP `192.168.1.5`. When it hits google.com, your router rewrites the source IP to its public IP (e.g. `103.45.67.89`). Google replies to the public IP, and the router translates it back on the way in.

**Docker context:** Docker's default bridge network uses NAT — a container's internal IP (`172.17.0.2`) isn't visible outside the host, so the host NATs traffic (this is why you need `-p 8080:80` port mapping).

**Kubernetes avoids NAT between pods** — the Kubernetes network model mandates that every pod can reach every other pod directly via its real IP, without NAT, cluster-wide. This keeps things simple: no port-mapping tables, source IP stays visible, easier debugging.

---

## 2. CNI (Container Network Interface)

**What it is:** A **specification/interface**, not an implementation. Kubernetes itself does not implement pod networking — it delegates to a CNI plugin.

**How it fits in:**
- Kubelet calls the CNI plugin binary (`ADD` / `DEL` commands) whenever a pod is created/destroyed, passing the pod's network namespace.
- The plugin's job: assign the pod an IP, wire the pod's network namespace to the host, and set up routes.
- Kubernetes only enforces the **Kubernetes network model**: *"every pod can reach every other pod's IP directly, without NAT, cluster-wide."*

**Common CNI plugins:**

| Plugin  | Approach                                                        |
|---------|-------------------------------------------------------------------|
| Flannel | Simple overlay network (VXLAN) — no native NetworkPolicy support |
| Calico  | BGP-based routing (often no overlay needed) + strong NetworkPolicy enforcement |
| Cilium  | eBPF-based — fast, deep observability + security                 |
| Weave   | Overlay + mesh, simpler setup                                    |

**Configuration — manual vs automatic:**
- **One-time setup (manual-ish):** Applying a CNI manifest (e.g. `kubectl apply -f calico.yaml`) installs a DaemonSet that drops the CNI config file into `/etc/cni/net.d/` on every node, and installs the CNI binary. You don't hand-write this config — the installer does it.
- **Runtime (automatic):** Once installed, kubelet automatically invokes the CNI binary for every new pod — no manual work per pod.

**Typical flow:**
```
Cluster created (kubeadm/minikube) → Nodes stay "NotReady" until CNI is installed
→ Apply a CNI manifest (Calico/Flannel/etc.)
→ Its DaemonSet drops CNI binary + config on every node
→ Nodes become "Ready", pods can now be scheduled with networking
```

**Personal note:** Minikube's default CNI (bridge/kindnet) does NOT support NetworkPolicy. Calico is added explicitly (`--cni=calico` or applied later) whenever NetworkPolicy testing is needed, because Calico brings the policy enforcement engine.

---

## 3. Overlay Networking — VXLAN

**Problem it solves:** Two pods on different nodes need to feel like they're on the same flat network, even though the underlying physical network may not directly support that.

**Mechanism:** VXLAN is a **tunneling protocol** — it wraps (encapsulates) the original packet inside a new UDP packet before sending it over the physical network.

**Packet journey:**
1. Original packet: Pod A (`10.244.1.5`) → Pod B (`10.244.2.8`)
2. Node-1's virtual interface (`flannel.1` / `vxlan.calico`) captures this packet
3. A **VXLAN header** is added, containing a **VNI (VXLAN Network Identifier)** — identifies which virtual network the packet belongs to (isolation, like a VLAN ID)
4. The packet is wrapped inside a **UDP packet**
5. This new UDP packet uses **real node IPs** as source/destination (node-1 → node-2) — original pod IPs are hidden inside
6. Travels over the physical network like a normal UDP packet
7. Node-2's VXLAN interface **decapsulates** it — strips UDP+VXLAN headers, recovers original packet
8. Original packet reaches Pod B via the local bridge

**Why useful:** The underlying network has no idea pod IPs exist — it only sees node-to-node UDP traffic. Works on **any network topology**, no special router config needed.

**Downside:** Encapsulation/decapsulation costs CPU cycles — adds overhead and latency.

---

## 4. Underlay Networking — BGP (Border Gateway Protocol)

**What it is:** A routing protocol originally built to run the internet (ISPs advertise routes to each other). Calico uses it at a smaller scale inside the cluster.

**Core idea:** No encapsulation. Every node acts as a **router**, and nodes use **BGP peering** to advertise which pod subnet they own.

**Mechanism:**
1. Each node is assigned a **pod CIDR block** (e.g. node-1 → `10.244.1.0/24`, node-2 → `10.244.2.0/24`)
2. Calico's BGP agent (**BIRD**) runs on every node
3. Agents form BGP sessions and advertise their subnet: *"Route `10.244.1.0/24` through me (node-1)"*
4. Every node updates its kernel **route table**:
   ```
   10.244.2.0/24 → via node-2's IP
   10.244.1.0/24 → via node-1's IP
   ```
5. When Pod A sends a packet to Pod B, node-1's kernel checks its route table, sees `10.244.2.0/24` routes via node-2
6. Packet is forwarded **without any wrapping** — standard IP routing, same as a home router

**Why fast:** No extra header, no encapsulation/decapsulation overhead — packet travels in its original form.

**Requirement:** Nodes must be **directly L3-reachable** (same network segment or routable subnets). This is usually true inside a cloud VPC (AWS/GCP), so Calico often runs in BGP mode by default there.

---

## 5. Overlay vs Underlay — Quick Comparison

| | VXLAN (Overlay) | BGP (Underlay) |
|---|---|---|
| Extra header?          | Yes (wrap/unwrap)         | No (raw packet)              |
| Speed                  | Slightly slower (CPU overhead) | Faster (native)         |
| Works everywhere?      | Yes, any network topology | Only if nodes are L3-reachable |
| Used by                | Flannel (default), Calico (fallback mode) | Calico (default when possible) |

**One-liner:**
> VXLAN = "wrap the packet, works anywhere." BGP = "update route tables, send raw, fast but network-dependent."

---

## 6. L2 vs L3 (OSI Model context)

| Layer | Name | Job | Example |
|---|---|---|---|
| L2 | Data Link | Communication within the same local network | MAC address, switches |
| **L3** | **Network** | **Routing between different networks** | **IP address, routers** |
| L4 | Transport | End-to-end connection, reliability | TCP/UDP, ports |

**L2 (same network):** Devices on the same subnet/LAN talk directly via MAC address through a switch — no routing decision needed.

**L3 (different networks):** Devices on different subnets need **routing** — IP addresses are used, and a router decides which direction to forward the packet.

**"L3-reachable" (used in the BGP context):** Node-1 can reach node-2 using **pure IP routing** (no tunneling/wrapping needed) — whether they're on the same subnet or on different subnets connected via a router.

- Cloud VPCs (AWS/GCP) are normally L3-reachable by default → Calico can use BGP (underlay) directly.
- If L3 reachability isn't available (complex on-prem setups, blocking security groups, disconnected subnets) → Calico falls back to VXLAN (overlay) to bypass the problem via encapsulation.

**Analogy:**
- L2 = same building, room-to-room directly (no address needed, just know the room)
- L3 = different buildings, you need an address (IP) and a courier/router in between

---

## 7. kube-proxy — Service Routing

**Role:** Converts Service → Pod IP mapping into **kernel-level rules**, so packet forwarding happens in the kernel (fast, no userspace hop). Runs as a daemon on every node.

### Mode 1: iptables (default, older)
- Watches Services and Endpoints via the API server
- Builds **iptables rules** on each node for every Service
- When a packet hits a ClusterIP, iptables chains use **random probability-based selection** to pick a backend pod
- **Problem:** Rules are **linear** — with thousands of Services, matching a packet may require traversing thousands of rules (O(n) complexity). Slow at scale.

### Mode 2: IPVS (newer, scales better)
- IPVS = Linux kernel's built-in **load balancer**, more efficient than iptables
- **Hash table lookup — O(1) complexity**, regardless of Service count
- Supports real load-balancing algorithms: round-robin, least connection, source hashing (iptables only supports random)
- Recommended for large/production clusters

**Check active mode:**
```bash
kubectl -n kube-system get configmap kube-proxy -o yaml | grep mode
```

**Note:** Calico's NetworkPolicy enforcement also uses iptables (or eBPF in newer versions) — but these are **separate rule sets** from kube-proxy's Service-routing rules. Both coexist on the same node for different purposes:
- kube-proxy rules → "which Pod IP should this Service IP forward to"
- Calico rules → "is this traffic allowed or blocked"

---

## 8. Traffic Path: Pod-to-Pod vs Pod-to-Service

### Pod-to-Pod Direct (e.g. using a Pod IP directly, like with StatefulSets)
```
Pod A (10.244.1.5) --direct--> Pod B (10.244.2.8)
```
- Destination IP is **already final** — Pod B's real IP
- CNI's route table forwards the packet directly to the correct node (VXLAN encapsulation or BGP native routing, as covered above)
- **kube-proxy is not involved** — no virtual IP in play

### Pod-to-Service (e.g. `curl http://backend-service`)
```
Pod A --> Service ClusterIP (10.96.0.10) --> [kube-proxy: DNAT] --> Pod B (10.244.2.8)
```
- Destination IP is **virtual** (ClusterIP) — doesn't exist on any real interface
- As the packet passes through the kernel, it hits **kube-proxy's rules** (iptables/IPVS)
- **DNAT (Destination NAT)** happens here — the destination IP is silently rewritten from ClusterIP to the actual backend Pod IP
- After DNAT, the packet travels via normal CNI routing (same as Pod-to-Pod)

**Key insight:**
> kube-proxy decides *"who to send it to"* (DNAT). CNI decides *"how to actually deliver it"* (routing).

**Two-stage summary for interview:**
1. **Stage 1 — kube-proxy (DNAT):** iptables/IPVS rules rewrite the Service ClusterIP to the real backend Pod IP.
2. **Stage 2 — CNI (delivery):** The packet, now addressed to a real Pod IP, is routed to the correct node via VXLAN or BGP.

**Note:** The API server is NOT involved in actual data traffic. It's only part of the control plane — kube-proxy watches it in the background to build its rules ahead of time, but the real packet flow never touches the API server.

---

## 9. Master Summary Table

| Concept | Key Point |
|---|---|
| NAT | Rewrites IP addresses across network boundaries; Kubernetes avoids it between pods |
| CNI | A spec, not an implementation — kubelet invokes the plugin binary on pod create |
| CNI config location | `/etc/cni/net.d/` — auto-created when the CNI manifest is applied |
| Overlay (VXLAN) | Encapsulation — extra header, some overhead, works on any network |
| Underlay (BGP) | No encapsulation — needs L3 reachability, faster |
| L2 | Same local network — MAC address based |
| L3 | Across networks — IP address + routing |
| kube-proxy (iptables) | O(n) rule matching, random pod selection |
| kube-proxy (IPVS) | O(1) hash lookup, real load-balancing algorithms |
| Pod-to-Pod | Direct CNI routing — kube-proxy not involved |
| Pod-to-Service | kube-proxy DNAT first, then CNI routing delivers it |

---

*Personal reference: Calico is added on top of Minikube's default CNI whenever NetworkPolicy testing is required, since the default CNI doesn't enforce policies.*
