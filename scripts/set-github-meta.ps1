<#
.SYNOPSIS
    Sets the GitHub repository description and topics (tags) for bounded-boxer.

.DESCRIPTION
    Uses the GitHub REST API. The token needs the `repo` scope.
    Token resolution order: -Token parameter, then $env:GH_TOKEN, then $env:GITHUB_TOKEN.
    Note: PUT /topics REPLACES the full topic list, so pass the complete set.

.EXAMPLE
    $env:GH_TOKEN = "ghp_..."
    powershell -ExecutionPolicy Bypass -File .\scripts\set-github-meta.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\set-github-meta.ps1 -Token "ghp_..." `
        -Description "My description" -Topics @("ai-agents","google-adk")
#>
[CmdletBinding()]
param(
    [string]$Owner = "kameshsampath",
    [string]$Repo = "bounded-boxer",
    [string]$Token = "",
    [string]$Description = "Teach Agents When Not to Act. Live offline demo of runtime boundaries for autonomous agents: the same Google ADK agent runs on the host and inside an OpenShell/bwrap sandbox, with a Streamlit auditor showing the breach vs the block.",
    [string[]]$Topics = @(
        "ai-agents", "agent-safety", "google-adk", "ollama", "local-llm",
        "openshell", "bubblewrap", "sandboxing", "llm-security",
        "python", "streamlit", "wsl2", "live-demo"
    )
)

$ErrorActionPreference = "Stop"

if (-not $Token) { $Token = $env:GH_TOKEN }
if (-not $Token) { $Token = $env:GITHUB_TOKEN }
if (-not $Token) {
    throw "No GitHub token found. Pass -Token or set GH_TOKEN / GITHUB_TOKEN (PAT with repo scope)."
}

$Headers = @{
    Authorization       = "Bearer $Token"
    Accept              = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}
$Api = "https://api.github.com/repos/$Owner/$Repo"

$before = Invoke-RestMethod -Uri $Api -Headers $Headers -Method Get
Write-Host "Before: description = '$($before.description)'"
Write-Host "Before: topics      = $($before.topics -join ', ')"

Invoke-RestMethod -Uri $Api -Headers $Headers -Method Patch `
    -Body (@{ description = $Description } | ConvertTo-Json) | Out-Null
Write-Host "Description updated."

Invoke-RestMethod -Uri "$Api/topics" -Headers ($Headers + @{ "Content-Type" = "application/json" }) -Method Put `
    -Body (@{ names = $Topics } | ConvertTo-Json) | Out-Null
Write-Host "Topics replaced with: $($Topics -join ', ')"

$after = Invoke-RestMethod -Uri $Api -Headers $Headers -Method Get
Write-Host "After:  description = '$($after.description)'"
Write-Host "After:  topics      = $($after.topics -join ', ')"
