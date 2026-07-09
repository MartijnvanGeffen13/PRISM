#!/usr/bin/env pwsh
# =============================================================================
# postprovision hook — Data Lake Network Security Perimeter inbound IP rule
# =============================================================================
# Upserts the "allow-inbound-ips" access rule on the Data Lake's NSP profile from
# DATA_LAKE_ALLOWED_IPS (+ optional DEPLOYER_IP_ADDRESS).
#
# WHY A HOOK (and not Bicep): the NSP resource provider rejects an IP-based rule
# and a subscription-based rule being written in the SAME ARM deployment with
# "Address Prefixes can't be overlapping" — even though both rules are valid and
# a *standalone* PUT of the IP rule succeeds. Bicep therefore owns the perimeter,
# profile, subscription rule and association; this hook owns the IP rule and runs
# after provisioning completes, so the PUT is standalone and reliable.
#
# Requires the Azure CLI (`az`) to be signed in (azd shares the login).
# =============================================================================
$ErrorActionPreference = 'Stop'

$rg  = $env:AZURE_RESOURCE_GROUP
$sub = $env:AZURE_SUBSCRIPTION_ID
if (-not $rg)  { Write-Warning 'AZURE_RESOURCE_GROUP not set; skipping NSP IP rule.'; exit 0 }
if (-not $sub) { Write-Warning 'AZURE_SUBSCRIPTION_ID not set; skipping NSP IP rule.'; exit 0 }

# --- Collect allowed IP prefixes (normalise bare IPs to /32) -----------------
$prefixes = [System.Collections.Generic.List[string]]::new()
function Add-Ip([string] $ip) {
  if ([string]::IsNullOrWhiteSpace($ip)) { return }
  $ip = $ip.Trim()
  if ($ip -notmatch '/') { $ip = "$ip/32" }
  if (-not $prefixes.Contains($ip)) { $prefixes.Add($ip) }
}

if ($env:DATA_LAKE_ALLOWED_IPS) {
  try {
    foreach ($ip in ($env:DATA_LAKE_ALLOWED_IPS | ConvertFrom-Json)) { Add-Ip $ip }
  } catch {
    Write-Warning "DATA_LAKE_ALLOWED_IPS is not valid JSON; ignoring. Value: $($env:DATA_LAKE_ALLOWED_IPS)"
  }
}
Add-Ip $env:DEPLOYER_IP_ADDRESS

# --- Locate the perimeter -----------------------------------------------------
$perimeter = az resource list -g $rg --resource-type 'Microsoft.Network/networkSecurityPerimeters' --query '[0].name' -o tsv
if (-not $perimeter) { Write-Warning "No Network Security Perimeter found in $rg; skipping NSP IP rule."; exit 0 }

$api     = '2023-08-01-preview'
$ruleUrl = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Network/networkSecurityPerimeters/$perimeter/profiles/prism-profile/accessRules/allow-inbound-ips?api-version=$api"

# --- No IPs: remove the rule if it exists ------------------------------------
if ($prefixes.Count -eq 0) {
  Write-Host 'No allowed IPs supplied (DATA_LAKE_ALLOWED_IPS / DEPLOYER_IP_ADDRESS). Removing allow-inbound-ips rule if present.'
  az rest --method delete --url $ruleUrl 2>$null | Out-Null
  exit 0
}

# --- Upsert the IP rule (standalone PUT) -------------------------------------
$loc        = az resource show -g $rg -n $perimeter --resource-type 'Microsoft.Network/networkSecurityPerimeters' --query location -o tsv
$prefixJson = ($prefixes | ForEach-Object { '"' + $_ + '"' }) -join ','
$json       = "{`"location`":`"$loc`",`"properties`":{`"direction`":`"Inbound`",`"addressPrefixes`":[$prefixJson]}}"

$tmp = New-TemporaryFile
try {
  Set-Content -Path $tmp -Value $json -Encoding utf8
  Write-Host "Setting NSP inbound IP rule on $perimeter/prism-profile: $($prefixes -join ', ')"
  az rest --method put --url $ruleUrl --body "@$tmp" | Out-Null
  Write-Host 'NSP inbound IP rule updated.'
} finally {
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
