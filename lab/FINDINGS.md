# Findings — Part 4 debug lab

> **Evidence note:** The output snippets below are copied from terminal output captured during this investigation. Where the original failure text was not preserved, I have said so rather than reconstructing an error message. The reporter's final end-to-end failure was still unresolved at the end of this session; I have not marked it as fixed.
>
> **Session recording:** I did not start `script -q part4-session.log` before the first investigation, so I cannot honestly provide a complete recording of the earlier work. A recording started now would capture only the remaining verification, not the investigation already completed. I will not present a retroactive or fabricated recording as a full session.

---

## Defect 1 — Migration Job restart policy

**Symptom** (what I observed):

The original `broken-chart/templates/migrate-job.yaml` had this Pod template setting:

```yaml
spec:
  template:
    spec:
      restartPolicy: Always
```

The initial exact Kubernetes admission/Helm error was not retained in my terminal transcript, so I am not inventing it. After changing the Job template, the verifier reported:

```text
PASS  migrate Job completed
```

**Cause** (root cause):

A Job's Pod template cannot use `restartPolicy: Always`. For Jobs, the supported values are `Never` and `OnFailure`. `Always` is the restart policy used by controllers such as Deployments, not one-shot Jobs.

**Fix**:

I changed the Job Pod template to `restartPolicy: Never` (the uploaded corrected template contains this value). I chose `Never` because the Job controller should observe a completed or failed Pod and apply the Job's `backoffLimit`; it should not continuously restart the process inside the same Pod.

**How I found it**:

I inspected the rendered Helm manifest and the migration Job template after the initial release/verification failure. The invalid setting was in the Job's Pod template, not in the image or the Job's backoff configuration. I then updated the template and used `./scenario.sh verify` to confirm the migration Job completed.

---

## Defect 2 — Application listen port did not match the chart port

**Symptom** (actual log output):

```text
$ kubectl logs backend-6f7946956-vhj26 -n debug-lab
2026/11/21 06:03:31 eb-debug-app 2.0.0 starting: mode=api pod=backend-6f7946956-vhj26 listening on :8081 (image default is 8081; set PORT to override)
```

The chart's `common.port`, container port, Service target port and readiness probe were configured for `8080`. The application log showed that it was actually listening on `8081` when no `PORT` override was supplied.

After the port configuration was corrected, the backend returned:

```text
{"status":"ok"}
```

**Cause** (root cause):

The chart advertised and probed port `8080`, but the image defaulted to port `8081`. The relevant `PORT` environment variable was missing from the workload environment configuration. This affected the HTTP workloads that shared the chart's `common.port` setting.

**Fix**:

I set `PORT` to the configured common port (`8080`) in the environment for the HTTP workloads, rather than changing the Services and probes to `8081`. The chart already defined `8080` as the intended application port, so making the process listen on that port kept the Deployment, Service and probe configuration consistent.

**How I found it**:

I compared the backend startup log with the Deployment's `containerPort` and readiness probe. The application explicitly logged `listening on :8081`, while the Kubernetes manifest declared port `8080`. I checked the other workload templates and their values because they also used `common.port`; I then supplied the explicit `PORT` override and re-tested the health endpoint from inside the cluster.

---

## Defect 3 — Gateway pointed to the backend in the wrong namespace

**Symptom** (actual verifier output):

```text
FAIL  gateway /status does not report backend=ok
```

The original `broken-chart/values.yaml` contained:

```yaml
BACKEND_URL: "http://backend:8080"
```

After correcting the destination, the in-cluster gateway check returned a body containing:

```json
{"app":"gateway","backend":"ok","backend_url":"http://backend:8080","self":"ok","version":"2.0.0"}
```

**Cause** (root cause):

The backend Service was deployed into the `debug-lab` namespace, but the gateway's `BACKEND_URL` explicitly targeted the `default` namespace. The DNS name was valid in form but referred to the wrong namespace, so the gateway could not reach the backend Service it was supposed to aggregate.

**Fix**:

I changed `BACKEND_URL` to the backend Service in the lab namespace, for example:

```yaml
BACKEND_URL: "http://backend.debug-lab.svc:8080"
```

I kept the backend as a ClusterIP Service and corrected the destination rather than exposing the backend externally. The in-cluster short name `http://backend:8080` would also work from a pod in the same namespace.

**How I found it**:

I used the gateway status check as the signal, then compared the configured `BACKEND_URL` with the namespace where `backend` was installed. The backend Service existed in `debug-lab`; the configured URL pointed to `default`. After changing the URL, I checked `/status` from a temporary in-cluster BusyBox pod and confirmed it reported `backend: ok`.

---

## Defect 4 — Worker needed a writable cache directory

**Symptom** (actual log output):

```text
$ kubectl logs worker-8499c9bf4d-f9vbp -n debug-lab
2026/11/21 06:05:00 FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

A later previous-container log showed the same failure:

```text
2026/11/21 06:28:46 FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

**Cause** (root cause):

The worker had `readOnlyRootFilesystem: true`, but the chart did not mount a writable volume at the cache directory expected by the application (`/var/cache/app`). The application exited when it tried to create its cache directory.

**Fix**:

I added an `emptyDir` volume and mounted it at `/var/cache/app`. This gives the worker an ephemeral writable location for cache files while keeping the container root filesystem read-only. I preferred this to disabling `readOnlyRootFilesystem`, because it grants write access only to the path the application needs.

**How I found it**:

I checked the worker's previous container logs with `kubectl logs ... --previous`, then searched the chart for `readOnlyRootFilesystem`, `volumes` and `volumeMounts`. The log named the exact path that needed write access; the template had the read-only security setting but no cache volume. I added the mount and checked the worker Deployment's readiness.

---

## Defect 5 — Reporter RoleBinding referenced the wrong ServiceAccount; reporter endpoint remained unresolved

**Symptom** (actual reporter logs and verifier output):

```text
FAIL  deployment reporter: 0/1 ready
FAIL  reporter /report does not return a pod count
```

The reporter log continued to show:

```text
2026/11/21 09:38:08 pod list failed: parse pod list: unexpected end of JSON input
2026/11/21 09:38:08 GET /healthz -> 503 (from 10.244.0.1:58642)
```

The original `rbac.yaml` RoleBinding subject was:

```yaml
subjects:
  - kind: ServiceAccount
    name: default
    namespace: {{ .Release.Namespace }}
```

But the reporter Deployment ran as `serviceAccountName: reporter`.

**Cause** (root cause):

The Role granted permission to list/get Pods, but its RoleBinding originally attached that Role to the `default` ServiceAccount instead of the `reporter` ServiceAccount used by the reporter Deployment. The permissions were therefore assigned to the wrong identity.

**Fix**:

The least-privilege fix is to keep a namespace-scoped `Role` and `RoleBinding`, and change the RoleBinding subject to `name: reporter` in the release namespace. I tested broader `ClusterRole` permissions during diagnosis, but cluster-wide access is not required by the verifier: it checks whether the reporter can list Pods in the lab namespace. I would keep the final configuration namespace-scoped rather than leave unnecessary cluster-wide permissions.

The permission check after correcting the subject returned:

```text
$ kubectl auth can-i list pods --as=system:serviceaccount:debug-lab:reporter -n debug-lab
yes
```

I also used a temporary pod with the reporter ServiceAccount to call the Kubernetes API directly; the namespaced PodList request returned `HTTP_STATUS=200`. However, the reporter application continued to log the JSON parsing error and `/report` remained empty. Therefore, the RBAC misbinding was identified and corrected, but I did **not** finish resolving the reporter's end-to-end API-client failure.

**How I found it**:

I compared the reporter Deployment's `serviceAccountName` with the `subjects` section of the RoleBinding. I then used `kubectl auth can-i` and a temporary diagnostic pod using the same ServiceAccount to separate an RBAC/API permission problem from the reporter process itself. The diagnostic pod could fetch a valid PodList, but the reporter continued returning `503`. The reporter image has no `/bin/sh` (`exec: "/bin/sh": stat /bin/sh: no such file or directory`), so I used a separate diagnostic pod rather than relying on `kubectl exec` into the application container.

**What I would try next**:

I would keep the namespace-scoped RoleBinding to `reporter`, then use an ephemeral debug container or a temporary instrumented sidecar to capture the exact URL, HTTP status and response body produced by the reporter's own Kubernetes API request. I would compare that request with the successful direct request from the diagnostic pod. I would not grant more permissions unless the captured request demonstrated a specific missing permission.

---

## Remaining work / final status

The migration Job, backend, gateway, worker and metrics checks were observed passing after their corresponding chart changes. The reporter's RBAC identity mismatch was corrected and its ServiceAccount could retrieve Pods, but the reporter application continued logging `unexpected end of JSON input`, `/healthz` returned `503`, and `/report` did not return a pod count. I ran out of time on that final reporter application issue.