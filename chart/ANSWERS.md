## Part 5 — Written question

**Q1.** A platform is running around 40 Ingress objects on `ingress-nginx`,
which has reached end-of-life. You need to migrate to the Kubernetes Gateway
API with no downtime. Outline your approach, the order you would do things in,
and what you expect to break along the way.


I would use a phased **blue-green migration** to reduce risk and
preserve a rollback path.

-   **Assess and prepare:** Inventory all 40 Ingress resources,
    including hosts, paths, TLS secrets, annotations, authentication,
    rewrites, timeouts and source-IP requirements. Back up the manifests
    and record current DNS and load-balancer settings.
-   **Build Green alongside Blue:** Keep ingress-nginx (Blue) serving
    production traffic. Install the Gateway API CRDs and a compatible
    controller (Green), then configure its Gateway and listeners without
    changing the existing traffic path.
-   **Convert and validate:** Translate Ingress rules into HTTPRoutes in
    small batches. Review NGINX-specific annotations carefully because
    some features need controller-specific policies or redesign. Test
    every hostname and path against Green directly, including TLS,
    redirects, large requests, WebSockets/gRPC where used, and backend
    health.
-   **Shift traffic gradually:** Use an external load balancer or
    traffic manager for a controlled canary, then increase traffic to
    Green while monitoring 4xx/5xx rates, latency and application
    health. DNS can be used, but caching means cutover is not immediate.
-   **Rollback and retire:** If checks fail, send traffic back to Blue;
    leave its routes and controller intact during an agreed observation
    period. Only after all 40 applications are stable on Green would I
    remove the old Ingress resources and decommission ingress-nginx.

The main risks are behavioral differences in annotations, TLS/DNS
automation, health probes and client-IP handling. I would treat each
batch as a release with explicit validation and rollback criteria.