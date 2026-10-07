---
name: nexus-install
description: Install a Nexus SDV platform into a Google Cloud project — check the project first, write the configuration, run the bootstrap, and read the result. Use when asked to deploy, install, bootstrap or stand up Nexus SDV, or to tear one down.
---

# Installing Nexus SDV

**Experimental in 1.2.1.** This skill ships so that it can be used and
criticised, not because it is finished. It has been exercised against live
platforms by more than one agent framework, and several corrections came out of
that. Expect it to change, and report what it gets wrong.

You are installing a connected-vehicle platform into someone's Google Cloud
project. It creates a GKE cluster, a Cloud SQL database, BigTable, certificate
authorities and DNS records, and it costs real money for as long as it runs.

Work through the steps in order. Two of them you cannot do yourself, and one of
them destroys things — both are marked.

## 0. What must be on the machine

Very little, and that is the point of this path: **`gcloud`**, **`git`** and
**`curl`**. Terraform, `nk` and `openssl` are **not** needed — they run inside
Cloud Build. `kubectl` is only needed afterwards, to operate the platform.

You also need an authenticated `gcloud` and Application Default Credentials
(`gcloud auth login` and `gcloud auth application-default login`). The preflight
in step 1 checks all of this and names whatever is missing, so run it before
installing anything by hand.

The one thing the preflight cannot name is a `gcloud` that does not start. Current
releases need **Python 3.10 or later**. macOS ships 3.9, and on Apple Silicon the
`gcloud` wrapper ignores the Python bundled with the SDK (it uses it on x86_64
only), so a fresh install dies with a `TypeError` in `urllib3`. Install a newer
Python and point `CLOUDSDK_PYTHON` at it. Until then the preflight says no more
than `gcloud not found`.

## 1. Check the project first — always

```bash
./iac/operating/nexus-preflight.sh <PROJECT_ID> --region <REGION> --pki <local|remote>
```

Read-only. It reports billing, APIs, your permissions, whether a platform is
already running there, and the two manual prerequisites.

| Exit | Meaning | What to do |
|---|---|---|
| 0 | ready | continue |
| 1 | blocked, or the project is on the do-not-touch list | fix what it names, or stop |
| 2 | ready with reservations | read each WARN before continuing |

Expect a FAIL for the **BigTable Admin API** in a fresh project: it is off, and
nothing in the bootstrap enables it. Enabling it costs nothing, but it is still a
change to the project — say so and get a yes before running the command the
preflight prints.

**Never skip this and bootstrap directly.** A bootstrap into a project that
already holds a platform collides on resource names, and the teardown afterwards
takes the other platform with it.

**Keep this result.** The same check runs again after the teardown, and the two
are compared: the question at the end is not whether the project is empty but
whether it is as you found it. Something that was already there before you
installed is not yours to have removed, and reporting it as your own leftover
sends the person looking for a problem that is not one.

For a comparison you can hold side by side rather than from memory, `--json`
gives the counts and every check as one line.

**If the preflight warns about leftover secrets, ask before clearing them.** A
finished teardown leaves none, so a warning here means the project was torn down
by an older version, or the teardown's secret step did not finish. It matters
because a bootstrap reuses any secret that already has a version — including TLS
private keys, so a new platform can end up serving with an old environment's key.
Show the person what the preflight counted and offer:

```bash
iac/bootstrapping/tools/delete-all-secrets.sh <PROJECT_ID>
```

**This one the person runs, not you.** Bulk deletion of secrets is one of the
actions the safety check blocks for you, so hand over the command instead of
looking for a variant that gets through. It asks twice, `yes` and then the
project ID, and keeps every secret named `github-oauthtoken`, which belongs to
the repository connection rather than to the platform. **Never pass `--yes` on
this path** — that switch is for the unattended test matrix, where nobody is
there to answer.

If the preflight says the project is already in use, stop and ask the person
whether that is expected. Several environments in one project are supported, but
that has to be a decision, not an accident.

## 2. Decide the two settings that matter

**PKI strategy.** This is the decision with consequences, so put it to the person
rather than picking the quicker one.

`remote` publishes services under your domain, with certificates from Google
Certificate Authority Service. **The certificate authorities' private keys never
leave Google-managed infrastructure**, and the Factory Helper issues vehicle
identities on request, so onboarding needs nothing but an endpoint and an OIDC
client secret.

`local` makes the platform its own certificate authority. It generates the
authorities itself, stores them in Secret Manager, uses IP addresses instead of
DNS names, and needs no domain and no delegation. It is markedly faster to stand
up, and the Factory Helper is **not deployed** on this path at all.

**What that costs, stated plainly:** with `local` there is no service that issues
vehicle identities, so whoever onboards a vehicle signs the certificate
themselves — and to do that they must fetch the factory authority's **private
key** onto their machine. Both sample clients do exactly that in their
`certs` and `downloadcerts` targets. The key then sits as a plain file on every
machine that has ever registered a vehicle.

So `local` is the right choice for a platform you control end to end: a
demonstration, a workshop, a development environment, anything you will tear down
afterwards. It is the wrong choice as soon as someone outside your control
onboards a vehicle, because there is no way for them to do so without the key.

**The common first step is a `local` install that is thrown away the same day.**
Someone who has never seen Nexus can have the whole path running — a vehicle
registering, telemetry arriving in BigTable, FleetView showing it — without a
domain, without a registrar, without arranging anything outside the project. That
is worth offering in those words, because the DNS delegation is the one
prerequisite nobody can satisfy from inside a Google Cloud project, and asking
for it before someone knows whether they want the platform is the wrong order.

Then, when they do: a DNS zone, delegation at the registrar, and `remote`.

**Say that this second step is a new environment, not an upgrade.** Nothing
converts a running `local` platform to `remote`: the hostnames change from IP
addresses to DNS names, the authorities change from self-generated to Certificate
Authority Service, and the Factory Helper appears where there was none. Bootstrap
a fresh environment and tear the first one down.

**Architecture and region.** `arm64` and `amd64` are both supported, but
availability differs. The combination known to work: **arm64 in europe-west4,
amd64 in europe-west3**. If the bootstrap fails while creating the cluster with
a message about unavailable resources, that is a regional stockout — change
region or architecture, not anything else.

## 3. The two steps you cannot do — stop and ask

Neither can be automated. If the preflight reported them missing, hand them to
the person and wait:

- **Cloud Build GitHub connection** — needs a browser sign-in to GitHub. This is
  the one prerequisite of the recommended path, so ask for it rather than
  routing around it. The connection is regional, and a trigger must live in the
  same region as the connection it uses. The platform itself does not: a trigger
  in `europe-west4` can bootstrap a platform in `europe-west3`, because the
  region a build *runs in* and the region it *builds into* are separate.
- **DNS delegation** — with `remote` PKI, the Cloud DNS zone's name servers must
  be delegated at the domain registrar. The preflight can see the zone; nobody
  can verify the delegation from inside the project.

## 4. Write the configuration

`iac/bootstrapping/.bootstrap_env` describes the environment. Copy
`iac/bootstrapping/sandbox.bootstrap_env` and fill it in; the full key reference
is in the documentation under *Cloud-native Deployment*.

Three rules that are not obvious and each cost a whole run:

- **Never reuse an `ENV` name.** A deleted Cloud SQL instance keeps its name
  reserved for about a week, and the bootstrap fails late, after the cluster
  exists.
- **Never copy a used `.bootstrap_env` without clearing every `EXISTING_*` CA
  field.** A completed bootstrap writes its CA pool names back into the file. A
  later run then tries to reuse pools that its teardown has since deleted.
  `EXISTING_DNS_ZONE` is the exception — that zone is permanent, keep it.
- **`ENV` must be short, lowercase and alphanumeric.** It prefixes the cluster,
  the network and the database.

### Filling `EXISTING_*` in a fresh file

**With `remote` PKI, look the DNS zone up before you write anything.** A project
that has hosted an environment before almost always has one already, and it is
the one resource a teardown deliberately keeps — recreating it means arranging
delegation at the registrar again, which nobody can do from inside the project.

```bash
gcloud dns managed-zones list --project=<PROJECT_ID> --format="value(name,dnsName)"
```

`EXISTING_DNS_ZONE` takes the **zone name** from the first column, `BASE_DOMAIN`
the domain from the second without its trailing dot:

```bash
EXISTING_DNS_ZONE="sdv-test-dh-com"     # the zone's name
BASE_DOMAIN="sdv-test-dh.com"           # the domain it serves
```

They differ by more than punctuation, and putting the domain in both is an easy
mistake to make. Leaving `EXISTING_DNS_ZONE` empty while a zone exists is worse:
the bootstrap then tries to create one that is already there. Ignore any
`gke-*-dns` entry — that is a cluster-internal zone, not yours. With `local` PKI
both keys stay empty.

**Then check every `EXISTING_*` you filled, including ones you inherited.**

```bash
gcloud privateca pools list --project=<PROJECT_ID> --format="value(name)"
```

The `.bootstrap_env` is input and output at once: a finished bootstrap writes
what it created back into it, and a teardown that deleted those resources does
not take the names out again. **A name in the file is evidence that something
existed once, not that it exists now.** If a pool named in the file is missing
from that list, clear the field and let the bootstrap create its own. A dead
reference fails the run late and the error points somewhere else entirely.

## 5. Run the bootstrap

**Use the trigger path. Ask before doing anything else.**

Two paths exist and they are not equivalent. Put the choice to the person in
plain terms and wait for an answer; do not pick the easier one because it has
fewer prerequisites.

| | Triggers (recommended) | Direct submit |
|---|---|---|
| Needs a GitHub connection | yes, one browser sign-in | no |
| Recurring health check and its schedule | **yes** | **no** |
| Who can redeploy or tear down | anyone with project permissions, from a browser | only someone with the repository cloned and `gcloud` set up |
| What gets built | a named branch, from the repository | your working tree, uncommitted changes included |

The schedule is the part people notice later. Without a trigger there is none,
so the platform never checks itself again after the bootstrap.

**Neither path avoids the `roles/owner` grant.** Both run as the Compute Engine
default service account, and the bootstrap needs that account to hold
`roles/owner` **before** it starts: Terraform creates IAM bindings, which
`roles/editor` — all a fresh project gives the account — cannot set. That includes
`compute_sa_owner` in `iac/terraform/cloudbuild.tf`, so Terraform keeps the
grant afterwards but cannot make it first. The trigger setup makes it; on direct
submit it is a manual step. Choosing direct submit to keep a project's IAM clean
does not work, and saying so saves an argument later.

### The rule, so nobody has to weigh this live

- **A platform anyone else will use, or that outlives today** → triggers.
- **A demonstration you will tear down afterwards** → triggers as well. The
  bootstrap is identical and the schedule costs nothing.
- **No browser, no permission to authorise a GitHub app, or an organisation that
  forbids the connection** → direct submit, and say in one sentence that there
  will be no recurring health check.

That is the whole decision. In a guided session, make it before the session, not
in front of an audience.

**Do not install by submit merely because no connection exists yet.** Ask for one
first.

### If a direct-submit build fails on permissions

Which identity `gcloud builds submit` runs as depends on the project. Recent
projects use the Compute Engine default service account — the one that needs
`roles/owner` — and the build works once it has it. Older projects can still
default to the legacy Cloud Build service agent, which is granted nothing here.

Measured: in every project we have installed into, submitted builds ran as
`<PROJECT_NUMBER>-compute@developer.gserviceaccount.com`, and each of those
installations succeeded. So do not add
`--service-account` pre-emptively; it also requires `iam.serviceAccounts.actAs`
on the caller and can break a path that works.

If a build does fail inside Terraform with permission errors, check which
identity ran it, and what that identity holds, before changing anything:

```bash
gcloud builds describe <BUILD_ID> --region=<REGION> --format="value(serviceAccount)"
gcloud projects get-iam-policy <PROJECT_ID> --flatten="bindings[].members" \
  --filter="bindings.members:<THAT_ACCOUNT>" --format="value(bindings.role)"
```

`roles/editor` without `roles/owner` is the missing upfront grant, not a wrong
identity.

### Creating the triggers

This is your job, not the person's:

```bash
./iac/operating/nexus-preflight.sh <PROJECT_ID> --region <REGION>   # is a connection there?
bash iac/bootstrapping/tools/setup-cloudbuild-triggers.sh           # once per project
gcloud builds triggers run bootstrap-platform --region=<REGION> --project=<PROJECT_ID>
```

The triggers are pinned to **the branch you have checked out**, and they keep
building it for as long as they exist. Check out `main` first unless the person
asked for something else. The script refuses a detached checkout and warns on
any other branch, because a trigger outlives the shell that made it.

### Before creating them, look at what is already there

```bash
gcloud builds triggers list --project=<PROJECT_ID> --region=<REGION> \
    --format="value(name,sourceToBuild.ref)"
```

Three things make existing triggers unusable, and all three are quiet:

- **a ref of `refs/heads/HEAD`** — created from a detached checkout. Every run
  fails with *"Couldn't read commit"*.
- **a ref naming a branch that no longer exists**, typically a merged feature
  branch.
- **triggers in a different region from the connection you need.** They cannot
  be moved; delete them and create them where the connection is.

In each case, delete and recreate rather than repair:

```bash
for t in bootstrap-platform teardown-platform test-environments run-sample-clients; do
  gcloud builds triggers delete "$t" --project=<PROJECT_ID> --region=<REGION> --quiet
done
```

**If triggers exist and are unusable, stop and say so before installing.** Go
ahead only when the person has said they want it anyway. A platform installed
around broken triggers works, and then quietly has no scheduled health check and
no console path for anyone else.

**Say this before running it:** the setup script grants **`roles/owner`** on the
project to the Compute Engine default service account. Both paths need that
grant, not only this one. Cloud Build runs
as that account, and the bootstrap drives Terraform across every resource in the
project. It is a broad grant and it persists — Terraform keeps the binding on
later applies. Anyone installing into a project they do not own outright should
know that before the command runs, not from the log afterwards.

**Direct submit:** the setup script does not run on this path, and it is what
makes the owner grant, creates the bucket `gs://<PROJECT_ID>-bootstrap-envs` and
uploads `.bootstrap_env` into it. Make those three preparations by hand first,
after saying the same thing about `roles/owner`:

```bash
gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="serviceAccount:<PROJECT_NUMBER>-compute@developer.gserviceaccount.com" \
  --role="roles/owner" --condition=None
gcloud storage buckets create gs://<PROJECT_ID>-bootstrap-envs \
  --location=<REGION> --uniform-bucket-level-access --project=<PROJECT_ID>
gcloud storage cp iac/bootstrapping/.bootstrap_env \
  gs://<PROJECT_ID>-bootstrap-envs/.bootstrap_env --project=<PROJECT_ID>
```

The safety check can block the IAM grant for you even after the person has
agreed. Hand that one command to the person then, as with the secrets cleanup.

```bash
gcloud builds submit . --config=iac/cloudbuild/bootstrap-platform.yaml \
  --project=<PROJECT_ID> --region=<REGION> --timeout=7200 --async \
  --substitutions=_BOOTSTRAP_ENV_GCS_PATH=gs://<PROJECT_ID>-bootstrap-envs/.bootstrap_env
```

Use `--async` for anything long: the build then has no dependency on your
session at all. Without it, `gcloud` stays attached streaming logs — the build
survives if that dies, but you lose the output.

Expect **45 to 60 minutes**.

## 6. Read the result

The bootstrap ends by submitting a **separate** health-check build. The summary
is therefore *not* in the bootstrap log — that log only prints a link to the
child build. Follow the link, or look in **Cloud Build → History**.

```
ENVIRONMENT                      PASS   WARN   FAIL
my-environment                     41      0      0
```

The number of checks depends on the platform: a `local` PKI install runs fewer,
because the DNS and certificate-authority checks do not apply. What matters is
that WARN and FAIL are zero, not the size of PASS.

**A red bootstrap build does not mean the bootstrap failed.** The health check
is step 2 of the same build, so its verdict colours the whole run. Read the end
of step 1 first: if it closes with `🎉 Nexus SDV platform bootstrapping
successfully completed! 🎉`, the platform is up and what failed is the
verification. Tell the person that before anything else — it is the difference
between a lost afternoon and a ten-minute fix.

The same counts go to a Cloud Monitoring dashboard named
**Platform health**, and a schedule repeats the check three times a day — **but only if the platform was installed on the trigger path.** The schedule pokes the Cloud Build trigger, and the trigger needs the repository connection, so a `gcloud builds submit` install has no trigger and therefore no recurring check. The bootstrap says so in passing (`CLOUDBUILD_REPO_RESOURCE is not set — skipping the platform-health-check trigger and its schedule`). Run it by hand, or connect the repository and re-run the trigger setup.

### If the FleetView login check fails

The deployment registers FleetView's address with Keycloak and then reads the
client back, so a build that succeeded has a sign-in that works. If the check
fails anyway, re-run `build-push-deploy-data-web-client.yaml` — the step is
idempotent and repairs the client.

If it comes back after that, something recreates the client after the
deployment. Collect the Keycloak pod log before changing anything further: it is
the only volatile evidence, and a restart destroys it.

**Do not stop at the numbers.** A green health check is the beginning of the
interesting part, not the end of the job. Offer to put a few more vehicles on
the platform and to open FleetView together — a platform with two vehicles
proves the path works, a platform with ten looks like a fleet. The procedure is
under *Putting more vehicles on the platform* in the `nexus-operate` skill.

## 7. Tearing down — confirm first

**Destructive and not reversible.** Name the environment and the project you are
about to destroy, and get an explicit yes before running it.

```bash
gcloud builds triggers run teardown-platform --region=<REGION> --project=<PROJECT_ID>
```

Two substitutions decide what survives:

| Substitution | Effect | Default in `teardown-platform` | Default in `test-environments` |
|---|---|---|---|
| `_PRESERVE_CAS` | `Y` keeps the CA pools, so the next environment reuses the same vehicle trust chain | `Y` — kept | `N` — **deleted** |
| `_PRESERVE_DNS` | `Y` keeps the Cloud DNS zone | `Y` — kept | `N` — **deleted** |

**The defaults differ on purpose.** A single teardown preserves, because
another environment in the same project may still be using the CA pools. The
multi-environment test run deletes, because it owns every environment it
creates and must leave the project clean.

A Cloud DNS zone can only be deleted by a teardown that created it — with
`EXISTING_DNS_ZONE` set, the zone is referenced rather than managed and is
never at risk.

Whenever a delegated DNS zone is involved, pass `_PRESERVE_DNS=Y` explicitly
unless the person has said the zone should go. Recreating it means arranging
delegation at the registrar again, which is outside the project and outside your
reach.

### Then check that it finished

A teardown reporting success is not the same as a project being clean. Run the
preflight afterwards and read it as the answer to *did that work*:

```bash
./iac/operating/nexus-preflight.sh <PROJECT_ID> --region <REGION> --pki <local|remote>
```

What a finished teardown looks like:

- **no cluster, database or BigTable instance** — if any is still listed, the
  teardown did not complete and the next bootstrap will trip over it
- **no leftover Terraform state** — a state left behind means the run was cut
  short, and the next bootstrap will plan to destroy what that state still
  describes
- **no leftover secrets** — the teardown removes the ones it created. A warning
  here is not routine: either the project was torn down by an older version, or
  the secret step did not finish. Offer to clear them, as described in step 1;
  a bootstrap reuses any secret that already has a version, private keys
  included

Two things survive on purpose and are not faults: **the Cloud Build triggers**,
because recreating them needs a browser sign-in, and **the DNS zone** where it
was referenced rather than created. The preflight does not flag either.

### Compare it with the one from the start

Hold this result against the one from step 1 and report the difference, not the
absolute state:

- **the same as before** — the project is as you found it. Say so plainly; that
  is the whole claim, and it is a stronger one than "the teardown went green".
- **something new is there** — your installation left it. Name it and offer to
  clear it.
- **something was already there at the start and still is** — not yours. Mention
  it once so nobody hunts for it, and leave it alone unless asked.

Tell the person what the comparison showed, in one line, rather than reporting
that the build went green. This week a teardown reported success while leaving
behind a Terraform state and a set of hostname secrets, and the next installation
failed two layers away from the cause.

## Testing several environments in sequence

`test-environments` bootstraps and tears down every `.bootstrap_env` file in the
bucket, one after another. `_BOOTSTRAP_ENVS_DIR` is **required** — without it the
build stops in its first seconds.

```bash
gcloud builds submit . --config=iac/cloudbuild/test-environments.yaml \
  --project=<PROJECT_ID> --region=<REGION> --timeout=86400 --async \
  --substitutions=_BOOTSTRAP_ENVS_DIR=gs://<PROJECT_ID>-bootstrap-envs/,_PRESERVE_DNS=Y,_PRESERVE_CAS=N
```

Everything lying in that bucket is processed, so move files you are not testing
into a subfolder — subfolders are skipped.

`_PRESERVE_DNS=Y` above is belt and braces: it matters only when the
environments create their own zone, and costs nothing when they reference an
existing one.

## Rules

- Read-only first, always: preflight before anything that creates.
- **Work in the repository as you found it.** Do not create branches, switch
  branches, commit or push to get the install going. The triggers are created
  from the checked-out branch, so if it is the wrong one, say so and ask — a
  branch switch changes what gets deployed.
- **Ask before the first thing that creates, costs or destroys**, and say what
  it will be. Everything up to and including the preflight is free and
  reversible; nothing after it is.
- Never bootstrap or tear down a project the preflight refuses.
- State what you are about to create or destroy, in which project, before doing
  it.
- If a step fails, read the build log before retrying. Most failures here are
  configuration, and a second identical run reproduces them exactly.
- Do not print secrets, certificates or keys into the conversation.

## Where the detail lives

This skill is the procedure. The reference is the documentation: *Cloud-native
Deployment* for the configuration keys and the flow, *Platform Deployment* for
the script-driven alternative, and *Security Architecture* for the trust chain
and the credential lifetimes.
