# IRSA (IAM Roles for Service Accounts) — Setup Guide

## Yeh kya solve karta hai

EKS pod ko AWS service (S3, DynamoDB, SQS, etc.) access karni hai. Bina IRSA ke do options hain:
1. **Node IAM role** — us node ke SAB pods ko same broad permissions mil jaati hain. Least privilege violate.
2. **Hardcoded access keys** — static, rotate nahi hoti, leak risk.

**IRSA** har Kubernetes ServiceAccount ko ek specific IAM Role se bind karta hai — sirf us ServiceAccount ke pods ko, sirf utni hi permissions milti hain jo role me hain. Pod-level granularity.

---

## Prerequisites

- EKS cluster already running (eksctl, Terraform, ya console se banaya hua)
- `aws` CLI aur `kubectl` configured, cluster se connected
- `eksctl` installed (OIDC association ke liye — Terraform se bhi ho sakta hai, dono tareeke neeche hain)

---

## Step 1 — OIDC Identity Provider ko cluster se associate karo

### Kyun karte hain
AWS IAM ko trust establish karna hota hai ki tumhara EKS cluster identities issue kar sakta hai. Jab tak yeh association nahi hai, AWS STS kisi bhi Kubernetes token ko verify nahi kar sakta — matlab IRSA kaam hi nahi karega, foundation yehi hai.

### Kaise karo
```bash
# Pehle check karo cluster ka OIDC issuer URL
aws eks describe-cluster --name <cluster-name> \
  --query "cluster.identity.oidc.issuer" --output text

# OIDC provider ko associate karo (agar already nahi hai)
eksctl utils associate-iam-oidc-provider \
  --cluster <cluster-name> \
  --approve
```

### Isse kya hoga
AWS IAM console me `IAM > Identity Providers` ke andar ek naya OIDC provider dikhega, jo tumhare EKS cluster ke issuer URL se linked hoga. Yeh one-time setup hai per cluster — dobara karne ki zaroorat nahi jab tak cluster delete na ho.

---

## Step 2 — IAM Policy banao (permissions define karo)

### Kyun karte hain
Yeh define karta hai ki **kya** access chahiye (e.g., sirf ek specific S3 bucket read karna) — least privilege ka pehla half.

### Kaise karo
```bash
cat > s3-read-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::my-app-bucket",
      "arn:aws:s3:::my-app-bucket/*"
    ]
  }]
}
EOF

aws iam create-policy \
  --policy-name my-app-s3-read \
  --policy-document file://s3-read-policy.json
```

### Isse kya hoga
Ek reusable IAM Policy ban jaati hai — bilkul specific resources ke liye, `*` wildcard avoid karo (production me yeh audit fail karwata hai).

---

## Step 3 — IAM Role banao with Trust Policy (kaun access kar sakta hai)

### Kyun karte hain
Yahi step **actual granularity** enforce karta hai. Trust Policy me condition likhi jaati hai ki sirf ek specific `namespace:serviceaccount` combination hi is role ko assume kar sakta hai — koi aur pod nahi, chahe wo same cluster me ho.

### Kaise karo
```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export OIDC_PROVIDER=$(aws eks describe-cluster --name <cluster-name> \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')

cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_PROVIDER}:sub": "system:serviceaccount:my-namespace:my-serviceaccount",
        "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name my-app-irsa-role \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name my-app-irsa-role \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/my-app-s3-read
```

### Isse kya hoga
Ek IAM Role ban jaata hai jo **sirf** `my-namespace` ke `my-serviceaccount` se aane wale requests ko assume karne dega. `aud` condition zaroor add karo — bina isके koi bhi OIDC-federated identity (galti se) role assume kar sakti hai.

---

## Step 4 — Kubernetes ServiceAccount banao aur annotate karo

### Kyun karte hain
Yeh Kubernetes side ka "link" hai — bina is annotation ke, Pod Identity Webhook ko pata hi nahi chalega ki is ServiceAccount ko kaunsi IAM role se jodna hai.

### Kaise karo
```yaml
# serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-serviceaccount
  namespace: my-namespace
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/my-app-irsa-role
```
```bash
kubectl apply -f serviceaccount.yaml
```

### Isse kya hoga
ServiceAccount object cluster me create ho jaata hai, IAM role ARN ke saath annotated. Isi annotation ko EKS ka built-in **Pod Identity Webhook** dekhta hai jab bhi is ServiceAccount se koi pod start hota hai.

---

## Step 5 — Pod is ServiceAccount ko use kare

### Kyun karte hain
ServiceAccount tabhi effective hai jab koi pod usse actually reference kare.

### Kaise karo
```yaml
# deployment.yaml (relevant part)
spec:
  serviceAccountName: my-serviceaccount
  containers:
    - name: my-app
      image: my-app:latest
```
```bash
kubectl apply -f deployment.yaml
```

### Isse kya hoga (runtime flow)
1. Pod start hote hi Pod Identity Webhook automatically inject karta hai:
   - Env vars: `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`
   - Ek projected, short-lived, signed JWT token (volume mount ke through)
2. Pod ke andar AWS SDK yeh token padhta hai
3. SDK `sts:AssumeRoleWithWebIdentity` call karta hai, token proof ke saath
4. AWS STS token verify karta hai (OIDC provider ke against) — signature, expiry, `sub` claim check
5. Verify hone pe temporary credentials milte hain (~1 hour validity, SDK auto-refresh karta hai)
6. Pod ab AWS API calls kar sakta hai, sirf attached policy jitni permissions ke saath

---

## Step 6 — Verify karo

```bash
kubectl exec -it <pod-name> -n my-namespace -- env | grep AWS

kubectl exec -it <pod-name> -n my-namespace -- aws sts get-caller-identity
# Output me role ARN dikhna chahiye, node role nahi

kubectl exec -it <pod-name> -n my-namespace -- aws s3 ls s3://my-app-bucket
```

Agar `get-caller-identity` galat role dikhaye ya `AccessDenied` aaye — checklist:
- ServiceAccount annotation me role ARN sahi hai?
- Trust policy ka `sub` condition exact `namespace:serviceaccount` match kar raha hai?
- Pod actually usi ServiceAccount ko use kar raha hai (`spec.serviceAccountName`)?
- OIDC provider associate hua tha ya nahi (Step 1)?

---

## Production me kaise hota hai (real-world differences)

Yeh manual CLI steps sirf **learning/understanding** ke liye hain. Production me:

1. **Terraform se sab kuch as code hota hai** — OIDC provider association, IAM policy, IAM role, trust policy — sab `.tf` files me, kabhi manual CLI se nahi. Module: `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks` widely used hai — tumhara khud ka 07-terraform-modules jaisa custom module bhi ban sakta hai isi pattern pe.
2. **One role per workload, not shared** — production me har microservice ka apna dedicated IRSA role hota hai, kabhi ek role multiple services share nahi karti (blast radius control ke liye).
3. **Policies bahut tightly scoped hoti hain** — resource ARN specific, action specific, kabhi `s3:*` ya `Resource: "*"` nahi. Security audits (SOC2, etc.) me yeh sabse pehle check hota hai.
4. **GitOps flow** — IAM role/policy Terraform se manage hoti hai (separate repo/pipeline), ServiceAccount YAML ArgoCD/Helm se deploy hoti hai — dono alag pipelines, alag approval flow (infra team vs app team separation).
5. **Naming convention aur tagging mandatory** — roles ko `<env>-<service>-irsa-role` jaisa naam milta hai, cost-tracking aur ownership tags (`Team`, `Environment`, `ManagedBy=terraform`) lagti hain.
6. **Drift detection** — agar koi manually console se trust policy change kar de, `terraform plan` usse turant dikhata hai (drift). Yeh production me continuously monitor hota hai (CI cron job ya tools jaise driftguard).
7. **Multiple environments = multiple roles** — dev/staging/prod ke alag AWS accounts hote hain (best practice), isliye har environment ka apna OIDC provider + roles hote hain, ek dusre se completely isolated.

---

## Folder placement (Devops-plates repo)

Tumhare repo me `07-terraform-modules` already EKS/VPC/RDS Terraform modules ke liye hai. IRSA concept-wise IAM + EKS security ka topic hai, isliye do options:

- **Agar yeh sirf conceptual/manual-steps reference hai** (jaisa yeh file hai) → naya numbered folder banao, jaise `08-irsa` ya `08-eks-security` — apne existing numbering sequence ke agle available number ke saath.
- **Agar aage chal ke isko Terraform module bhi banaoge** (jo prod section me discuss hua) → `07-terraform-modules/` ke andar hi ek subfolder `irsa/` add kar sakte ho, kyunki wo already terraform modules ka ghar hai.

Recommendation: `08-irsa/README.md` (ya jo bhi tumhara agla sequential number hai) — isse standalone concept reference rehta hai, aur baad me jab Terraform module banao, tab `07-terraform-modules/irsa/` me actual `.tf` code jaayega, dono cross-reference kar sakte ho.
