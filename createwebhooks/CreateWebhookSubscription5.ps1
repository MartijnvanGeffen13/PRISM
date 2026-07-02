# =========================
# CONFIG
# =========================
# Supply all values via environment variables before running (never hard-code):
#   $env:PURVIEW_TENANT_ID     = "<your-tenant-guid>"
#   $env:PURVIEW_CLIENT_ID     = "<your-app-client-guid>"
#   $env:PURVIEW_CLIENT_SECRET = "<your-app-secret>"
#   $env:AZUREAD_WEBHOOK_URL   = "https://<func>.azurewebsites.net/api/webhook?code=<function-key>"
$tenantId     = $env:PURVIEW_TENANT_ID
$clientId     = $env:PURVIEW_CLIENT_ID
$clientSecret = $env:PURVIEW_CLIENT_SECRET
$webhookUrl   = $env:AZUREAD_WEBHOOK_URL

foreach ($v in @("PURVIEW_TENANT_ID", "PURVIEW_CLIENT_ID", "PURVIEW_CLIENT_SECRET", "AZUREAD_WEBHOOK_URL")) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($v))) {
        throw "$v environment variable is not set."
    }
}
 
$contentType  = "Audit.AzureActiveDirectory"
$publisherId  = $tenantId
 
# Webhook endpoint (must be public HTTPS) comes from $env:AZUREAD_WEBHOOK_URL (set above).
 
# =========================
# STEP 1 – GET TOKEN
# =========================
$tokenEndpoint = "https://login.microsoftonline.com/$tenantId/oauth2/token"
 
$tokenBody = @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSecret
    resource      = "https://manage.office.com"
}
 
$tokenResponse = Invoke-RestMethod -Method POST -Uri $tokenEndpoint -Body $tokenBody
$accessToken = $tokenResponse.access_token
 
# =========================
# STEP 2 – HEADERS
# =========================
$headers = @{
    Authorization = "Bearer $accessToken"
    "Content-Type" = "application/json"
}
 
# =========================
# STEP 3 – WEBHOOK BODY
# =========================
$body = @{
    webhook = @{
        address = $webhookUrl
        authId  = "MyWebhookAuth"
    }
} | ConvertTo-Json -Depth 5
 
# =========================
# STEP 4 – CREATE SUBSCRIPTION
# =========================
$uri = "https://manage.office.com/api/v1.0/$tenantId/activity/feed/subscriptions/start?contentType=$contentType&PublisherIdentifier=$publisherId"

$response = Invoke-RestMethod `
    -Method POST `
    -Uri $uri `
    -Headers $headers `
    -Body $body

$response
 
