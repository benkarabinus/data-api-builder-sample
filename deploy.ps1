<#
.SYNOPSIS
    One-command deployment of the "chat with your data" stack on Azure.

.DESCRIPTION
    Provisions and wires up the entire solution end to end, using a single
    User-Assigned Managed Identity (UAMI) for every service-to-service call
    (no keys, no passwords). Stages:

      1. Foundation  (infra/foundation.bicep)
         Resource group, UAMI, Azure SQL (Entra-only), Azure AI Foundry
         account + project, text-embedding-3-small deployment, and the
         "Cognitive Services OpenAI User" role for the UAMI.

      2. SQL data plane (sql/*.sql, run with "sqlcmd -G" as you)
         Schema + optional sample data, the UAMI database user, the
         EXTERNAL MODEL, an embeddings backfill, a full-text index, and
         the dbo.find_similar_reviews_hybrid stored procedure.

      3. Hosted DAB    (infra/dab-aca.bicep)
         ACR + image build (az acr build, no local Docker), Log Analytics,
         a Container Apps environment, and the DAB container exposing
         REST + GraphQL + MCP, authenticating to SQL as the UAMI.

      4. Web UI        (infra/webapp-aca.bicep)  [optional, on by default]
         A Streamlit container app that calls DAB's REST endpoint so you
         can demo hybrid search without a terminal.

    A single outputs.json is written next to this script (gitignored) with
    everything the other tooling and you need. Re-running is safe — every
    stage is idempotent.

.PARAMETER ResourceGroupName
    Resource group to deploy into. Created if it does not exist.

.PARAMETER NamePrefix
    Lowercase alphanumeric prefix for resource names (3-12 chars), e.g. "sqlrag".

.PARAMETER EnvironmentName
    Short environment name appended to resource names (2-6 chars). Default: dev.

.PARAMETER Location
    Azure region. Default: westus.

.PARAMETER SubscriptionId
    Optional. If set, switches az to this subscription first.

.PARAMETER SeedSampleData
    Default $true. Pass -SeedSampleData:$false to skip the demo Products/Reviews.

.PARAMETER InstallAutoEmbedTrigger
    Install the optional trigger that auto-embeds rows on INSERT/UPDATE.

.PARAMETER DeployWebApp
    Default $true. Pass -DeployWebApp:$false to skip the Streamlit web UI.

.PARAMETER SkipSqlScripts
    Only deploy infrastructure; run no SQL. Useful if your client cannot
    reach Azure SQL on port 1433.

.PARAMETER ImageTag
    Tag applied to the DAB and web images. Default: latest.

.PARAMETER SkipImageBuild
    Skip "az acr build" for both images (reuse what's already in ACR).

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName rg-sqlrag-dev -NamePrefix sqlrag

.EXAMPLE
    # Bring your own data later: skip the sample seed
    .\deploy.ps1 -ResourceGroupName rg-sqlrag-dev -NamePrefix sqlrag -SeedSampleData:$false

.EXAMPLE
    # Core only, no web UI
    .\deploy.ps1 -ResourceGroupName rg-sqlrag-dev -NamePrefix sqlrag -DeployWebApp:$false
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z][a-z0-9]{2,11}$')]
    [string] $NamePrefix,

    [ValidatePattern('^[a-z][a-z0-9]{1,5}$')]
    [string] $EnvironmentName = 'dev',

    [string] $Location = 'westus',

    [string] $SubscriptionId,

    [bool] $SeedSampleData = $true,

    [switch] $InstallAutoEmbedTrigger,

    [bool] $DeployWebApp = $true,

    [switch] $SkipSqlScripts,

    [string] $ImageTag = 'latest',

    [switch] $SkipImageBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root        = Split-Path -Parent $MyInvocation.MyCommand.Path
$infraDir    = Join-Path $root 'infra'
$sqlDir      = Join-Path $root 'sql'
$dabDir      = Join-Path $root 'dab'
$appDir      = Join-Path $root 'app'
$outFile     = Join-Path $root 'outputs.json'

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
}

# =============================================================================
# Stage 0 — Preflight
# =============================================================================

Write-Section '0  Preflight: az login, subscription, tools'

foreach ($tool in @('az', 'sqlcmd')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' not found on PATH. See the Prerequisites section in README.md."
    }
}

$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) { throw 'Not logged in. Run "az login" first.' }
if ($SubscriptionId -and $account.id -ne $SubscriptionId) {
    Write-Host "Switching to subscription $SubscriptionId"
    az account set --subscription $SubscriptionId | Out-Null
    $account = az account show -o json | ConvertFrom-Json
}
Write-Host "Subscription : $($account.name) ($($account.id))"
Write-Host "Tenant       : $($account.tenantId)"

# Signed-in user becomes the SQL Entra admin.
$me            = az ad signed-in-user show -o json | ConvertFrom-Json
$adminObjectId = $me.id
$adminLogin    = if ($me.userPrincipalName) { $me.userPrincipalName } else { $me.displayName }
Write-Host "SQL admin    : $adminLogin"

# Developer IP for the SQL firewall (best effort).
$myIp = '0.0.0.0'
try {
    $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
    Write-Host "Developer IP : $myIp"
} catch {
    Write-Warning 'Could not detect public IP; skipping developer firewall rule.'
}

# =============================================================================
# Stage 1 — Foundation
# =============================================================================

Write-Section '1  Foundation: RG, UAMI, SQL, Foundry, embedding model'

$rg = az group show -n $ResourceGroupName -o json 2>$null | ConvertFrom-Json
if (-not $rg) {
    az group create -n $ResourceGroupName -l $Location -o none
    Write-Host "Created resource group $ResourceGroupName"
} else {
    Write-Host "Resource group $ResourceGroupName already exists"
}

$foundationDeploy = "foundation-$(Get-Date -Format yyyyMMddHHmmss)"
$foundationOut = az deployment group create `
    --resource-group $ResourceGroupName `
    --name $foundationDeploy `
    --template-file (Join-Path $infraDir 'foundation.bicep') `
    --parameters `
        namePrefix=$NamePrefix `
        environmentName=$EnvironmentName `
        location=$Location `
        sqlAadAdminObjectId=$adminObjectId `
        sqlAadAdminLogin=$adminLogin `
        developerIpAddress=$myIp `
    --output json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0 -or -not $foundationOut) {
    throw 'Foundation Bicep deployment failed. See az output above.'
}

$f = $foundationOut.properties.outputs

$state = [ordered]@{
    deployedAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
    resourceGroup       = $ResourceGroupName
    location            = $Location
    namePrefix          = $NamePrefix
    environmentName     = $EnvironmentName
    subscriptionId      = $account.id
    tenantId            = $account.tenantId
    uamiName            = $f.uamiName.value
    uamiResourceId      = $f.uamiResourceId.value
    uamiClientId        = $f.uamiClientId.value
    uamiPrincipalId     = $f.uamiPrincipalId.value
    sqlServerName       = $f.sqlServerName.value
    sqlServerFqdn       = $f.sqlServerFqdn.value
    sqlDatabaseName     = $f.sqlDatabaseName.value
    foundryAccountName  = $f.foundryAccountName.value
    foundryProjectName  = $f.foundryProjectName.value
    foundryEndpoint     = $f.foundryEndpoint.value
    openAiEndpoint      = $f.openAiEndpoint.value
    embeddingDeployment = $f.embeddingDeployment.value
    chatDeployment      = $f.chatDeployment.value
}
Write-Host "SQL server   : $($state.sqlServerFqdn)"
Write-Host "Foundry      : $($state.foundryAccountName)"

# =============================================================================
# Stage 2 — SQL data plane
# =============================================================================

$sqlServerFqdn = $state.sqlServerFqdn
$sqlDb         = $state.sqlDatabaseName

# Token replacements for SQL files that reference UAMI / endpoint / deployment.
$tokenMap = @{
    '<<UAMI_NAME>>'            = $state.uamiName
    '<<OPENAI_ENDPOINT>>'      = $state.openAiEndpoint.TrimEnd('/')
    '<<EMBEDDING_DEPLOYMENT>>' = $state.embeddingDeployment
}

function Invoke-SqlFile([string]$FileName) {
    $path = Join-Path $sqlDir $FileName
    if (-not (Test-Path $path)) { throw "SQL file not found: $path" }
    Write-Host "  -> $FileName"
    $content = Get-Content -LiteralPath $path -Raw
    foreach ($k in $tokenMap.Keys) { $content = $content.Replace($k, $tokenMap[$k]) }
    $tmp = New-TemporaryFile
    $tmp = Rename-Item -Path $tmp.FullName -NewName ($tmp.BaseName + '.sql') -PassThru
    try {
        Set-Content -LiteralPath $tmp.FullName -Value $content -Encoding utf8
        & sqlcmd -S $sqlServerFqdn -d $sqlDb -G -i $tmp.FullName -b
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed for $FileName (exit $LASTEXITCODE)" }
    } finally {
        Remove-Item -LiteralPath $tmp.FullName -ErrorAction SilentlyContinue
    }
}

if ($SkipSqlScripts) {
    Write-Section '2  SQL data plane SKIPPED (-SkipSqlScripts)'
} else {
    Write-Section '2  SQL data plane: schema, embeddings, hybrid search'

    Write-Host 'Schema:'
    Invoke-SqlFile '00-create-schema.sql'

    if ($SeedSampleData) {
        Write-Host 'Sample data:'
        Invoke-SqlFile '01-seed-products.sql'
        Invoke-SqlFile '02-seed-reviews.sql'
    } else {
        Write-Host 'Skipping sample data (-SeedSampleData:$false). See byo/README.md.'
    }

    Write-Host 'Embeddings (UAMI db user, credential, external model, backfill):'
    Invoke-SqlFile '10-create-uami-db-user.sql'
    Invoke-SqlFile '11-create-credential.sql'
    Invoke-SqlFile '12-create-external-model.sql'
    Invoke-SqlFile '13-test-embedding.sql'
    if ($SeedSampleData) {
        Invoke-SqlFile '14-backfill-embeddings.sql'
    } else {
        Write-Host '  (no rows to backfill — sample data skipped)'
    }
    if ($InstallAutoEmbedTrigger) {
        Invoke-SqlFile '15-create-auto-embed-trigger.sql'
    }

    Write-Host 'Hybrid search (full-text index + stored procedure):'
    Invoke-SqlFile '20-create-fulltext-index.sql'
    Invoke-SqlFile '21-create-hybrid-search-sp.sql'
    if ($SeedSampleData) {
        Invoke-SqlFile '22-test-hybrid-search.sql'
    }
}

# =============================================================================
# Stage 3 — Hosted DAB on Azure Container Apps
# =============================================================================

Write-Section '3  Hosted DAB: ACR, image build, Container App'

# ACR name must be globally unique + stable per RG. Reuse the suffix that
# foundation baked into the SQL server name: "{prefix}-sql-{env}-{uniq}".
$uniqSuffix = $state.sqlServerName.Substring($state.sqlServerName.LastIndexOf('-') + 1)
if (-not $uniqSuffix) { throw "Could not derive uniq suffix from '$($state.sqlServerName)'." }
$acrName = ("{0}acr{1}{2}" -f $NamePrefix, $EnvironmentName, $uniqSuffix).ToLower()
Write-Host "ACR name     : $acrName"

# Ensure the containerapp extension + providers.
$ext = az extension list --query "[?name=='containerapp'].name" -o tsv
if (-not $ext) { az extension add --name containerapp --yes | Out-Null }
az provider register -n Microsoft.App --wait | Out-Null
az provider register -n Microsoft.ContainerRegistry --wait | Out-Null
az provider register -n Microsoft.OperationalInsights --wait | Out-Null

# ACR (idempotent — created here so images exist before the apps come up).
$acrExists = az acr show -n $acrName -g $ResourceGroupName --query name -o tsv 2>$null
if (-not $acrExists) {
    Write-Host "Creating ACR $acrName..."
    az acr create --resource-group $ResourceGroupName --name $acrName --sku Basic `
        --location $Location --admin-enabled false -o none
} else {
    Write-Host "ACR $acrName already exists"
}
$acrLoginServer = az acr show -n $acrName -g $ResourceGroupName --query loginServer -o tsv

$dabTag = "$acrLoginServer/dab:$ImageTag"
if ($SkipImageBuild) {
    Write-Host "Skipping DAB image build; using existing $dabTag"
} else {
    Write-Host "Building DAB image: $dabTag"
    az acr build --registry $acrName --resource-group $ResourceGroupName `
        --image "dab:$ImageTag" --file (Join-Path $dabDir 'Dockerfile') $dabDir
    if ($LASTEXITCODE -ne 0) { throw 'az acr build failed for the DAB image.' }
}

# Deploy by immutable digest, not the :latest tag. Re-pushing the same tag
# leaves the Bicep image parameter unchanged, so ACA keeps the old revision
# and silently ignores config edits. The digest changes whenever the image
# content changes, forcing a new revision exactly when needed.
$dabDigest = az acr repository show --name $acrName --image "dab:$ImageTag" --query digest -o tsv
if (-not $dabDigest) { throw "Could not resolve digest for dab:$ImageTag in $acrName." }
$dabImage = "$acrLoginServer/dab@$dabDigest"
Write-Host "DAB image    : $dabImage"

# UAMI-auth connection string (no secrets).
$sqlConn = "Server=tcp:$sqlServerFqdn,1433;Database=$sqlDb;Authentication=Active Directory Managed Identity;User Id=$($state.uamiClientId);Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

$dabDeploy = "dab-aca-$(Get-Date -Format yyyyMMddHHmmss)"
az deployment group create `
    --resource-group $ResourceGroupName `
    --name $dabDeploy `
    --template-file (Join-Path $infraDir 'dab-aca.bicep') `
    --parameters `
        namePrefix=$NamePrefix `
        environmentName=$EnvironmentName `
        location=$Location `
        uamiResourceId=$($state.uamiResourceId) `
        uamiClientId=$($state.uamiClientId) `
        uamiPrincipalId=$($state.uamiPrincipalId) `
        acrName=$acrName `
        sqlConnectionString="$sqlConn" `
        dabImage="$dabImage" `
    -o none
if ($LASTEXITCODE -ne 0) { throw 'DAB ACA Bicep deployment failed.' }

$dabOut = (az deployment group show -g $ResourceGroupName -n $dabDeploy -o json | ConvertFrom-Json).properties.outputs
$state.acrName        = $acrName
$state.acrLoginServer = $acrLoginServer
$state.dabImage       = $dabImage
$state.acaEnvName     = $dabOut.acaEnvName.value
$state.dabAppName     = $dabOut.acaAppName.value
$state.dabAppFqdn     = $dabOut.acaAppFqdn.value
$state.dabAppUrl      = $dabOut.acaAppUrl.value
Write-Host "DAB live at  : $($state.dabAppUrl)"

# =============================================================================
# Stage 4 — Web UI (optional)
# =============================================================================

if ($DeployWebApp) {
    Write-Section '4  Web UI: Streamlit container app'

    $webTag = "$acrLoginServer/web:$ImageTag"
    if ($SkipImageBuild) {
        Write-Host "Skipping web image build; using existing $webTag"
    } else {
        Write-Host "Building web image: $webTag"
        az acr build --registry $acrName --resource-group $ResourceGroupName `
            --image "web:$ImageTag" --file (Join-Path $appDir 'Dockerfile') $appDir
        if ($LASTEXITCODE -ne 0) { throw 'az acr build failed for the web image.' }
    }

    # Deploy by digest (see DAB note above) so the web app rolls a new
    # revision whenever app.py or its image changes.
    $webDigest = az acr repository show --name $acrName --image "web:$ImageTag" --query digest -o tsv
    if (-not $webDigest) { throw "Could not resolve digest for web:$ImageTag in $acrName." }
    $webImage = "$acrLoginServer/web@$webDigest"
    Write-Host "Web image    : $webImage"

    $webDeploy = "web-aca-$(Get-Date -Format yyyyMMddHHmmss)"

    az deployment group create `
        --resource-group $ResourceGroupName `
        --name $webDeploy `
        --template-file (Join-Path $infraDir 'webapp-aca.bicep') `
        --parameters `
            namePrefix=$NamePrefix `
            environmentName=$EnvironmentName `
            location=$Location `
            uamiResourceId=$($state.uamiResourceId) `
            uamiClientId=$($state.uamiClientId) `
            acrName=$acrName `
            webImage="$webImage" `
            dabBaseUrl=$($state.dabAppUrl) `
            foundryProjectEndpoint=$($state.foundryEndpoint) `
            foundryAgentName="" `
            foundryAgentVersion="" `
        -o none
    if ($LASTEXITCODE -ne 0) { throw 'Web ACA Bicep deployment failed.' }

    $webOut = (az deployment group show -g $ResourceGroupName -n $webDeploy -o json | ConvertFrom-Json).properties.outputs
    $state.webAppName = $webOut.acaAppName.value
    $state.webAppUrl  = $webOut.acaAppUrl.value
    Write-Host "Web UI live  : $($state.webAppUrl)"
} else {
    Write-Section '4  Web UI SKIPPED (-DeployWebApp:$false)'
}

# =============================================================================
# Stage 5 — Foundry prompt agent (new agents runtime) + chat wiring
# =============================================================================

Write-Section '5  Foundry Agent: prompt agent with DAB MCP tool'

# The agent's model, instructions, and DAB MCP tool all live in the Foundry
# agent definition. We upsert it with the azure-ai-projects SDK
# (agents.create_version), which lands it in the new Foundry Agents
# experience. The Streamlit chat tab then connects to it with the Microsoft
# Agent Framework SDK (FoundryAgent), authenticating as the UAMI.

$agentName    = "chat-with-your-data"
$dabMcpUrl    = "$($state.dabAppUrl)/mcp"
$projEndpoint = $state.foundryEndpoint

$agentScript = @"
import json, sys
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition, MCPTool

PROJECT_ENDPOINT = "$projEndpoint"
AGENT_NAME = "$agentName"
DAB_MCP_URL = "$dabMcpUrl"
MODEL_DEPLOYMENT = "$($state.chatDeployment)"

instructions = (
    "You answer questions about products and product reviews by calling the "
    "DAB MCP tools. Rules you must follow:\n\n"
    "1. Before any read_records, create_record, update_record, delete_record, "
    "or aggregate_records call, FIRST call describe_entities with the entities "
    "parameter for the specific entity (for example {\"entities\":[\"Product\"]}) "
    "to get its real field list.\n"
    "2. NEVER call describe_entities with nameOnly: true for query planning - it "
    "omits the field names you need.\n"
    "3. Use field names EXACTLY as returned by describe_entities. They are "
    "case-sensitive (e.g. Category, not category). Never invent field names, and "
    "never pass * to select (omit select to return all fields).\n"
    "4. To search reviews by meaning, prefer the find_similar_reviews_hybrid tool "
    "with queryText and top.\n"
    "5. Ground every answer in the rows the tools return, and cite the review text "
    "you used.\n"
    "6. If a question cannot be answered from the connected tools, say you do not know."
)

try:
    project = AIProjectClient(endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential())
    tool = MCPTool(
        server_label="AzureSQLMCPServer",
        server_url=DAB_MCP_URL,
        require_approval="never",
    )
    agent = project.agents.create_version(
        agent_name=AGENT_NAME,
        definition=PromptAgentDefinition(
            model=MODEL_DEPLOYMENT,
            instructions=instructions,
            tools=[tool],
        ),
    )
    print(json.dumps({"agentName": agent.name, "agentVersion": str(agent.version)}))
except Exception as e:
    print(f"Error creating agent: {e}", file=sys.stderr)
    sys.exit(1)
"@

# Grant the UAMI permission to invoke the agent's responses endpoint on the
# Foundry account (the web container authenticates as this identity). The
# documented role is 'Foundry User' (recently renamed from 'Azure AI User' —
# same role ID/permissions). The rename is rolling out per-tenant, so try the
# new name first and fall back to the old one. Role assignment is idempotent.
$foundryAccountId = "/subscriptions/$($account.id)/resourceGroups/$ResourceGroupName/providers/Microsoft.CognitiveServices/accounts/$($state.foundryAccountName)"
$invokeRoleAssigned = $false
foreach ($roleName in @('Foundry User', 'Azure AI User')) {
    Write-Host "Granting '$roleName' to the UAMI on the Foundry account..."
    az role assignment create `
        --assignee-object-id $($state.uamiPrincipalId) `
        --assignee-principal-type ServicePrincipal `
        --role "$roleName" `
        --scope $foundryAccountId `
        -o none 2>$null
    if ($LASTEXITCODE -eq 0) { $invokeRoleAssigned = $true; break }
}
if (-not $invokeRoleAssigned) {
    Write-Warning "Could not assign the agent-invoke role ('Foundry User'/'Azure AI User'). It may already exist, or you may need elevated rights. The chat tab needs this role to invoke the agent."
}

# Upsert the agent
$pythonTmp = New-TemporaryFile | Rename-Item -NewName { $_.BaseName + '.py' } -PassThru
Set-Content -LiteralPath $pythonTmp.FullName -Value $agentScript -Encoding utf8
try {
    Write-Host "Ensuring agent SDK packages (azure-ai-projects, azure-identity)..."
    python -m pip install --quiet --disable-pip-version-check azure-ai-projects azure-identity 2>&1 | Out-Null
    $agentResult = python $pythonTmp.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Agent upsert failed (see output above). Create/update it via https://ai.azure.com.`n$agentResult"
        $state.agentName = ''
        $state.agentVersion = ''
    } else {
        $agentJson = $agentResult | Select-Object -Last 1 | ConvertFrom-Json
        $state.agentName    = $agentJson.agentName
        $state.agentVersion = $agentJson.agentVersion
        Write-Host "Agent ready  : $($state.agentName) (version $($state.agentVersion))"

        if ($DeployWebApp) {
            Write-Host "Wiring the web UI chat tab to the agent..."
            az containerapp update `
                --resource-group $ResourceGroupName `
                --name $($state.webAppName) `
                --set-env-vars `
                    "FOUNDRY_PROJECT_ENDPOINT=$($state.foundryEndpoint)" `
                    "FOUNDRY_AGENT_NAME=$($state.agentName)" `
                    "FOUNDRY_AGENT_VERSION=$($state.agentVersion)" `
                -o none
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to set agent env vars on the web app; the chat tab may stay hidden."
            } else {
                Write-Host "Web UI chat tab wired to $($state.agentName)"
            }
        }
    }
} catch {
    Write-Warning "Agent upsert script failed. Create/update it via https://ai.azure.com.`nError: $_"
    $state.agentName = ''
    $state.agentVersion = ''
} finally {
    Remove-Item -LiteralPath $pythonTmp.FullName -ErrorAction SilentlyContinue
}

# =============================================================================
# Done
# =============================================================================

$state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outFile -Encoding utf8

Write-Section 'Done'
Write-Host ''
Write-Host 'You now have:' -ForegroundColor Green
Write-Host "  Resource group : $ResourceGroupName"
Write-Host "  SQL database   : $sqlDb on $sqlServerFqdn"
Write-Host "  Hosted DAB     : $($state.dabAppUrl)"
Write-Host "    REST    : $($state.dabAppUrl)/api/Product"
Write-Host "    GraphQL : $($state.dabAppUrl)/graphql"
Write-Host "    MCP     : $($state.dabAppUrl)/mcp"
if ($DeployWebApp) {
    Write-Host "  Web UI         : $($state.webAppUrl)"
}
if ($state.agentName) {
    Write-Host "  Foundry agent  : $($state.agentName) (version $($state.agentVersion))"
}
Write-Host ''
Write-Host "State written to: $outFile" -ForegroundColor Yellow
Write-Host 'Bring your own data: see byo/README.md' -ForegroundColor Yellow
Write-Host 'Connect a Foundry agent: see agent/README.md' -ForegroundColor Yellow
