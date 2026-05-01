#!/usr/bin/env bash
# Microsoft Entra External ID demo provisioner (FRESH-RUN MODE)
#
# Each run:
#   1. Tears down any existing demo resources with the same names
#   2. Creates everything brand new (app reg, SP, perms, secret, user flow, link)
#   3. Re-scaffolds the C# app with the new app's IDs and secret
#
#
# Usage:
#   az login --tenant <YOUR_EXTERNAL_TENANT> --allow-no-subscriptions
#   ./setup-external-id-demo.sh
#
# Skip the C# scaffold:   SCAFFOLD_DOTNET=no ./setup-external-id-demo.sh
# Keep existing (no wipe):  RESET=no ./setup-external-id-demo.sh

set -euo pipefail

# ── tweakables (defaults — overridable by env var or interactive prompt) ─────
APP_NAME="${APP_NAME:-AZ204-ExternalID-Demo}"
FLOW_NAME="${FLOW_NAME:-AZ204SignUpSignIn}"
PORT="${PORT:-7273}"
PROJECT_DIR="${PROJECT_DIR:-ExternalIdDemo}"
SCAFFOLD_DOTNET="${SCAFFOLD_DOTNET:-yes}"
RESET="${RESET:-yes}"
INTERACTIVE="${INTERACTIVE:-yes}"   # set to "no" to skip prompts (CI / re-runs)
TENANT="${TENANT:-}"                # pre-set tenant ID/domain to skip tenant prompt

MSGRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
SCOPE_USER_READ="e1fe6dd8-ba31-4d61-89e7-88639da4683d"
SCOPE_OFFLINE="7427e0e9-2fba-42fe-b0c0-848c9e6a8182"
SCOPE_OPENID="37f7f235-527c-4136-accd-4a02d197296e"
SCOPE_PROFILE="14dad69e-099b-42c9-810b-d002981feec1"

# REDIRECT_URI/LOGOUT_URI are computed AFTER prompts (PORT may change)

# ── output helpers ───────────────────────────────────────────────────────────
c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_red=$'\033[1;31m'
c_cyan=$'\033[1;36m'; c_blu=$'\033[1;34m'; c_mag=$'\033[1;35m'
c_dim=$'\033[2m'; c_bold=$'\033[1m'; c_off=$'\033[0m'

step()  { printf "\n%s┌─ STEP %s ─ %s%s\n" "$c_cyan" "$1" "$2" "$c_off"; }
info()  { printf "%s   ▸%s %s\n" "$c_blu" "$c_off" "$*"; }
note()  { printf "%s   ⓘ %s%s\n" "$c_dim" "$*" "$c_off"; }
ok()    { printf "%s   ✓%s %s\n" "$c_grn" "$c_off" "$*"; }
warn()  { printf "%s   ⚠ %s%s\n" "$c_yel" "$*"  "$c_off"; }
err()   { printf "%s   ✗ %s%s\n" "$c_red" "$*"  "$c_off"; }
die()   { err "$*"; exit 1; }
banner(){ printf "\n%s%s%s\n" "$c_mag" "$1" "$c_off"; }

# ── preflight ────────────────────────────────────────────────────────────────
banner "════════════════════════════════════════════════════════════════"
banner "  Microsoft Entra External ID · LIVE DEMO PROVISIONER"
banner "════════════════════════════════════════════════════════════════"

step "0" "Preflight checks"
command -v az >/dev/null     || die "az CLI not installed"
command -v jq >/dev/null     || die "jq not installed (brew install jq)"
[[ "$SCAFFOLD_DOTNET" == "yes" ]] && { command -v dotnet >/dev/null || die "dotnet SDK not installed"; }
ok "az, jq$([[ $SCAFFOLD_DOTNET == yes ]] && echo ', dotnet') present"

# Helper: validate the currently-active tenant is CIAM and capture domain
verify_ciam_tenant() {
  local t_type t_domain
  t_type=$(az rest --method GET --url "https://graph.microsoft.com/v1.0/organization" --query "value[0].tenantType" -o tsv 2>/dev/null || echo "")
  t_domain=$(az rest --method GET --url "https://graph.microsoft.com/v1.0/organization" --query "value[0].verifiedDomains[0].name" -o tsv 2>/dev/null || echo "")
  TENANT_TYPE="$t_type"
  TENANT_DOMAIN="$t_domain"
  [[ "$t_type" == "CIAM" ]]
}

# ── Tenant selection / login ─────────────────────────────────────────────────
step "0a" "Choose External ID tenant (CIAM required)"

ACCT_JSON=$(az account show -o json 2>/dev/null || echo "")
if [[ -z "$ACCT_JSON" ]]; then
  info "Not logged in — starting interactive az login…"
  az login --allow-no-subscriptions >/dev/null
  ACCT_JSON=$(az account show -o json)
fi

TENANT_ID=$(jq -r '.tenantId' <<<"$ACCT_JSON")
USER_NAME=$(jq -r '.user.name' <<<"$ACCT_JSON")
ok "Signed in as: $USER_NAME"
ok "Currently active tenant: $TENANT_ID"

# Pre-supplied tenant via env var → switch unconditionally
if [[ -n "$TENANT" && "$TENANT" != "$TENANT_ID" ]]; then
  info "Switching to tenant $TENANT (from \$TENANT env var)…"
  az login --tenant "$TENANT" --allow-no-subscriptions >/dev/null
  TENANT_ID=$(az account show --query tenantId -o tsv)
  ok "Now on: $TENANT_ID"
fi

# Validate it's CIAM. If not, offer to switch.
if ! verify_ciam_tenant; then
  warn "Current tenant is type '$TENANT_TYPE' — NOT CIAM. External ID flows won't work here."
  if [[ "$INTERACTIVE" == "yes" ]]; then
    echo ""
    info "Tenants you can sign into:"
    az account tenant list --query "[].tenantId" -o tsv 2>/dev/null | nl -ba -w2 -s'  '
    echo ""
    read -rp "Enter the CIAM tenant ID or domain (e.g. yourtenant.onmicrosoft.com): " TARGET
    [[ -z "$TARGET" ]] && die "no tenant chosen"
    info "Running: az login --tenant $TARGET --allow-no-subscriptions"
    az login --tenant "$TARGET" --allow-no-subscriptions >/dev/null
    TENANT_ID=$(az account show --query tenantId -o tsv)
    if ! verify_ciam_tenant; then
      die "Tenant $TENANT_ID is type '$TENANT_TYPE' — still not CIAM. Aborting."
    fi
  else
    die "INTERACTIVE=no and current tenant isn't CIAM. Set TENANT=<your-ext-tenant> or run interactively."
  fi
fi
ok "Confirmed CIAM tenant"
ok "Tenant ID:     $TENANT_ID"
ok "Tenant domain: $TENANT_DOMAIN"

CIAM_HOST="${TENANT_DOMAIN%.onmicrosoft.com}.ciamlogin.com"
note "External ID authority will be: https://${CIAM_HOST}/"

# ── Interactive naming (press Enter to keep defaults) ────────────────────────
if [[ "$INTERACTIVE" == "yes" && -t 0 ]]; then
  step "0b" "Pick names (press Enter for defaults)"
  read -rp "  App registration name [$APP_NAME]: " in_app;  APP_NAME="${in_app:-$APP_NAME}"
  read -rp "  User flow name        [$FLOW_NAME]: " in_flow; FLOW_NAME="${in_flow:-$FLOW_NAME}"
  read -rp "  C# project folder     [$PROJECT_DIR]: " in_proj; PROJECT_DIR="${in_proj:-$PROJECT_DIR}"
  read -rp "  HTTPS port            [$PORT]: " in_port; PORT="${in_port:-$PORT}"
  ok "Will use:"
  ok "  App name:    $APP_NAME"
  ok "  Flow name:   $FLOW_NAME"
  ok "  Project dir: $PROJECT_DIR"
  ok "  Port:        $PORT"
fi

# Compute URIs now that PORT is final
REDIRECT_URI="https://localhost:${PORT}/signin-oidc"
LOGOUT_URI="https://localhost:${PORT}/signout-oidc"

# ── teardown phase ───────────────────────────────────────────────────────────
if [[ "$RESET" == "yes" ]]; then
  step "1" "Tear down any existing demo resources"

  EXISTING_APPS=$(az ad app list --display-name "$APP_NAME" --query "[].appId" -o tsv)
  if [[ -n "$EXISTING_APPS" ]]; then
    for OLD_APP in $EXISTING_APPS; do
      info "Found existing app reg '$APP_NAME' ($OLD_APP) — deleting"
      az ad app delete --id "$OLD_APP" 2>/dev/null && ok "Deleted app reg $OLD_APP"
    done
  else
    note "No existing app reg with name '$APP_NAME'"
  fi

  EXISTING_FLOWS=$(az rest --method GET --url "https://graph.microsoft.com/beta/identity/authenticationEventsFlows" --query "value[?displayName=='$FLOW_NAME'].id" -o tsv 2>/dev/null || echo "")
  if [[ -n "$EXISTING_FLOWS" ]]; then
    for OLD_FLOW in $EXISTING_FLOWS; do
      info "Found existing user flow '$FLOW_NAME' ($OLD_FLOW) — deleting"
      az rest --method DELETE --url "https://graph.microsoft.com/beta/identity/authenticationEventsFlows/$OLD_FLOW" 2>/dev/null && ok "Deleted user flow $OLD_FLOW"
    done
  else
    note "No existing user flow with name '$FLOW_NAME'"
  fi

  if [[ "$SCAFFOLD_DOTNET" == "yes" && -d "$PROJECT_DIR" ]]; then
    info "Removing existing project dir '$PROJECT_DIR'"
    rm -rf "$PROJECT_DIR"
    ok "Cleaned project dir"
  fi
else
  note "RESET=no — skipping teardown, will reuse anything that exists"
fi

# ── 2. app registration ──────────────────────────────────────────────────────
step "2" "Create app registration  (the customer-facing identity for our app)"
info "Display name:    $APP_NAME"
info "Audience:        AzureADMyOrg  (this External ID tenant only)"
info "Redirect URI:    $REDIRECT_URI"
info "Sign-out URI:    $LOGOUT_URI"
note "Audience='AzureADMyOrg' is correct for External ID — customers sign UP into THIS tenant."

APP_ID=$(az ad app create \
  --display-name "$APP_NAME" \
  --sign-in-audience "AzureADMyOrg" \
  --web-redirect-uris "$REDIRECT_URI" \
  --enable-id-token-issuance true \
  --enable-access-token-issuance false \
  --query "appId" -o tsv)
OBJ_ID=$(az ad app show --id "$APP_ID" --query "id" -o tsv)
ok "App created — appId: $APP_ID"
ok "                  objectId: $OBJ_ID"

info "Patching app to add front-channel logout URL (no CLI flag for this — Graph PATCH)"
az rest --method PATCH \
  --url "https://graph.microsoft.com/v1.0/applications/$OBJ_ID" \
  --headers "Content-Type=application/json" \
  --body "{\"web\":{\"logoutUrl\":\"$LOGOUT_URI\",\"redirectUris\":[\"$REDIRECT_URI\"],\"implicitGrantSettings\":{\"enableIdTokenIssuance\":true,\"enableAccessTokenIssuance\":false}}}" >/dev/null
ok "Logout URL set"

# ── 3. service principal ─────────────────────────────────────────────────────
step "3" "Create service principal  (the runtime identity bound to the app reg)"
note "App reg = blueprint. Service principal = the live identity in this tenant."
SP_ID=$(az ad sp create --id "$APP_ID" --query "id" -o tsv)
ok "Service principal created — objectId: $SP_ID"

# ── 4. graph permissions + admin consent ─────────────────────────────────────
step "4" "Add Microsoft Graph delegated permissions  (what the app can do AS the user)"
info "Adding scopes:"
info "  • User.Read         — read signed-in user's profile from /me"
info "  • openid            — needed for OIDC sign-in"
info "  • profile           — basic profile claims (name, etc.)"
info "  • offline_access    — issue refresh tokens"
az ad app permission add --id "$APP_ID" --api "$MSGRAPH_APP_ID" --api-permissions \
  "$SCOPE_USER_READ=Scope" \
  "$SCOPE_OFFLINE=Scope" \
  "$SCOPE_OPENID=Scope" \
  "$SCOPE_PROFILE=Scope" 2>/dev/null || true
ok "Permissions added"

info "Waiting 5s for SP to propagate before consent…"
sleep 5
info "Granting admin consent (so users don't see a consent prompt at sign-in)"
az ad app permission admin-consent --id "$APP_ID" 2>/dev/null || warn "consent grant warned — verifying…"
GRANTED=$(az rest --method GET --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$SP_ID'" --query "value[0].scope" -o tsv)
ok "Admin consent granted: $GRANTED"

# ── 5. client secret ─────────────────────────────────────────────────────────
step "5" "Generate client secret  (the app's password to prove its identity to Entra)"
SECRET_VALUE=$(az ad app credential reset --id "$APP_ID" --display-name "az204-demo-secret" --years 1 --query "password" -o tsv 2>/dev/null)
ok "Secret created (length ${#SECRET_VALUE}, expires in 1 year)"
note "Will be stored in dotnet user-secrets — never written to a file in the repo."

# ── 6. user flow ─────────────────────────────────────────────────────────────
step "6" "Create user flow  (defines HOW customers sign up & sign in)"
info "Identity provider:  Email + Password (built-in)"
info "Sign-up:             enabled (customers can self-register)"
info "Attributes collected: Email, Display Name"

FLOW_BODY=$(cat <<'JSON'
{
  "@odata.type": "#microsoft.graph.externalUsersSelfServiceSignUpEventsFlow",
  "displayName": "__FLOW_NAME__",
  "onAuthenticationMethodLoadStart": {
    "@odata.type": "#microsoft.graph.onAuthenticationMethodLoadStartExternalUsersSelfServiceSignUp",
    "identityProviders": [ { "id": "EmailPassword-OAUTH" } ]
  },
  "onInteractiveAuthFlowStart": {
    "@odata.type": "#microsoft.graph.onInteractiveAuthFlowStartExternalUsersSelfServiceSignUp",
    "isSignUpAllowed": true
  },
  "onAttributeCollection": {
    "@odata.type": "#microsoft.graph.onAttributeCollectionExternalUsersSelfServiceSignUp",
    "attributes": [ { "id": "email" }, { "id": "displayName" } ],
    "attributeCollectionPage": { "views": [ { "title": "", "description": "", "inputs": [
      { "attribute": "email",       "label": "Email Address", "inputType": "text", "defaultValue": "", "hidden": true,  "editable": false, "writeToDirectory": true, "required": true, "validationRegEx": "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", "options": [] },
      { "attribute": "displayName", "label": "Display Name",  "inputType": "text", "defaultValue": "", "hidden": false, "editable": true,  "writeToDirectory": true, "required": true, "validationRegEx": "^.*", "options": [] }
    ] } ] }
  }
}
JSON
)
FLOW_BODY="${FLOW_BODY//__FLOW_NAME__/$FLOW_NAME}"
TMP_FLOW=$(mktemp); echo "$FLOW_BODY" >"$TMP_FLOW"
FLOW_ID=$(az rest --method POST --url "https://graph.microsoft.com/beta/identity/authenticationEventsFlows" --headers "Content-Type=application/json" --body @"$TMP_FLOW" --query "id" -o tsv)
rm -f "$TMP_FLOW"
ok "User flow created — id: $FLOW_ID"

# ── 7. associate app ↔ user flow ─────────────────────────────────────────────
step "7" "Link app registration to user flow  (so this app uses this flow at sign-in)"
note "Without this link, the app falls back to default Entra sign-in (no signup link!)."
note "Gotcha: drop the type cast from the path — with it, new External ID tenants"
note "        misroute to legacy CPIM backend and 404."
az rest --method POST \
  --url "https://graph.microsoft.com/beta/identity/authenticationEventsFlows/$FLOW_ID/conditions/applications/includeApplications" \
  --headers "Content-Type=application/json" \
  --body "{\"appId\":\"$APP_ID\"}" >/dev/null
ok "App linked to user flow"

# ── 8. C# scaffold ───────────────────────────────────────────────────────────
if [[ "$SCAFFOLD_DOTNET" == "yes" ]]; then
  step "8" "Scaffold ASP.NET Core MVC app with Microsoft.Identity.Web"

  if [[ -d "$PROJECT_DIR" ]]; then
    note "Project dir exists (RESET=no?) — keeping it, just updating settings"
  else
    info "Running: dotnet new mvc --auth SingleOrg → $PROJECT_DIR"
    dotnet new mvc --auth SingleOrg \
      --output "$PROJECT_DIR" --name "$PROJECT_DIR" \
      --client-id "$APP_ID" --tenant-id "$TENANT_ID" --domain "$TENANT_DOMAIN" \
      --calls-graph false --no-https false >/dev/null
    ok "Project scaffolded"
  fi

  info "Storing client secret in dotnet user-secrets (never in appsettings.json)"
  ( cd "$PROJECT_DIR" \
    && dotnet user-secrets init >/dev/null 2>&1 \
    && dotnet user-secrets set "AzureAd:ClientSecret" "$SECRET_VALUE" >/dev/null )
  ok "Secret stored"

  info "Writing appsettings.json with External ID authority (ciamlogin.com)"
  cat > "$PROJECT_DIR/appsettings.json" <<JSON
{
  "AzureAd": {
    "Instance": "https://${CIAM_HOST}/",
    "Domain": "${TENANT_DOMAIN}",
    "TenantId": "${TENANT_ID}",
    "ClientId": "${APP_ID}",
    "CallbackPath": "/signin-oidc",
    "SignedOutCallbackPath": "/signout-oidc"
  },
  "Logging": { "LogLevel": { "Default": "Information", "Microsoft.AspNetCore": "Warning" } },
  "AllowedHosts": "*"
}
JSON
  ok "appsettings.json written"
  note "Note: 'Instance' is ciamlogin.com (NOT login.microsoftonline.com) — that's the External ID giveaway"

  info "Pinning launch port to $PORT"
  python3 - "$PROJECT_DIR/Properties/launchSettings.json" "$PORT" <<'PY'
import json, sys
p, port = sys.argv[1], sys.argv[2]
with open(p, encoding='utf-8-sig') as f: d = json.load(f)
d['profiles']['https']['applicationUrl'] = f"https://localhost:{port};http://localhost:5244"
with open(p, 'w', encoding='utf-8') as f: json.dump(d, f, indent=2)
PY
  ok "Port set"

  if ! grep -q "UseAuthentication" "$PROJECT_DIR/Program.cs"; then
    info "Inserting app.UseAuthentication() in Program.cs (template sometimes omits it)"
    sed -i.bak 's/app.UseAuthorization();/app.UseAuthentication();\napp.UseAuthorization();/' "$PROJECT_DIR/Program.cs"
    rm -f "$PROJECT_DIR/Program.cs.bak"
    ok "Pipeline order fixed"
  fi

  info "Writing claims-dump home page (so students can SEE the ID token)"
  cat > "$PROJECT_DIR/Views/Home/Index.cshtml" <<'CSHTML'
@{ ViewData["Title"] = "Home Page"; }
<div class="text-center">
  <h1 class="display-4">External ID Demo</h1>
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
CSHTML
  ok "View written"

  info "Building project"
  ( cd "$PROJECT_DIR" && dotnet build >/dev/null ) && ok "Build succeeded"
fi

# ── summary ──────────────────────────────────────────────────────────────────
banner "════════════════════════════════════════════════════════════════"
banner "  ✓ READY FOR USE"
banner "════════════════════════════════════════════════════════════════"
cat <<EOF

  ${c_bold}What was created in this run:${c_off}

  Tenant ID         : $TENANT_ID
  Tenant domain     : $TENANT_DOMAIN
  External authority: ${c_grn}https://${CIAM_HOST}/${c_off}
  App (client) ID   : ${c_grn}$APP_ID${c_off}
  Service principal : $SP_ID
  Client secret     : ${c_yel}$SECRET_VALUE${c_off}
                      ${c_dim}(also stored in dotnet user-secrets)${c_off}
  User flow         : $FLOW_NAME
  User flow ID      : $FLOW_ID
  Redirect URI      : $REDIRECT_URI

  ${c_bold}Run the app:${c_off}
    cd $PROJECT_DIR && dotnet run --launch-profile https
    open https://localhost:${PORT}

  ${c_bold}Tear it all down later:${c_off}
    az ad app delete --id $APP_ID
    az rest --method DELETE --url "https://graph.microsoft.com/beta/identity/authenticationEventsFlows/$FLOW_ID"

EOF
