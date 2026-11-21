# Enterprise Bot — DevOps / Platform Engineer Take-Home

This repository covers the containerized HTTP service, its Helm deployment, the local `kind` setup, the Kubernetes debugging lab, and the written migration question.

## Prerequisites

- Docker
- `kind`
- `kubectl`
- Helm 3

The commands below assume the repository layout from the assignment: `setup.sh`, `service/`, `chart/`, `lab/`, and `ANSWERS.md` at the repository root.

## Run and verify

### 1. Build and deploy the application

From the repository root:

```bash
chmod +x ./setup.sh
./setup.sh
```

The setup script is intended to create or reuse the `demo` kind cluster, install `ingress-nginx`, build and load the application image, and install the Helm release `demo` in namespace `demo`.

Run it a second time to check idempotency:

```bash
./setup.sh
```

Inspect the deployed resources:

```bash
kubectl cluster-info --context kind-demo
kubectl get nodes
kubectl -n demo get deployments,pods,services,ingress
kubectl -n ingress-nginx get pods,services
```

Lint and render the chart, including the value overrides used by the assignment harness:

```bash
helm lint ./chart
helm template demo ./chart -n demo \
  --set replicaCount=3 \
  --set config.appName=override-check \
  --set config.version=0.0.0
```

Check the application through the Ingress. The kind cluster must expose the ingress controller on localhost port 80, and `demo.local` must resolve to localhost (or use the equivalent host/IP mapping configured by `setup.sh`):

Please note that the requried 'demo.local' as to be configured with in the hosts file of your system.

```bash
curl --fail --show-error --resolve demo.local:80:127.0.0.1 http://demo.local/
curl --fail --show-error --resolve demo.local:80:127.0.0.1 http://demo.local/healthz
```

The root endpoint should return the configured application name and version, together with the pod hostname. The health endpoint should return HTTP 200. To test through the Service directly instead, first inspect the Service name and port with `kubectl -n demo get services`, then use `kubectl port-forward` and curl the forwarded local port.

### 2. Run and verify the Part 4 debugging lab

From the repository root:

```bash
cd lab
./scenario.sh up
./scenario.sh verify
```

`verify` is the authoritative acceptance check for the lab and returns a non-zero exit status when one or more checks fail. It checks the migration Job, workload readiness, CrashLoopBackOff status, reporter permissions, backend health, gateway status, and reporter output.

Useful diagnostics when a check fails:

```bash
kubectl get pods -n debug-lab -o wide
kubectl get events -n debug-lab --sort-by=.lastTimestamp
kubectl describe deployment -n debug-lab
kubectl logs deployment/backend -n debug-lab
kubectl logs deployment/gateway -n debug-lab
kubectl logs deployment/worker -n debug-lab
kubectl logs deployment/reporter -n debug-lab
helm get values debug-lab -n debug-lab
helm get manifest debug-lab -n debug-lab
```

Do not change `lab/cluster-state/` or the supplied debug image repository/tag; the assignment harness reapplies the environment and checks the chart behaviour.

## Resource requests and limits

For the lightweight Part 4 lab workloads, the baseline sizing is deliberately conservative. These values are starting points for a small local cluster, not production capacity recommendations.

| Workload | CPU request | Memory request | CPU limit | Memory limit |
|---|---:|---:|---:|---:|
| Backend | 50m | 64Mi | 200m | 128Mi |
| Gateway | 50m | 64Mi | 200m | 128Mi |
| Worker | 50m | 64Mi | 200m | 128Mi |
| Reporter | 50m | 64Mi | 200m | 128Mi |
| Migration Job | 50m | 64Mi | 200m | 128Mi |
| Metrics | 100m | 64Mi | 500m | 128Mi |

The requests provide a small baseline reservation so the scheduler can place these low-volume processes without reserving excessive capacity. The limits cap resource consumption and help prevent a single lab process from monopolizing the node. Metrics receives a higher CPU request and limit than the other services to allow for additional processing while remaining below the namespace LimitRange maximum of one CPU per container. The memory values follow the same low-footprint approach; they should be revisited using observed working-set and peak-memory data before production use.

For the Part 2 application chart, the resource values in `chart/values.yaml` are the source of truth. Keep this section aligned with those values if they differ from the Part 4 lab sizing above.

## Deliberately omitted and associated risks

- **High availability and autoscaling:** The lab uses one replica per workload. There is no HPA or PodDisruptionBudget. A pod or node failure, rollout, or maintenance event can therefore make a component unavailable, and the workloads do not scale automatically with demand.
- **NetworkPolicies:** Pod-to-pod traffic is not restricted. A compromised workload could communicate with other services in the namespace more freely than it should.
- **Production observability:** The exercise relies primarily on Kubernetes events, pod status, and container logs. Centralized logs, service-level dashboards, distributed tracing, and alerting are not included, which would increase detection and diagnosis time during an incident.
- **Persistent worker cache:** The worker cache uses an ephemeral writable volume to preserve a read-only container root filesystem. Cache contents are lost when the pod is replaced. This is acceptable for disposable cache data, but not for durable state.
- **Reporter end-to-end validation:** The reporter ServiceAccount permission was investigated and the RoleBinding identity was corrected to `reporter`. A diagnostic pod using that ServiceAccount could retrieve a PodList from the Kubernetes API, but the reporter process continued logging `parse pod list: unexpected end of JSON input` and its readiness endpoint returned 503 in the captured session. I have not treated this as resolved. The next step is to capture the exact URL, HTTP status, and response body from the reporter process's own API request and compare it with the successful diagnostic request.
- **Complete debugging-session recording:** The terminal recording did not capture the entire investigation from its start. This limits how completely the diagnostic sequence can be audited, even though the findings include the observed commands and outputs available from the session.

## What I would change for production

1. Run multiple replicas for stateless services and configure readiness, liveness, and startup probes based on actual application behaviour. Add PodDisruptionBudgets and topology spread constraints so maintenance or a node failure does not remove every replica from service.
2. Tune requests and limits from load tests and production telemetry, then add HPA or event-based scaling where workload characteristics justify it. Validate cluster capacity and configure a Cluster Autoscaler or equivalent node-provisioning mechanism.
3. Apply least-privilege RBAC and default-deny NetworkPolicies. Keep the worker root filesystem read-only, run containers as non-root with an explicit UID/GID, use a restrictive seccomp profile, and avoid unnecessary Linux capabilities.
4. Use TLS for service ingress, automated certificate management, managed secret storage, and secret rotation. Avoid storing credentials in Helm values or container images.
5. Add centralized structured logging, metrics, tracing, service-level objectives, and actionable alerts. Include resource saturation, request latency, error rate, pod restarts, and dependency health.
6. Add CI checks for formatting, unit/integration tests, `helm lint`, rendered-manifest validation, container vulnerability scanning, and image provenance/signing. Deploy through a controlled rolling or blue-green strategy with a tested rollback path.
7. Make migrations explicitly idempotent, observable, and safe to retry. Validate backup and recovery requirements for any persistent data before rollout.

## How I used AI

I used **ChatGPT** as a supporting assistant during the exercise. I asked it to explain Kubernetes and Helm behaviour, help interpret selected pod logs and rendered manifests, suggest diagnostic commands, and help structure the written Gateway API migration answer and this README.

I ran the Kubernetes and Helm commands myself and used their output to decide which hypotheses were supported. I did not treat generated explanations as proof. For example, a broader RBAC binding was considered during reporter troubleshooting, but a direct API test using the reporter ServiceAccount returned a valid PodList while the reporter application still failed to parse its response. I therefore did not claim that the reporter issue was fixed and documented the remaining investigation instead. The final changes and conclusions should be understood from the committed manifests, command output, and findings file—not from AI suggestions alone.
