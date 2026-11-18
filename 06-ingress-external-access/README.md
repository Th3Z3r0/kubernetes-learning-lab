# Lesson 06 — Ingress and External Access

Use the [hands-on lab](LAB.md) to work through exercises 06A–F on the Ubuntu kind cluster from Lesson 00.

## Objective

Trace three paths to an application, then isolate a Service selector failure by inspecting Kubernetes, the Cilium Service dataplane, and Envoy separately.

| Entry point | What selects the destination | Reference request |
|---|---|---|
| ClusterIP Service | The Service selects Pods by label. Kubernetes records eligible endpoints in EndpointSlices, and Cilium implements Service forwarding in this cluster. | Client Pod → `lesson06-web:80` → web Pods |
| Application NodePort Service | An allocated port on a reachable node exposes the Service. Its selector points at the same web Pods as the ClusterIP Service. | Ubuntu host → node IP and web NodePort → web Pods |
| Cilium Ingress | Cilium configures an Envoy listener. Envoy evaluates the HTTP host and path to select the upstream described by the Ingress. | Ubuntu host → node IP and Ingress NodePort → Envoy → web or API Pod |

A NodePort exposes a transport port. The HTTP hostname and path rules live in the Ingress and are implemented by its controller and proxy. This lab uses a dedicated Cilium Ingress Service of type NodePort so that it can run on kind without an external load balancer. Its backends are the two ClusterIP Services, and the Ingress specifies each backend's **Service port**.

## Hostname and path routing

The final stage uses one Ingress and one HTTP entry point.

| HTTP host | Path | Backend Service |
|---|---|---|
| `app.myk8s.local` | `/api` and its subpaths | `lesson06-api:5678` |
| `app.myk8s.local` | `/` and paths outside the API prefix | `lesson06-web:80` |
| `api.myk8s.local` | `/` and its subpaths | `lesson06-api:5678` |

Kubernetes `Prefix` matching uses path elements. The longest matching path takes precedence. The rule sending traffic to the web Service does not guarantee that the web app serves every matched URL. The lab uses different response bodies to identify which application answered.

## Reference run: selector break

The reference run changed `myk8s/lesson06-api` from `app=lesson06-api` to `app=lesson06-api-broken`. These values describe that run. IP addresses and Pod names will vary.

| Observation point | Result with the broken selector |
|---|---|
| API workload | The API Pod remained up at `10.10.2.242:5678`. |
| Kubernetes EndpointSlice | The API Service's slice showed `endpoints: null`. |
| Cilium ClusterIP forwarding | The `10.11.81.42:5678/TCP` ClusterIP entry had no backend. The direct request from a diagnostic Pod gave curl exit 7 and `HTTP 000`, meaning no HTTP response was received. |
| Envoy runtime EDS | All three Cilium agents (`cilium-cbnnd`, `cilium-ccq2z`, `cilium-k6xwp`) still reported `10.10.2.242:5678` under `myk8s/lesson06-api:5678`. |
| Ingress request | Repeated requests for `app.myk8s.local/api` returned `Hello from Lesson 06 API` and HTTP 200. |

The retained Envoy endpoint explains how Ingress could still reach the API while direct Service traffic failed. The underlying reason the endpoint remained in EDS is unconfirmed. The observed discrepancy is specific to this run and does not establish a Cilium defect. The `HEALTHY` field in the dump records Envoy's endpoint status. The HTTP request independently verified that the Ingress path could serve the API. [Cilium Envoy endpoint inspection](https://docs.cilium.io/en/latest/cmdref/cilium-dbg_envoy_admin_config/).

After restoring the selector, the EndpointSlice again listed `10.10.2.242:5678`, and the Ingress API request returned HTTP 200. The original diagnostic Pod had already reached `Succeeded`, so the direct post-recovery ClusterIP request was not verified in that run. The runbook includes a direct recovery check with its own client Pod.

## References

- [Kubernetes Services](https://kubernetes.io/docs/concepts/services-networking/service/)
- [Kubernetes EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)
- [Kubernetes Ingress routing and path types](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [Cilium Ingress support and annotations](https://docs.cilium.io/en/stable/network/servicemesh/ingress/)

[Back to the learning path](../README.md#learning-path).
