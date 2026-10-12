# Submit one file to SignPath via the classic REST API (SubmitWithArtifact).
# Works without a Trusted Build System, so free-trial orgs can sign from CI.
# Requires env: SIGNPATH_API_TOKEN, SIGNPATH_ORG_ID, SIGNPATH_PROJECT_SLUG.
param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string]$PolicySlug,
    [string]$Description = 'Bettbox-Mod CI'
)
$ErrorActionPreference = 'Stop'
$org = $env:SIGNPATH_ORG_ID
$project = $env:SIGNPATH_PROJECT_SLUG
$token = $env:SIGNPATH_API_TOKEN
if (-not $org -or -not $project -or -not $token) {
    throw 'SIGNPATH_ORG_ID / SIGNPATH_PROJECT_SLUG / SIGNPATH_API_TOKEN are required'
}
if (-not (Test-Path -LiteralPath $FilePath)) {
    throw "artifact not found: $FilePath"
}

$headers = @{ Authorization = "Bearer $token" }
$form = @{
    projectSlug        = $project
    signingPolicySlug  = $PolicySlug
    description        = $Description
    artifact           = Get-Item -LiteralPath $FilePath
}
$submitUri = "https://app.signpath.io/Api/v1/$org/SigningRequests/SubmitWithArtifact"
Write-Host "Submitting $FilePath with policy $PolicySlug..."
$submit = Invoke-WebRequest -Uri $submitUri -Method Post -Headers $headers -Form $form -UseBasicParsing
if ($submit.StatusCode -ne 201) {
    throw "submit failed: HTTP $($submit.StatusCode)"
}
$location = $submit.Headers['Location']
if (-not $location) {
    throw 'submit response has no Location header'
}
$id = ($location -split '/')[-1]
Write-Host "Signing request: $id"

$statusUri = "https://app.signpath.io/Api/v1/$org/SigningRequests/$id/Status"
$deadline = (Get-Date).AddMinutes(30)
while ($true) {
    $status = Invoke-RestMethod -Uri $statusUri -Headers $headers
    Write-Host "Status: $($status.status) / $($status.workflowStatus)"
    if ($status.isFinalStatus) { break }
    if ((Get-Date) -gt $deadline) {
        throw "timeout waiting for signing request $id"
    }
    Start-Sleep -Seconds 5
}
if ($status.status -ne 'Completed') {
    throw "signing request $id ended as $($status.status) / $($status.workflowStatus)"
}

$signedUri = "https://app.signpath.io/Api/v1/$org/SigningRequests/$id/SignedArtifact"
Invoke-WebRequest -Uri $signedUri -Headers $headers -OutFile $FilePath -UseBasicParsing
Write-Host "Signed $FilePath (request $id)"
