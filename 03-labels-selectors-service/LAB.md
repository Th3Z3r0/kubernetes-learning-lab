# Lesson 03 Hands-on Lab — Labels, Selectors, Service, EndpointSlice, and Kubernetes DNS

Run commands from the repository root.

## Goal

Expose the `web` Deployment with a ClusterIP Service, inspect EndpointSlice backends, test Service traffic and DNS, intentionally break the selector, observe failure, restore it, and test cross-namespace discovery.

## Prerequisite and starting state

Lesson 02 should leave `web` running with three replicas.

Verify:

```bash
kubectl get deployment web -n myk8s
kubectl get pods -n myk8s -l app=web
```

### Expected result

```text
Deployment READY: 3/3
3 Pods: Running
```

If needed, restore the expected state:

```bash
kubectl apply -f 02-deployment-replicaset/manifests/deployment-web.yaml
kubectl scale deployment web --replicas=3 -n myk8s
kubectl rollout status deployment/web -n myk8s
```

## Step 1 — Inspect labels and selectors

```bash
kubectl get pods -n myk8s -l app=web --show-labels
kubectl get deployment web -n myk8s -o jsonpath='{.spec.selector.matchLabels}{"\n"}'
```

### Expected result

All web Pods should include `app=web`. The Deployment selector should include:

```text
{"app":"web"}
```

## Step 2 — Create the Service

```bash
kubectl apply -f 03-labels-selectors-service/manifests/service-web.yaml
kubectl get svc web-service -n myk8s -o wide
```

### Expected result

The Service should be `ClusterIP`, expose port `80/TCP`, and use selector `app=web`.

The ClusterIP is assigned by Kubernetes and may differ from the value captured in the theory notes.

Save it for later tests:

```bash
SVC_IP=$(kubectl get svc web-service -n myk8s -o jsonpath='{.spec.clusterIP}')
echo "$SVC_IP"
```

## Step 3 — Inspect EndpointSlice backends

```bash
kubectl get endpointslice \
  -n myk8s \
  -l kubernetes.io/service-name=web-service \
  -o wide

kubectl get pods -n myk8s -l app=web -o wide
```

### Expected result

The EndpointSlice should list backend IPs matching the current web Pod IPs.

The exact EndpointSlice name and Pod IPs can differ.

## Step 4 — Create a reusable curl client

```bash
kubectl delete pod curl-client -n myk8s --ignore-not-found
kubectl apply -f 03-labels-selectors-service/manifests/curl-client.yaml
kubectl wait --for=condition=Ready pod/curl-client -n myk8s --timeout=120s
```

### Expected result

`curl-client` should become `Running` and `Ready`.

## Step 5 — Test Service name and ClusterIP

```bash
kubectl exec -n myk8s curl-client -- curl -sS http://web-service | head
kubectl exec -n myk8s curl-client -- curl -sS "http://$SVC_IP" | head
```

### Expected result

Both commands should return nginx HTML. This proves:

```text
Service name → DNS + Service networking
ClusterIP    → Service networking without DNS
```

## Step 6 — Inspect DNS

```bash
kubectl exec -n myk8s curl-client -- nslookup web-service
kubectl exec -n myk8s curl-client -- cat /etc/resolv.conf
```

### Expected result

`web-service` should resolve to the Service ClusterIP. The resolver configuration should include the cluster DNS server and search domains such as:

```text
myk8s.svc.cluster.local
svc.cluster.local
cluster.local
```

Exact DNS Service IP can differ.

## Step 7 — Break the Service selector

```bash
kubectl patch svc web-service -n myk8s \
  -p '{"spec":{"selector":{"app":"broken"}}}'
```

Inspect:

```bash
kubectl describe svc web-service -n myk8s
kubectl get endpointslice \
  -n myk8s \
  -l kubernetes.io/service-name=web-service \
  -o wide
```

### Expected result

The Service still exists and keeps its ClusterIP, but it should have no usable backend endpoints.

Test traffic:

```bash
kubectl exec -n myk8s curl-client -- \
  curl --connect-timeout 3 -sS http://web-service
```

### Expected result

The request should fail because the Service has no matching backend Pods.

This proves:

```text
Service exists ≠ Service has backends
```

## Step 8 — Restore the selector

```bash
kubectl patch svc web-service -n myk8s \
  -p '{"spec":{"selector":{"app":"web"}}}'
```

Verify:

```bash
kubectl get endpointslice \
  -n myk8s \
  -l kubernetes.io/service-name=web-service \
  -o wide

kubectl exec -n myk8s curl-client -- curl -sS http://web-service | head
```

### Expected result

Backend IPs should return and nginx should be reachable again.

## Step 9 — Observe kube-proxy

```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
```

### Expected result

In the reference kind cluster, one kube-proxy Pod should run on each node.

This is an observation of the Service dataplane implementation used by this cluster; other Kubernetes environments may implement Service networking differently.

## Step 10 — Prove requests can reach different backend Pods

Change each nginx Pod's page to its own hostname:

```bash
for POD in $(kubectl get pods -n myk8s -l app=web -o name); do
  kubectl exec -n myk8s "$POD" -- sh -c \
    'echo "Response from: $(hostname)" > /usr/share/nginx/html/index.html'
done
```

Send repeated requests:

```bash
for i in $(seq 1 20); do
  kubectl exec -n myk8s curl-client -- curl -s http://web-service
  echo
done
```

### Expected result

You should normally see responses from more than one Pod name. Do not expect strict round-robin order or equal counts.

## Step 11 — Restore normal nginx content

The direct edits above are intentionally temporary. Delete the Pods so the ReplicaSet recreates clean Pods from the Deployment template:

```bash
kubectl delete pod -n myk8s -l app=web
kubectl wait --for=condition=Ready pod -l app=web -n myk8s --timeout=120s
kubectl get pods -n myk8s -l app=web
```

### Expected result

Three new Running Pods should appear.

## Step 12 — Cross-namespace Service discovery

Create a second namespace and test Pod:

```bash
kubectl create namespace test-client --dry-run=client -o yaml | kubectl apply -f -
kubectl run dns-client \
  --image=curlimages/curl:latest \
  --restart=Never \
  -n test-client \
  --command -- sh -c 'sleep 3600'

kubectl wait --for=condition=Ready pod/dns-client -n test-client --timeout=120s
```

Short same-name lookup from the other namespace:

```bash
kubectl exec -n test-client dns-client -- \
  curl --connect-timeout 3 -sS http://web-service
```

### Expected result

This should fail because `web-service` is searched relative to `test-client`.

Now use the Service plus namespace:

```bash
kubectl exec -n test-client dns-client -- \
  curl -sS http://web-service.myk8s | head
```

And the full Service DNS name:

```bash
kubectl exec -n test-client dns-client -- \
  curl -sS http://web-service.myk8s.svc.cluster.local | head
```

### Expected result

Both should return nginx HTML.

Inspect resolver configuration:

```bash
kubectl exec -n test-client dns-client -- cat /etc/resolv.conf
```

Note: diagnostic utilities such as `nslookup` can handle search-domain expansion differently from applications. Test the actual application path as well as DNS tools.

## Cleanup

Remove temporary clients and namespace:

```bash
kubectl delete pod curl-client -n myk8s --ignore-not-found
kubectl delete namespace test-client --ignore-not-found
```

Keep `web` Deployment and `web-service`; Lesson 04 uses them.

## End-state checklist

```text
Deployment/web: 3 Running Pods
Service/web-service: ClusterIP, selector app=web
EndpointSlice: current Pod backends
```

You should be able to troubleshoot in this order:

```text
Service
  ↓
Selector
  ↓
Pod labels
  ↓
EndpointSlice
  ↓
Pod readiness/application
```

Continue with [Lesson 04 Hands-on Lab](../04-configmap-secret/LAB.md).
