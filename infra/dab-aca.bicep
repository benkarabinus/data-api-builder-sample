// =============================================================================
// Step 5 — Host DAB on Azure Container Apps
// -----------------------------------------------------------------------------
// Creates:
//   * Log Analytics workspace
//   * Container Apps managed environment
//   * Container App running the DAB image, with the step 1 UAMI attached
//   * Role assignment: UAMI -> AcrPull on the registry (so ACA can pull
//     the image without admin creds)
//
// The Azure Container Registry itself is created OUTSIDE of this Bicep,
// by deploy.ps1 (so the script can build + push the image *before* the
// ACA app comes up — Bicep doesn't gracefully handle that ordering).
//
// Re-uses the User-Assigned Managed Identity from step 1. The same identity
// is already a SQL DB user (from step 2) and has Cognitive Services OpenAI
// User on the Foundry account (from step 1), so DAB inherits both.
//
// Scope: resource group.
// =============================================================================

targetScope = 'resourceGroup'

// -----------------------------------------------------------------------------
// Parameters
// -----------------------------------------------------------------------------

@description('Name prefix used for all resources. Should match step 1.')
@minLength(3)
@maxLength(12)
param namePrefix string

@description('Environment short name. Should match step 1.')
@minLength(2)
@maxLength(6)
param environmentName string = 'dev'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Resource ID of the User-Assigned Managed Identity created in step 1.')
param uamiResourceId string

@description('Client ID (GUID) of the same UAMI. Used in the SQL connection string and exposed as AZURE_CLIENT_ID inside the container.')
param uamiClientId string

@description('Principal ID (objectId) of the same UAMI. Used for the AcrPull role assignment.')
param uamiPrincipalId string

@description('Name of the Azure Container Registry that deploy.ps1 created and pushed the DAB image to.')
param acrName string

@description('SQL connection string with Authentication=Active Directory Managed Identity. Built by deploy.ps1.')
@secure()
param sqlConnectionString string

@description('Full image name including registry and tag, e.g. myregistry.azurecr.io/dab:latest.')
param dabImage string

// -----------------------------------------------------------------------------
// Variables — naming
// -----------------------------------------------------------------------------

var lawName    = '${namePrefix}-law-${environmentName}'
var acaEnvName = '${namePrefix}-acaenv-${environmentName}'
var acaAppName = '${namePrefix}-dab-${environmentName}'

// Built-in role: AcrPull
var roleAcrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// -----------------------------------------------------------------------------
// Existing resources (ACR + UAMI live elsewhere)
// -----------------------------------------------------------------------------

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: acrName
}

// -----------------------------------------------------------------------------
// AcrPull on the registry for the UAMI
// -----------------------------------------------------------------------------

resource raUamiAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(acr.id, uamiResourceId, roleAcrPull)
  properties: {
    principalId: uamiPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAcrPull)
  }
}

// -----------------------------------------------------------------------------
// Log Analytics + Container Apps environment
// -----------------------------------------------------------------------------

resource law 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: lawName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: acaEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Container App — DAB
// -----------------------------------------------------------------------------

resource acaApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: acaAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uamiResourceId}': {}
    }
  }
  dependsOn: [
    raUamiAcrPull   // role must propagate before the pull is attempted
  ]
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 5000
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: uamiResourceId
        }
      ]
      secrets: [
        {
          name: 'sql-connection-string'
          value: sqlConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'dab'
          image: dabImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'SQL_CONNECTION_STRING'
              secretRef: 'sql-connection-string'
            }
            // Hint to DefaultAzureCredential which UAMI to use when more
            // than one is attached to the container.
            {
              name: 'AZURE_CLIENT_ID'
              value: uamiClientId
            }
            // ACA's ingress terminates TLS at the edge and forwards plain
            // HTTP to the container with X-Forwarded-Proto: https. Without
            // this flag, Kestrel doesn't honor the header, so when DAB
            // issues a redirect (e.g. SP execute -> 201 with Location) the
            // Location is built with http:// and clients refuse to follow.
            {
              name: 'ASPNETCORE_FORWARDEDHEADERS_ENABLED'
              value: 'true'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

output acrLoginServer string = acr.properties.loginServer
output acaEnvName     string = acaEnv.name
output acaAppName     string = acaApp.name
output acaAppFqdn     string = acaApp.properties.configuration.ingress.fqdn
output acaAppUrl      string = 'https://${acaApp.properties.configuration.ingress.fqdn}'

