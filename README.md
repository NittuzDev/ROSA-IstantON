# InstantOn on ROSA

This demo checks whether Open Liberty InstantOn can restore on a ROSA cluster.

InstantOn checkpoints the running Liberty process while the container image is built. On the cluster, CRIU restores that snapshot. The application itself does not change. The pod needs two Linux capabilities, `CHECKPOINT_RESTORE` and `SETPCAP`, and a seccomp profile that allows the CRIU system calls. OpenShift will not grant those under the default `restricted-v2` constraint, so this project uses the SCC in `openshift/scc-cap-cr.yaml`.

The pass signal is this line in the container log, on the build host and again in the pod:

```text
CWWKC0452I: The Liberty server process resumed operation from a checkpoint
```

`CWWKF0011I` then reports that the server is ready and how long startup took. After a restore that time is a fraction of a second. `CWWKE0961I` means the restore failed.

References:

- [Open Liberty InstantOn](https://openliberty.io/docs/latest/instanton.html)
- [IBM: Liberty InstantOn on OpenShift](https://community.ibm.com/community/user/blogs/tam-dinh/2024/09/09/liberty-instanton-on-ocp)

## What you need

- A **RHEL 10 x86_64 build host** with Podman and `sudo`. This procedure was run on a `t3.micro`. InstantOn does not restore an image built for another architecture, so the host must be `amd64`, the same architecture as the ROSA workers. The checkpoint is taken inside `podman build`, which is why the build needs extra capabilities. Kernel 5.9 or newer is required. ROSA 4.14 and later uses RHCOS 9, which meets that requirement.
- An **AWS account** that can create an ECR repository in the cluster region, and AWS CLI credentials on the build host. An ECR authorization token expires after 12 hours.
- A **ROSA cluster** and a user with **cluster-admin**. Creating an SCC is cluster-scoped. The ROSA `dedicated-admin` role cannot create it. `rosa create admin` provides a cluster-admin if you do not already have one.
- `oc` and Helm 3, logged into the cluster. These commands can run on the build host or on another machine. If you use another machine, repeat the `export` lines from step 4 there before creating the pull secret.

## Repository layout

| Path | Purpose |
| --- | --- |
| `pom.xml` | Builds the war. The only dependency is the servlet API, provided by Liberty. |
| `src/main/java/com/example/instanton/StatusServlet.java` | The application: one servlet on `/status`. |
| `src/main/liberty/config/server.xml` | Liberty config. Enables `servlet-6.0` only. |
| `Containerfile` | Multi-stage build. The last instruction is `checkpoint.sh afterAppStart`. |
| `Containerfile.baseline` | Same application with no checkpoint, kept for a cold-start comparison outside this procedure. |
| `openshift/namespace.yaml` | Test project. Pod Security Admission is `privileged` so it allows the SCC. |
| `openshift/scc-cap-cr.yaml` | SCC you apply as cluster-admin. |
| `helm/instanton-demo` | ServiceAccount, Deployment, Service, and Route. |

Run every build command from the repository root, the directory that contains `Containerfile`.

## 1. Connect to the build host

The image is built on the RHEL instance, not on a laptop. `ec2-user` is the default login on RHEL AMIs. Replace the key path and the public DNS with your instance.

```bash
ssh -i <ssk-key> ec2-user@<ec2 hostname>
```

Put the repository on that host and work from its root. The host used here is a `t3.micro` (1 GiB of memory). If `podman build` is killed during `checkpoint.sh`, move the build to a larger instance.

```bash
git clone https://github.com/NittuzDev/ROSA-IstantON.git
cd ROSA-IstantON
```

## 2. Update the host

```bash
sudo dnf update -y
```

This pulls current packages before the checkpoint build. Podman is already present on the RHEL image used here.

## 3. Allow CRIU through SELinux

CRIU uses netlink while it takes the checkpoint. On an enforcing RHEL host, SELinux blocks that call from a container unless this boolean is on.

```bash
getenforce
sudo setsebool virt_sandbox_use_netlink 1
```

`getenforce` should print `Enforcing` or `Permissive`. `setsebool` without `-P` lasts until the next reboot, which is enough for this test. Add `-P` only if you want the boolean to survive a reboot.

If the boolean is off, the build fails with `CWWKE0963E` and a message that mentions `virt_sandbox_use_netlink`.

## 4. Install the AWS CLI and set the image name

The AWS CLI v2 installer is a zip archive, so `unzip` has to be installed first. The install script puts the `aws` binary on the host.

```bash
sudo dnf install unzip -y
curl -fsSL https://awscli.amazonaws.com/v2/install.sh | bash
```

Open a new login shell if `aws` is not on your `PATH` yet, then set the registry coordinates. The account and region below are the ones used for this demo. Change them if you publish the image somewhere else.

```bash
export AWS_REGION=<your aws region>
export AWS_ACCOUNT=<your aws account number>
export REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export IMAGE="${REGISTRY}/instanton-demo:1.0.0"
```

`aws login --remote` is for a host that has no browser. It prints a URL and a code. Open that URL on your laptop, sign in, and the CLI on the build host receives temporary credentials.

```bash
aws login --remote
```

Create the ECR repository that will hold the image. If the name already exists, the command returns `RepositoryAlreadyExistsException` and you can continue.

```bash
aws ecr create-repository --repository-name instanton-demo --region "${AWS_REGION}"
```

## 5. Log Podman in to ECR

The build, the local run, and the push all use `sudo podman`, which is rootful Podman. The login uses `sudo` so the credentials are stored for that same Podman.

```bash
aws ecr get-login-password --region "${AWS_REGION}" \
  | sudo podman login --username AWS --password-stdin "${REGISTRY}"
```

`aws ecr get-login-password` runs as `ec2-user`, because that is where `aws login` stored the credentials. The password is piped to Podman and is not written into the shell history.

## 6. Build the checkpoint image

`checkpoint.sh afterAppStart` is the last instruction in `Containerfile`. It starts Liberty, waits until the application is up, then freezes the process into the image. That freeze needs three capabilities, and it needs seccomp out of the way:

| Build flag | Why it is there |
| --- | --- |
| `--cap-add=CHECKPOINT_RESTORE` | Lets CRIU checkpoint the process. |
| `--cap-add=SYS_PTRACE` | Lets CRIU attach to the Liberty process while the checkpoint is taken. |
| `--cap-add=SETPCAP` | Lets the build change the process capability set. |
| `--security-opt seccomp=unconfined` | The default seccomp profile blocks system calls CRIU uses. |

`SYS_PTRACE` is required only while the checkpoint is created. The restore in the next step, and the pod on the cluster, do not add it.

```bash
sudo podman build \
  --cap-add=CHECKPOINT_RESTORE \
  --cap-add=SYS_PTRACE \
  --cap-add=SETPCAP \
  --security-opt seccomp=unconfined \
  -t "${IMAGE}" \
  -f Containerfile \
  .
```

The final `.` is the build context: the repository root. Podman must exit 0. In the build log, a completed checkpoint prints:

```text
CWWKC0451I: A server checkpoint "afterAppStart" was requested. When the checkpoint completes, the server stops.
```

`INSTANTON_DEMO_CLASS_INIT` is printed while the application starts, before the process is frozen. It belongs in the build log. Static initialization does not run again on restore, so that line should not appear when the container starts later.

These build errors mean the checkpoint was not taken:

| Build log | Cause |
| --- | --- |
| `exit status 74` or `Operation not permitted` on `criu` | One of the three capabilities was missing, or seccomp was left confined. Re-run the `podman build` command above. |
| `CWWKE0963E` and `virt_sandbox_use_netlink` | SELinux blocked netlink. Run the `setsebool` command in step 3. |
| `CWWKC0456E` | `server.xml` enabled a feature InstantOn does not support. This demo enables only `servlet-6.0`. |

## 7. Confirm the architecture, then push

Push only after this prints `amd64 linux`. Any other architecture will not restore on the ROSA workers.

```bash
sudo podman image inspect "${IMAGE}" --format '{{.Architecture}} {{.Os}}'
sudo podman push "${IMAGE}"
```

## 8. Restore once on the build host

This runs the image you just built and shows whether CRIU can restore it before the cluster is involved. The capabilities here are the restore set: `CHECKPOINT_RESTORE` and `SETPCAP`. `SYS_PTRACE` stays off.

`CRIU_RESTORE_DISABLE_RECOVERY=true` makes a failed restore exit. Without it, Liberty can ignore the checkpoint, start from scratch, and still serve the page. `WLP_LOGGING_CONSOLE_FORMAT=simple` prints one message per line so the codes below are easy to find.

```bash
sudo podman run --rm \
  --cap-add=CHECKPOINT_RESTORE \
  --cap-add=SETPCAP \
  --security-opt seccomp=unconfined \
  --env CRIU_RESTORE_DISABLE_RECOVERY=true \
  --env WLP_LOGGING_CONSOLE_FORMAT=simple \
  -p 9080:9080 \
  "${IMAGE}"
```

A good restore prints both of these:

```text
CWWKC0452I: The Liberty server process resumed operation from a checkpoint in 0.3xx seconds.
CWWKF0011I: The defaultServer server is ready to run a smarter planet. The defaultServer server started in 0.4xx seconds.
```

The fractions vary. For this application they should be well under two seconds. Stop the container with `Ctrl-C` before you move on.

## 9. Create the project and the SCC

Apply these as cluster-admin. The namespace is where the demo runs. The SCC is cluster-scoped and is what allows the pod to restore.

```bash
oc apply -f openshift/namespace.yaml
oc apply -f openshift/scc-cap-cr.yaml
```

Check the constraint. In the `CAPS` column you must see both `CHECKPOINT_RESTORE` and `SETPCAP`.

```bash
oc get scc scc-cap-cr
```

What that SCC allows, and why:

| Setting | Why InstantOn needs it |
| --- | --- |
| `CHECKPOINT_RESTORE`, `SETPCAP` | CRIU restore. `SYS_PTRACE` stays off at runtime. |
| `allowPrivilegeEscalation: true` | Kubernetes treats adding those capabilities as privilege escalation. |
| `allowPrivilegedContainer: false` | The container is not privileged. |
| `seccompProfiles: unconfined` | The default cri-o profile blocks `clone3`, `ptrace`, and `vmsplice`. |
| `runAsUser: MustRunAsNonRoot` | The Liberty image runs as UID 1001. |
| `priority: 10` | Preferred over `restricted-v2` when both could match. The pod requests capabilities `restricted-v2` refuses, so this SCC is the one that can admit it. |

The namespace label `pod-security.kubernetes.io/enforce: privileged` stops Pod Security Admission from rejecting the pod before the SCC is considered. It does not mark the container privileged. The label is set only on `instanton-demo`, and `security.openshift.io/scc.podSecurityLabelSync=false` keeps the SCC syncer from changing it back to `restricted`.

`openshift/scc-cap-cr.yaml` already lists `system:serviceaccount:instanton-demo:liberty-instanton-sa` under `users`. This command grants the same constraint to that service account through a cluster role binding. Helm creates the service account in the next step. The name in the binding is enough; the account object does not have to exist yet.

```bash
oc adm policy add-scc-to-user scc-cap-cr -z liberty-instanton-sa -n instanton-demo
```

The IBM sample grants this style of SCC to `system:authenticated`. This file does not. Only the demo service account can use it.

## 10. Let the cluster pull the image

ECR tokens expire after 12 hours, so create the pull secret just before install. `REGISTRY` must be the same value exported in step 4.

```bash
oc create secret docker-registry ecr-pull \
  --namespace instanton-demo \
  --docker-server="${REGISTRY}" \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region "${AWS_REGION}")"
```

The secret name `ecr-pull` is what the Helm release expects.

## 11. Install the application

```bash
helm upgrade --install instanton-demo ./helm/instanton-demo \
  --namespace instanton-demo \
  --set image="${REGISTRY}/instanton-demo:1.0.0" \
  --set imagePullSecret=ecr-pull
```

`image` is the same reference stored in `${IMAGE}`. The chart creates:

- the service account `liberty-instanton-sa`
- a Deployment that runs that account
- a Service on port 9080
- an edge Route

It does not create the SCC. That was applied in step 9.

The container adds `CHECKPOINT_RESTORE` and `SETPCAP`, drops every other capability, sets `seccompProfile: Unconfined`, and runs as UID 1001. The checkpoint was taken as UID 1001, so the restore has to use that user. `CRIU_RESTORE_DISABLE_RECOVERY=true` is set on the pod for the same reason as in the local run: a failed restore exits instead of starting Liberty from scratch.

## 12. Confirm the restore on the cluster

Wait until the pod is `1/1 Running`.

```bash
oc get pods -n instanton-demo -l app=instanton-demo
```

Then check the log. The first command is the restore line on its own. The second also prints the ready line and shows `CWWKE0961I` if the restore failed.

```bash
oc logs -n instanton-demo -l app=instanton-demo | grep CWWKC0452I
oc logs -n instanton-demo -l app=instanton-demo | grep -E 'CWWKC0452I|CWWKF0011I|CWWKE0961I'
```

A pass looks like the local run:

```text
CWWKC0452I: The Liberty server process resumed operation from a checkpoint in 0.3xx seconds.
CWWKF0011I: The defaultServer server is ready to run a smarter planet. The defaultServer server started in 0.4xx seconds.
```

There should be no `CWWKE0961I`. `INSTANTON_DEMO_CLASS_INIT` should stay in the build log only. It is not printed again here, because static initialization does not run a second time after restore.

## 13. Remove the test

Helm removes the Deployment, Service, Route, and service account. The `add-scc-to-user` command in step 9 also created a cluster role binding. Remove that binding while the namespace still exists, then delete the SCC and the project. Deleting the namespace removes the pull secret. Deleting the SCC removes the cluster-wide constraint.

```bash
helm uninstall instanton-demo --namespace instanton-demo
oc adm policy remove-scc-from-user scc-cap-cr \
  -z liberty-instanton-sa \
  -n instanton-demo
oc delete -f openshift/scc-cap-cr.yaml
oc delete -f openshift/namespace.yaml
```

If the namespace is already gone, delete the `system:serviceaccount:instanton-demo:liberty-instanton-sa` subject from the ClusterRoleBinding `system:openshift:scc:scc-cap-cr` by hand.
