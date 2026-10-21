# Jenkins CI Pipeline: Docker build, push and GitOps tag update

A pipeline for the Task Tracker project (React + Spring Boot + MySQL), plus the concepts needed to understand it. It also covers how a practice setup differs from production.

> Status: this Jenkinsfile has not been run on a real Jenkins by the author of this note. Read the console output carefully on the first run.

---

## Table of contents

1. Goal and flow
2. Jenkins setup
3. Parameters (IMAGE_VERSION and BUILD_TARGET)
4. Final Jenkinsfile
5. Stage by stage
6. What `git rev-parse --short HEAD` does
7. Per-service tags: why only the changed service gets a new tag
8. How image tags are updated in production
9. Practice vs production
10. Security: the `docker` group is root-equivalent
11. Validation checklist
12. Common errors
13. Rollback
14. Interview-ready lines

---

## 1. Goal and flow

CI's job is to **build an artifact** (an image), not to deploy to the cluster. Deployment happens by changing the tag in Git, and ArgoCD (later) applies it to the cluster.

```
Commit in the app repo
   -> Jenkins: set version, build, push (tag = commit SHA or your own version)
   -> update the image tag in the GitOps repo + commit
   -> (for now) on EC2: git pull && kubectl apply -f .
   -> (after ArgoCD) ArgoCD syncs it automatically
```

Two separate repos:

| Repo | Contents |
|---|---|
| App repo | `backend/`, `frontend/`, `db/`, `Jenkinsfile` |
| GitOps repo | Kubernetes manifests (`Deployment.yaml`, `statefulset.yaml`, `ingress.yaml`) |

They are separate so that a push to the GitOps repo does not trigger a new build (avoids an infinite loop).

---

## 2. Jenkins setup

- **Credentials**
  - `dockerhub-credentials`: Username with password. Use a Docker Hub **access token** as the password, not the account password.
  - `github-credentials`: GitHub username + personal access token (write access to the GitOps repo only).
- **Plugins:** Git, Credentials Binding, Workspace Cleanup.
- **Docker access:** `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins`, then verify with `sudo -u jenkins docker ps`.
- **Job type:** Pipeline, "Pipeline script from SCM", with the `Jenkinsfile` at the root of the app repo.
- **Run the first build with "Build Now".** The "Build with Parameters" button only appears after the first run, because Jenkins learns the parameters by reading the Jenkinsfile.

---

## 3. Parameters (IMAGE_VERSION and BUILD_TARGET)

The pipeline has two parameters, defined in the `parameters { }` block.

```groovy
parameters {
    string(name: 'IMAGE_VERSION',
           defaultValue: '',
           description: 'Image tag (e.g. v4). Leave empty to use the git commit SHA.')
    choice(name: 'BUILD_TARGET',
           choices: ['backend', 'frontend', 'both'],
           description: 'Which image(s) to build, push and update in the GitOps repo')
}
```

### 3.1 `IMAGE_VERSION` (string): choose the image tag yourself

| Value | What happens |
|---|---|
| Empty (default) | Tag = short commit SHA from `git rev-parse --short HEAD` (for example `a1b2c3d`) |
| `v4`, `1.4.0`, `release-2` | That exact value becomes the tag |

Rules enforced by the "Set version" stage (regex `^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`):

- Letters, digits, `_`, `.` and `-` only. It cannot start with `.` or `-`. Maximum 128 characters.
- Anything else (for example `v4; ls`) fails the pipeline immediately. This follows Docker's tag rules and also stops shell injection, because the value is later used inside `sh` steps.
- If the tag already exists in Docker Hub, the push stage fails (it never overwrites a tag).

Things to watch:

- The tag is only a label. If you type `v4`, make sure the commit Jenkins checks out is really the commit you mean to release.
- Do not use `latest`. The regex allows it, but fixed tags are what make rollback and audit possible.

### 3.2 `BUILD_TARGET` (choice): choose which image(s) get built and which tag changes

This is the "tag change choice". It decides which service's image is built, pushed, and updated in the GitOps repo.

| BUILD_TARGET | Built | Pushed | Tag changed in `Deployment.yaml` |
|---|---|---|---|
| `backend` (default) | `task-backend` | `task-backend:<VERSION>` | backend `image:` line only |
| `frontend` | `task-frontend` | `task-frontend:<VERSION>` | frontend `image:` line only |
| `both` | both | both, with the same `<VERSION>` | both `image:` lines |

How it works in the code: the "Set version" stage turns the choice into `env.IMAGES`:

```groovy
env.IMAGES = (params.BUILD_TARGET == 'both')
                ? 'task-backend task-frontend'
                : "task-${params.BUILD_TARGET}"
```

The build, push, tag-exists and GitOps `sed` steps all loop over `$IMAGES`, so only the chosen service is touched. The other service keeps its current tag and its Pod is not restarted.

### 3.3 Examples

Current `Deployment.yaml`: backend `v3`, frontend `v1`. Latest commit in the app repo: `a1b2c3d`.

| IMAGE_VERSION | BUILD_TARGET | Result |
|---|---|---|
| empty | `backend` | `task-backend:a1b2c3d` is built and pushed. GitOps: backend becomes `a1b2c3d`, frontend stays `v1` |
| `v4` | `backend` | `task-backend:v4`. Backend becomes `v4`, frontend stays `v1` |
| `v2` | `frontend` | `task-frontend:v2`. Frontend becomes `v2`, backend stays `v3` |
| `v5` | `both` | Both images get `v5`. Both lines change |

Use `both` only when both services really changed, or for a coordinated release. With `both`, an unchanged service still gets a new image and a Pod restart.

### 3.4 How parameters are read

- In Groovy: `params.IMAGE_VERSION`, `params.BUILD_TARGET`.
- In shell steps they are also environment variables: `$BUILD_TARGET` (used in the commit message). `VERSION` and `IMAGES` are set by the pipeline itself via `env.`.
- Defaults: the string default is empty, and a `choice` defaults to its first entry (`backend`).
- On the very first run, a declarative pipeline uses the default values. If the console shows something odd such as `task-null`, run the build once more after the first one.

### 3.5 Possible next parameter (not implemented)

A `DEPLOY_ENV` parameter, for when per-environment values files exist (after Helm):

```groovy
parameters {
    choice(name: 'DEPLOY_ENV', choices: ['dev', 'prod'], description: 'Target environment')
}

stage('Approve prod') {
    when { expression { params.DEPLOY_ENV == 'prod' } }
    steps { input message: "Deploy ${env.VERSION} to PROD?", ok: 'Deploy' }
}
```

The GitOps update stage would then edit `envs/${params.DEPLOY_ENV}/values.yaml`.

---

## 4. Final Jenkinsfile

Features: `IMAGE_VERSION`, `BUILD_TARGET`, version validation, no overwriting of existing tags, and only the chosen service's tag is updated in the GitOps repo.

```groovy
pipeline {
    agent any

    parameters {
        string(name: 'IMAGE_VERSION',
               defaultValue: '',
               description: 'Image tag (e.g. v4). Leave empty to use the git commit SHA.')
        choice(name: 'BUILD_TARGET',
               choices: ['backend', 'frontend', 'both'],
               description: 'Which image(s) to build, push and update in the GitOps repo')
    }

    environment {
        DOCKERHUB_USER = 'kartavyanirwel'
        // Confirm the URL of your GitOps (manifests) repo
        GITOPS_REPO    = 'https://github.com/kartavynirwel-code/gitops-pratice-3-tier.git'
        MANIFEST_FILE  = 'Deployment.yaml'
    }

    options {
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
    }

    stages {
        stage('Set version') {
            steps {
                script {
                    def v = params.IMAGE_VERSION?.trim()
                    if (!v) {
                        v = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                    }
                    // Docker tag rules + protection against shell injection
                    if (!(v ==~ /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/)) {
                        error "Invalid image version: '${v}'. Only letters, digits, _ . - are allowed."
                    }
                    env.VERSION = v
                    env.IMAGES  = (params.BUILD_TARGET == 'both')
                                    ? 'task-backend task-frontend'
                                    : "task-${params.BUILD_TARGET}"
                }
                echo "Version: ${env.VERSION} | Images: ${env.IMAGES}"
            }
        }

        stage('Build') {
            steps {
                sh '''
                    for img in $IMAGES; do
                        docker build -t $DOCKERHUB_USER/$img:$VERSION ./${img#task-}
                    done
                '''
            }
        }

        stage('Push to Docker Hub') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials',
                                                  usernameVariable: 'DH_USER',
                                                  passwordVariable: 'DH_TOKEN')]) {
                    sh 'echo "$DH_TOKEN" | docker login -u "$DH_USER" --password-stdin'
                    // Never overwrite an existing tag
                    sh '''
                        for img in $IMAGES; do
                            if docker manifest inspect $DOCKERHUB_USER/$img:$VERSION >/dev/null 2>&1; then
                                echo "Tag $VERSION already exists for $img"
                                exit 1
                            fi
                        done
                    '''
                    sh '''
                        for img in $IMAGES; do
                            docker push $DOCKERHUB_USER/$img:$VERSION
                        done
                    '''
                }
            }
            post {
                always { sh 'docker logout || true' }
            }
        }

        stage('Update GitOps repo') {
            steps {
                dir('gitops') {
                    git url: env.GITOPS_REPO, branch: 'main', credentialsId: 'github-credentials'
                    withCredentials([gitUsernamePassword(credentialsId: 'github-credentials')]) {
                        sh '''
                            git config user.name "jenkins-ci"
                            git config user.email "jenkins-ci@users.noreply.github.com"
                            for img in $IMAGES; do
                                sed -i "s|image: $DOCKERHUB_USER/$img:.*|image: $DOCKERHUB_USER/$img:$VERSION|" $MANIFEST_FILE
                            done
                            git add $MANIFEST_FILE
                            git diff --cached --quiet || git commit -m "ci: deploy $VERSION ($BUILD_TARGET)"
                            git pull --rebase origin main
                            git push origin HEAD:main
                        '''
                    }
                }
            }
        }
    }

    post {
        success { echo 'Pipeline completed successfully!' }
        failure { echo 'Pipeline failed!' }
        always  { cleanWs() }
    }
}
```

The shell blocks use single-quoted Groovy strings (`'''...'''`) so that Groovy does not interpolate secrets into the script text. The shell expands the variables, and Jenkins masks secret values in the log.

---

## 5. Stage by stage

### 5.1 Set version

- `params.IMAGE_VERSION?.trim()`: `?.` is Groovy's safe navigation (no crash on null). `trim()` removes spaces, so a value of only spaces counts as "not provided".
- Fallback to the commit SHA: `returnStdout: true` brings the shell output into a Groovy variable, and `.trim()` removes the trailing newline.
- Regex check (`==~` matches the whole string): Docker tag rules plus shell-injection protection.
- `env.VERSION = v`: `def v` only lives inside that `script` block. Assigning to `env.` makes it available in later stages, where every `sh` step sees it as `$VERSION`.
- The same stage also builds `env.IMAGES` from `BUILD_TARGET` (see section 3.2).

### 5.2 Build

`${img#task-}` is shell prefix removal: `task-backend` becomes `backend`, which is the build context folder (`./backend`). The `kartavyanirwel/` prefix on the image name is required, otherwise the push finds no local image.

### 5.3 Push to Docker Hub

- `withCredentials` exposes secrets as environment variables only inside the block and masks them in logs.
- `docker login --password-stdin`: passing the password as an argument (`-p`) shows up in the process list, stdin does not. After login the credentials sit in `~/.docker/config.json` as base64 (not encrypted), hence `docker logout` in `post`.
- Tag-exists check: `docker manifest inspect` asks the registry for the manifest without pulling the image. Exit code 0 means the tag exists, so the pipeline fails. This command has not been tested on your Docker version; check it once against an existing tag.
- Push internals: an image is layers + config + manifest, each identified by a `sha256` digest. Layers already in the registry are skipped (`Layer already exists`). **A tag is a mutable pointer, a digest is immutable.** That is why the same tag must never be pushed twice.

### 5.4 Update GitOps repo

- `dir('gitops')` uses a separate folder so the app repo workspace is not overwritten.
- Only the services in `$IMAGES` get their `sed` run, so the other service's tag is untouched.
- `git diff --cached --quiet || git commit` skips the commit when nothing changed, so the pipeline does not fail.
- `git pull --rebase` before the push handles someone else committing in between.
- **The order is always: push the image first, update the tag afterwards.** If the tag reaches Git before the image exists, the cluster goes into `ImagePullBackOff`.

---

## 6. What `git rev-parse --short HEAD` does

- `HEAD`: the commit that is currently checked out.
- `git rev-parse`: converts a name (HEAD, branch, tag) into an object hash.
- `--short`: shortens the long hash.

```bash
$ git rev-parse HEAD
a1b2c3d4e5f60718293a4b5c6d7e8f9012345678      # 40-character SHA-1

$ git rev-parse --short HEAD
a1b2c3d                                        # first 7 characters (same as git log --oneline)
```

Use `--short=8` for a fixed length.

### Image tag = commit hash: example

```
1. Backend CORS fix committed, commit hash: a1b2c3d
2. Jenkins checks out that commit
3. VERSION = a1b2c3d
4. Image pushed: kartavyanirwel/task-backend:a1b2c3d
5. GitOps repo Deployment.yaml:  image: kartavyanirwel/task-backend:a1b2c3d
```

From the image you can run `git show a1b2c3d` to see the exact code (traceability). The next commit `7f3e2a1` produces a new tag, and old tags stay as they are, so a rollback is just putting the old tag back.

Note: this hash belongs to a commit in the **app repo**, not the GitOps repo.

---

## 7. Per-service tags: why only the changed service gets a new tag

If only the backend changed, the frontend tag should not change. The first version of this pipeline gave both images the same tag and rebuilt both, which was wrong:

| | Before | Correct |
|---|---|---|
| Backend | `task-backend:7f3e2a1` | `task-backend:7f3e2a1` |
| Frontend | `task-frontend:7f3e2a1` (rebuilt, code unchanged) | `task-frontend:v1` (nothing changed) |
| Frontend Pod | Restarted | Keeps running |

The cost of the wrong way: a wasted build (CPU on a 2 vCPU VM), a wasted Pod restart, and a misleading tag (the frontend code did not change in that commit).

The fix is the `BUILD_TARGET` parameter (section 3.2). In production each service has its own tag and often its own pipeline, and only the changed service is built and deployed. Auto-detection (`when { changeset 'backend/**' }`) can come later; start with the parameter because it is predictable.

---

## 8. How image tags are updated in production

Rule: **nobody changes the tag on the cluster. The tag is changed in Git, and the cluster follows Git.**

```
Commit in the app repo
   -> CI: test, build, scan, push image (tag = commit SHA, only the changed service)
   -> tag update in the GitOps repo (commit or pull request)
   -> ArgoCD sees the change in Git
   -> ArgoCD makes the cluster match Git
```

### Four ways to update the tag

| Way | How | When |
|---|---|---|
| 1. CI pushes directly | The pipeline edits the manifest/values and pushes (what this Jenkinsfile does) | Dev / staging |
| 2. CI opens a Pull Request | No direct push to main. A PR is opened and merged after approval | Production (review + audit trail) |
| 3. Image updater tool | A tool watches the registry and commits to Git itself (Argo CD Image Updater, Flux image automation) | When you do not want tag-update logic in CI |
| 4. Promotion pipeline | One image is promoted dev -> staging -> prod, with a test or approval at each step | Larger setups |

The current maintenance status and features of image updater tools were not checked for this note. Read their docs before adopting one.

### Environments and promotion

The image is **built once**. Only "which environment runs which tag" changes:

```
gitops-repo/
  envs/dev/values.yaml       image.tag: a1b2c3d   <- CI updates automatically
  envs/staging/values.yaml   image.tag: 9f8e7d6   <- after tests pass
  envs/prod/values.yaml      image.tag: 9f8e7d6   <- after PR + approval
```

After Helm, `values-dev.yaml` and `values-prod.yaml` take this role. The prod tag changes only after the same tag has been tested in dev/staging (no rebuild).

### Rollback in production

Run `git revert <commit>` on the GitOps repo and ArgoCD syncs it. Do not use `kubectl rollout undo`: ArgoCD's self-heal treats that as drift and puts the Git tag back.

### Four improvements to make Jenkins more production-like (later)

1. Use `yq` instead of `sed` (after Helm): `yq -i '.backend.image.tag = strenv(VERSION)' envs/dev/values.yaml`
2. A `DEPLOY_ENV` parameter (dev/prod) and an `input` approval stage for prod.
3. For prod, push a branch and open a PR (`gh pr create`) instead of pushing to main, and turn on branch protection on the GitOps repo (no direct push to main, at least one approval).
4. Give Jenkins' token write access to the GitOps repo only, ideally through a separate bot account or a deploy key.

### Adoption order

1. Now: what exists (way 1, `sed`, `BUILD_TARGET`).
2. After Helm: `yq` on `values.yaml`.
3. After ArgoCD: auto-sync on, so for dev the CI push becomes the deploy.
4. Then: a prod values file with PR + approval.

---

## 9. Practice vs production

| This setup | Production |
|---|---|
| You can type any version by hand | Version comes from git automatically. Releases use a git tag (`v1.4.0`) and CI builds from it |
| Public Docker Hub | Private registry (ECR, GHCR, Harbor) |
| Long-lived PAT / token | Short-lived credentials: OIDC or IAM roles |
| Tag-exists check in a script | The registry enforces it (for example ECR tag immutability) |
| Build, then push straight away | Build, test, **scan** (Trivy), push, **sign** (cosign). A failed scan blocks the push |
| Builds on the Jenkins host's `docker` | Ephemeral build agents (Kubernetes Pod agents), rootless or daemonless builders |
| Deploy by tag | Deploy by digest (`image@sha256:...`), because a tag can move |
| Jenkins and cluster on one VM | CI and cluster are separate |

Typical production pipeline order:

```
checkout -> test -> build -> scan -> push -> sign -> update GitOps repo (SHA/digest) -> ArgoCD sync
```

---

## 10. Security: the `docker` group is root-equivalent

The Docker daemon runs as root. If the `jenkins` user is in the `docker` group, any `sh` command in a pipeline can do this:

```bash
docker run --rm -v /:/host alpine cat /host/etc/shadow
```

On a single VM that also hosts the cluster, `/etc/kubernetes/admin.conf` is on the same disk, so anyone who can edit the Jenkinsfile is effectively cluster admin. To see it on your own VM:

```bash
sudo -u jenkins docker run --rm -v /:/host alpine ls /host/etc/kubernetes
```

### What to do

Now, on this VM:
- Allow Jenkins port 8080 in the Security Group only from **My IP**.
- Keep login enabled and limit who can configure jobs or edit the Jenkinsfile.
- Do not build code from forks or pull requests of other people on this Jenkins.
- Do not use `--privileged` or mount `/var/run/docker.sock` into containers in the pipeline.
- Do not keep the cluster admin kubeconfig on the build machine. CI only needs the Docker Hub token and the GitOps repo token, not `kubectl` (ArgoCD deploys).

Next step: put Jenkins and the cluster on **separate VMs**.

Real fix: rootless Docker or daemonless builders (BuildKit rootless, Buildah, Kaniko). Check Kaniko's current maintenance status in its docs, it was not verified for this note. In production, builds run in ephemeral agents that have no cluster credentials.

---

## 11. Validation checklist

1. `sudo -u jenkins docker ps` works.
2. First build via "Build Now": the console shows `Version: <sha> | Images: ...`.
3. Docker Hub has tags only for the chosen service (`BUILD_TARGET=backend` gives only `task-backend:<sha>`).
4. The GitOps repo has a new commit, and `git diff HEAD~1` shows **only that service's tag** changed.
5. Run the same version again: it should fail with "Tag already exists".
6. A bad value (`v4;ls`): fails in the "Set version" stage.
7. Run again with no code change (same SHA): fails on the tag check. Make a new commit or give a manual version.

---

## 12. Common errors

| Symptom | Cause | Fix |
|---|---|---|
| Syntax error on `Checkout scm` / `docker build` | Shell commands written directly in declarative `steps` | Put them in `sh '...'`; `checkout scm` is not needed |
| `permission denied ... docker.sock` | `jenkins` is not in the docker group | `usermod -aG docker jenkins`, restart Jenkins |
| `image does not exist locally` at push time | Build used no `kartavyanirwel/` prefix | Use the same name for build and push |
| `unauthorized` on push | Docker Hub token wrong or expired | Create a new access token and update the credential |
| `gitUsernamePassword` not found | Git plugin is old | Update the plugin |
| GitOps push `rejected` | Someone committed in between | `git pull --rebase` (already in the Jenkinsfile) |
| Pipeline passes but nothing changes on the cluster | CI only changes the tag in Git | `git pull && kubectl apply -f .` or ArgoCD |
| `ImagePullBackOff` | Tag reached Git but the image was not pushed | Check the stage order and look for the tag on Docker Hub |
| Builds keep triggering forever | A GitOps repo push triggers CI | Keep the repos separate, webhook on the app repo only |
| `task-null` in the console | Parameters not set on the very first run | Run the build once more |

---

## 13. Rollback

- Bad Jenkinsfile: `git revert <commit>` in the app repo.
- Wrong tag pushed to the GitOps repo: `git revert <commit>` there, then `git pull && kubectl apply -f .`.
- Registry tags are immutable, so old images stay available.

---

## 14. Interview-ready lines

- "A tag is a mutable pointer and a digest is immutable, so we tag with the commit SHA and pin digests in production."
- "An image is built once and promoted, not rebuilt for each environment."
- "CI only produces the artifact and changes the tag in the GitOps repo. ArgoCD deploys, and rollback is a Git revert."
- "Being in the docker group is root-equivalent on the host, so production builds run in ephemeral, rootless or daemonless agents that hold no cluster credentials."
- "Each service has its own tag, and only the changed service is built and deployed."
