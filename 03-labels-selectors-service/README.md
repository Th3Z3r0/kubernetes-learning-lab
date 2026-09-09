# Lesson 03 — Labels, Selectors, Service, EndpointSlice, and Kubernetes DNS

## Objective

Understand how Kubernetes provides stable network access to dynamic Pods using:

- Labels
- Selectors
- Service
- ClusterIP
- EndpointSlice
- CoreDNS
- Cilium Service dataplane
- Same-namespace and cross-namespace DNS
- Basic Service troubleshooting
- Distribution of connections across multiple backend Pods

The key problem is:

> Pods are disposable. Their names, IP addresses, and Nodes can change. How can applications reliably reach them?

---

## 1. Pods Are Dynamic

A Deployment-managed Pod may be deleted and recreated with a new name, IP, or Node.

Therefore applications should not normally depend directly on Pod IPs.

```text
Dynamic Pods
    ↓
Stable Service
```

---

## 2. Labels and Selectors

The web workload uses:

```text
app=web
```

A selector such as:

```text
app=web
```

means:

> Find objects whose labels match `app=web`.

Relationship:

```text
Service selector
   app=web
      ↓
Matching Pods
```

The Deployment also uses a selector to manage its Pods.

---

## 3. ClusterIP Service

The lab Service is:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-service
  namespace: myk8s
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

A ClusterIP is a stable virtual IP used to reach the Service inside the cluster.

```text
Client
  ↓
web-service
  ↓
ClusterIP:80
  ↓
backend Pod:80
```

`port` is the port exposed by the Service.

`targetPort` is the destination application port on the backend Pod.

---

## 4. Service → Selector → EndpointSlice → Pod

The Service does not store fixed Pod IPs in its manifest.

Instead:

```text
Service
   ↓ selector
Pod labels
   ↓
EndpointSlice
   ↓
current Pod IPs
```

EndpointSlice is a Kubernetes control-plane object describing current Service endpoints.

Packets do not literally travel through an EndpointSlice object.

---

## 5. Control Plane vs Data Plane

Keep these two ideas separate.

### Control-plane information

```text
Service
   +
EndpointSlice
```

These describe the desired Service and current backends.

### Dataplane implementation

In the reference lab:

```text
Client packet
   ↓
Service ClusterIP
   ↓
Cilium eBPF Service dataplane
   ↓
selected Pod backend
```

The reference cluster deliberately has no kube-proxy:

```text
kube-proxy                absent
Cilium KubeProxyReplacement=True
```

Inspect Cilium with:

```bash
kubectl exec -n kube-system ds/cilium \
  -c cilium-agent -- \
  cilium-dbg status
```

Inspect the Service dataplane with:

```bash
kubectl exec -n kube-system ds/cilium \
  -c cilium-agent -- \
  cilium-dbg service list
```

A Service entry should map a ClusterIP frontend to active Pod backends.

---

## 6. Kubernetes DNS

CoreDNS provides Service-name resolution.

Within the same namespace:

```text
web-service
   ↓
CoreDNS
   ↓
Service ClusterIP
```

The fully qualified Service DNS name is:

```text
web-service.myk8s.svc.cluster.local
```

Useful distinction:

```text
curl http://web-service
→ DNS + Service networking

curl http://<ClusterIP>
→ Service networking without DNS
```

If the ClusterIP works but the Service name does not, DNS becomes a likely troubleshooting area.

---

## 7. Cross-Namespace DNS

A short Service name is normally resolved relative to the client's namespace.

From another namespace, use:

```text
web-service.myk8s
```

or:

```text
web-service.myk8s.svc.cluster.local
```

Mental model:

```text
same namespace
web-service

other namespace
web-service.myk8s
```

---

## 8. Broken Selector Experiment

If the Service selector is changed from:

```text
app=web
```

to:

```text
app=broken
```

then the Service object and ClusterIP still exist, but no Pods match.

```text
Service exists
     ↓
selector matches nothing
     ↓
EndpointSlice has no usable backend
     ↓
traffic fails
```

Important lesson:

> Service exists does not mean Service has working backends.

---

## 9. Service Troubleshooting Flow

Use this order:

```text
Application cannot connect
       ↓
Does Service exist?
       ↓
Check Service selector
       ↓
Does selector match Pod labels?
       ↓
Check EndpointSlice
       ↓
Are backend Pod IPs present?
       ↓
Check Cilium Service dataplane
       ↓
Check Pod readiness/application
```

Useful commands:

```bash
kubectl get svc web-service -n myk8s
kubectl describe svc web-service -n myk8s
kubectl get pods -n myk8s -l app=web --show-labels
kubectl get endpointslice -n myk8s \
  -l kubernetes.io/service-name=web-service -o wide
kubectl exec -n kube-system ds/cilium \
  -c cilium-agent -- cilium-dbg service list
```

---

## 10. Connection Distribution

A Service may distribute different connections across multiple backend Pods.

Do not assume strict round-robin ordering or exactly equal request counts.

The important abstraction is:

```text
Client
  ↓
one stable Service
  ↓
multiple changing Pods
```

The client does not need to know which Node hosts each Pod.

---

## 11. Final Mental Model

```text
NAME RESOLUTION

web-service
    ↓
CoreDNS
    ↓
ClusterIP
```

```text
CONTROL PLANE

Service
   ↓ selector
Pod labels
   ↓
EndpointSlice
```

```text
DATA PLANE

ClusterIP
   ↓
Cilium eBPF Service state
   ↓
Pod IP
```

Three separate functions:

```text
CoreDNS
→ name resolution

Cilium Service dataplane
→ Service IP / NodePort to backend

Cilium CNI
→ Pod networking
```

---

## Hands-on Lab

Follow the reproducible procedure in [LAB.md](LAB.md).

---

## Next Lesson

[Lesson 04 — ConfigMap and Secret](../04-configmap-secret/README.md)
