# supervisor-preflight

Pre-flight validation for deploying a Helm chart to a vSphere Supervisor namespace, with an optional gated deploy.

Whether a chart can be installed depends on who is installing it: their RBAC, the admission webhooks and policies on the Supervisor, and the storage that is available. Normally you only find out halfway through `helm install`. `supervisor-preflight` answers the question first, for the identity in your current kube context, and can run the real install only when every check passes.

It never writes to the cluster unless you pass `--deploy`.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Reading the report](#reading-the-report)
- [Deploying with `--deploy`](#deploying-with---deploy)
- [Examples](#examples)
- [Charts that need cluster-scoped access](#charts-that-need-cluster-scoped-access)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Tests](#tests)

## Requirements

| Tool | Version | Notes |
|---|---|---|
| bash | 4+ | the script uses associative arrays |
| `kubectl` | any recent | logged in to the Supervisor (for example with `kubectl vsphere login`) |
| `helm` | 3.13+ | `--dry-run=server` is required |
| `jq` | any recent | |
| `yq` | mikefarah v4 | not the Python `yq` |

**macOS.** The system bash is 3.2, which is too old, and the script stops with exit code 2 and a message if it finds it. Install the requirements with Homebrew, then run the script with the new bash:

```
brew install bash yq jq helm kubectl
"$(brew --prefix)/bin/bash" ./supervisor-preflight <chart> <release> ...
```

Or put `$(brew --prefix)/bin` first on your `PATH`, so that `#!/usr/bin/env bash` finds the new bash.

You need a kube context for the Supervisor namespace you want to deploy to. List them with `kubectl config get-contexts`.

## Installation

Copy the script somewhere on your `PATH` and make it executable:

```
install -m 0755 supervisor-preflight ~/bin/supervisor-preflight
supervisor-preflight --help
```

The script is self-contained, so there is nothing else to install.

## Quick start

```
# 1. Validate. Read the report and fix anything that is DENIED.
supervisor-preflight <chart> <release> -n <namespace> --kube-context <context> -f my-values.yaml

# 2. When the result is PASS, run the same command again with --deploy.
supervisor-preflight <chart> <release> -n <namespace> --kube-context <context> -f my-values.yaml --deploy
```

`<chart>` is anything `helm template` accepts: a chart directory, a packaged `.tgz`, or `repo/chart` after `helm repo add`. The examples below pull each chart first with `helm pull`, so that you can read its values.

## Usage

```
supervisor-preflight <chart> <release> [options]
```

| Option | Description |
|---|---|
| `<chart>` | Chart to check. |
| `<release>` | Release name that the install would use. |
| `-n`, `--namespace NS` | Target namespace. Default `demo1`. Must exist. |
| `-f`, `--values FILE` | Values file. Repeatable; later files win. |
| `--set k=v` | Override a single value. Repeatable; wins over `-f`. |
| `--version V` | Chart version. |
| `--upgrade` | Validate an upgrade (`helm upgrade --install`) instead of a fresh install. Also checks `get`, `patch`, `update` and `delete`. |
| `--kube-context CTX` | kubectl context to use. Default: the current context. |
| `--skip-dry-run` | Skip the server-side validation. Cannot be combined with `--deploy`. |
| `--deploy` | Run the real install, only if the result is PASS. |
| `--json` | Print the result as JSON. |
| `-h`, `--help` | Show usage. |

Keep your changes in a separate values file and pass it with `-f`. Do not edit the values inside the chart: the chart then stays pristine and your changes are easy to review.

## How it works

1. **Preflight.** The script checks that the cluster is reachable and that the namespace exists. If not, it stops with exit code 2.
2. **Render.** `helm template --include-crds` renders the chart with your values, hooks included.
3. **RBAC check.** Every object is mapped to its API resource through discovery. For each one the script checks `create` (and `get`, `patch`, `update`, `delete` with `--upgrade`) for your identity, plus the verbs Helm needs for its release Secret. Namespaced checks use one SelfSubjectRulesReview, and every denial is confirmed with `kubectl auth can-i`. Roles and bindings get escalation checks (`escalate`, `bind`).
4. **Server-side validation.** Each object is dry-run on its own with `kubectl create --dry-run=server` (`apply` with `--upgrade`). This runs the full admission chain, so webhooks, ValidatingAdmissionPolicies, quota and Pod Security all get a say. Checking objects one at a time means one denial does not hide the others.
5. **Storage check.** Every PVC, and every `volumeClaimTemplate` of a StatefulSet, must have a StorageClass that exists, or the cluster must have a default one. A StatefulSet creates its PVCs only after it is deployed, so this is checked up front. Each template is also dry-run as a PVC (install mode), which catches classes the namespace is not allowed to use.
6. **Helm dry-run.** `helm install --dry-run=server` runs once as an end-to-end check.
7. **Report and optional deploy.** With `--deploy` and a PASS, the chart is installed.

## Reading the report

A run prints an identity header, an RBAC table, a server-side table, the Helm dry-run result and a summary:

```
Identity : sso:Administrator@vsphere.local
Target   : namespace demo1  (7 rendered objects)
...
Helm dry-run: OK

RBAC     : 12 allowed, 0 denied, 0 unsupported, 0 warnings
Server   : 8 ok, 0 denied, 0 warnings, 0 skipped
Result   : PASS
```

The result is **PASS** only if nothing is denied or unsupported, no server-side check is denied, and the Helm dry-run did not fail.

**RBAC table status**

| Status | Meaning |
|---|---|
| `ALLOWED` | Your identity can do this. |
| `DENIED` | Your identity cannot. Blocks PASS. |
| `UNSUPPORTED` | The Supervisor does not serve this kind. Blocks PASS. |
| `WARN` | Informational, for example a RoleBinding where you do not hold `bind` on the role. Never blocks. |

**Server-side table result**

| Result | Meaning |
|---|---|
| `OK` | The API server accepted the object. |
| `DENIED` | The API server rejected it. Blocks PASS. |
| `WARN` | Non-blocking: an admission warning, or a check that could not be completed. |
| `SKIPPED` | Not checked, with the reason in the category. |

Every server-side row carries a **category** that says what rejected it. See [Troubleshooting](#troubleshooting).

**Exit codes**

| Code | Meaning |
|---|---|
| 0 | PASS (and deployed, when `--deploy` was given) |
| 1 | The checks failed: something was denied, unsupported, or the Helm dry-run failed |
| 2 | The tool could not run: bad context, missing namespace, bad chart or values file |
| 3 | The checks passed but the deployment itself failed |

**JSON.** `--json` prints the same result as one JSON object with `user`, `namespace`, `pass`, `results` (RBAC rows), `server_checks`, `server_dry_run` and `deploy`.

## Deploying with `--deploy`

`--deploy` runs the real `helm install` (or `helm upgrade --install` with `--upgrade`) only if the final result is PASS. It writes to the cluster and does not ask for confirmation: the flag is the confirmation.

- It uses the same chart, values, release name and namespace as the checks.
- On a FAIL it prints `Deploy   : SKIPPED (result is not PASS)` and changes nothing.
- It refuses to run with `--skip-dry-run`, because the server-side validation is what makes a PASS trustworthy.
- If Helm's own dry-run is inconclusive (see [Charts that ship their own CRDs](#charts-that-ship-their-own-crds)), the deploy is skipped as well.
- On success it prints `Deploy   : DEPLOYED (<release> in namespace <ns>)` followed by Helm's own output, including the chart's notes.
- With `--json` the outcome is in `deploy.state`: `deployed`, `failed`, `skipped` or `not-requested`.

A PASS means the API server will accept every object. It does not mean the workload will start: image pulls, probes and scheduling are not tested. After a deploy, check the pods:

```
kubectl --context <context> -n <namespace> get pods
```

To remove a release: `helm uninstall <release> -n <namespace>`. This does not delete PVCs; delete them by label with `kubectl delete pvc -l app.kubernetes.io/instance=<release>`.

## Examples

All examples were run as `Administrator@vsphere.local` in the namespace `demo1`, using the context `supervisor:demo1`. Output is shortened: ALLOWED and OK rows are omitted, and long lines are cut with `…`. Replace the context, namespace and release names with your own.

Each example follows the same loop: validate, fix what the report says, validate again, then `--deploy`.

### Example 1: PostgreSQL

Pull the chart:

```
helm pull oci://registry-1.docker.io/bitnamicharts/postgresql --untar -d charts
```

**Validate.** With the defaults, the chart's StatefulSet asks for a volume without naming a StorageClass, and this Supervisor has no default:
```
$ supervisor-preflight charts/postgresql postgresql --kube-context supervisor:demo1
Identity : sso:Administrator@vsphere.local
Target   : namespace demo1  (7 rendered objects)
PVC/data-postgresql-0 (volumeClaimTemplate of StatefulSet/postgresql)  demo1      DENIED  STORAGECLASS  no StorageClass is set and the cluster has no…
Helm dry-run: OK
RBAC     : 12 allowed, 0 denied, 0 unsupported, 0 warnings
Server   : 7 ok, 1 denied, 0 warnings, 0 skipped
Result   : FAIL
```

**Fix.** Name a StorageClass that is assigned to your namespace. List the available ones with `kubectl get storageclass`. This chart takes the class through `global.defaultStorageClass`:
```
$ supervisor-preflight charts/postgresql postgresql --kube-context supervisor:demo1 \
    --set global.defaultStorageClass=vsan-default-storage-policy
Identity : sso:Administrator@vsphere.local
Target   : namespace demo1  (7 rendered objects)
PVC/data-postgresql-0 (volumeClaimTemplate of StatefulSet/postgresql)  demo1      OK      -         StorageClass vsan-default-storage-policy; accepte…
Helm dry-run: OK
RBAC     : 12 allowed, 0 denied, 0 unsupported, 0 warnings
Server   : 8 ok, 0 denied, 0 warnings, 0 skipped
Result   : PASS
```

**Deploy.** Run the same command with `--deploy`:

```
supervisor-preflight charts/postgresql postgresql --kube-context supervisor:demo1 \
    --set global.defaultStorageClass=vsan-default-storage-policy --deploy
```

**Verify and clean up.**

```
kubectl --context supervisor:demo1 -n demo1 get pods,pvc -l app.kubernetes.io/instance=postgresql
helm uninstall postgresql -n demo1 --kube-context supervisor:demo1
kubectl --context supervisor:demo1 -n demo1 delete pvc -l app.kubernetes.io/instance=postgresql
```

### Example 2: Redis

```
helm pull oci://registry-1.docker.io/bitnamicharts/redis --untar -d charts
```

**Validate.** Redis has a master and replicas, so there are two StatefulSets and two volume claim templates to fail:
```
$ supervisor-preflight charts/redis redis --kube-context supervisor:demo1
Identity : sso:Administrator@vsphere.local
Target   : namespace demo1  (14 rendered objects)
PVC/redis-data-redis-master-0 (volumeClaimTemplate of StatefulSet/redis-master)      demo1      DENIED  STORAGECLASS  no StorageClass is set and the …
PVC/redis-data-redis-replicas-0 (volumeClaimTemplate of StatefulSet/redis-replicas)  demo1      DENIED  STORAGECLASS  no StorageClass is set and the …
Helm dry-run: OK
RBAC     : 19 allowed, 0 denied, 0 unsupported, 0 warnings
Server   : 14 ok, 2 denied, 0 warnings, 0 skipped
Result   : FAIL
```

**Fix and validate again.** The same value fixes it:
```
$ supervisor-preflight charts/redis redis --kube-context supervisor:demo1 \
    --set global.defaultStorageClass=vsan-default-storage-policy
Identity : sso:Administrator@vsphere.local
Target   : namespace demo1  (14 rendered objects)
PVC/redis-data-redis-master-0 (volumeClaimTemplate of StatefulSet/redis-master)      demo1      OK      -         StorageClass vsan-default-storage-p…
PVC/redis-data-redis-replicas-0 (volumeClaimTemplate of StatefulSet/redis-replicas)  demo1      OK      -         StorageClass vsan-default-storage-p…
Helm dry-run: OK
RBAC     : 19 allowed, 0 denied, 0 unsupported, 0 warnings
Server   : 16 ok, 0 denied, 0 warnings, 0 skipped
Result   : PASS
```

Optional: add `--set rbac.create=true` to create a namespaced Role and RoleBinding. This also passes, with a bind-check warning and a dependency warning, neither of which blocks.

**Deploy, verify and clean up.**

```
supervisor-preflight charts/redis redis --kube-context supervisor:demo1 \
    --set global.defaultStorageClass=vsan-default-storage-policy --deploy
kubectl --context supervisor:demo1 -n demo1 get pods,pvc -l app.kubernetes.io/instance=redis
helm uninstall redis -n demo1 --kube-context supervisor:demo1
kubectl --context supervisor:demo1 -n demo1 delete pvc -l app.kubernetes.io/instance=redis
```

### Example 3: Grafana

```
helm repo add grafana https://grafana.github.io/helm-charts
helm pull grafana/grafana --untar -d charts
```

**Validate.** By default the chart creates a ClusterRole and a ClusterRoleBinding, which need cluster-scoped rights that a namespace user does not have:
```
$ supervisor-preflight charts/grafana grafana --kube-context supervisor:demo1
Identity : sso:Administrator@vsphere.local
Target   : namespace demo1  (12 rendered objects)
ClusterRole/grafana-clusterrole                demo1      DENIED  RBAC        clusterroles.rbac.authorization.k8s.io is forbidden: User "sso:Administ…
ClusterRoleBinding/grafana-clusterrolebinding  demo1      DENIED  RBAC        clusterrolebindings.rbac.authorization.k8s.io is forbidden: User "sso:A…
Helm dry-run: FAILED [RBAC]
RBAC     : 17 allowed, 2 denied, 0 unsupported, 2 warnings
Server   : 8 ok, 2 denied, 2 warnings, 0 skipped
Result   : FAIL
```

**Fix.** Grafana can run with a namespaced Role instead. Put that change in a values file, not in the chart:

```
printf 'rbac:\n  namespaced: true\n' > /tmp/grafana-override.yaml
```
```
$ supervisor-preflight charts/grafana grafana --kube-context supervisor:demo1 \
    -f /tmp/grafana-override.yaml
Identity : sso:Administrator@vsphere.local
Target   : namespace demo1  (10 rendered objects)
Helm dry-run: OK
RBAC     : 16 allowed, 0 denied, 0 unsupported, 1 warnings
Server   : 8 ok, 0 denied, 2 warnings, 0 skipped
Result   : PASS
```

The two server warnings are `DEPENDENCY` rows: the RoleBinding needs the chart's Role and the test pod needs its ServiceAccount, and a dry-run creates neither.

**Deploy.**

```
supervisor-preflight charts/grafana grafana --kube-context supervisor:demo1 \
    -f /tmp/grafana-override.yaml --deploy
```

**Log in.** The username is `admin`. The password is generated by the chart:

```
kubectl --context supervisor:demo1 -n demo1 get secret grafana -o jsonpath='{.data.admin-password}' | base64 --decode; echo
kubectl --context supervisor:demo1 -n demo1 port-forward deploy/grafana 3000
```

Then open `http://localhost:3000`. Persistence is off by default, so dashboards are lost when the pod restarts.

**Change a release later.** To expose Grafana with a LoadBalancer, validate and apply an upgrade. Only the Service changes, so an in-place upgrade is fine:
```
$ supervisor-preflight charts/grafana grafana --kube-context supervisor:demo1 \
    -f /tmp/grafana-override.yaml --set service.type=LoadBalancer --upgrade
Identity : sso:Administrator@vsphere.local
Target   : namespace demo1  (10 rendered objects)
Helm dry-run: OK
RBAC     : 56 allowed, 0 denied, 0 unsupported, 1 warnings
Server   : 8 ok, 0 denied, 2 warnings, 0 skipped
Result   : PASS
```

Run the same command with `--deploy` to apply it. The Service receives an external IP after a minute or so (`kubectl get svc grafana`).

### Example 4: Headlamp

```
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm pull headlamp/headlamp --untar -d charts
```

**Validate.** By default the chart binds its ServiceAccount to `cluster-admin`:
```
$ supervisor-preflight charts/headlamp headlamp --kube-context supervisor:demo1
Identity : sso:Administrator@vsphere.local
Target   : namespace demo1  (5 rendered objects)
ClusterRoleBinding/headlamp-admin  demo1      DENIED  RBAC      clusterrolebindings.rbac.authorization.k8s.io is forbidden: User "sso:Administrator@v…
Helm dry-run: FAILED [RBAC]
RBAC     : 9 allowed, 1 denied, 0 unsupported, 1 warnings
Server   : 4 ok, 1 denied, 0 warnings, 0 skipped
Result   : FAIL
```

**Fix.** Turn that binding off with a values file:

```
printf 'clusterRoleBinding:\n  create: false\n' > /tmp/headlamp-override.yaml
```
```
$ supervisor-preflight charts/headlamp headlamp --kube-context supervisor:demo1 \
    -f /tmp/headlamp-override.yaml
Identity : sso:Administrator@vsphere.local
Target   : namespace demo1  (4 rendered objects)
Helm dry-run: OK
RBAC     : 9 allowed, 0 denied, 0 unsupported, 0 warnings
Server   : 4 ok, 0 denied, 0 warnings, 0 skipped
Result   : PASS
```

**Deploy.**

```
supervisor-preflight charts/headlamp headlamp --kube-context supervisor:demo1 \
    -f /tmp/headlamp-override.yaml --deploy
```

Without the cluster-admin binding, Headlamp can only see what its ServiceAccount is granted, so give it a namespaced Role or sign in with a token that already has the access you want.

### Example 5: Upgrading a release

Add `--upgrade` to validate (and, with `--deploy`, apply) a change to an existing release:

```
supervisor-preflight charts/grafana grafana --kube-context supervisor:demo1 \
    -f /tmp/grafana-override.yaml --set service.type=LoadBalancer --upgrade --deploy
```

Some changes cannot be applied in place. The most common is a StatefulSet's `volumeClaimTemplates`: Kubernetes forbids changing them on an existing StatefulSet, and the check reports this as `INVALID`, with the deploy skipped. Uninstall the release and install it again instead.

### Example 6: Using it in CI

Use the exit code to gate a pipeline, and `--json` to report why a run failed:

```
supervisor-preflight charts/postgresql postgresql --kube-context supervisor:demo1 \
    --set global.defaultStorageClass=vsan-default-storage-policy --json > result.json
status=$?
jq -r '.server_checks[] | select(.result == "DENIED") | "\(.category)  \(.resource)"' result.json
exit $status
```

The shape of the JSON:

```
{
  "user": "sso:Administrator@vsphere.local",
  "namespace": "demo1",
  "pass": true,
  "results": [
    {
      "resource": "ServiceAccount/headlamp",
      "ns": "demo1",
      "verb": "create",
      "status": "ALLOWED",
      "note": ""
    }
  ],
  "server_checks": [
    {
      "resource": "ServiceAccount/headlamp",
      "ns": "demo1",
      "result": "OK",
      "category": "-",
      "message": ""
    }
  ],
  "server_dry_run": {
    "ok": true,
    "inconclusive": false,
    "category": ""
  },
  "deploy": {
    "state": "not-requested"
  }
}
```

For a chart that fails, the denied rows look like this (here PostgreSQL without a StorageClass):

```
STORAGECLASS  PVC/data-postgresql-0 (volumeClaimTemplate of StatefulSet/postgresql)
```

## Charts that need cluster-scoped access

Some charts cannot be deployed by a user with namespace-level rights, and no values change fixes that. The validator reports exactly why, and `--deploy` refuses to run.

### kube-prometheus-stack

```
$ supervisor-preflight charts/kube-prometheus-stack kps --kube-context supervisor:demo1 --deploy
Identity : sso:Administrator@vsphere.local
Target   : namespace demo1  (136 rendered objects)
ClusterRole/kps-kube-state-metrics  -  escalate-check  DENIED
ClusterRole/kps-kube-prometheus-stack-operator  -  escalate-check  DENIED
Alertmanager/kps-kube-prometheus-stack-alertmanager  demo1  create  DENIED
Prometheus/kps-kube-prometheus-stack-prometheus  demo1  create  DENIED
PrometheusRule/kps-kube-prometheus-stack-alertmanager.rules  demo1  create  DENIED
DaemonSet/kps-prometheus-node-exporter  demo1  DENIED  WEBHOOK  admission webhook "admission.vmware.com" denied the request: Cannot add toleration { key:, effect:NoSched…
Helm dry-run: INCONCLUSIVE [MISSING-CRD] (Helm cannot map kinds from this chart's own CRDs before they exist; not counted as a failure)
RBAC     : 67 allowed, 80 denied, 0 unsupported, 6 warnings
Server   : 56 ok, 28 denied, 2 warnings, 50 skipped
Result   : FAIL
Deploy   : SKIPPED (result is not PASS)
```

Why it fails:

- **Cluster-scoped objects.** The chart needs CustomResourceDefinitions, ClusterRoles, ClusterRoleBindings and webhook configurations. A namespace-level identity is denied all of these, both by the RBAC check and by the API server.
- **A webhook rejection.** The Supervisor's `admission.vmware.com` webhook rejects the node-exporter DaemonSet: `Cannot add toleration { key:, effect:NoSchedule } for master taint`.
- **Objects that depend on the chart's own CRDs.** 50 ServiceMonitors and rules cannot exist until the CRDs do, so they are `SKIPPED` as `DEPENDENCY`, and Helm's own dry-run is `INCONCLUSIVE`. An inconclusive result also blocks `--deploy`.
- **No values-only fix was found.** Switching off the cluster-scoped parts removes what the stack is for, and the DaemonSet was rejected in every run. Installing the CRDs and cluster roles takes someone with cluster-scoped rights on the Supervisor.

### Other charts that were tested

| Chart | Result | Reason |
|---|---|---|
| `ingress-nginx` | FAIL | ClusterRoles, IngressClass and a ValidatingWebhookConfiguration need cluster scope |
| `cert-manager` (`crds.enabled=true`) | FAIL | CRDs and webhook configurations are denied, and its CRDs already exist on the Supervisor (`CONFLICT`) |
| `metrics-server` | FAIL | APIService and ClusterRole(Binding)s need cluster scope |
| `argo-cd` | FAIL | CRDs and Roles; Role creation is also blocked by the escalation check |

## Troubleshooting

Each server-side row has a category. This is what each one means and what to do about it.

| Category | Meaning | What to do |
|---|---|---|
| `RBAC` | The API server answered `forbidden`. | Ask for the role that grants it, or change the values so the chart does not create that object. |
| `WEBHOOK` | An admission webhook denied the object. | Read the message. It usually names the offending field, for example a toleration or a security setting. |
| `ADMISSION-POLICY` | A ValidatingAdmissionPolicy denied it. | Read the message and change the values to comply. |
| `QUOTA` | A resource quota would be exceeded. | Lower the requests, or ask for more quota. |
| `POD-SECURITY` | The pod violates the namespace's Pod Security level. Shown as a warning for workloads. | Adjust the `securityContext` in the values. |
| `STORAGECLASS` | A PVC has no StorageClass and there is no default, or the named class does not exist. | Set a StorageClass in the values. List them with `kubectl get storageclass`. |
| `INVALID` | Schema or field validation failed, or an immutable field would change. | Fix the value. For immutable StatefulSet fields, uninstall and install again. |
| `CONFLICT` | The object already exists, or exists without Helm ownership. | Pick another release name, remove the conflicting object, or uninstall the old release. |
| `MISSING-CRD` | A kind or CRD is not available. | Install the CRD first, or enable the chart's own CRD option. |
| `WEBHOOK-NO-DRYRUN` | A webhook with side effects cannot be dry-run, so the result is inconclusive. (WARN) | Nothing; informational. |
| `DEPENDENCY` | The object needs another object from the same chart, which a dry-run does not create. (WARN or SKIPPED) | Nothing; informational. |
| `UNSUPPORTED` | The Supervisor does not serve the kind, and the chart does not ship a CRD for it. (SKIPPED) | Remove the object through the values, or pick another chart. |
| `OTHER` | Not recognized. | Read the message. |

### Charts that ship their own CRDs

Kinds defined by a CRD inside the chart (for example a `ServiceMonitor` from `kube-prometheus-stack`) are not reported as unsupported. Their RBAC is checked using the plural name and scope from the CRD, and their server-side check is skipped as `DEPENDENCY`.

Helm's own dry-run cannot map those kinds before the CRDs exist, so a `MISSING-CRD` failure in that case is shown as `Helm dry-run: INCONCLUSIVE` and does not fail the run. `--deploy` still refuses to deploy on an inconclusive result.

## Limitations

- **A PASS is not a guarantee that the workload will run.** Image pulls, probes, scheduling and resource limits are not tested.
- **Quota is not evaluated.** A dry-run does not enforce it, and this identity cannot read the namespace's quota objects.
- **A StorageClass that exists is accepted.** The check cannot tell whether a class is assigned to the namespace unless the API server rejects it during the PVC dry-run.
- **Pod Security only warns for workloads.** For Deployments and StatefulSets the pods are checked later, when the ReplicaSet or StatefulSet creates them.
- **Hooks are checked but not executed.** Helm does not run hooks in a dry-run.
- **Helm's dry-run stops at its first error.** This is why each object is also checked on its own.
- **`--upgrade` is approximated per object** with `kubectl apply`, which can print harmless "missing last-applied-configuration" warnings for objects that Helm created.
- **Large charts are slow.** Each object is checked separately, so charts with 100+ objects take 60 to 90 seconds.
- **Only the current identity is checked.** Checking another user would need impersonation rights, which a namespace-level user does not have.

## Tests

`tests/` holds small charts that exercise the checks:

| Chart | Expected result | What it covers |
|---|---|---|
| `plain` | PASS | Deployment, Service and ConfigMap |
| `rbac` | PASS with a WARN | Role and RoleBinding (escalation and bind checks) |
| `cluster` | FAIL | ClusterRole and CRD (cluster-scoped objects) |
| `hookunsup` | FAIL | a hook, plus a kind the Supervisor does not serve |
| `admission` | FAIL | an object that RBAC allows but the API server rejects as invalid |
| `storage` | FAIL by default | a StatefulSet and a PVC without a StorageClass; pass `--set storageClass=<class>` to fix |

Run one with, for example:

```
supervisor-preflight tests/storage st --kube-context supervisor:demo1
supervisor-preflight tests/storage st --kube-context supervisor:demo1 --set storageClass=vsan-default-storage-policy
```
