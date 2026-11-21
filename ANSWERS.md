### Q1. Migrating from ingress-nginx to Kubernetes Gateway API

I would use a **blue-green migration strategy** to avoid downtime and reduce deployment risk.

1. **Assess the existing setup:** Inventory all 40 Ingress objects, including hosts, paths, TLS certificates, annotations, rewrites, authentication, rate limits and timeouts. Identify ingress-nginx-specific configurations that need alternatives.

2. **Deploy the new environment:** Install the Gateway API CRDs and a compatible Gateway controller. Create the `GatewayClass`, `Gateway` and corresponding `HTTPRoute` resources while keeping ingress-nginx running.

3. **Migrate incrementally:** Convert a few low-risk Ingress resources first. Validate route matching, TLS, authentication, backend connectivity, health checks and application behaviour. Pay special attention to controller-specific annotations that may not have direct Gateway API equivalents.

4. **Blue-green traffic migration:** Expose the new Gateway through a separate endpoint and test it independently. Gradually shift traffic from the old Ingress to the new Gateway using a load balancer or traffic-management layer, starting with a small percentage and increasing to 100%.

5. **Monitor and roll back:** Monitor HTTP 4xx/5xx errors, latency and backend availability at every stage. If issues occur, redirect traffic to the existing ingress-nginx environment.

6. **Decommission:** Once the new Gateway is stable, remove the old Ingress resources and ingress-nginx controller.

**Expected challenges:** Unsupported annotations, differences in path matching and rewrites, TLS configuration, authentication policies, controller-specific feature gaps and connection-draining behaviour. I would maintain both environments until the migration is fully validated.