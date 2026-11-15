param location string
param tags object
@minLength(13)
param token string
param principalId string
param principalType string
param enableGateway bool
param gpuVmSize string

var roles = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  acrImporter: '577a9874-89fd-4f24-9dbd-b5034d0ad23a' // Container Registry Data Importer and Data Reader
  openAiUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // Cognitive Services OpenAI User
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  monitoringReader: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  grafanaAdmin: '22926164-76b3-42b3-bc55-97df8dab3e41'
}

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${token}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${token}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acr${token}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

// Keyless: only Microsoft Entra tokens (the app's workload identity, the operator's az login) can call it.
resource openAi 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: 'oai-${token}'
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: 'oai-${token}'
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource embedding 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAi
  name: 'text-embedding-3-large'
  sku: { name: 'GlobalStandard', capacity: 150 }
  properties: {
    model: { format: 'OpenAI', name: 'text-embedding-3-large', version: '1' }
  }
}

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-movielog-app'
  location: location
  tags: tags
}

// Preview API: Gateway API, Application Gateway for Containers and application monitoring add-ons.
resource aks 'Microsoft.ContainerService/managedClusters@2026-08-02-preview' = {
  name: 'aks-${token}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  sku: { name: 'Base', tier: 'Free' }
  properties: {
    dnsPrefix: 'aks-${token}'
    agentPoolProfiles: [
      {
        name: 'nodepool1'
        mode: 'System'
        count: 2
        vmSize: 'Standard_D4s_v5'
        osType: 'Linux'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
    }
    oidcIssuerProfile: { enabled: true }
    securityProfile: { workloadIdentity: { enabled: true } }
    addonProfiles: {
      azureKeyvaultSecretsProvider: { enabled: true }
    }
    ingressProfile: enableGateway
      ? {
          gatewayAPI: { installation: 'Standard' }
          applicationLoadBalancer: { enabled: true }
        }
      : null
    azureMonitorProfile: {
      appMonitoring: { autoInstrumentation: { enabled: true } }
    }
  }
}

// Embedding server node: one NVIDIA GPU spot VM. Spot capacity uses the regional low-priority vCPU quota instead of
// the GPU family quota. AKS installs the driver, device plugin and DCGM exporter (managementMode Managed). After an
// eviction the autoscaler (min 1) requests a new spot VM.
resource gpuPool 'Microsoft.ContainerService/managedClusters/agentPools@2026-08-02-preview' = {
  parent: aks
  name: 'gpuspot'
  properties: {
    mode: 'User'
    vmSize: gpuVmSize
    count: 1
    enableAutoScaling: true
    minCount: 1
    maxCount: 1
    osType: 'Linux'
    scaleSetPriority: 'Spot'
    scaleSetEvictionPolicy: 'Delete'
    spotMaxPrice: -1
    nodeLabels: { workload: 'embeddings' }
    nodeTaints: ['sku=gpu:NoSchedule']
    gpuProfile: { driver: 'Install', nvidia: { managementMode: 'Managed' } }
  }
}

resource federatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: appIdentity
  name: 'movielog-sa'
  properties: {
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:movielog:movielog'
    audiences: ['api://AzureADTokenExchange']
  }
}

// Public network access is disabled; hooks/postprovision.sh adds a private endpoint in the AKS virtual network and
// writes the secrets through the ARM control plane.
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${token}'
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enablePurgeProtection: null
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'AzureServices' }
  }
}

resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' = {
  name: 'graf-${take(token, 10)}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  identity: { type: 'SystemAssigned' }
  properties: {
    zoneRedundancy: 'Disabled'
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, aks.id, roles.acrPull)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPull)
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

resource appOpenAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: openAi
  name: guid(openAi.id, appIdentity.id, roles.openAiUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.openAiUser)
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource appSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, appIdentity.id, roles.keyVaultSecretsUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource grafanaReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, grafana.id, roles.monitoringReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.monitoringReader)
    principalId: grafana.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// The operator embeds the catalog, imports images and uploads the dashboard.
resource operatorOpenAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: openAi
  name: guid(openAi.id, principalId, roles.openAiUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.openAiUser)
    principalId: principalId
    principalType: principalType
  }
}

resource operatorImporter 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: registry
  name: guid(registry.id, principalId, roles.acrImporter)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrImporter)
    principalId: principalId
    principalType: principalType
  }
}

resource operatorGrafanaAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: grafana
  name: guid(grafana.id, principalId, roles.grafanaAdmin)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.grafanaAdmin)
    principalId: principalId
    principalType: principalType
  }
}

output registryName string = registry.name
output registryEndpoint string = registry.properties.loginServer
output aksName string = aks.name
output aksNodeResourceGroup string = aks.properties.nodeResourceGroup
output aksOutboundIpId string = aks.properties.networkProfile.loadBalancerProfile.effectiveOutboundIPs[0].id
output openAiEndpoint string = openAi.properties.endpoint
output appIdentityClientId string = appIdentity.properties.clientId
output keyVaultName string = keyVault.name
output appInsightsId string = appInsights.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output grafanaName string = grafana.name
