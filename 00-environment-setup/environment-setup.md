# 00 - Environment Setup (Ubuntu EC2 / Machine)

Yeh guide ek fresh Ubuntu machine (EC2 ya local) par saare DevSecOps tools install karne ke liye hai. Har tool ke saath: definition, install commands, aur verify command diya gaya hai.

> Assumed OS: **Ubuntu 20.04 / 22.04 / 24.04**
> Run as: user with `sudo` access

---

## 1. System Update & Essentials

Base packages jo baaki sab tools ke installation me use honge.

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget unzip git gnupg lsb-release ca-certificates apt-transport-https software-properties-common
```

Verify:
```bash
curl --version
wget --version
```

---

## 2. Java (OpenJDK 21)

Jenkins, Maven, aur Spring Boot apps ke liye required.

```bash
sudo apt install -y openjdk-21-jdk
```

Verify:
```bash
java -version
javac -version
```

---

## 3. Git

Version control - source code management ke liye.

```bash
sudo apt install -y git
git config --global user.name "Your Name"
git config --global user.email "your-email@example.com"
```

Verify:
```bash
git --version
```

---

## 4. Docker

Containers build/run karne ke liye.

```bash
sudo apt install -y docker.io
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER
newgrp docker
```

Verify:
```bash
docker --version
docker run hello-world
```

> Note: `usermod` ke baad naya SSH session lo ya `newgrp docker` chalao, warna permission denied milega.

---
## 5. Docker Compose

Multi-container apps (`docker-compose.yml`) define/run karne ke liye - tumhare ecommerce-microservices jaise projects me directly kaam aayega.

```bash
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name"' | cut -d '"' -f4)
sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

Verify:
```bash
docker-compose --version
```

> Note: Newer Docker installs already have Compose v2 built-in as a plugin (`docker compose`, no hyphen). Check karo pehle:
> ```bash
> docker compose version
> ```
> Agar woh kaam kar jaye to standalone binary install karne ki zarurat nahi.

---

## 5. Jenkins

CI server - build/test/deploy pipelines automate karne ke liye.

```bash
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update
sudo apt install jenkins
sudo systemctl enable jenkins
sudo systemctl start jenkins
```

Verify:
```bash
sudo systemctl status jenkins
```

Initial admin password (browser setup ke liye):
```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Jenkins UI: `http://<ec2-public-ip>:8080`

---

## 6. Maven

Java project build tool.

```bash
sudo apt install -y maven
```

Verify:
```bash
mvn -version
```

---

## 7. kubectl

Kubernetes cluster ke saath interact karne ka CLI.

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

Verify:
```bash
kubectl version --client
```

---
## 8. k3s / kind (Optional - Local Kubernetes Cluster)

Agar EC2 pe hi lightweight K8s cluster chahiye (bina EKS ke).

### k3s (single binary, production-grade lightweight K8s)

Install:
```bash
curl -sfL https://get.k3s.io | sh -
```

**Important — configure `kubectl` access:**
K3s apna kubeconfig `/etc/rancher/k3s/k3s.yaml` mein banata hai, aur plain `kubectl` (system-installed) usko by default nahi dhoondta — isliye `kubectl get pods` seedha chalane pe `localhost:8080 connection refused` error aata hai. Fix:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
source ~/.bashrc
```

Verify service is running:
```bash
sudo systemctl status k3s
```

If inactive:
```bash
sudo systemctl enable --now k3s
```

Verify cluster access:
```bash
kubectl get nodes
kubectl get pods -A
```

> Alternative without kubeconfig setup: `sudo k3s kubectl get nodes` always works out of the box (uses k3s's bundled kubectl + embedded config directly), but requires `sudo` every time and doesn't work with Helm/other tools expecting standard `~/.kube/config`. The kubeconfig setup above is the one-time fix so plain `kubectl` and `helm` work normally afterward.

---

### kind (Kubernetes in Docker — local testing/dev ke liye)

Install:
```bash
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

Create a cluster (kind doesn't auto-create one on install — this step was missing):
```bash
kind create cluster --name devops-practice
```

This automatically writes/merges its kubeconfig into `~/.kube/config`, so `kubectl` works immediately for this cluster — no manual kubeconfig copy needed (unlike k3s).

---

### Verify

```bash
k3s --version
kind --version
kubectl get nodes        # shows whichever cluster's context is currently active
kubectl config get-contexts   # lists all available cluster contexts (k3s, kind, etc.)
```

> Note: If both k3s and kind are installed on the same machine, `kubectl config get-contexts` will show both — use `kubectl config use-context <name>` to switch between them.

---

## 9. Amazon EKS Tools (eksctl + aws-iam-authenticator)

EKS cluster create karne aur access karne ke liye.

**eksctl** - EKS cluster create/manage karne ka official CLI:
```bash
curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
```

**aws-iam-authenticator** - kubectl ko EKS cluster ke saath IAM se authenticate karne ke liye (kabhi-kabhi zaroori, though newer AWS CLI `aws eks update-kubeconfig` mostly sufficient hota hai):
```bash
curl -o aws-iam-authenticator https://amazon-eks.s3.us-west-2.amazonaws.com/1.29.0/2024-01-04/bin/linux/amd64/aws-iam-authenticator
chmod +x ./aws-iam-authenticator
sudo mv ./aws-iam-authenticator /usr/local/bin
```

Verify:
```bash
eksctl version
aws-iam-authenticator version
```

---

## 10. Helm

Kubernetes ke liye package manager (charts install/manage karne ke liye).

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Verify:
```bash
helm version
```

---

## 11. AWS CLI v2

AWS resources (EC2, S3, EKS, etc.) manage karne ka CLI.

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

Verify:
```bash
aws --version
aws configure   # AWS Access Key, Secret Key, Region set karne ke liye
```

---

## 12. Terraform

Infrastructure as Code (IaC) tool.

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update
sudo apt install -y terraform
```

Verify:
```bash
terraform -version
```

---

## 13. Trivy

Container images, filesystems, aur IaC me vulnerability scanning (SCA/Container Security).

```bash
sudo apt install -y wget gnupg
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" | sudo tee -a /etc/apt/sources.list.d/trivy.list
sudo apt update
sudo apt install -y trivy
```

Verify:
```bash
trivy --version
```

---

## 14. Checkov (Optional)

IaC static analysis - Terraform/K8s/Dockerfile misconfigurations detect karne ke liye.

```bash
sudo apt install -y python3-pip
pip3 install checkov
```

Verify:
```bash
checkov --version
```

---

## 15. Gitleaks

Git repos me hardcoded secrets/credentials scan karne ke liye.

```bash
curl -sSL https://github.com/gitleaks/gitleaks/releases/latest/download/gitleaks_8.18.4_linux_x64.tar.gz -o gitleaks.tar.gz
tar -xzf gitleaks.tar.gz gitleaks
sudo mv gitleaks /usr/local/bin/
```

Verify:
```bash
gitleaks version
```

> Note: version number URL me change ho sakta hai - [latest release](https://github.com/gitleaks/gitleaks/releases) check kar lena.

---

## 16. HashiCorp Vault CLI

Secrets management (KV store, dynamic secrets, Kubernetes injection) ke liye.

```bash
sudo apt install -y vault
```

(Yeh HashiCorp repo se milega jo Terraform install ke time already add ho chuka hai - step 12 dekho)

Verify:
```bash
vault --version
```

---

## 17. OWASP Dependency-Check

Project dependencies me known vulnerabilities (CVEs) scan karne ke liye (SCA).

```bash
wget https://github.com/jeremylong/DependencyCheck/releases/download/v9.2.0/dependency-check-9.2.0-release.zip
unzip dependency-check-9.2.0-release.zip
sudo mv dependency-check /opt/
echo 'export PATH=$PATH:/opt/dependency-check/bin' >> ~/.bashrc
source ~/.bashrc
```

Verify:
```bash
dependency-check.sh --version
```

---

## 18. jq & yq

JSON aur YAML parsing/manipulation - scripting me bohot use hote hain.

```bash
sudo apt install -y jq
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
```

Verify:
```bash
jq --version
yq --version
```

---

## 19. k9s

Kubernetes cluster ke liye terminal UI - debugging fast karne ke liye.

```bash
curl -sS https://webinstall.dev/k9s | bash
```

Verify:
```bash
k9s version
```

---

## 20. kubectx & kubens

Kubernetes context aur namespace fast switch karne ke liye.

```bash
sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx
sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens
```

Verify:
```bash
kubectx --help
kubens --help
```

---

## 21. SonarScanner CLI (Optional)

Standalone code quality scan (bina Jenkins plugin ke) chalane ke liye.

```bash
wget https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-5.0.1.3006-linux.zip
unzip sonar-scanner-cli-5.0.1.3006-linux.zip
sudo mv sonar-scanner-5.0.1.3006-linux /opt/sonar-scanner
echo 'export PATH=$PATH:/opt/sonar-scanner/bin' >> ~/.bashrc
source ~/.bashrc
```

Verify:
```bash
sonar-scanner --version
```
---

## 22. Syft (SBOM Generator)

Software components aur dependencies ki inventory (SBOM) generate karne ke liye.

```bash
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sudo sh -s -- -b /usr/local/bin
```

Verify:
```bash
syft version
```

Generate SBOM:
```bash
syft nginx:latest -o cyclonedx-json > sbom.json
```

View SBOM:
```bash
jq '.components[] | {name, version, type}' sbom.json
```

**Remember:**
- Syft → SBOM Generator
- Trivy → Vulnerability Scanner
- CycloneDX → SBOM Format

**Use:** Generate SBOM for every new production image and store it with the corresponding image tag/digest.

---

## Final Verification (Run All Together)

Sab tools ek saath check karne ke liye:

```bash
echo "Java:" && java -version
echo "Git:" && git --version
echo "Docker:" && docker --version
echo "Jenkins:" && sudo systemctl status jenkins --no-pager
echo "Maven:" && mvn -version
echo "kubectl:" && kubectl version --client
echo "k3s:" && k3s --version
echo "kind:" && kind --version
echo "eksctl:" && eksctl version
echo "aws-iam-authenticator:" && aws-iam-authenticator version
echo "Helm:" && helm version
echo "AWS CLI:" && aws --version
echo "Terraform:" && terraform -version
echo "Trivy:" && trivy --version
echo "Checkov:" && checkov --version
echo "Gitleaks:" && gitleaks version
echo "Vault:" && vault --version
echo "Dependency-Check:" && dependency-check.sh --version
echo "jq:" && jq --version
echo "yq:" && yq --version
echo "k9s:" && k9s version
echo "kubectx:" && kubectx --help | head -1
echo "SonarScanner:" && sonar-scanner --version
```

---

## Notes

- **Mandatory for basic Jenkins CI/CD node**: Java, Git, Docker, Jenkins, Maven
- **Mandatory for Kubernetes work**: kubectl, Helm
- **Mandatory for AWS/EKS work**: AWS CLI, eksctl, aws-iam-authenticator
- **Security scanning stack (DevSecOps)**: Trivy, Checkov, Gitleaks, OWASP Dependency-Check, Vault
- **Optional / nice-to-have**: k3s, kind, k9s, kubectx/kubens, SonarScanner, Checkov
- Heavy server-side stacks (SonarQube server, Prometheus/Grafana, Loki/Tempo/Pyroscope, MetalLB, Envoy Gateway) yahan cover nahi kiye gaye - woh Helm charts / K8s manifests se deploy hote hain aur unke dedicated folders already repo me hain.
