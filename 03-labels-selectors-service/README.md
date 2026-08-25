# Lesson 03 — Labels, Selectors, Service, EndpointSlice, and Kubernetes DNS

## Objective

Understand how Kubernetes provides stable network access to dynamic Pods using:

* Labels
* Selectors
* Service
* ClusterIP
* EndpointSlice
* CoreDNS
* kube-proxy / Service dataplane
* Same-namespace and cross-namespace DNS
* Basic Service troubleshooting
* Distribution of connections across multiple backend Pods

The key problem in this lesson is:

> Pods are disposable. Their names, IP addresses, and Nodes can change. How can applications reliably reach them?

---

# 1. The Problem: Pods Are Dynamic

From Lesson 02, Pods managed by a Deployment can be deleted and automatically recreated.

When recreated, a Pod may get:

* A new name
* A new Pod IP
* A different Node

Example:

```text
Old Pod
web-799996dd5c-rkl9s
IP: 10.10.0.242
Node: kind-worker2

Deleted
   ↓

New Pod
web-799996dd5c-qx8zd
IP: 10.10.2.176
Node: kind-worker
```

Therefore, applications should not normally connect directly to Pod IPs.

Instead, Kubernetes provides a stable abstraction:

```text
Client
  ↓
Service
  ↓
Pods
```

---

# 2. Labels

Labels are key/value metadata attached to Kubernetes objects.

Our web Pods use:

```text
app=web
```

Check labels:

```bash
kubectl get pods -n myk8s -l app=web --show-labels
```

Example:

```text
web-799996dd5c-qx8zd   app=web,pod-template-hash=799996dd5c
web-799996dd5c-rvq9v   app=web,pod-template-hash=799996dd5c
web-799996dd5c-v6bcm   app=web,pod-template-hash=799996dd5c
```

Mental model:

```text
Pod
├── name: web-799996dd5c-qx8zd
└── labels:
    ├── app=web
    └── pod-template-hash=799996dd5c
```

Important lesson:

> Labels give Kubernetes a logical way to group objects without depending on object names or IP addresses.

---

# 3. Selectors

Selectors find Kubernetes objects that have matching labels.

Example:

```bash
kubectl get pods -n myk8s -l app=web
```

Here:

```text
-l app=web
```

means:

> Find Pods whose label matches `app=web`.

Relationship:

```text
Selector
app=web
   │
   ▼
Matching Pods
   │
   ├── Pod A
   ├── Pod B
   └── Pod C
```

If I use a selector that does not match any Pods:

```bash
kubectl get pods -n myk8s -l app=does-not-exist
```

Kubernetes returns no matching Pods.

Nothing is broken. The selector simply does not match anything.

---

# 4. Deployment Selector

Our Deployment also uses:

```yaml
selector:
  matchLabels:
    app: web
```

Check:

```bash
kubectl get deployment web -n myk8s \
  -o jsonpath='{.spec.selector.matchLabels}{"\n"}'
```

Expected:

```text
{"app":"web"}
```

The Deployment's Pod template also applies:

```yaml
metadata:
  labels:
    app: web
```

So:

```text
Deployment
selector: app=web
        │
        ▼
Pods
label: app=web
```

Labels and selectors are a fundamental Kubernetes relationship.

---

# 5. Creating the Service

A Service was created for the Deployment:

```bash
kubectl expose deployment web \
  --name=web-service \
  --port=80 \
  --target-port=80 \
  -n myk8s
```

Check it:

```bash
kubectl get svc web-service -n myk8s -o wide
```

Observed:

```text
NAME          TYPE        CLUSTER-IP    PORT(S)   SELECTOR
web-service   ClusterIP   10.11.80.51   80/TCP    app=web
```

The important values are:

```text
Type:       ClusterIP
ClusterIP:  10.11.80.51
Port:       80
Selector:   app=web
```

---

# 6. Service Manifest

A minimal declarative Service manifest is:

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

Save this as:

```text
manifests/service-web.yaml
```

Apply it with:

```bash
kubectl apply -f manifests/service-web.yaml
```

---

# 7. What Is a ClusterIP?

A ClusterIP is a stable virtual IP for a Service inside the Kubernetes cluster.

Our Service has:

```text
10.11.80.51
```

while its backend Pods have different Pod IPs:

```text
10.10.0.191
10.10.2.186
10.10.2.176
```

Relationship:

```text
web-service
10.11.80.51
     │
     ├── 10.10.0.191
     ├── 10.10.2.186
     └── 10.10.2.176
```

Important concept:

```text
Dynamic Pod IPs
      ↓
Stable Service IP
```

The Service remains stable while Pods can be replaced underneath it.

---

# 8. Service Selector

The Service contains:

```yaml
selector:
  app: web
```

The Pods contain:

```yaml
labels:
  app: web
```

Therefore:

```text
Service
selector: app=web
       │
       ▼
Matching Pods
label: app=web
```

The Service does not need to know:

* Pod names
* Pod IPs in advance
* Which Node a Pod runs on

It discovers backends through labels and selectors.

---

# 9. Service Port vs TargetPort

Our Service uses:

```text
port:       80
targetPort: 80
```

Traffic flow:

```text
Client
  │
  │ TCP/80
  ▼
Service
port: 80
  │
  ▼
Pod
targetPort: 80
  │
  ▼
nginx
```

`port` is the port exposed by the Service.

`targetPort` is the port used by the application inside the destination Pod.

They do not have to be the same.

Example:

```text
Service port: 8080
        ↓
Pod targetPort: 80
```

For this lab:

```text
80 → 80
```

---

# 10. EndpointSlice

Kubernetes uses EndpointSlice objects to track actual Service backend endpoints.

Check:

```bash
kubectl get endpointslice \
  -n myk8s \
  -l kubernetes.io/service-name=web-service \
  -o wide
```

Observed:

```text
NAME                ADDRESSTYPE   PORTS   ENDPOINTS
web-service-hbt7h   IPv4          80      10.10.0.191,10.10.2.186,10.10.2.176
```

Compare with:

```bash
kubectl get pods -n myk8s -l app=web -o wide
```

Observed Pod IPs:

```text
web-799996dd5c-qx8zd   10.10.2.176
web-799996dd5c-rvq9v   10.10.2.186
web-799996dd5c-v6bcm   10.10.0.191
```

The EndpointSlice addresses exactly matched the Pod IPs.

---

# 11. Important Control-Plane Concept

A useful simplified relationship is:

```text
Service
   │
   │ selector
   ▼
Matching Pods
   │
   ▼
EndpointSlice
   │
   ├── Pod IP A
   ├── Pod IP B
   └── Pod IP C
```

However, packets do not literally travel through an EndpointSlice object.

EndpointSlice is control-plane information describing backend endpoints.

Better model:

```text
CONTROL PLANE

Service
   +
EndpointSlice
      │
      ▼
Service dataplane state
```

```text
DATA PLANE

Client packet
   ↓
Service ClusterIP
   ↓
Node networking rules
   ↓
Selected Pod IP
```

---

# 12. Testing the Service

A temporary curl client was created:

```bash
kubectl run curl-client \
  --image=curlimages/curl \
  --restart=Never \
  -it \
  --rm \
  -n myk8s \
  -- sh
```

Inside the Pod:

```sh
curl http://web-service
```

Result:

```text
Welcome to nginx!
```

This proved the basic path:

```text
Client Pod
   ↓
Service DNS name
   ↓
ClusterIP
   ↓
Backend Pod
```

---

# 13. Broken Selector Experiment

The Service selector was intentionally changed from:

```text
app=web
```

to:

```text
app=broken
```

Command:

```bash
kubectl patch svc web-service \
  -n myk8s \
  -p '{"spec":{"selector":{"app":"broken"}}}'
```

The Service still existed:

```text
ClusterIP: 10.11.80.51
```

but:

```text
Selector: app=broken
Endpoints:
```

The EndpointSlice showed:

```text
PORTS       <unset>
ENDPOINTS   <unset>
```

Curl failed:

```text
curl: (7) Failed to connect to web-service:80
```

Important lesson:

> A Service can exist and have a valid ClusterIP while having no usable backend endpoints.

---

# 14. Restoring the Selector

The correct selector was restored:

```bash
kubectl patch svc web-service \
  -n myk8s \
  -p '{"spec":{"selector":{"app":"web"}}}'
```

The endpoints returned:

```text
10.10.2.176:80
10.10.0.191:80
10.10.2.186:80
```

Curl worked again.

This proves the relationship:

```text
Service
   ↓
Selector
   ↓
Pod Labels
   ↓
EndpointSlice
   ↓
Backend Pods
```

---

# 15. Service Troubleshooting Method

When a Service is unreachable:

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
Check Pods
       ↓
Check application
```

Useful commands:

```bash
kubectl get svc web-service -n myk8s
```

```bash
kubectl describe svc web-service -n myk8s
```

```bash
kubectl get pods -n myk8s -l app=web --show-labels
```

```bash
kubectl get endpointslice \
  -n myk8s \
  -l kubernetes.io/service-name=web-service \
  -o wide
```

---

# 16. kube-proxy

The cluster has one kube-proxy Pod per Node.

Check:

```bash
kubectl get pods \
  -n kube-system \
  -l k8s-app=kube-proxy \
  -o wide
```

Observed:

```text
kube-proxy-5t8gs   kind-worker2
kube-proxy-hz54q   kind-control-plane
kube-proxy-xwm7l   kind-worker
```

Mental model:

```text
Node
└── kube-proxy
```

Simplified responsibility:

```text
kube-proxy
     │
     │ programs Service networking rules
     ▼
Node dataplane
     │
     ▼
Backend Pods
```

Important:

> kube-proxy normally does not behave like a traditional application proxy that processes every HTTP request directly.

It programs the Service dataplane.

---

# 17. Service Traffic Flow

Simplified end-to-end flow:

```text
curl-client Pod
      │
      │ curl http://web-service
      ▼
CoreDNS
      │
      │ resolves Service name
      ▼
10.11.80.51
Service ClusterIP
      │
      ▼
Service dataplane
      │
      ▼
Selected backend
      │
      ▼
Pod IP
```

Three important networking functions should be kept separate:

```text
CoreDNS
   ↓
Name resolution

Service dataplane
   ↓
Service IP → Pod endpoint

CNI / Pod network
   ↓
Pod-to-Pod connectivity
```

---

# 18. Testing DNS Separately

Inside the temporary client Pod:

```sh
nslookup web-service
```

Observed DNS server:

```text
Server: 10.11.0.10
```

Successful Service resolution:

```text
Name: web-service.myk8s.svc.cluster.local
Address: 10.11.80.51
```

So:

```text
web-service
     ↓
CoreDNS
     ↓
10.11.80.51
```

---

# 19. Testing ClusterIP Directly

Inside the client Pod:

```sh
curl http://10.11.80.51
```

This also returned nginx successfully.

This bypasses DNS.

Comparison:

```text
curl http://web-service
     ↓
DNS + Service networking
```

```text
curl http://10.11.80.51
     ↓
Service networking only
```

Useful troubleshooting rule:

```text
ClusterIP works
Service name fails

→ likely DNS issue
```

---

# 20. Pod Distribution Across Nodes

The backend Pods were distributed across two Workers.

Example:

```text
kind-worker
├── 10.10.2.176
└── 10.10.2.186

kind-worker2
└── 10.10.0.191
```

The client still used only:

```text
web-service
```

or:

```text
10.11.80.51
```

The client did not need to know which Node hosted each backend.

---

# 21. Service Connection Distribution Experiment

To identify which backend answered, each nginx Pod was modified to return its own hostname.

Example command:

```bash
for POD in $(kubectl get pods -n myk8s -l app=web -o name); do
  kubectl exec -n myk8s "$POD" -- sh -c \
    'echo "Response from: $(hostname)" > /usr/share/nginx/html/index.html'
done
```

Then 20 requests were sent:

```sh
for i in $(seq 1 20); do
  curl -s http://web-service
  echo
done
```

Responses came from all three backend Pods:

```text
Response from: web-799996dd5c-v6bcm
Response from: web-799996dd5c-qx8zd
Response from: web-799996dd5c-rvq9v
```

The sequence was not strict round robin.

Example:

```text
A
B
B
A
B
B
A
A
C
B
...
```

Important lesson:

> A Kubernetes Service can distribute connections across multiple available backend endpoints, but applications should not assume a strict round-robin sequence.

---

# 22. Kubernetes Service DNS Name

A Kubernetes Service has a DNS name in this format:

```text
<SERVICE>.<NAMESPACE>.svc.<CLUSTER-DOMAIN>
```

For this lab:

```text
web-service.myk8s.svc.cluster.local
```

Breakdown:

```text
web-service
     │
     └── Service name

myk8s
     │
     └── Namespace

svc
     │
     └── Service DNS domain

cluster.local
     │
     └── Cluster domain
```

---

# 23. Same-Namespace DNS

When the client Pod is in:

```text
myk8s
```

and the Service is also in:

```text
myk8s
```

the short name works:

```sh
curl http://web-service
```

Mental model:

```text
Client namespace = myk8s
Service namespace = myk8s

web-service
    ✓
```

---

# 24. Cross-Namespace DNS

A second namespace was created:

```bash
kubectl create namespace test-client
```

A curl Pod was started there:

```bash
kubectl run curl-client \
  --image=curlimages/curl \
  --restart=Never \
  -it \
  --rm \
  -n test-client \
  -- sh
```

From `test-client`:

```sh
nslookup web-service
```

failed because Kubernetes tried namespace-relative names such as:

```text
web-service.test-client.svc.cluster.local
```

but the actual Service is in:

```text
myk8s
```

---

# 25. Full Service DNS Name

This worked from the different namespace:

```sh
nslookup web-service.myk8s.svc.cluster.local
```

Result:

```text
Name: web-service.myk8s.svc.cluster.local
Address: 10.11.80.51
```

And:

```sh
curl http://web-service.myk8s.svc.cluster.local
```

returned:

```text
Response from: web-799996dd5c-qx8zd
```

So cross-namespace Service discovery worked correctly.

---

# 26. Short Cross-Namespace Name

This command:

```sh
curl http://web-service.myk8s
```

also worked.

The system resolver expanded the name using the Pod's DNS search configuration.

So a useful naming model is:

```text
Same namespace:

web-service
    ✓
```

```text
Different namespace:

web-service
    ✕

web-service.myk8s
    ✓

web-service.myk8s.svc.cluster.local
    ✓
```

The fully qualified name is the most explicit and unambiguous form.

---

# 27. /etc/resolv.conf

Inside the `test-client` Pod:

```sh
cat /etc/resolv.conf
```

Observed:

```text
search test-client.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.11.0.10
options ndots:5
```

Important fields:

```text
search
```

defines DNS suffixes used during name resolution.

```text
nameserver 10.11.0.10
```

points to the Kubernetes cluster DNS Service.

```text
ndots:5
```

influences whether a name is first treated as relative or sufficiently qualified.

---

# 28. Why `web-service.myk8s` Worked With curl

The name:

```text
web-service.myk8s
```

can be expanded using the search domain:

```text
svc.cluster.local
```

to:

```text
web-service.myk8s.svc.cluster.local
```

which exists.

Conceptually:

```text
web-service.myk8s
       +
svc.cluster.local
       ↓
web-service.myk8s.svc.cluster.local
       ↓
10.11.80.51
```

---

# 29. nslookup vs Application Resolver

An interesting observation:

```sh
nslookup web-service.myk8s
```

returned:

```text
NXDOMAIN
```

while:

```sh
curl http://web-service.myk8s
```

worked.

Important lesson:

> DNS diagnostic tools and application resolver behavior are not always identical.

When troubleshooting DNS, it can be useful to test:

```text
DNS tool
+
actual application
```

---

# 30. Important DNS Troubleshooting Logic

If:

```text
nslookup Service name fails
```

investigate DNS.

If:

```text
Service name fails
but direct ClusterIP works
```

the likely problem is DNS resolution.

If:

```text
Service name resolves
but curl to ClusterIP fails
```

investigate:

* Service selector
* EndpointSlice
* Pod readiness
* Service dataplane
* Network connectivity
* Application state

---

# 31. Object and Component Responsibilities

## Label

```text
Identifies or groups Kubernetes objects
```

Example:

```text
app=web
```

## Selector

```text
Finds objects with matching labels
```

## Service

```text
Provides stable access to dynamic Pods
```

## ClusterIP

```text
Stable virtual IP inside the cluster
```

## EndpointSlice

```text
Stores current backend endpoint information
```

## CoreDNS

```text
Provides Kubernetes DNS and Service discovery
```

## kube-proxy / Service Dataplane

```text
Implements or programs Service-to-backend packet steering
```

## CNI / Pod Network

```text
Provides Pod network connectivity
```

---

# 32. Mandatory Mental Model

The most important object relationship is:

```text
                 Service
               web-service
              10.11.80.51
                   │
            selector: app=web
                   │
                   ▼
              EndpointSlice
                   │
          ┌────────┼────────┐
          ▼        ▼        ▼
        Pod A    Pod B    Pod C
```

The DNS and packet path is:

```text
Application
    │
    │ web-service
    ▼
CoreDNS
    │
    ▼
Service ClusterIP
    │
    ▼
Service dataplane
    │
    ▼
Selected Pod
```

---

# 33. What I Must Remember

## Labels

```text
Label
= metadata used to identify/group objects
```

## Selectors

```text
Selector
= query used to find matching labels
```

## Service

```text
Service
= stable network frontend for dynamic Pods
```

## EndpointSlice

```text
EndpointSlice
= current backend endpoint information
```

## CoreDNS

```text
CoreDNS
= Service name resolution
```

## kube-proxy / Dataplane

```text
kube-proxy
= programs/maintains Service traffic steering
```

## Key relationship

```text
Service
selector: app=web
       │
       ▼
Pods
label: app=web
```

---

# 34. Commands Learned

## Labels

```bash
kubectl get pods -n myk8s -l app=web
```

```bash
kubectl get pods -n myk8s -l app=web --show-labels
```

---

## Service

```bash
kubectl get svc -n myk8s
```

```bash
kubectl get svc web-service -n myk8s -o wide
```

```bash
kubectl describe svc web-service -n myk8s
```

---

## EndpointSlice

```bash
kubectl get endpointslice \
  -n myk8s \
  -l kubernetes.io/service-name=web-service \
  -o wide
```

---

## kube-proxy

```bash
kubectl get pods \
  -n kube-system \
  -l k8s-app=kube-proxy \
  -o wide
```

---

## Temporary Test Pod

```bash
kubectl run curl-client \
  --image=curlimages/curl \
  --restart=Never \
  -it \
  --rm \
  -n myk8s \
  -- sh
```

---

## DNS Testing

```sh
nslookup web-service
```

```sh
nslookup web-service.myk8s.svc.cluster.local
```

```sh
cat /etc/resolv.conf
```

---

## Service Connectivity Testing

```sh
curl http://web-service
```

```sh
curl http://10.11.80.51
```

```sh
curl http://web-service.myk8s
```

```sh
curl http://web-service.myk8s.svc.cluster.local
```

---

## Break Service Selector

```bash
kubectl patch svc web-service \
  -n myk8s \
  -p '{"spec":{"selector":{"app":"broken"}}}'
```

---

## Restore Service Selector

```bash
kubectl patch svc web-service \
  -n myk8s \
  -p '{"spec":{"selector":{"app":"web"}}}'
```

---

# 35. Troubleshooting Checklist

When a Kubernetes Service is not working:

```text
1. Does the Service exist?
        ↓
2. Is the Service ClusterIP present?
        ↓
3. Is the selector correct?
        ↓
4. Do Pod labels match?
        ↓
5. Does EndpointSlice contain backend IPs?
        ↓
6. Are the Pods Ready?
        ↓
7. Can the ClusterIP be reached directly?
        ↓
8. Does DNS resolve the Service name?
        ↓
9. Is the application listening on targetPort?
```

Useful sequence:

```bash
kubectl get svc web-service -n myk8s
kubectl describe svc web-service -n myk8s
kubectl get pods -n myk8s -l app=web --show-labels
kubectl get endpointslice -n myk8s \
  -l kubernetes.io/service-name=web-service -o wide
```

---

# 36. Lesson 03 Key Takeaway

Do not think:

```text
Service knows Pod names
```

or:

```text
Service permanently points to specific Pod IPs
```

Instead think:

```text
Service
   ↓
Selector
   ↓
Matching Pod Labels
   ↓
EndpointSlice
   ↓
Current Pod Endpoints
```

Pods may change:

```text
Pod name
Pod IP
Node
```

while clients continue using:

```text
web-service
```

This allows Kubernetes to provide stable service discovery over dynamic workloads.

---

# 37. Lesson 03 Final Mental Model

```text
                     Kubernetes Cluster

Client Pod
   │
   │ curl http://web-service
   ▼
CoreDNS
10.11.0.10
   │
   │ resolves
   ▼
web-service
10.11.80.51
   │
   │ selector: app=web
   ▼
EndpointSlice
   │
   ├───────────────┬───────────────┐
   ▼               ▼               ▼
Pod A             Pod B           Pod C
10.10.0.191       10.10.2.186     10.10.2.176
   │               │               │
   └──────────── nginx ─────────────┘
```

The important concepts are:

```text
Labels
   ↓
Selectors
   ↓
Service
   ↓
EndpointSlice
   ↓
Service dataplane
   ↓
Pods
```

and:

```text
Service Name
   ↓
CoreDNS
   ↓
ClusterIP
```

---

# Next Lesson

## Lesson 04 — ConfigMap and Secret

Next problem:

> How should application configuration be provided without hardcoding everything inside the container image or Deployment manifest?

Next relationship:

```text
ConfigMap ──────┐
                │
                ▼
               Pod
                │
                ▼
            Application
                ▲
                │
Secret ─────────┘
```

Topics to learn next:

* ConfigMap
* Secret
* Environment variables
* Mounting configuration as files
* Separating configuration from container images
* Updating application configuration
* Basic Secret security considerations
