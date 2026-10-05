---
name: nexus-operate
description: Operate a running Nexus SDV platform — check its health, watch certificate expiry, send test telemetry through it, and report which vehicles it knows. Use when asked whether a Nexus platform is healthy, why it stopped working, which vehicles are registered, or to run its sample clients.
---

# Operating a Nexus SDV platform

**Experimental in 1.2.1.** This skill ships so that it can be used and
criticised, not because it is finished. It has been exercised against live
platforms by more than one agent framework, and several corrections came out of
that. Expect it to change, and report what it gets wrong.

For a platform that already exists. To create one, use `nexus-install`.

Start with the health check: it answers most questions on its own, and its
output tells you which of the sections below to read next.

**Three things here are not read-only.** Renewing a certificate replaces one and
restarts the service that holds it. Running the health check submits a Cloud
Build and writes metrics to Cloud Monitoring, which costs a little and shows up
in the project's history. And starting a sample client **creates a vehicle
identity that cannot be removed** — a VIN invented for a demonstration is issued
a real certificate and stays in the Vehicle Registry for good. Ask before any of
the three; the rest of this skill only looks.

You need **`gcloud`**, and **`kubectl`** for the fleet report further down.
`iac/operating/nexus-preflight.sh` reports both if you are unsure what the
machine has.

## Is the platform healthy?

The check runs three times a day on its own schedule **if the platform was
installed on the trigger path** — the schedule pokes the Cloud Build trigger, and
that trigger needs the repository connection. After a `gcloud builds submit`
install there is no trigger and no recurring check: run it by hand, or connect the
repository and re-run the trigger setup. Where the schedule does exist, there is
usually a
recent answer already in **Cloud Build → History**. To run it now:

```bash
gcloud builds submit . --config=iac/cloudbuild/platform-health-check.yaml \
  --project=<PROJECT_ID> --region=<REGION> \
  --substitutions=^::^_TARGET_MODE=file::_BOOTSTRAP_ENV_GCS_PATH=gs://<PROJECT_ID>-bootstrap-envs/<name>.bootstrap_env
```

`_TARGET_MODE` selects what to check and must be set explicitly: `file` for one
environment, `dir` for every environment in a bucket, `project` for everything
in a project. Add `_RUN_E2E=Y` to also push real telemetry through the platform
and read it back — slower, and the only check that proves the data path rather
than the deployment.

It ends with:

```
ENVIRONMENT                      PASS   WARN   FAIL
my-environment                     41      0      0
```

The PASS count varies with the platform — a `local` PKI install has fewer checks
to run. Read the WARN and FAIL columns, not the total.

The same counts go to a Cloud Monitoring dashboard named **Platform health**.

## When something is wrong

Read the failing lines before doing anything. The check names the component, and
the common causes are distinct enough to tell apart:

- **An endpoint does not answer** — look at the pods in the `base-services`
  namespace first. A GKE Autopilot cluster in `RECONCILING` or `PROVISIONING` is
  transient; give it a few minutes rather than redeploying.
- **A certificate is expiring or expired** — see the next section. This is the
  most common cause of a platform that worked last month and does not today.
- **An API is disabled** — someone turned it off, or the project was recreated.

## Certificates expire after 30 days

**This applies to remote PKI only.** With `local` PKI the platform signs its own
certificates with `openssl -days 365`, so they last a year and this section is
not urgent. Check `PKI_STRATEGY` before worrying about it.

With **remote** PKI, five platform TLS certificates are issued from Certificate
Authority Service for 30 days, and **nothing renews them automatically**. There
is no scheduler job and no trigger. A platform left alone stops working roughly
a month after its last deployment, and the first symptom is usually vehicles
failing to obtain a token.

The health check warns seven days ahead for **all five**, and so does the status
script. Until 2026-09-25 two of them — `FACTORY_HELPER_TLS_CERT` and
`NATS_LEAF_TLS_CERT` — were watched by neither; that gap is closed.

On a `local` platform, `FLEETVIEW_TLS_CRT` and `FACTORY_HELPER_TLS_CERT` are
never created. The status script says `not issued with local PKI` for those,
which is a statement about the platform and not a fault.

```bash
./iac/operating/nexus-cert-status.sh                   # all five, with days remaining
./iac/operating/nexus-cert-status.sh --warn-days 14    # widen the warning threshold
./iac/operating/nexus-cert-status.sh --renew <NAME>    # renew one — asks first
```

Renewal re-runs the single pipeline that owns that certificate. **Do not reach
for `deploy-all.yaml` to rotate a certificate** — it redeploys the entire
platform, which is a disproportionate blast radius for routine maintenance.

Vehicle credentials are a separate matter and are not covered by this script:
factory certificates last 730 days and operational certificates 90 by default,
both configurable in the `.bootstrap_env`.

## Send telemetry through it

The end-to-end proof: a real client registers, authenticates and publishes, and
the data arrives in BigTable.

```bash
gcloud builds submit . --config=iac/cloudbuild/run-sample-clients.yaml \
  --project=<PROJECT_ID> --region=<REGION> \
  --substitutions=_BOOTSTRAP_ENV_GCS_PATH=gs://<PROJECT_ID>-bootstrap-envs/<name>.bootstrap_env
```

To onboard a vehicle by hand instead — useful when someone has no access to the
Google Cloud project — the factory launchers walk the whole path. They need a
Keycloak client secret and nothing else:

```bash
cd sample-clients/vehicle-client/
FACTORY_OPERATOR_CLIENT_SECRET="<secret>" \
  ./run-vehicle-client-factory.sh --vin <VIN> --base-domain <DOMAIN>
```

Never paste that secret into the conversation or into a file under version
control. Read it from Secret Manager and pass it in the environment.

### Putting more vehicles on the platform

:::caution[On local PKI, onboarding puts a CA private key on this machine]
Say this before the first launcher runs, not after. It applies to **every**
vehicle started here, not only to the Kuksa section below.

With `local` PKI there is no Factory Helper, so a client signs its own factory
certificate — and to do that it fetches `REGISTRATION_FACTORY_CA_KEY`, the
factory authority's **private key**, onto this machine. Both sample clients do
it: `make certs` in the Go client, `make downloadcerts` in the Python one. The
key then sits there as a plain file, gitignored but unencrypted.

That is acceptable on a machine the person controls and intends to discard. It
is not acceptable on a shared or long-lived one. With `remote` PKI none of this
happens: the Factory Helper issues the certificate and the key never leaves
Google-managed infrastructure.
:::

A platform with two vehicles demonstrates the path; it does not look like a
fleet. **Offer this rather than waiting to be asked** — after a fresh install,
after a green health check, or whenever someone is looking at a nearly empty
FleetView.

Each launcher takes a VIN and a publishing interval, so more vehicles are a
matter of running it again with a different one. **Which launcher depends on the
PKI strategy**, and getting this wrong is the first thing that fails:

```bash
# remote PKI — the Factory Helper issues the identity
cd sample-clients/vehicle-client/
FACTORY_OPERATOR_CLIENT_SECRET="<secret>" \
  ./run-vehicle-client-factory.sh --vin VEHICLE003 --interval 2 --base-domain <DOMAIN>

# local PKI — no Factory Helper, no domain
./run-vehicle-client.sh --vin VEHICLE003 --interval 2
```

The Python client is the same on both paths: `run-python-client-factory.sh` with
remote PKI, `run-python-client.sh` with local, each taking `--vin` and
`--interval`. Only `--base-domain` is specific to the remote launchers.

| Option | Effect |
| :--- | :--- |
| `--vin` | the vehicle's identifier; **a new one creates a new vehicle** |
| `--interval` | seconds between messages, default 3 for the Go client and 5 for Python |
| `--message-type` | Go client only: `telemetry` for flat sensor readings, `metrics_report` for the vehicle metrics envelope. The two produce **different signal names**, so a platform that has seen both shows both sets of columns |

The clients run until stopped, so a longer demonstration is a matter of leaving
one running rather than of any setting. Start several with different VINs to
fill the fleet view.

Two things to tell the person before starting a batch:

- **Each vehicle is a real identity.** It registers, is issued a certificate and
  is recorded in the Vehicle Registry permanently — a VIN invented for a demo
  stays in the fleet afterwards.
- **A VIN is not reusable as a clean slate.** Running the same VIN again adds a
  second issuance event rather than replacing the first, which is what the
  vehicle's history is for.
- **Give each vehicle its own working directory.** The client stores its
  operational certificate under a fixed name, so several started side by side in
  one directory share one set of files. A client now refuses a certificate
  issued to a different VIN and registers anew, but the simplest arrangement is
  still one directory per vehicle.

### Feeding it from a VSS data broker

The launchers above are Nexus's own clients. For a platform that has to convince
someone from the automotive side, there is a second path: **Eclipse Kuksa**, the
COVESA VSS data broker. Signals go into the broker, and a bridge relays them to
Nexus.

It needs Docker, and it runs on the operator's machine.

**First register a vehicle**, because the bridge has no identity of its own — it
reuses the one the Python client last obtained, from `nexus_client_config.json`.
Skip this and the readings arrive under whatever VIN was registered before:

```bash
cd sample-clients/python/
make downloadcerts
./run-python-client.sh --vin <VIN>          # registers, then publishes
```

Then the broker and the bridge:

```bash
docker run -it --rm -p 56789:55555 ghcr.io/eclipse-kuksa/kuksa-databroker:0.7.1
uv run vss-bridge-sim                        # simulation and cloud relay in one process
```

Verified with broker 0.7.1 and `kuksa-client` 0.4.3 on 2026-09-25: 59 batches
relayed in 180 seconds. The `eclipse/kuksa.val/databroker` path named in older
notes stops at 0.4.3 and is not needed.

For the modular version — simulator and relay as separate processes, which is
what a real vehicle application looks like — run `uv run vss-sim` and
`uv run vss-vapp` side by side. `sample-clients/python/README.md` has the
detail; do not restate it from memory.

**What this actually demonstrates.** Not new signal names: the plain Python
client already publishes VSS paths such as `Vehicle.Speed`. What is new is the
**broker in between** — Nexus consuming from a standard VSS data broker rather
than from a client written for it. That is the point worth making to someone
evaluating the platform against their own VSS tooling. The bridge adds paths the
plain client does not send, such as
`Vehicle.Powertrain.CombustionEngine.Speed`, so its arrival in BigTable is what
proves the data went through Kuksa.

:::caution[The same CA private key applies here]
`make downloadcerts` fetches `REGISTRATION_FACTORY_CA_KEY` on `local` PKI, as it
does for any vehicle started from this machine. See the caution under *Putting
more vehicles on the platform*; it is not specific to Kuksa.
:::

**Note:** the `run-sample-clients` pipeline cannot help here — its two VINs are
written into the build file (`run-sample-clients.yaml:262`), so it always
produces the same two vehicles. Further ones have to come from the launchers.

## Which vehicles does the platform know?

The Vehicle Registry records every issued identity. FleetView shows it in the
browser, but a signed-in session is awkward for an agent, and the registry
answers directly inside the cluster:

```bash
gcloud container clusters get-credentials <ENV>-gke --region <REGION> --project <PROJECT_ID> --dns-endpoint
kubectl port-forward -n base-services svc/vin-registry 8080:8080 &
curl -s localhost:8080/v1/vins
```

**`--dns-endpoint` is not optional.** Without it `kubectl` talks to the
cluster's public IP endpoint, which is behind master-authorized-networks, and
times out from anywhere that is not already on the list. The obvious repair —
adding your own address with `gcloud container clusters update
--master-authorized-networks` — changes the cluster to answer a read-only
question, replaces the whole list rather than extending it, and is wrong again
the next time your address changes. `--dns-endpoint` routes through Google's
front end instead, is not subject to that list at all, and writes nothing but
your local kubeconfig.

You get one entry per VIN with its event count, when it was first and last seen,
and the last action and its result — a factory certificate or an operational
one, and whether that issuance succeeded.

Two things to know before reading too much into it:

- The registry is **best effort**. A report made while it was down is lost, and
  nothing reconciles it afterwards. An absent VIN does not prove no certificate
  was issued.
- A **failed** issuance is recorded but enrols nothing, so such a VIN is
  invisible to anyone without the `nexus-admin` realm role.

Remember to stop the port-forward when you are finished.

## Reaching FleetView

With remote PKI it is published under its hostname. **With local PKI it is
reached on its load balancer's IP on port 3000** — the deployment registers
exactly that address with Keycloak, so a port forward to `localhost:3000` is
rejected at sign-in as an invalid redirect. Keycloak also uses the platform's
own certificate there, so its warning has to be accepted in the browser before
the first sign-in, or the redirect fails on something the user cannot see.

The first account is `nexus-fleet`, with a one-time password in the Secret
Manager secret `NEXUS_FLEET_INITIAL_PASSWORD`. **Do not read it.** Give the
person the command and let them run it in their own terminal:

```bash
gcloud secrets versions access latest \
  --secret="NEXUS_FLEET_INITIAL_PASSWORD" --project=<PROJECT_ID>
```

Say nothing about whether you could have read it — not "I will not show it
here", not "I am not reading it into the chat". Hand over the command and move
on. Remarking on your own restraint raises the question of whether the password
passed through the conversation at all, and the answer has to be plainly no.

The *FleetView* documentation page has the full procedure; do not restate it
from memory.

### An empty table is usually the time range

A vehicle's telemetry view opens on **1h** (`device/[id]/page.tsx:18`). A vehicle
whose last message is older than that shows an empty table, and someone seeing
FleetView for the first time reads that as a platform without data.

**So: whenever the last client run was more than an hour ago, say before they
look** that the view starts at one hour and that the **6h**, **24h** and **7d**
buttons are at the top right. It costs one sentence and it prevents the worst
first impression the platform can make.

If the longer ranges are empty too, then it is worth looking at the platform.

## Who can see what in FleetView

Visibility follows Keycloak group membership: a user sees the vehicles enrolled
in their groups, and the registry enrols every successfully issued VIN into
`nexus-fleet`. The realm role `nexus-admin` sees every identity, including ones
that belong to no group.

If someone reports an empty FleetView, check their group membership before
suspecting the platform.

## Rules

- Prefer the health check to poking at individual components; it exists so you
  do not have to guess which one is broken.
- Read a failure before retrying. A second identical run reproduces a
  configuration error exactly and costs the same time.
- Certificate renewal changes a running platform. Say which certificate, in
  which project, and get a yes first.
- Never print secrets, private keys or certificate contents.
- If the fix looks like "redeploy everything", stop and ask. It rarely is, and
  it is never reversible in a hurry.

## Where the detail lives

The documentation carries the reference: *FleetView* for the interface and its
access model, *Vehicle Registry* for what the registry records and how fleet
membership works, *Factory Helper* for onboarding a vehicle without a Google
Cloud account, and *Security Architecture* for the trust chain and the
credential lifetimes.
