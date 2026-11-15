// MovieLog on Azure HorizonDB: everything except HorizonDB itself, which has no Bicep types yet (BCP081) and is
// created by hooks/postprovision.sh through the ARM REST API.
targetScope = 'subscription'

@minLength(1)
@maxLength(48)
@description('azd environment name; names the resource group and seeds the resource name suffix.')
param environmentName string

@minLength(1)
@description('Region for every resource, including the HorizonDB cluster created by the hook.')
param location string

@description('Object ID of the identity running azd. It gets the data-plane roles the hooks need.')
param principalId string = ''

@allowed(['User', 'ServicePrincipal'])
param principalType string = 'User'

@description('Install the Gateway API and Application Gateway for Containers add-ons for the HTTPS endpoint.')
param enableGateway bool = true

@description('NVIDIA GPU VM size of the spot node pool that serves the bge-m3-ko embeddings with vLLM.')
param gpuVmSize string = 'Standard_NC4as_T4_v3'

var tags = { 'azd-env-name': environmentName }
var token = toLower(uniqueString(subscription().id, environmentName, location))

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  scope: rg
  name: 'movielog-resources'
  params: {
    location: location
    tags: tags
    token: token
    principalId: principalId
    principalType: principalType
    enableGateway: enableGateway
    gpuVmSize: gpuVmSize
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_CONTAINER_REGISTRY_NAME string = resources.outputs.registryName
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.registryEndpoint
output AZURE_AKS_CLUSTER_NAME string = resources.outputs.aksName
output AZURE_AKS_NODE_RESOURCE_GROUP string = resources.outputs.aksNodeResourceGroup
output AZURE_AKS_OUTBOUND_IP_ID string = resources.outputs.aksOutboundIpId
output AZURE_OPENAI_ENDPOINT string = resources.outputs.openAiEndpoint
output MI_CLIENT_ID string = resources.outputs.appIdentityClientId
output KEYVAULT_NAME string = resources.outputs.keyVaultName
output APPLICATIONINSIGHTS_ID string = resources.outputs.appInsightsId
output APPLICATIONINSIGHTS_CONNECTION_STRING string = resources.outputs.appInsightsConnectionString
output AZURE_GRAFANA_NAME string = resources.outputs.grafanaName
output HORIZONDB_CLUSTER_NAME string = 'hzdb-${token}'
output GATEWAY_ENABLED bool = enableGateway
