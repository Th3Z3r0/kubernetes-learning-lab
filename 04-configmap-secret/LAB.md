# Lesson 04 Hands-on Lab — ConfigMap and Secret

Run commands from the repository root.

## Goal

Use ConfigMaps and Secrets as mounted files and environment variables, observe update behavior, and troubleshoot missing configuration dependencies.

## Prerequisite and starting state

Lesson 03 should leave the `web` Deployment and `web-service` available.

Verify:

```bash
kubectl get deployment web -n myk8s
kubectl get svc web-service -n myk8s
kubectl get pods -n myk8s -l app=web
```

### Expected result

`web` should have three Running Pods and `web-service` should exist.

If needed, restore them:

```bash
kubectl apply -f 02-deployment-replicaset/manifests/deployment-web.yaml
kubectl scale deployment web --replicas=3 -n myk8s
kubectl apply -f 03-labels-selectors-service/manifests/service-web.yaml
kubectl rollout status deployment/web -n myk8s
```

## Step 1 — Create a ConfigMap containing nginx web content

```bash
kubectl apply -f 04-configmap-secret/manifests/configmap-web-content.yaml
kubectl get configmap web-content -n myk8s -o yaml
```

### Expected result

The ConfigMap should contain one key named `index.html` with the Lesson 04 HTML content.

Important:

```text
ConfigMap exists ≠ application uses it
```

## Step 2 — Mount the ConfigMap into nginx

```bash
kubectl apply -f 04-configmap-secret/manifests/deployment-web-configmap.yaml
kubectl rollout status deployment/web -n myk8s
kubectl get pods -n myk8s -l app=web
```

### Expected result

The Deployment should roll out successfully with three new Running Pods. A new ReplicaSet should normally appear because the Pod template changed.

Inspect one Pod:

```bash
POD=$(kubectl get pods -n myk8s -l app=web -o jsonpath='{.items[0].metadata.name}')
echo "$POD"
kubectl describe pod "$POD" -n myk8s
```

Confirm the Pod shows a ConfigMap-backed volume mounted at:

```text
/usr/share/nginx/html
```

Read the file:

```bash
kubectl exec -n myk8s "$POD" -- cat /usr/share/nginx/html/index.html
```

### Expected result

The output should contain:

```text
Kubernetes Lesson 04
This page is loaded from a ConfigMap.
```

## Step 3 — Test ConfigMap content through the Service

Create a temporary curl client:

```bash
kubectl delete pod curl-client -n myk8s --ignore-not-found
kubectl run curl-client \
  --image=curlimages/curl:latest \
  --restart=Never \
  -n myk8s \
  --command -- sh -c 'sleep 3600'

kubectl wait --for=condition=Ready pod/curl-client -n myk8s --timeout=120s
```

Test:

```bash
kubectl exec -n myk8s curl-client -- curl -sS http://web-service
```

### Expected result

The Service should return the Lesson 04 HTML from the ConfigMap.

## Step 4 — Update a mounted ConfigMap without recreating Pods

Record current Pod names:

```bash
kubectl get pods -n myk8s -l app=web
```

Patch the page:

```bash
kubectl patch configmap web-content -n myk8s --type merge \
  -p '{"data":{"index.html":"<h1>Kubernetes Lesson 04</h1>\n<p>ConfigMap updated without recreating the Pod!</p>\n"}}'
```

Verify the ConfigMap object changed:

```bash
kubectl get configmap web-content -n myk8s -o yaml
```

Check all Pods repeatedly:

```bash
for POD in $(kubectl get pods -n myk8s -l app=web -o name); do
  echo "=== $POD ==="
  kubectl exec -n myk8s "$POD" -- cat /usr/share/nginx/html/index.html
done
```

### Expected result

The same Pod names remain, but mounted files eventually show the new text. Refresh is asynchronous, so replicas may temporarily show different versions.

Test several Service requests:

```bash
for i in $(seq 1 10); do
  kubectl exec -n myk8s curl-client -- curl -s http://web-service
  echo
done
```

### Expected result

During propagation you may see a temporary mix of old and new content. Eventually all responses should use the updated content.

## Step 5 — ConfigMap as environment variable

Reset/create the application settings ConfigMap:

```bash
kubectl apply -f 04-configmap-secret/manifests/configmap-app-settings.yaml
kubectl set env deployment/web --from=configmap/app-settings -n myk8s
kubectl rollout status deployment/web -n myk8s
```

Capture a current Pod and read the variable:

```bash
POD=$(kubectl get pods -n myk8s -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n myk8s "$POD" -- printenv APP_MESSAGE
```

### Expected result

```text
Hello from ConfigMap environment variable
```

Patch the ConfigMap:

```bash
kubectl patch configmap app-settings -n myk8s --type merge \
  -p '{"data":{"APP_MESSAGE":"ConfigMap environment variable UPDATED"}}'
```

Check the same Pod again:

```bash
kubectl exec -n myk8s "$POD" -- printenv APP_MESSAGE
```

### Expected result

The existing Pod should still show the old value.

Restart the Deployment:

```bash
kubectl rollout restart deployment/web -n myk8s
kubectl rollout status deployment/web -n myk8s
POD=$(kubectl get pods -n myk8s -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n myk8s "$POD" -- printenv APP_MESSAGE
```

### Expected result

The new Pod should show:

```text
ConfigMap environment variable UPDATED
```

What this proves:

```text
Mounted ConfigMap file → eventually refreshes in same Pod
ConfigMap env variable  → requires container/Pod recreation
```

## Step 6 — Create and inspect a Secret

Apply the safe example Secret:

```bash
kubectl apply -f 04-configmap-secret/manifests/secret-app-example.yaml
kubectl get secret app-secret -n myk8s
kubectl describe secret app-secret -n myk8s
kubectl get secret app-secret -n myk8s -o yaml
```

### Expected result

The Secret type should be `Opaque` with two data keys. `describe` shows key sizes but not values. YAML shows Base64-encoded data.

Decode the example username:

```bash
kubectl get secret app-secret -n myk8s \
  -o jsonpath='{.data.DB_USERNAME}' | base64 -d
echo
```

### Expected result

```text
demo-user
```

Important:

```text
Base64 ≠ encryption
```

The manifest contains only lab/example credentials. Never commit real credentials.

## Step 7 — Secret as environment variables

```bash
kubectl set env deployment/web --from=secret/app-secret -n myk8s
kubectl rollout status deployment/web -n myk8s
POD=$(kubectl get pods -n myk8s -l app=web -o jsonpath='{.items[0].metadata.name}')
```

Verify:

```bash
kubectl exec -n myk8s "$POD" -- printenv DB_USERNAME
kubectl exec -n myk8s "$POD" -- printenv DB_PASSWORD
```

### Expected result

```text
demo-user
demo-password-change-me
```

This is a lab demonstration only; avoid printing real production secrets.

## Step 8 — Secret as mounted files

```bash
kubectl delete pod secret-reader -n myk8s --ignore-not-found
kubectl apply -f 04-configmap-secret/manifests/secret-reader.yaml
kubectl wait --for=condition=Ready pod/secret-reader -n myk8s --timeout=120s
```

Inspect:

```bash
kubectl exec -n myk8s secret-reader -- ls -l /etc/app-secret
kubectl exec -n myk8s secret-reader -- cat /etc/app-secret/DB_USERNAME
```

### Expected result

Files named `DB_USERNAME` and `DB_PASSWORD` should exist. The username should initially be `demo-user`.

Update the Secret:

```bash
kubectl patch secret app-secret -n myk8s --type merge \
  -p '{"stringData":{"DB_USERNAME":"newadmin"}}'
```

Verify the Secret object:

```bash
kubectl get secret app-secret -n myk8s \
  -o jsonpath='{.data.DB_USERNAME}' | base64 -d
echo
```

Expected:

```text
newadmin
```

Check the same Pod repeatedly:

```bash
kubectl exec -n myk8s secret-reader -- cat /etc/app-secret/DB_USERNAME
```

### Expected result

The mounted file may initially show `demo-user`, then eventually change to `newadmin` without recreating the Pod.

## Step 9 — Troubleshoot a missing ConfigMap

Ensure the dependency is absent and create the broken Pod:

```bash
kubectl delete configmap does-not-exist -n myk8s --ignore-not-found
kubectl delete pod broken-config -n myk8s --ignore-not-found
kubectl apply -f 04-configmap-secret/manifests/broken-config-pod.yaml
sleep 5
kubectl get pod broken-config -n myk8s
```

### Expected result

Typical status:

```text
CreateContainerConfigError
```

Inspect:

```bash
kubectl describe pod broken-config -n myk8s
```

Expected Event:

```text
configmap "does-not-exist" not found
```

Fix the dependency:

```bash
kubectl create configmap does-not-exist \
  --from-literal=APP_MESSAGE="Recovered configuration" \
  -n myk8s

kubectl wait --for=condition=Ready pod/broken-config -n myk8s --timeout=120s
kubectl exec -n myk8s broken-config -- printenv APP_MESSAGE
```

### Expected result

```text
Recovered configuration
```

The same Pod recovers because kubelet retries when the dependency appears.

## Step 10 — Troubleshoot a missing Secret

```bash
kubectl delete secret missing-secret -n myk8s --ignore-not-found
kubectl delete pod broken-secret -n myk8s --ignore-not-found
kubectl apply -f 04-configmap-secret/manifests/broken-secret-pod.yaml
sleep 5
kubectl get pod broken-secret -n myk8s
kubectl describe pod broken-secret -n myk8s
```

### Expected result

Typical status:

```text
CreateContainerConfigError
```

Expected Event:

```text
secret "missing-secret" not found
```

Fix it:

```bash
kubectl create secret generic missing-secret \
  --from-literal=DB_PASSWORD="RecoveredSecret123!" \
  -n myk8s

kubectl wait --for=condition=Ready pod/broken-secret -n myk8s --timeout=120s
kubectl exec -n myk8s broken-secret -- printenv DB_PASSWORD
```

### Expected result

```text
RecoveredSecret123!
```

## Step 11 — Troubleshooting summary

For `CreateContainerConfigError`:

```text
kubectl get pod
      ↓
kubectl describe pod
      ↓
Events
      ↓
Check ConfigMap / Secret name
      ↓
Check key name
      ↓
Create/fix dependency
```

Compare:

```text
ImagePullBackOff           → image retrieval problem
CreateContainerConfigError → container configuration problem
```

## Cleanup and restore a clean web Deployment

First replace the modified Deployment with a clean base Deployment so it no longer references Lesson 04 ConfigMaps or Secrets:

```bash
kubectl delete deployment web -n myk8s --ignore-not-found
kubectl apply -f 02-deployment-replicaset/manifests/deployment-web.yaml
kubectl scale deployment web --replicas=3 -n myk8s
kubectl rollout status deployment/web -n myk8s
kubectl apply -f 03-labels-selectors-service/manifests/service-web.yaml
```

Now remove temporary Lesson 04 resources:

```bash
kubectl delete pod curl-client secret-reader broken-config broken-secret \
  -n myk8s --ignore-not-found

kubectl delete configmap web-content app-settings does-not-exist \
  -n myk8s --ignore-not-found

kubectl delete secret app-secret missing-secret \
  -n myk8s --ignore-not-found
```

Verify:

```bash
kubectl get deployment web -n myk8s
kubectl get pods -n myk8s -l app=web
kubectl get svc web-service -n myk8s
```

### Expected end state

```text
Deployment/web: 3 Running Pods using nginx:latest
Service/web-service: present
Lesson 04 temporary ConfigMaps/Secrets/Pods: removed
```

You are now ready for Lesson 05.
