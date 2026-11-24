# InstantOn on ROSA

This demo checks whether Open Liberty InstantOn can restore on a ROSA cluster.

InstantOn checkpoints the running Liberty process while the container image is built. On the cluster, CRIU restores that snapshot. The application does not change. The pod needs two Linux capabilities (`CHECKPOINT_RESTORE` and `SETPCAP`) and a seccomp profile that allows the CRIU system calls. OpenShift will not grant those under the default `restricted-v2` constraint, so the test project uses the SCC in `openshift/scc-cap-cr.yaml`.

The pass signal is this line in the pod log:

```text
CWWKC0452I: The Liberty server process resumed operation from a checkpoint
```

A page that loads, by itself, is not a pass. If restore fails, Liberty can start normally and still serve traffic. This chart sets `CRIU_RESTORE_DISABLE_RECOVERY=true` so a failed restore exits instead of doing that.

References:

- [Open Liberty InstantOn](https://openliberty.io/docs/latest/instanton.html)
- [IBM: Liberty InstantOn on OpenShift](https://community.ibm.com/community/user/blogs/tam-dinh/2024/09/09/liberty-instanton-on-ocp)

## What you need

- A ROSA cluster on OpenShift 4.14 or later, with **x86_64 worker nodes**. InstantOn does not support arm64. A Graviton ROSA cluster will not restore this image.
- A user with **cluster-admin**. Creating an SCC is cluster-scoped. The ROSA `dedicated-admin` role cannot create it. `rosa create admin` provides a cluster-admin if you do not already have one.
- A **Linux x86_64 build machine** with kernel 5.9 or newer, Podman, and `sudo`. The checkpoint runs inside the image build. Docker cannot add `CHECKPOINT_RESTORE` to a `RUN` step, so Podman is required. Build on the same architecture as the workers. A Mac, including a Podman machine on Apple Silicon, is the wrong build host.
- `oc` and Helm 3, logged into the cluster.
- A registry the ROSA workers can pull from. Amazon ECR in the cluster region is the straightforward choice. An ECR authorization token expires after 12 hours.

## Repository layout

| Path | Purpose |
| --- | --- |
| `pom.xml` | Builds the war. The only dependency is the servlet API, provided by Liberty. |
| `src/main/java/com/example/instanton/StatusServlet.java` | The application: one servlet on `/status`. |
| `src/main/liberty/config/server.xml` | Liberty config. Enables `servlet-6.0` only. |
| `Containerfile` | Multi-stage build. The last instruction is `checkpoint.sh afterAppStart`. |
| `Containerfile.baseline` | Same application with no checkpoint, for the timing comparison. |
| `openshift/namespace.yaml` | Test project. Pod Security Admission is `privileged` so it allows the SCC. |
| `openshift/scc-cap-cr.yaml` | SCC you apply as cluster-admin. |
| `helm/instanton-demo` | One values file and one template: ServiceAccount, Deployment, Service, Route. |
| `scripts/build-instanton.sh` | Podman build with the three checkpoint capabilities. |
| `scripts/check-restore.sh` | Pass/fail check against the pod log and the route. |

## 1. Check the cluster before building

```bash
oc get nodes -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,KERNEL:.status.nodeInfo.kernelVersion
```

Every worker that might run the pod must show `amd64` and a kernel of 5.9 or newer. ROSA 4.14 and later uses RHCOS 9, which meets the kernel requirement.

On one worker, confirm the Yama ptrace setting. InstantOn works when `kernel.yama.ptrace_scope` is `0` or `1`. It fails when the value is `2` or `3`.

```bash
NODE="$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')"
oc debug "node/${NODE}" -- chroot /host sysctl kernel.yama.ptrace_scope
```

`oc debug` removes that pod when the command exits. If one is left behind, it is in the project you were using. Delete it with `oc delete pod <name>`.

## 2. Build the checkpoint image

Run this on the Linux x86_64 build host, from the repository root.

If SELinux is enforcing on that host, allow the netlink calls CRIU uses during checkpoint:

```bash
getenforce
sudo setsebool virt_sandbox_use_netlink 1
```

`setsebool` without `-P` lasts until reboot, which is enough for the test. Use `-P` only if you want it permanent.

Log in to ECR and build. Replace the account and region.

```bash
export AWS_REGION=us-east-1
export AWS_ACCOUNT=123456789012
export REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export IMAGE="${REGISTRY}/instanton-demo:1.0.0"

aws ecr describe-repositories --repository-names instanton-demo --region "${AWS_REGION}" \
  || aws ecr create-repository --repository-name instanton-demo --region "${AWS_REGION}"

aws ecr get-login-password --region "${AWS_REGION}" \
  | sudo podman login --username AWS --password-stdin "${REGISTRY}"

scripts/build-instanton.sh "${IMAGE}" instanton
```

The build is a pass only when Podman exits 0. In the build log, find:

```text
CWWKC0451I: A server checkpoint "afterAppStart" was requested. When the checkpoint completes, the server stops.
```

Also find `INSTANTON_DEMO_CLASS_INIT`. That line is printed while the application starts, before the process is frozen. It should appear in the build log and should not be printed again when the pod starts.

These build errors mean the checkpoint was not taken:

| Build log | Cause |
| --- | --- |
| `exit status 74` or `Operation not permitted` on `criu` | The build was not given `CHECKPOINT_RESTORE`, `SYS_PTRACE`, and `SETPCAP`, or seccomp was left confined. Use `scripts/build-instanton.sh`. |
| `CWWKE0963E` and `virt_sandbox_use_netlink` | SELinux on the build host blocked netlink. Run the `setsebool` command above. |
| `CWWKC0456E` | `server.xml` enabled a feature InstantOn does not support. This demo enables only `servlet-6.0`. |

Confirm the image architecture, then push:

```bash
sudo podman image inspect "${IMAGE}" --format '{{.Architecture}} {{.Os}}'
sudo podman push "${IMAGE}"
```

The inspect line must be `amd64 linux`.

### Optional: restore once on the build host

This catches a bad checkpoint before you involve the cluster.

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

Pass: the log contains `CWWKC0452I` and `CWWKF0011I`, and the reported start time is a fraction of a second. In another terminal:

```bash
curl -fsS http://127.0.0.1:9080/status
```

Stop the container with `Ctrl-C`.

`SYS_PTRACE` is required to **take** the checkpoint. It is not required to **restore**.

## 3. Create the project and the SCC

As cluster-admin:

```bash
oc apply -f openshift/namespace.yaml
oc apply -f openshift/scc-cap-cr.yaml
oc get scc scc-cap-cr
```

`openshift/scc-cap-cr.yaml` already lists `system:serviceaccount:instanton-demo:liberty-instanton-sa`. That is the grant. You do not also need a role binding unless you remove that `users` entry.

The IBM sample grants the same style of SCC to `system:authenticated`. This file does not. Only the demo service account can use it.

If you change the namespace or the service account name, either edit `users` or run:

```bash
oc adm policy add-scc-to-user scc-cap-cr \
  -z liberty-instanton-sa \
  -n instanton-demo
```

What the SCC allows, and why:

| Setting | Why InstantOn needs it |
| --- | --- |
| `CHECKPOINT_RESTORE`, `SETPCAP` | CRIU restore. `SYS_PTRACE` stays off at runtime. |
| `allowPrivilegeEscalation: true` | Kubernetes treats adding those capabilities as privilege escalation. |
| `allowPrivilegedContainer: false` | The container is not privileged. |
| `seccompProfiles: unconfined` | The default cri-o profile blocks `clone3`, `ptrace`, and `vmsplice`. |
| `runAsUser: MustRunAsNonRoot` | The Liberty image runs as UID 1001. |
| `priority: 10` | Preferred over `restricted-v2` when both could match. The pod requests capabilities `restricted-v2` refuses, so this SCC is the one that can admit it. |

The namespace label `pod-security.kubernetes.io/enforce: privileged` stops Pod Security Admission from rejecting the pod before the SCC is considered. It does not mark the container privileged. The label is set only on `instanton-demo`, and `security.openshift.io/scc.podSecurityLabelSync=false` keeps the SCC syncer from changing it back to `restricted`.

## 4. Let the cluster pull the image

ECR tokens expire. Create the pull secret just before install. Skip this if the worker IAM role can already pull from the repository.

```bash
oc create secret docker-registry ecr-pull \
  --namespace instanton-demo \
  --docker-server="${REGISTRY}" \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region "${AWS_REGION}")"
```

## 5. Deploy

```bash
helm upgrade --install instanton-demo ./helm/instanton-demo \
  --namespace instanton-demo \
  --set image="${REGISTRY}/instanton-demo:1.0.0" \
  --set imagePullSecret=ecr-pull
```

Omit `--set imagePullSecret=ecr-pull` when you did not create that secret.

The chart creates the service account `liberty-instanton-sa`, a Deployment, a Service on port 9080, and an edge Route. It does not create the SCC.

`serviceAccountName` is a pod field. The capabilities are a container field. The container adds `CHECKPOINT_RESTORE` and `SETPCAP`, drops every other capability, sets `seccompProfile: Unconfined`, and runs as UID 1001. Swapping the service account and the capabilities is the usual reason a pod reaches `Running` and then logs `Operation not permitted` on `/opt/criu/criu`.

## 6. Run the test

```bash
oc get pods -n instanton-demo -w
```

Wait until the pod is `1/1 Running`. Then:

```bash
scripts/check-restore.sh instanton-demo instanton-demo
```

Or do the same checks by hand.

**Which SCC admitted the pod**

```bash
oc get pod -n instanton-demo \
  -l app=instanton-demo \
  -o jsonpath='{.items[0].metadata.annotations.openshift\.io/scc}{"\n"}'
```

Expected value: `scc-cap-cr`.

**Restore message and startup time**

```bash
oc logs -n instanton-demo -l app=instanton-demo \
  | grep -E 'CWWKC0452I|CWWKF0011I|CWWKE0961I'
```

Pass looks like:

```text
CWWKC0452I: The Liberty server process resumed operation from a checkpoint in 0.3xx seconds.
CWWKF0011I: The defaultServer server is ready to run a smarter planet. The defaultServer server started in 0.4xx seconds.
```

The fractions vary. For this application they should be well under two seconds. There must be no `CWWKE0961I`.

**Application response**

```bash
ROUTE="$(oc get route -n instanton-demo instanton-demo -o jsonpath='{.spec.host}')"
curl -fsS "https://${ROUTE}/status"
echo
```

Open `https://<route>/status` in a browser as well. The response is only a reachability check. The log line is the result.

Read `/status` this way:

- `classInitializedEpochMillis` is the time the servlet class was initialized. With a real restore, that happened on the build host, so `millisSinceClassInit` is large (minutes or hours since the image was built).
- `jvmUptimeMillis` is the time since this JVM began running in the pod. After a restore it is small, on the order of the `CWWKC0452I` time plus the time you waited before calling `/status`.
- A large `millisSinceClassInit` together with a small `jvmUptimeMillis` supports the log line. The log line is the result that matters.
- If both numbers are small, the class was initialized when the pod started. The process was not restored.

`INSTANTON_DEMO_CLASS_INIT` should be in the **build** log. It should not be printed again in `oc logs`, because static initialization does not run a second time after restore.

## 7. Compare with a normal start

Build and push an image that has no checkpoint:

```bash
export BASELINE="${REGISTRY}/instanton-demo:baseline"
scripts/build-instanton.sh "${BASELINE}" baseline
sudo podman push "${BASELINE}"
```

Deploy it beside the InstantOn release. `instanton=false` drops the extra capabilities, uses the `RuntimeDefault` seccomp profile, and selects the `default` service account, so `restricted-v2` can admit it. It does not set `runAsUser: 1001`. That UID is outside the project range, which `restricted-v2` rejects. OpenShift assigns an in-range UID. The InstantOn pod still runs as 1001, because that is the UID the checkpoint was taken as.

```bash
helm upgrade --install instanton-baseline ./helm/instanton-demo \
  --namespace instanton-demo \
  --set image="${REGISTRY}/instanton-demo:baseline" \
  --set instanton=false \
  --set imagePullSecret=ecr-pull
```

```bash
oc logs -n instanton-demo -l app=instanton-baseline \
  | grep -E 'CWWKC0452I|CWWKF0011I'
```

The baseline log has `CWWKF0011I` and no `CWWKC0452I`. Record the two `CWWKF0011I` times. The checkpoint image should be the shorter one. On a small servlet the baseline is often a few seconds and the restored process is a few hundred milliseconds. Use the numbers from your cluster.

Remove the comparison when you are done:

```bash
helm uninstall instanton-baseline --namespace instanton-demo
```

## 8. If the test fails

Look at the pod events first:

```bash
oc describe pod -n instanton-demo -l app=instanton-demo
oc get events -n instanton-demo --sort-by='.lastTimestamp'
```

| What you see | What it means | What to do |
| --- | --- | --- |
| `capability may not be added` for `CHECKPOINT_RESTORE` or `SETPCAP`, provider `restricted-v2` | The service account cannot use `scc-cap-cr`, or the pod was created before the SCC existed. | Confirm `oc get scc scc-cap-cr -o jsonpath='{.users}'` contains `system:serviceaccount:instanton-demo:liberty-instanton-sa`. Delete the pod so it is recreated. |
| `Forbidden: unable to validate against any security context constraint` and `allowPrivilegeEscalation` | Same SCC miss. | Same check. The container must set `allowPrivilegeEscalation: true`. |
| `would violate PodSecurity "restricted"` and the pod is not created | The namespace label was overwritten or not applied. | Re-apply `openshift/namespace.yaml`. Confirm `pod-security.kubernetes.io/enforce=privileged`. |
| Pod `Running`, log says `/opt/criu/criu: Operation not permitted` and `CWWKE0961I` | The process did not receive the capabilities. | `oc get pod -o yaml` and confirm the **container** `securityContext.capabilities.add` lists both capabilities. Confirm the SCC annotation is `scc-cap-cr`. |
| `restore.log` mentions `clone3`, `ptrace`, or `vmsplice` with `Operation not permitted` | seccomp blocked CRIU. | The container `seccompProfile.type` must be `Unconfined`, and the SCC `seccompProfiles` must include `unconfined`. |
| `ptrace(PTRACE_TRACEME) failed` in `restore.log` | Yama is blocking ptrace. | `kernel.yama.ptrace_scope` on the node must be `0` or `1`. This is a node setting; changing it is a cluster-admin decision and is outside this demo. |
| `CrashLoopBackOff` and `oc logs` is empty | The failed process already exited. | `oc logs --previous`. With `CRIU_RESTORE_DISABLE_RECOVERY=true`, a failed restore is supposed to exit. |
| `CWWKF0011I` after several seconds and no `CWWKC0452I` | The image has no checkpoint, or recovery started the server cold. | Confirm the running image tag is the InstantOn tag, not `baseline`. Search the build log for `CWWKC0451I`. |
| `exec format error` or the pod never starts on an `arm64` node | The image and the node architecture differ. | Rebuild on x86_64 and schedule onto `amd64` workers. |
| Image pull `403` or `unauthorized` | The ECR token expired or the pull secret is missing. | Recreate `ecr-pull` and restart the pod. |

CRIU writes a restore log inside the container when the process stays up long enough:

```bash
oc exec -n instanton-demo deploy/instanton-demo -- cat /logs/checkpoint/restore.log
```

## 9. Remove the test

```bash
helm uninstall instanton-demo --namespace instanton-demo
oc delete -f openshift/scc-cap-cr.yaml
oc delete -f openshift/namespace.yaml
```

Deleting the namespace removes the pull secret and the service account. Deleting the SCC removes the cluster-wide constraint. If you also ran `oc adm policy add-scc-to-user`, delete the binding it created:

```bash
oc adm policy remove-scc-from-user scc-cap-cr \
  -z liberty-instanton-sa \
  -n instanton-demo
```

Run that removal before deleting the namespace, or delete the ClusterRoleBinding `system:openshift:scc:scc-cap-cr` subject by hand if the namespace is already gone.
