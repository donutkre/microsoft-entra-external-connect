# Microsoft Entra External ID (post-May 2025)

> Live demo of customer identity in the **new** Microsoft Entra External ID.
> This is what replaced **Azure AD B2C** for new tenants after **1 May 2025**.

End-to-end demo: an external tenant with sign-up + sign-in flow, plus an ASP.NET Core MVC app that signs customers in, displays their ID-token claims, and signs them out.

This folder contains **everything** you need:

```
Identity/
├── README.md                       ← you are here
└── setup-external-id-demo.sh       ← one script that provisions Azure + scaffolds the app
```

---

## 📖 Background — what changed in May 2025

### The history

| Year | What it was called | Notes |
|---|---|---|
| 2014–2024 | **Azure AD B2C** | A separate Azure resource. Custom policies in XML. Different login URL (`b2clogin.com`). Different SDK pattern. |
| Sept 2023 | **Microsoft Entra External ID** announced | The new product. Built on the same identity platform as workforce Entra ID. |
| **1 May 2025** | **B2C deprecated for new tenants** | You can no longer create new Azure AD B2C tenants. Existing B2C tenants keep working until **2030**. |
| Today | **External ID is the only customer-identity option for new tenants** | Tenant type `CIAM`. Login URL `*.ciamlogin.com`. Standard `Microsoft.Identity.Web` library. |

### What this means for new projects

| | Old Azure AD B2C | New Entra External ID |
|---|---|---|
| Tenant type | B2C | **CIAM** |
| Login authority host | `<tenant>.b2clogin.com` | `<tenant>.ciamlogin.com` |
| User flows | Built-in flows + custom XML policies | **`authenticationEventsFlows`** Graph API |
| Library | `Microsoft.Identity.Web` (with B2C-specific config) | **`Microsoft.Identity.Web`** (standard config) |
| Code path | Mostly the same | Mostly the same |
| Pricing | Per-MAU | Per-MAU (but model differs) |
| Multifactor | Built-in but limited | Built-in, full Entra ID feature parity |
| Conditional Access | Limited | **Full Conditional Access** ✓ |

### The "only difference" code-wise

For a developer, the only line that changes between workforce Entra and External ID is the **`Instance`** in `appsettings.json`:

```json
// Workforce Entra ID
"Instance": "https://login.microsoftonline.com/"

// Microsoft Entra External ID
"Instance": "https://Demob2caz204.ciamlogin.com/"
```

Same `Microsoft.Identity.Web`, same `AddMicrosoftIdentityWebApp`, same OIDC flow. The host changes. That's it.

"If you know how to wire MSAL for workforce, you know how to wire it for External ID. Just point it at `ciamlogin.com`."

---

## ✅ Prerequisites

### Tools

| Tool | Install | Verify |
|---|---|---|
| **Azure CLI** | `brew install azure-cli` (macOS) / `winget install Microsoft.AzureCLI` (Win) | `az --version` |
| **.NET SDK 8 or 9** | https://dotnet.microsoft.com/download | `dotnet --version` |
| **jq** (script only) | `brew install jq` / `apt install jq` / `choco install jq` | `jq --version` |

### An External ID tenant (post-May 2025)

You need a **Microsoft Entra External ID tenant** (tenant type `CIAM`).

How to create one:

1. Go to https://entra.microsoft.com → **Manage tenants** (top-right) → **+ Create**
2. Pick **External** as the tenant type (NOT "Workforce")
3. Fill in:
   - Tenant name: e.g. `Demob2caz204`
   - Initial domain name: e.g. `Demob2caz204.onmicrosoft.com`
   - Country: any
4. Wait ~2 min for provisioning
5. Switch to the new tenant via the directory picker

> ⚠ If you see "B2C" as an option, don't pick it — that's the old product, deprecated for new tenants.

### Permissions in the External ID tenant

Your account must have **at least ONE** of these Entra roles:

- ✅ **Global Administrator** (covers everything — easiest for a demo)
- ✅ **Application Administrator** + **External Identity User Flow Administrator** (least-privilege option)

Check at `entra.microsoft.com` → Roles & administrators.

### Sign in via CLI

You have two options:

**Option 1: Sign in first, then run the script**

```bash
az login --tenant <YOUR-TENANT>.onmicrosoft.com --allow-no-subscriptions
./setup-external-id-demo.sh
```

**Option 2: Just run the script — it handles login interactively**

```bash
./setup-external-id-demo.sh
```

The script will detect if you're not signed in, kick off `az login`, and (if the active tenant isn't CIAM) prompt you to enter the right tenant ID/domain and switch automatically.

The `--allow-no-subscriptions` flag matters because **External ID tenants don't have Azure subscriptions** attached by default. Identity is tenant-level, not subscription-level.

---

## 🎯 What gets created

After you run the script (or follow the portal walkthrough), the following exists in your External ID tenant:

| # | Resource | Name | Purpose |
|---|---|---|---|
| 1 | **App registration** | `AZ204-ExternalID-Demo` | The customer-facing app's identity in your tenant |
| 2 | **Service principal** | (auto-created with #1) | The runtime instance of the app reg |
| 3 | **Client secret** | `az204-demo-secret` (1 yr) | Stored in `dotnet user-secrets` — **never in any file** |
| 4 | **Graph delegated permissions** | `User.Read`, `openid`, `profile`, `offline_access` | What the app can do as the signed-in user |
| 5 | **User flow** | `AZ204SignUpSignIn` | Email + password sign-up + sign-in |
| 6 | **App ↔ flow link** | (the magic that makes signup link appear) | Without this link, no "Create one" button |

Plus the C# project at `ExternalIdDemo/` with everything wired up.

---

## 🖱 OPTION A — Portal walkthrough (click-by-click)

Open https://entra.microsoft.com → **switch tenant** (top-right) → pick your External ID tenant.

### Step 1 — Create the app registration

`Identity → Applications → App registrations → + New registration`

| Field | Value |
|---|---|
| Name | `AZ204-ExternalID-Demo` |
| Supported account types | **Accounts in this organizational directory only** (single tenant) |
| Redirect URI (Web) | `https://localhost:7273/signin-oidc` |

Click **Register**.

→ On the **Overview** blade, copy:
- **Application (client) ID** → keep this as `<APP-ID>`
- **Directory (tenant) ID** → keep this as `<TENANT-ID>`

---

### Step 2 — Authentication blade (logout URL + ID token)

App reg → **Authentication** (left nav)

- **Front-channel logout URL:** `https://localhost:7273/signout-oidc`
- Under **Implicit grant and hybrid flows** → tick **ID tokens (used for implicit and hybrid flows)**
- Click **Save**

> The front-channel logout URL is what External ID redirects the user to after they click "Sign out" — it lets the app clear its own session.

---

### Step 3 — API permissions + admin consent

App reg → **API permissions → + Add a permission → Microsoft Graph → Delegated permissions**

Tick all four:
- `User.Read` — read the signed-in user's basic profile
- `openid` — required for OIDC
- `profile` — basic profile claims (name, etc.)
- `offline_access` — issue refresh tokens

Click **Add permissions**.

Then click **Grant admin consent for <tenant> → Yes**.

→ All four should show green ✓ "Granted for <tenant>".

> Without admin consent, every customer who signs in would see a consent prompt asking them to approve these permissions. With admin consent, it's silent.

---

### Step 4 — Client secret

App reg → **Certificates & secrets → + New client secret**

| Field | Value |
|---|---|
| Description | `az204-demo-secret` |
| Expires | 6 months (or whatever) |

Click **Add**.

⚠ **Copy the Value column immediately** → keep this as `<SECRET>`. You can never see it again.

---

### Step 5 — Create the user flow

Left nav → **External Identities → User flows → + New user flow**

| Field | Value |
|---|---|
| Name | `AZ204SignUpSignIn` |
| Identity providers | **Email with password** ✓ |
| User attributes (collected at sign-up) | Tick **Display Name** (Email is auto-included) |

Click **Create**.

> A user flow defines *how* customers sign up and sign in. You can add other identity providers (Google, Facebook, custom OIDC) here. For the demo, email + password is enough.

---

### Step 6 — Link app to user flow ⚠ critical

Open the new user flow → **Applications** (left nav) → **+ Add application**

Tick **AZ204-ExternalID-Demo** → **Select**.

> Without this link, the **"No account? Create one"** sign-up link never appears at sign-in. **This is the most common mistake.** The app falls back to default Entra sign-in (which only allows existing users to sign in, no signup).

---

## 🤖 OPTION B — One script does it all

Use this for fast re-runs (e.g. each new class session). Takes ~60 seconds.

```bash
chmod +x setup-external-id-demo.sh
./setup-external-id-demo.sh
```

The script provisions everything in steps 1–6 above, plus scaffolds the C# app (Option C below) end-to-end. Output is colored.

### Interactive prompts (default)

When you run the script, it asks you for:

1. **Tenant** — if your active `az` tenant isn't CIAM, the script lists all tenants you have access to and asks which one to switch to. Then it runs `az login --tenant <chosen> --allow-no-subscriptions` for you and re-validates.
2. **App registration name** (default `AZ204-ExternalID-Demo`)
3. **User flow name** (default `AZ204SignUpSignIn`)
4. **C# project folder** (default `ExternalIdDemo`)
5. **HTTPS port** (default `7273`)

Press **Enter** at any prompt to keep the default.

### Tweakable env vars (optional — skip prompts)

Set any of these BEFORE running the script to skip the matching prompt:

| Variable | Default | When to set |
|---|---|---|
| `TENANT` | (current `az` tenant) | Pre-select tenant by ID/domain — script will `az login --tenant <value>` automatically |
| `APP_NAME` | `AZ204-ExternalID-Demo` | Multiple parallel demos |
| `FLOW_NAME` | `AZ204SignUpSignIn` | Same |
| `PORT` | `7273` | Port 7273 in use |
| `PROJECT_DIR` | `ExternalIdDemo` | Folder name conflict |
| `SCAFFOLD_DOTNET` | `yes` | Set to `no` for Azure-only (skip C# scaffold) |
| `RESET` | `yes` | Set to `no` to keep existing resources |
| `INTERACTIVE` | `yes` | Set to `no` to skip ALL prompts (CI / scripted runs) |

Examples:

```bash
# Pre-pick everything for a non-interactive run
TENANT="myext.onmicrosoft.com" APP_NAME="MyDemo" PORT=8443 INTERACTIVE=no ./setup-external-id-demo.sh

# Just rename the app
APP_NAME="ContosoLogin" ./setup-external-id-demo.sh

# Skip the C# scaffold (Azure resources only)
SCAFFOLD_DOTNET=no ./setup-external-id-demo.sh
```

### What the script does (in order)

```
STEP 0  — Preflight checks (CLI tools)
STEP 0a — Tenant selection (auto-detect / az login / verify CIAM)
STEP 0b — Interactive naming prompts (skippable via INTERACTIVE=no)
STEP 1  — Tear down existing resources with the same names (if RESET=yes)
STEP 2  — Create app registration with redirect URI + ID token enabled
STEP 3 — Create service principal
STEP 4 — Add Graph delegated permissions + grant admin consent
STEP 5 — Generate client secret
STEP 6 — Create user flow with email+password + signup enabled
STEP 7 — Link app registration to user flow ⚠ (the magic)
STEP 8 — Scaffold C# project + write Program.cs / appsettings.json / view
```

Idempotent: re-runs cleanly. Good for "I screwed up, let me start over."

---

## 💻 OPTION C — Scaffold C# manually

Use this when you've done the portal walkthrough yourself and want to see the C# part typed out.

In this folder:

```bash
cd /Users/Dir/Source/Identity
```
```bash
dotnet new mvc --auth SingleOrg -o ExternalIdDemo --name ExternalIdDemo --client-id <APP-ID> --tenant-id <TENANT-ID> --domain <YOURTENANT>.onmicrosoft.com
```
```bash
cd ExternalIdDemo
```
```bash
dotnet user-secrets init
```
```bash
dotnet user-secrets set "AzureAd:ClientSecret" "<SECRET>"
```

> ⚠ Run **one line at a time**. Multi-line `\` continuations break in zsh when blank lines slip in.

### Edit `appsettings.json`

The template's default `Instance` points at workforce Entra. Change it to External ID:

```json
{
  "AzureAd": {
    "Instance": "https://<YOURTENANT>.ciamlogin.com/",
    "Domain": "<YOURTENANT>.onmicrosoft.com",
    "TenantId": "<TENANT-ID>",
    "ClientId": "<APP-ID>",
    "CallbackPath": "/signin-oidc",
    "SignedOutCallbackPath": "/signout-oidc"
  },
  "Logging": { "LogLevel": { "Default": "Information", "Microsoft.AspNetCore": "Warning" } },
  "AllowedHosts": "*"
}
```

### Edit `Properties/launchSettings.json`

Pin the HTTPS port to 7273 (must match the redirect URI):

```json
"applicationUrl": "https://localhost:7273;http://localhost:5073",
```

### Edit `Program.cs`

The .NET 9 template ships **without** `app.UseAuthentication()`. Add it before `UseAuthorization()`:

```csharp
app.UseRouting();
app.UseAuthentication();   // ← add this
app.UseAuthorization();
```

### (Optional) Replace `Views/Home/Index.cshtml` — claims dump

Lets *see* what's in the ID token:

```cshtml
@{ ViewData["Title"] = "Home Page"; }
<div class="text-center">
  <h1 class="display-4">External ID</h1>
  <p class="lead">Signed in via <strong>Microsoft Entra External ID</strong>.</p>
</div>
<hr/>
<h3>Identity</h3>
<dl class="row">
  <dt class="col-sm-3">Name</dt><dd class="col-sm-9">@User.Identity?.Name</dd>
  <dt class="col-sm-3">Authenticated</dt><dd class="col-sm-9">@User.Identity?.IsAuthenticated</dd>
</dl>
<h3>Claims (what's inside your ID token)</h3>
<table class="table table-sm table-striped">
  <thead><tr><th>Type</th><th>Value</th></tr></thead>
  <tbody>
  @foreach (var c in User.Claims) { <tr><td><code>@c.Type</code></td><td>@c.Value</td></tr> }
  </tbody>
</table>
```

---

## 🚀 Run the app

```bash
cd /Users/Dir/Source/Identity/ExternalIdDemo
dotnet run --launch-profile https
```

Open https://localhost:7273 → redirected to External ID → click **No account? Create one** → enter real email → enter OTP from your inbox → set password → set Display Name → land on home page showing all your ID-token claims.

### Killing the app (port stuck)

If you close the terminal but the app keeps running on port 7273:

```bash
kill -9 $(lsof -t -nP -iTCP:7273 -sTCP:LISTEN)
```

---

## 🎓 What `--auth SingleOrg` gives you for free (talking points)

| Thing | Where |
|---|---|
| `Microsoft.Identity.Web` + `Microsoft.Identity.Web.UI` NuGet packages | `.csproj` |
| `AddMicrosoftIdentityWebApp(...)` — wires the OIDC pipeline in 1 line | `Program.cs` |
| Global `[Authorize]` filter so every page requires sign-in | `Program.cs` |
| Sign in / Sign out nav menu | `Views/Shared/_LoginPartial.cshtml` |

**You write only the config** — the auth code is already there. That's the lesson.

---

## ⚠️ Common errors

| Symptom | Cause | Fix |
|---|---|---|
| **No "Create one" sign-up link** at sign-in | App not linked to user flow (Step 6) | Re-link in portal: User flow → Applications → Add |
| Stuck on `login.microsoftonline.com` (workforce screen) | Forgot to change `Instance` to `ciamlogin.com` | Edit `appsettings.json` |
| `AADSTS50011: redirect URI mismatch` | Port in `launchSettings.json` ≠ port in app reg redirect URI | Align both to 7273 |
| `IDX10501: Signature validation failed` | Wrong `TenantId` or `Instance` | Re-check `appsettings.json` |
| Sign-in completes but claims are empty | Forgot `app.UseAuthentication()` | Add it before `UseAuthorization()` |
| **OTP never arrives** | Email typo or in spam folder | Try a known-good email; check spam |
| `Insufficient privileges to complete the operation` | Account lacks Application Administrator role | Use Global Admin, or grant App Admin role |
| `tenantType is 'AAD'` warning | Logged into workforce tenant by mistake | Re-login: `az login --tenant <ext-tenant>` |
| `port 7273: address already in use` | Old `dotnet run` still alive | `kill -9 $(lsof -t -nP -iTCP:7273 -sTCP:LISTEN)` |
| `dotnet new` fails: "package not found" | Old .NET SDK | Upgrade to .NET 8+ |

---

## 🧹 Tear down (after class)

The script prints these at the end. To wipe everything:

```bash
# Replace with the appId + flowId from the script's output
az ad app delete --id <APP-ID>
az rest --method DELETE --url "https://graph.microsoft.com/beta/identity/authenticationEventsFlows/<FLOW-ID>"
```

To find the flow ID if you forgot:

```bash
az rest --method GET \
  --url "https://graph.microsoft.com/beta/identity/authenticationEventsFlows" \
  --query "value[?displayName=='AZ204SignUpSignIn'].id" -o tsv
```

To clean up the local C# project + secrets:

```bash
rm -rf ExternalIdDemo
# user-secrets are stored at ~/.microsoft/usersecrets/<id>/secrets.json
# safe to leave (not in repo) or remove with `dotnet user-secrets clear`
```

---

> **"External ID = a separate tenant for *customers*. Workforce Entra = the same Entra you use for employees. Don't mix them.**
>
> **`ciamlogin.com` ≠ `login.microsoftonline.com`** — different host, **same library**, same code.
>
> **The user flow is what makes signup work.** No flow link = no signup link. Period.
>
> **B2C is dead for new tenants.** If you've worked with B2C before, External ID is the cleaner re-think — same goals, simpler model, full Conditional Access support, and standard `Microsoft.Identity.Web` instead of B2C-specific config."

---

## 📚 Further reading

- Microsoft docs: https://learn.microsoft.com/en-us/entra/external-id/customers/overview-customers-ciam
- B2C → External ID transition: https://learn.microsoft.com/en-us/entra/external-id/customers/concept-supported-features-customers
- `Microsoft.Identity.Web` library: https://github.com/AzureAD/microsoft-identity-web

---

## 📁 What this folder will contain after you run the script

```
Identity/
├── README.md
├── Identity.sln
├── setup-external-id-demo.sh
└── ExternalIdDemo/
    ├── ExternalIdDemo.csproj
    ├── Program.cs                          ← MSAL wiring + UseAuthentication()
    ├── appsettings.json                    ← ciamlogin.com authority + tenant IDs
    ├── Properties/
    │   └── launchSettings.json             ← port 7273
    ├── Controllers/
    │   └── HomeController.cs
    ├── Views/
    │   ├── Home/Index.cshtml               ← claims dump
    │   ├── Shared/_Layout.cshtml
    │   ├── Shared/_LoginPartial.cshtml     ← Sign in / Sign out menu
    │   └── ...
    └── ... (standard MVC scaffold)
```

The client secret lives in `~/.microsoft/usersecrets/<id>/secrets.json` — outside the project, outside git. You can move/share the project safely without leaking the secret.
