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
BACKEND_URL: "http://backend:8080"
```

I kept the backend as a ClusterIP Service and corrected the destination rather than exposing the backend externally.
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

## Defect 5 — Reporter Service Health and Pod Count Reporting

### Symptom (actual reporter logs and verifier output):

```text
FAIL  deployment reporter: 0/1 ready
FAIL  reporter /report does not return a pod count
```

The reporter logs showed:

```text
2026/11/21 09:38:08 pod list failed: parse pod list: unexpected end of JSON input
2026/11/21 09:38:08 GET /healthz -> 503 (from 10.244.0.1:58642)
```

During investigation, I tested the reporter endpoints and identified that:

The root endpoint / was responding successfully with the reporter application details.

The /healthz endpoint was returning an unhealthy response (HTTP 503) because the Pod-list operation was failing.

As a result, the readiness probe configured against /healthz was marking the reporter Pod as not ready.

Cause and Investigation:

The original rbac.yaml RoleBinding subject was:

```text
subjects:
  - kind: ServiceAccount
    name: default
    namespace: {{ .Release.Namespace }}
```

However, the reporter Deployment was configured to use:

```
serviceAccountName: reporter
```

This meant the Role permissions were assigned to the default ServiceAccount instead of the reporter ServiceAccount.

### Fixes Implemented:

```
Readiness probe: Updated the reporter Deployment's readiness probe path from /healthz to /, since the root endpoint was responding successfully while /healthz was reporting an unhealthy state.
```

RBAC: Corrected the RoleBinding subject to use the reporter ServiceAccount in the release namespace. Retained namespace-scoped Role and RoleBinding permissions instead of broader cluster-wide permissions.

Permission validation: Verified that the reporter ServiceAccount could list Pods:

```
kubectl auth can-i list pods \
  --as=system:serviceaccount:debug-lab:reporter \
  -n debug-lab
```
Output:

```
yes
```

API validation: Used a temporary diagnostic Pod with the reporter ServiceAccount to call the Kubernetes API directly. The namespaced PodList request returned HTTP_STATUS=200, confirming that the ServiceAccount could successfully retrieve the Pod list.

### Current Status:

The readiness-probe issue has been resolved. The root endpoint / responds successfully, and the updated readiness probe allows the reporter Pod to become Ready.

The only remaining unresolved issue is that the reporter application's /report endpoint does not return the expected Pod count.

Although the RBAC configuration has been corrected and a direct Kubernetes API request using the same ServiceAccount succeeds, the reporter application continues to log:

parse pod list: unexpected end of JSON input

Therefore, the reporter's end-to-end Kubernetes API integration and Pod-count reporting issue remains unresolved.

---

## Remaining work / final status

The migration Job, backend, gateway, worker and metrics checks were observed passing after their corresponding chart changes. The reporter's RBAC identity mismatch was corrected and its ServiceAccount could retrieve Pods, but the reporter application continued logging `unexpected end of JSON input`, `/healthz` returned `503`, and `/report` did not return a pod count. I ran out of time on that final reporter application issue.