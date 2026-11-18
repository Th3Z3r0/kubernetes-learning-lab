# Lesson 06 Hands-on Lab — Ingress and External Access

Run these Bash commands from the repository root on the Ubuntu host that runs the kind cluster. Keep the same shell so the variables and functions remain available.

## Prerequisite and starting state

Use the three-node cluster from [Lesson 00](../00-prerequisites/LAB.md), with Cilium kube-proxy replacement, the L7 proxy, and the Cilium Ingress controller enabled. The lab uses the existing `myk8s` namespace and needs `kubectl`, Docker access, `curl`, and `jq`. Use your learning cluster for the deliberate selector change.

```bash
kubectl config current-context
kubectl get nodes -o wide
kubectl get namespace myk8s
kubectl get ingressclass cilium
kubectl get pods -n kube-system -l k8s-app=cilium -o wide

LAB=06-ingress-external-access/manifests
kubectl get deploy,svc,ingress,pod,cm -n myk8s | grep lesson06
```

Confirm the context points to your lab, the Nodes and Cilium agents are Ready, and the namespace is Active. An empty result from the last command is expected on a fresh run. If you already have Lesson 06 resources from an earlier run, inspect them before applying the manifests. Ingress stages C–E update the same Ingress in order.

## 06A — Reach both applications through ClusterIP

```bash
kubectl apply -f "$LAB/backends.yaml" -f "$LAB/curl-client.yaml"
kubectl rollout status deployment/lesson06-web -n myk8s --timeout=180s
kubectl rollout status deployment/lesson06-api -n myk8s --timeout=180s
kubectl wait --for=condition=Ready pod/lesson06-client -n myk8s --timeout=120s

kubectl get svc lesson06-web lesson06-api -n myk8s
kubectl get endpointslice -n myk8s \
  -l 'kubernetes.io/service-name in (lesson06-web,lesson06-api)' -o wide

pod_http() {
  kubectl exec -n myk8s lesson06-client -- \
    curl -sS --max-time 5 -w '\nHTTP %{http_code}\n' "$1"
}

pod_http http://lesson06-web/
pod_http http://lesson06-api:5678/
```

Expect two web endpoints and one API endpoint after both rollouts settle. The client Pod resolves each short Service name in its own namespace. Expect `Hello from Lesson 06 Web` and `Hello from Lesson 06 API`, respectively, each with HTTP 200. The API call uses Service port 5678.

## 06B — Reach the web app through NodePort

```bash
kubectl apply -f "$LAB/service-web-nodeport.yaml"
kubectl get svc lesson06-web-nodeport -n myk8s

NODE=kind-worker
NODE_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$NODE")
WEB_PORT=$(kubectl get svc lesson06-web-nodeport -n myk8s \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
printf 'Node IP %s, web NodePort %s\n' "$NODE_IP" "$WEB_PORT"

curl -sS --max-time 5 -w '\nHTTP %{http_code}\n' "http://${NODE_IP}:${WEB_PORT}/"
```

Use your actual worker name if it differs. Confirm both printed values are populated before sending the request. Expect the web body and HTTP 200 from the Ubuntu host. This second Service selects the same web Pods and Kubernetes allocates its NodePort. The kind node IP is on the Docker bridge. If you access the lab over SSH, run the request in the SSH session on Ubuntu.

## 06C — Reach the web app through Cilium Ingress

```bash
kubectl apply -f "$LAB/ingress-web.yaml"
kubectl describe ingress lesson06-web -n myk8s
kubectl get svc -n myk8s
```

Wait for Cilium's dedicated Ingress Service, normally `cilium-ingress-lesson06-web`, to appear as `NodePort`. If your version uses a different name, find the generated Service for this Ingress with `kubectl get svc -n myk8s -o yaml` and substitute its name below. Read the NodePort for Service port **80**.

```bash
INGRESS_SVC=cilium-ingress-lesson06-web
INGRESS_PORT=$(kubectl get svc "$INGRESS_SVC" -n myk8s \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
printf 'Ingress HTTP NodePort %s\n' "$INGRESS_PORT"

ingress_http() {
  curl -sS --max-time 5 -w '\nHTTP %{http_code}\n' \
    -H "Host: $1" "http://${NODE_IP}:${INGRESS_PORT}$2"
}

ingress_http app.myk8s.local /
```

Expect the web body and HTTP 200. If the Service has just appeared, give reconciliation a few seconds and retry. The NodePort from 06B reaches the web Pods directly through Service forwarding. This NodePort reaches Envoy, which evaluates the Ingress rule for `app.myk8s.local`.

## 06D — Route by hostname

```bash
kubectl apply -f "$LAB/ingress-hosts.yaml"
ingress_http app.myk8s.local /
ingress_http api.myk8s.local /
ingress_http unmatched.myk8s.local /
```

Use the same node IP, port, and path for all three requests. The `Host` header selects the rule. Expect the web body for `app.myk8s.local` and the API body for `api.myk8s.local`, each with HTTP 200. An unmatched host normally returns HTTP 404 on this dedicated listener. Retry briefly after applying if the new route has yet to converge. The explicit HTTP header requires no change to DNS or `/etc/hosts`.

## 06E — Route by path

```bash
kubectl apply -f "$LAB/ingress-paths.yaml"
ingress_http app.myk8s.local /
ingress_http app.myk8s.local /api
ingress_http app.myk8s.local /api/health
ingress_http api.myk8s.local /
```

Expect the web body for the first request and the API body for the other three, all with HTTP 200. On `app.myk8s.local`, the more specific `/api` prefix takes precedence over `/`. The echo server responds to the forwarded path, so this setup needs no rewrite. The API hostname still reaches the API through its own rule.

## 06F — Break the API Service selector and recover

Start with both the direct API request from the client Pod and the Ingress API request returning 200. The only intentional change is to the selector of `myk8s/lesson06-api`. Keep the restore command available in case you stop before finishing.

```bash
pod_http http://lesson06-api:5678/
ingress_http app.myk8s.local /api

restore_api_selector() {
  kubectl patch svc lesson06-api -n myk8s --type merge \
    -p '{"spec":{"selector":{"app":"lesson06-api"}}}'
}

kubectl patch svc lesson06-api -n myk8s --type merge \
  -p '{"spec":{"selector":{"app":"lesson06-api-broken"}}}'
kubectl get pods -n myk8s -l app=lesson06-api -o wide
kubectl get endpointslice -n myk8s \
  -l kubernetes.io/service-name=lesson06-api -o wide
```

Wait until there are no API endpoints and confirm the API Pod is still Ready. Repeat the EndpointSlice command if the previous backend is still visible immediately after the patch.

```bash
pod_http http://lesson06-api:5678/
ingress_http app.myk8s.local /api
ingress_http app.myk8s.local /
```

Expect direct API access to fail at the connection layer. Curl's `HTTP 000` indicates that it received no HTTP response. Once the proxy converges on an empty upstream, expect the Ingress API request to fail as well, commonly with HTTP 503. The web route should still return 200. The reference run instead continued returning the API body and HTTP 200 through Ingress. See the [observed results](README.md#reference-run-selector-break) for the evidence and its limits.

### Compare Cilium Service state and Envoy endpoints

Run this inspection while the selector is broken if Ingress still serves the API. It also works as a before-and-after comparison. It requires permission to exec in the Cilium agent Pods.

```bash
API_CLUSTER_IP=$(kubectl get svc lesson06-api -n myk8s -o jsonpath='{.spec.clusterIP}')
printf 'Look for %s:5678 in each Cilium Service table\n' "$API_CLUSTER_IP"
kubectl get ciliumenvoyconfigs -n myk8s

for agent in $(kubectl get pods -n kube-system -l k8s-app=cilium -o name); do
  printf '\n%s\n' "$agent"
  kubectl exec -n kube-system "$agent" -c cilium-agent -- cilium-dbg service list
  dump=$(kubectl exec -n kube-system "$agent" -c cilium-agent -- \
    cilium-dbg envoy admin config endpoints) || continue
  jq -r '
    .configs[]?
    | select(.endpoint_config.cluster_name == "myk8s/lesson06-api:5678")
    | .endpoint_config.endpoints[]?.lb_endpoints[]?
    | .endpoint.address.socket_address
    | "\(.address):\(.port_value)"
  ' <<< "$dump"
done
```

In the Service table, read the API ClusterIP row and any indented backend rows beneath it. The filtered Envoy output shows addresses from the runtime EDS dump. An empty filter result can also mean that the EDS name or output format differs in your version. Check the unfiltered dump for the API cluster when in doubt.

### Restore and validate both paths

```bash
restore_api_selector
kubectl get svc lesson06-api -n myk8s -o jsonpath='{.spec.selector}{"\n"}'
kubectl get endpointslice -n myk8s \
  -l kubernetes.io/service-name=lesson06-api -o wide

pod_http http://lesson06-api:5678/
ingress_http app.myk8s.local /api
ingress_http app.myk8s.local /
```

Repeat the EndpointSlice check until the current API Pod address appears on port 5678. Then confirm HTTP 200 and the expected body for both API requests and the web control request. If a diagnostic Pod from a previous session has completed, use the `lesson06-client` Pod from 06A. If that Pod is absent, apply its manifest and wait for Ready again.

## Troubleshooting

| Symptom | Check |
|---|---|
| Client name lookup fails | Check the client's namespace, the Service name and whether CoreDNS is healthy. |
| Direct Service call fails | Compare the selector with Pod labels and readiness, then inspect every EndpointSlice for that Service. |
| Both NodePort calls time out | Verify the kind node IP from the Ubuntu host, then check the allocated NodePorts and Cilium agent readiness. |
| Ingress NodePort Service is missing | Check the IngressClass, dedicated-mode annotations, and Ingress events with `kubectl describe ingress lesson06-web -n myk8s`. |
| Ingress returns 404 for a known route | Verify the exact `Host` header and path, then inspect the applied rules. |
| Ingress serves an apparently removed backend | Record EndpointSlices, Cilium Service state, Envoy EDS, and the HTTP result before restoring the selector. |

## Cleanup and next lesson

You can keep the restored web/API stack for later networking exercises. To remove the lab, delete only the resources named in its manifests. The final Ingress manifest identifies the same object used in 06C–E.

```bash
kubectl delete -f "$LAB/ingress-paths.yaml" --ignore-not-found
kubectl delete -f "$LAB/service-web-nodeport.yaml" \
  -f "$LAB/curl-client.yaml" -f "$LAB/backends.yaml" --ignore-not-found
kubectl get deploy,svc,ingress,pod,cm -n myk8s | grep lesson06
```

After cleanup, expect no resources from these manifests. Give Cilium a moment to remove its generated Ingress resources. The required end state is a working cluster and an active `myk8s` namespace, with the API selector restored if you kept the stack. [Next lesson in the learning path](../README.md#learning-path).
