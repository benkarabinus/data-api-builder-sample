// =============================================================================
// Web UI — Streamlit demo app on Azure Container Apps
// -----------------------------------------------------------------------------
// Deploys a second container app (the Streamlit UI) into the SAME Container
// Apps environment created by dab-aca.bicep, pulling from the SAME registry.
//
// Reuses the step-1 User-Assigned Managed Identity. That identity already
// holds AcrPull on the registry (granted by dab-aca.bicep), so this template
// creates no new role assignment. The web app needs no SQL access — it only
// calls DAB's public REST endpoint over HTTPS.
//
// Scope: resource group.
// =============================================================================

targetScope = 'resourceGroup'

@description('Name prefix used for all resources. Should match the foundation deploy.')
@minLength(3)
@maxLength(12)
param namePrefix string

@description('Environment short name. Should match the foundation deploy.')
@minLength(2)
@maxLength(6)
param environmentName string = 'dev'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Resource ID of the User-Assigned Managed Identity (used to pull the image).')
param uamiResourceId string

@description('Name of the Azure Container Registry holding the web image.')
param acrName string

@description('Full web image name including registry and tag, e.g. myregistry.azurecr.io/web:latest.')
param webImage string

@description('Public base URL of the hosted DAB app, e.g. https://sqlrag-dab-dev.<region>.azurecontainerapps.io.')
param dabBaseUrl string

@description('Optional: Foundry project endpoint for the agent chat tab, e.g. https://<account>.services.ai.azure.com/api/projects/<project>.')
param foundryProjectEndpoint string = ''

@description('Optional: Foundry prompt agent name for the chat tab.')
param foundryAgentName string = ''

@description('Optional: Foundry prompt agent version for the chat tab. Empty resolves to the latest version.')
param foundryAgentVersion string = ''

@description('Client ID of the User-Assigned Managed Identity. Required so DefaultAzureCredential targets the UAMI for agent calls.')
param uamiClientId string

var acaEnvName = '${namePrefix}-acaenv-${environmentName}'
var webAppName = '${namePrefix}-web-${environmentName}'

// Both created earlier by dab-aca.bicep.
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: acrName
}

resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: acaEnvName
}

resource webApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: webAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uamiResourceId}': {}
    }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8501
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: uamiResourceId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'web'
          image: webImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'DAB_BASE_URL'
              value: dabBaseUrl
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: uamiClientId
            }
            {
              name: 'FOUNDRY_PROJECT_ENDPOINT'
              value: foundryProjectEndpoint
            }
            {
              name: 'FOUNDRY_AGENT_NAME'
              value: foundryAgentName
            }
            {
              name: 'FOUNDRY_AGENT_VERSION'
              value: foundryAgentVersion
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 2
      }
    }
  }
}

output acaAppName string = webApp.name
output acaAppFqdn string = webApp.properties.configuration.ingress.fqdn
output acaAppUrl  string = 'https://${webApp.properties.configuration.ingress.fqdn}'
