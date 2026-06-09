// =============================================================================
// Step 1 — Foundation
// -----------------------------------------------------------------------------
// Creates the resources every later step depends on:
//
//   * One User-Assigned Managed Identity (UAMI) used everywhere in the tutorial
//   * Azure SQL logical server (Entra-only auth, UAMI as primary identity)
//   * Azure SQL database (serverless GP_Gen5_2)
//   * Azure AI Foundry account + project
//   * One embedding model deployment (text-embedding-3-small, 1536 dims)
//   * Role assignment: UAMI -> Cognitive Services OpenAI User on Foundry
//   * SQL firewall rule(s)
//
// Step 1 does NOT deploy ACR, ACA, a chat model, or anything DAB-related.
// Those come in later steps.
//
// Scope: resource group (deployed via the deploy.ps1 wrapper).
// =============================================================================

targetScope = 'resourceGroup'

// -----------------------------------------------------------------------------
// Parameters
// -----------------------------------------------------------------------------

@description('Name prefix used for all resources. Lower-case alphanumeric. Example: "sqlrag".')
@minLength(3)
@maxLength(12)
param namePrefix string

@description('Environment short name. Appended to most resource names. Example: "dev".')
@minLength(2)
@maxLength(6)
param environmentName string = 'dev'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Object ID (GUID) of the AAD user/group to be set as the Azure SQL AAD admin. The deploy.ps1 wrapper resolves this from "az ad signed-in-user show".')
param sqlAadAdminObjectId string

@description('UPN or display name of the AAD user/group above. Used as the SQL admin login string.')
param sqlAadAdminLogin string

@description('IPv4 address to allow through the SQL firewall (typically the deploying machine). Pass "0.0.0.0" to skip adding a developer firewall rule.')
param developerIpAddress string = '0.0.0.0'

@description('Embedding model name to deploy on the Foundry account.')
param embeddingModelName string = 'text-embedding-3-small'

@description('Embedding model version.')
param embeddingModelVersion string = '1'

@description('Embedding model deployment capacity (TPM in thousands).')
param embeddingModelCapacity int = 10

// -----------------------------------------------------------------------------
// Variables — naming
// -----------------------------------------------------------------------------

// Suffix used to make globally-unique resource names stable per (sub, RG).
var uniq = toLower(substring(uniqueString(subscription().id, resourceGroup().id), 0, 6))

var uamiName        = '${namePrefix}-uami-${environmentName}'
var sqlServerName   = '${namePrefix}-sql-${environmentName}-${uniq}'
var sqlDbName       = 'ProductsDB'
var foundryName     = '${namePrefix}-ai-${environmentName}-${uniq}'
var foundryProject  = '${namePrefix}-proj-${environmentName}'
var embedDeployName = 'embedding'

// Built-in role: Cognitive Services OpenAI User
var roleCogSvcOpenAIUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

// -----------------------------------------------------------------------------
// User-Assigned Managed Identity
// -----------------------------------------------------------------------------

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
}

// -----------------------------------------------------------------------------
// Azure SQL — server + database + firewall
// -----------------------------------------------------------------------------

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    primaryUserAssignedIdentityId: uami.id
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'User'
      login: sqlAadAdminLogin
      sid: sqlAadAdminObjectId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDbName
  location: location
  sku: {
    name: 'GP_S_Gen5_2'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    autoPauseDelay: 60
    minCapacity: json('0.5')
    maxSizeBytes: 34359738368 // 32 GB
    zoneRedundant: false
  }
}

// Allow all Azure services (lets later ACA-hosted DAB reach the server).
resource fwAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Allow the deploying developer's IP (skipped if caller passed 0.0.0.0).
resource fwDev 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (developerIpAddress != '0.0.0.0') {
  parent: sqlServer
  name: 'AllowDeveloperIp'
  properties: {
    startIpAddress: developerIpAddress
    endIpAddress: developerIpAddress
  }
}

// -----------------------------------------------------------------------------
// Azure AI Foundry — account + project + embedding deployment
// -----------------------------------------------------------------------------

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: foundryName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
    allowProjectManagement: true
  }
}

resource foundryProj 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundry
  name: foundryProject
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

resource embedDeploy 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundry
  name: embedDeployName
  sku: {
    name: 'Standard'
    capacity: embeddingModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModelName
      version: embeddingModelVersion
    }
  }
}

// -----------------------------------------------------------------------------
// Role assignment — UAMI is "Cognitive Services OpenAI User" on the account
// -----------------------------------------------------------------------------
//
// This is the role that lets the SQL server (acting as the UAMI via
// sp_invoke_external_rest_endpoint) call the embedding endpoint.
//
// The same UAMI is later granted AcrPull (step 5). DAB and any other
// caller using this UAMI inherits the same OpenAI access automatically.

resource raUamiOnFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, uami.id, roleCogSvcOpenAIUser)
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCogSvcOpenAIUser)
  }
}

// -----------------------------------------------------------------------------
// Outputs (consumed by deploy.ps1 to print a "what you got" summary,
// and by later steps' deploy scripts.)
// -----------------------------------------------------------------------------

output uamiName             string = uami.name
output uamiResourceId       string = uami.id
output uamiClientId         string = uami.properties.clientId
output uamiPrincipalId      string = uami.properties.principalId

output sqlServerName        string = sqlServer.name
output sqlServerFqdn        string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName      string = sqlDb.name

output foundryAccountName   string = foundry.name
output foundryProjectName   string = foundryProj.name
output foundryEndpoint      string = 'https://${foundry.name}.services.ai.azure.com/api/projects/${foundryProj.name}'
output openAiEndpoint       string = 'https://${foundry.name}.openai.azure.com/'
output embeddingDeployment  string = embedDeploy.name
