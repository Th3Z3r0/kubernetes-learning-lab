# Lesson 04 — ConfigMap and Secret

## Objective

Understand how Kubernetes separates application configuration from container images using ConfigMaps and Secrets.

This lesson covers:

- ConfigMap as mounted files
- ConfigMap as environment variables
- Secret basics and Base64 encoding
- Secret as environment variables
- Secret as mounted files
- Update behavior for mounted volumes vs environment variables
- Troubleshooting missing ConfigMaps and Secrets

---

## 1. Why ConfigMap and Secret Exist

Applications need configuration such as messages, ports, feature flags, usernames, passwords, and tokens.

Instead of hardcoding everything into a container image:

```text
Container Image
     │
     ▼
    Pod
     ▲
     │
 ┌───┴────┐
 │        │
ConfigMap Secret
```

Use:

```text
ConfigMap → non-sensitive configuration
Secret    → sensitive configuration
```

---

## 2. ConfigMap from a File

A custom nginx page was stored in a ConfigMap named `web-content`.

Example:

```bash
kubectl create configmap web-content \
  --from-file=index.html=lesson04-index.html \
  -n myk8s
```

Inspect it:

```bash
kubectl get configmap web-content -n myk8s -o yaml
```

Mental model:

```text
Local file
lesson04-index.html
        │
        ▼
ConfigMap/web-content
        │
        └── index.html
```

A ConfigMap can exist without any Pod using it.

```text
ConfigMap exists ≠ Application uses it
```

---

## 3. Mount ConfigMap into nginx

The ConfigMap was mounted into nginx at:

```text
/usr/share/nginx/html
```

Important Pod configuration:

```yaml
volumeMounts:
  - name: web-content
    mountPath: /usr/share/nginx/html

volumes:
  - name: web-content
    configMap:
      name: web-content
```

Relationship:

```text
ConfigMap/web-content
        ↓
Pod Volume
        ↓
volumeMount
        ↓
/usr/share/nginx/html
        ↓
nginx
```

Because the Deployment Pod template changed, Kubernetes created a new ReplicaSet and new Pods.

This reinforced the Lesson 02 behavior:

```text
Pod template changes
        ↓
new pod-template-hash
        ↓
new ReplicaSet
        ↓
new Pods
```

---

## 4. Verify ConfigMap Inside the Pod

The mounted file was verified with:

```bash
kubectl exec -n myk8s <pod-name> -- \
  cat /usr/share/nginx/html/index.html
```

`kubectl describe pod` showed:

```text
Mounts:
  /usr/share/nginx/html from web-content

Volumes:
  web-content:
    Type: ConfigMap
    Name: web-content
```

The existing `web-service` returned the ConfigMap-provided HTML, proving the full path:

```text
ConfigMap
   ↓
Pod Volume
   ↓
nginx
   ↓
Service
   ↓
Client
```

---

## 5. Update a Mounted ConfigMap

The `web-content` ConfigMap was edited while the nginx Pods were still running.

The Pod names did not change, but the mounted file eventually changed.

Important behavior:

```text
ConfigMap changes
        ↓
kubelet refreshes mounted volume
        ↓
same Pod can see new file contents
```

The update was not instantaneous across all replicas. During the refresh period, requests through the Service returned a mix of old and new content.

Production lesson:

> Mounted ConfigMap updates are eventually propagated. Multiple replicas may temporarily observe different configuration versions.

---

## 6. ConfigMap as Environment Variables

A second ConfigMap was created:

```bash
kubectl create configmap app-settings \
  --from-literal=APP_MESSAGE="Hello from ConfigMap environment variable" \
  -n myk8s
```

It was injected into the Deployment:

```bash
kubectl set env deployment/web \
  --from=configmap/app-settings \
  -n myk8s
```

Verify:

```bash
kubectl exec -n myk8s <pod-name> -- printenv APP_MESSAGE
```

The ConfigMap was then changed while the Pod was running.

The ConfigMap showed the new value, but the existing container still showed the old environment variable.

After:

```bash
kubectl rollout restart deployment/web -n myk8s
```

new Pods received the updated value.

Key difference:

```text
ConfigMap as mounted file
        ↓
running Pod can eventually see updates

ConfigMap as environment variable
        ↓
value is read when container starts
        ↓
Pod restart/recreation required
```

---

## 7. Kubernetes Secret

A Secret was created with two keys:

```bash
kubectl create secret generic app-secret \
  --from-literal=DB_USERNAME=<lab-user> \
  --from-literal=DB_PASSWORD=<lab-password> \
  -n myk8s
```

Inspecting with:

```bash
kubectl describe secret app-secret -n myk8s
```

showed key names and byte sizes without printing the values.

However:

```bash
kubectl get secret app-secret -n myk8s -o yaml
```

showed Base64-encoded values.

Important:

```text
Base64 ≠ encryption
Base64 ≠ hashing
Base64 ≠ secure storage by itself
```

A Kubernetes Secret is a dedicated object for sensitive data, but security still depends on controls such as RBAC and encryption at rest.

Do not commit real credentials to this repository.

---

## 8. Secret as Environment Variables

The Secret was injected into the nginx Deployment:

```bash
kubectl set env deployment/web \
  --from=secret/app-secret \
  -n myk8s
```

The container could read the values using:

```bash
kubectl exec -n myk8s <pod-name> -- printenv DB_USERNAME
kubectl exec -n myk8s <pod-name> -- printenv DB_PASSWORD
```

This proves that Secret values are available to the application when injected into the container.

---

## 9. Secret as Mounted Files

A standalone `secret-reader` Pod mounted `app-secret` at:

```text
/etc/app-secret
```

Each Secret key became a file:

```text
Secret/app-secret
│
├── DB_USERNAME
│        ↓
│   /etc/app-secret/DB_USERNAME
│
└── DB_PASSWORD
         ↓
    /etc/app-secret/DB_PASSWORD
```

The mounted files appeared as links into Kubernetes-managed data:

```text
DB_USERNAME -> ..data/DB_USERNAME
DB_PASSWORD -> ..data/DB_PASSWORD
```

When the Secret was updated, the same running Pod initially showed the old value and later showed the new value.

Important behavior:

```text
Secret mounted as volume
        ↓
can eventually refresh in same Pod

Secret as environment variable
        ↓
existing container keeps old value
```

---

## 10. Troubleshooting Missing ConfigMap

A Pod referenced a ConfigMap that did not exist.

The Pod changed from:

```text
ContainerCreating
```

to:

```text
CreateContainerConfigError
```

`kubectl describe pod` showed:

```text
Error: configmap "does-not-exist" not found
```

After the missing ConfigMap was created, the same Pod recovered automatically and became `Running`.

Relationship:

```text
Pod desired state exists
        ↓
ConfigMap dependency missing
        ↓
CreateContainerConfigError
        ↓
ConfigMap created
        ↓
kubelet retries
        ↓
Pod starts
```

---

## 11. Troubleshooting Missing Secret

The same experiment was repeated with a missing Secret.

The Pod showed:

```text
CreateContainerConfigError
```

and Events showed:

```text
Error: secret "missing-secret" not found
```

After creating the Secret, the same Pod automatically recovered and became `Running`.

Useful troubleshooting rule:

```text
CreateContainerConfigError
        ↓
kubectl describe pod
        ↓
check Events
        ↓
look for missing ConfigMap, Secret, key, or other container configuration dependency
```

---

## 12. ConfigMap vs Secret Summary

| Capability | ConfigMap | Secret |
|---|---|---|
| Intended data | Non-sensitive | Sensitive |
| Can be environment variable | Yes | Yes |
| Can be mounted as files | Yes | Yes |
| Mounted files can refresh | Yes, eventually | Yes, eventually |
| Env vars refresh in running container | No | No |
| Values Base64 encoded in YAML | Normally no | Yes |
| Automatically encrypted simply because of object type | No | No |

---

## 13. Troubleshooting Mental Model

```text
Pod does not start
      ↓
kubectl get pod
      ↓
CreateContainerConfigError?
      ↓
kubectl describe pod
      ↓
Events
      ↓
Check ConfigMap / Secret
      ↓
Check object name
      ↓
Check key name
      ↓
Fix dependency
      ↓
kubelet retries
```

Compare with Lesson 01:

```text
ImagePullBackOff
→ image retrieval problem

CreateContainerConfigError
→ container configuration problem
```

---

## 14. Commands Learned

```bash
kubectl create configmap <name> --from-file=<key>=<file> -n myk8s
kubectl create configmap <name> --from-literal=<key>=<value> -n myk8s
kubectl get configmap <name> -n myk8s -o yaml
kubectl edit configmap <name> -n myk8s
kubectl set env deployment/web --from=configmap/<name> -n myk8s

kubectl create secret generic <name> --from-literal=<key>=<value> -n myk8s
kubectl get secret <name> -n myk8s -o yaml
kubectl describe secret <name> -n myk8s
kubectl set env deployment/web --from=secret/<name> -n myk8s

kubectl exec -n myk8s <pod> -- printenv <variable>
kubectl exec -n myk8s <pod> -- cat <mounted-file>
kubectl describe pod <pod> -n myk8s
kubectl rollout restart deployment/web -n myk8s
```

---

## 15. Key Takeaways

```text
ConfigMap
  ↓
non-sensitive application configuration

Secret
  ↓
sensitive application configuration
```

Both can be consumed as:

```text
Environment Variables
or
Mounted Files
```

But update behavior differs:

```text
Mounted file
→ can eventually refresh in existing Pod

Environment variable
→ requires container/Pod restart to receive new value
```

Most important troubleshooting lesson:

```text
CreateContainerConfigError
        ↓
inspect Pod Events
        ↓
check configuration dependencies
```

---

# Next Lesson

## Lesson 05 — Storage: Volume, PersistentVolume, and PersistentVolumeClaim

Next question:

> ConfigMap and Secret volumes provide configuration, but what happens when an application needs data that must survive Pod recreation?

Next relationship:

```text
Pod
 ↓
PVC
 ↓
PV
 ↓
Persistent Storage
```
