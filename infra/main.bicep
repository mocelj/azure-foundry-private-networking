// =============================================================================
// Private Microsoft Foundry — reference deployment (azd entry point)
// Modes: standalone (default) | hub-spoke | spoke-ready
// Outbound: byoVnet (default) | managedVnet (preview, explicit ack) | none
// =============================================================================
targetScope = 'subscription'

// ----------------------------------------------------------------------------- core
@minLength(1)
@maxLength(40)
@description('azd environment name; used for resource group and tags.')
param environmentName string

@minLength(1)
@description('Azure region. Foundry account, VNet and private endpoints must share this region.')
param location string

@description('Object ID of the human admin / demo user (azd sets AZURE_PRINCIPAL_ID). Empty = no human role assignments.')
param principalId string = ''

@allowed(['User', 'Group', 'ServicePrincipal'])
param principalType string = 'User'

// ----------------------------------------------------------------------------- networking
@description('standalone | hub-spoke | spoke-ready = private (default). public = quick demo without private networking (PUBLIC_NETWORK_ACCESS_ACK=true required by preflight; Entra-only).')
@allowed(['standalone', 'hub-spoke', 'spoke-ready', 'public'])
param networkMode string = 'standalone'

@description('NETWORK_MODE=public: comma-separated client IPv4 addresses/CIDRs allowed through the Foundry firewall. Empty = open to the internet (Entra-only).')
param publicAllowedIps string = ''

param vnetAddressPrefix string = '10.80.0.0/16'
param peSubnetPrefix string = '10.80.1.0/24'
param managementSubnetPrefix string = '10.80.2.0/24'
param bastionSubnetPrefix string = '10.80.3.0/26'
param appSubnetPrefix string = ''
param integrationSubnetPrefix string = ''
param agentSubnetPrefix string = '10.80.6.0/24'

@description('Outbound isolation for Foundry agents. byoVnet = Standard agent setup with VNet injection into snet-agent (default). managedVnet = Standard agent setup in a Microsoft-managed VNet, AllowOnlyApprovedOutbound (PREVIEW API, irreversible; preflight requires MANAGED_VNET_PREVIEW_ACK=true). none = models only.')
@allowed(['byoVnet', 'managedVnet', 'none'])
param outboundNetworkMode string = 'byoVnet'

@description('AI Search SKU for the Standard agent setup vector store.')
@allowed(['basic', 'standard', 'standard2', 'standard3'])
param agentSearchSku string = 'basic'

@description('Storage replication for the Standard agent setup file store.')
param agentStorageSku string = 'Standard_ZRS'

@description('Trusted-service exception on the agent storage account (AzureServices = Microsoft template default; None = no exception, validated live for all tested paths).')
@allowed(['AzureServices', 'None'])
param agentStorageNetworkBypass string = 'AzureServices'

@allowed(['AzureServices', 'None'])
param networkAclsBypass string = 'AzureServices'

@description('Comma-separated custom DNS servers for the spoke VNet (e.g. 10.0.2.4 = hub Private DNS Resolver inbound IP). Empty = Azure-provided DNS.')
param customDnsServers string = ''

// ----------------------------------------------------------------------------- hub integration
@description('Resource ID of the existing hub VNet (hub-spoke mode).')
param existingHubVnetId string = ''

@description('Create spoke -> hub peering.')
param enableHubPeering bool = false

@description('Also create hub -> spoke peering (modifies customer hub; explicit opt-in).')
param enableHubSidePeering bool = false

@description('Use the hub VPN/ExpressRoute gateway for the spoke.')
param useHubGateway bool = false

@description('Hub firewall/NVA private IP. When set (hub-spoke), a 0.0.0.0/0 UDR is applied to workload subnets.')
param hubFirewallPrivateIp string = ''

@description('Comma-separated source prefixes allowed to RDP to the jumpbox in hub-spoke mode (e.g. 10.0.3.0/26 = hub AzureBastionSubnet).')
param hubAdminSourcePrefixes string = ''

@allowed(['create', 'existing'])
param privateDnsZoneMode string = 'create'

@description('Comma-separated resource IDs of existing (central) private DNS zones (privateDnsZoneMode = existing). The zone name is taken from the last ID segment.')
param existingPrivateDnsZoneIds string = ''

// ----------------------------------------------------------------------------- admin access
param enableBastion bool = true
param enableJumpbox bool = true
param jumpboxVmSize string = 'Standard_D2s_v5'

@description('Daily jumpbox auto-shutdown (HHmm UTC). Empty = disabled.')
param jumpboxAutoShutdownTime string = '1900'

@secure()
@description('Random by default and never output. Entra ID sign-in is the supported access path.')
param jumpboxAdminPassword string = '${toUpper(take(newGuid(), 8))}#${newGuid()}'

@description('Grant the jumpbox managed identity data-plane roles so automated in-VNet functional tests can run.')
param grantJumpboxValidationRoles bool = true

@description('Object ID of the managed identity of an EXISTING private client (e.g. a hub workstation) used for seeding, demo-agent creation and in-VNet validation when no jumpbox is deployed (hub-spoke / spoke-ready). Gets the same scoped validation roles as the jumpbox. Empty = none.')
param privateClientPrincipalId string = ''

// ----------------------------------------------------------------------------- Foundry
param projectName string = 'private-demo'
param modelFormat string = 'OpenAI'
param modelName string = 'gpt-5.4-mini'
param modelVersion string = '2026-03-17'
param modelDeploymentType string = 'DataZoneStandard'
param modelCapacity int = 10

@minValue(30)
param logRetentionDays int = 30

// ----------------------------------------------------------------------------- optional modules
@description('Optional module 1: private Azure AI Search for curated knowledge (index seeded from inside the VNet).')
param enableAiSearch bool = false

@allowed(['basic', 'standard', 'standard2', 'standard3', 'storage_optimized_l1', 'storage_optimized_l2'])
param aiSearchSku string = 'basic'

@description('Name of the sample knowledge index (seeded by scripts/ai-search/Seed-KnowledgeIndex.ps1).')
param aiSearchIndexName string = 'contoso-policies'

@description('Optional module 6: Foundry IQ knowledge base over the private knowledge index (minimal reasoning, extractive; no outbound call from Search) + RemoteTool MCP connection. Requires enableAiSearch and byoVnet.')
param enableFoundryIq bool = false

@description('Foundry IQ knowledge base name (created post-provision from inside the network).')
param foundryIqKnowledgeBaseName string = 'contoso-policies-kb'

@description('Foundry IQ retrieval reasoning effort. minimal = no LLM, no outbound call from Search (default). low/medium = LLM query planning (option A+): adds a shared private link knowledge search -> Foundry account (openai_account, approved post-provision) and Cognitive Services OpenAI User for the search managed identity.')
@allowed(['minimal', 'low', 'medium'])
param foundryIqReasoning string = 'minimal'

@description('Optional module 5: advanced monitoring - Application Insights (Entra-only) connected to the project for server-side agent traces, AMPLS, alerts, saved queries.')
param enableAdvancedMonitoring bool = false

@description('Hub-spoke: resource ID of the central (hub-owned) Azure Monitor Private Link Scope to join. Standalone creates its own AMPLS.')
param existingAmplsId string = ''

@description('Optional e-mail for monitoring alerts. Empty = alerts are visible in Azure Monitor only.')
param monitorAlertEmail string = ''

@description('Public ingestion for Application Insights when a private path exists. Disabled = traces only via AMPLS. Changing it is an explicit, documented decision.')
@allowed(['Enabled', 'Disabled'])
param monitorPublicIngestion string = 'Disabled'

@description('Optional module 4: demo prompt agent grounded on the private knowledge index (created post-provision from inside the network). Requires enableAiSearch and byoVnet.')
param enableAgentDemo bool = false

@description('Name of the demo agent.')
param demoAgentName string = 'contoso-policy-agent'

@description('Optional module 7: hosted agent demo (Agent Framework code + project toolbox over the Foundry IQ knowledge base), deployed post-provision with azd from the in-network private client. No extra Azure resources. Requires enableFoundryIq.')
param enableHostedAgentDemo bool = false

@description('Optional module 3: private RAG demo (VM in snet-app, no public IP, no internet egress). Requires enableAiSearch.')
param enableRagDemo bool = false

@description('HTTPS port of the RAG demo app (reachable only from the VNet / peered hub).')
param ragAppPort int = 8443

param ragVmSize string = 'Standard_D2s_v5'

@secure()
@description('Random by default and never output. No interactive login path exists (no SSH rule).')
param ragVmAdminPassword string = '${toUpper(take(newGuid(), 8))}#${newGuid()}'

// =============================================================================
// Derived settings
// =============================================================================
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
  workload: 'foundry-private-enterprise-demo'
  'network-mode': networkMode
  // Makes non-private environments obvious in the portal, cost reports and Azure Policy.
  'network-exposure': networkMode == 'public' ? 'public' : 'private'
}

var isStandalone = networkMode == 'standalone'
var isHub = networkMode == 'hub-spoke'
// Quick-demo mode: no VNet, private endpoints, DNS zones, Bastion, jumpbox or NAT; Basic agent setup.
var isPublic = networkMode == 'public'
var privateNetwork = !isPublic
// Optional modules rely on private endpoints / in-network clients: not deployed in public mode (preflight fails early).
var aiSearchOn = enableAiSearch && privateNetwork
var publicAllowedIpList = filter(map(split(publicAllowedIps, ','), s => trim(s)), s => !empty(s))

// List/object parameters are strings so azd's ${VAR=default} substitution stays unambiguous.
var customDnsServerList = filter(map(split(customDnsServers, ','), s => trim(s)), s => !empty(s))
var hubAdminSourcePrefixList = filter(map(split(hubAdminSourcePrefixes, ','), s => trim(s)), s => !empty(s))
var existingPrivateDnsZoneIdList = filter(map(split(existingPrivateDnsZoneIds, ','), s => trim(s)), s => !empty(s))
var existingPrivateDnsZoneIdMap = toObject(existingPrivateDnsZoneIdList, id => last(split(id, '/')), id => id)
var deployBastion = isStandalone && enableBastion
var deployJumpbox = (isStandalone || isHub) && enableJumpbox
var deployAgentSubnet = outboundNetworkMode == 'byoVnet'
var deployManagedNetwork = outboundNetworkMode == 'managedVnet'
// Agents (Standard setup) run in either the customer subnet (byoVnet) or the managed VNet.
var agentsEnabled = (deployAgentSubnet || deployManagedNetwork) && privateNetwork
var deployRag = enableRagDemo && aiSearchOn
var deployMonitoring = enableAdvancedMonitoring && privateNetwork
var deployFoundryIq = enableFoundryIq && aiSearchOn && agentsEnabled
var deployFoundryIqPlanning = deployFoundryIq && foundryIqReasoning != 'minimal'
// Hosted agent demo: data-plane objects only (toolbox + hosted agent), created by the postprovision hook.
var deployHostedAgentDemo = enableHostedAgentDemo && deployFoundryIq
var foundryIqSplName = 'spl-foundry-openai'

// One AMPLS per DNS/network: standalone owns its DNS, hub-spoke joins the central hub AMPLS.
var createAmpls = deployMonitoring && isStandalone
var joinAmpls = deployMonitoring && isHub && !empty(existingAmplsId)
var monitorPrivatePath = createAmpls || joinAmpls
// snet-app defaults to the 5th /24 of the VNet when the RAG demo needs it and no prefix is given.
var effectiveAppSubnetPrefix = !empty(appSubnetPrefix) ? appSubnetPrefix : (deployRag ? cidrSubnet(vnetAddressPrefix, 24, 4) : '')

var egressMode = isHub && !empty(hubFirewallPrivateIp)
  ? 'hubFirewall'
  : (isStandalone && (deployJumpbox || deployAgentSubnet) ? 'natGateway' : 'none')

var adminSourcePrefixes = deployBastion ? [bastionSubnetPrefix] : (isHub ? hubAdminSourcePrefixList : [])

var foundryDnsZones = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
]
var agentDnsZones = {
  blob: 'privatelink.blob.${environment().suffixes.storage}'
  cosmos: 'privatelink.documents.azure.com'
  search: 'privatelink.search.windows.net'
}
var amplsDnsZones = [
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  'privatelink.blob.${environment().suffixes.storage}'
]
var allDnsZones = union(
  foundryDnsZones,
  agentsEnabled ? [agentDnsZones.blob, agentDnsZones.cosmos] : [],
  (agentsEnabled || aiSearchOn) ? [agentDnsZones.search] : [],
  createAmpls ? amplsDnsZones : []
)

var names = {
  rg: 'rg-${environmentName}'
  vnet: 'vnet-${environmentName}-${resourceToken}'
  law: 'log-${resourceToken}'
  account: 'aif-${resourceToken}'
  bastion: 'bas-${resourceToken}'
  jumpbox: 'vm-jump-${take(resourceToken, 6)}'
  rag: 'vm-rag-${take(resourceToken, 6)}'
  storage: 'stagent${resourceToken}'
  cosmos: 'cosmos-agent-${resourceToken}'
  search: 'srch-agent-${resourceToken}'
  knowledgeSearch: 'srch-kb-${resourceToken}'
  appInsights: 'appi-${resourceToken}'
  ampls: 'ampls-${resourceToken}'
}

// Built-in role IDs
var roles = {
  foundryUser: '53ca6127-db72-4b80-b1b0-d745d6d5456d' // data actions within a Foundry project
  openAiUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // inference on account endpoints
  searchIndexDataReader: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
  searchIndexDataContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  monitoringMetricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
  logAnalyticsReader: '73c42c96-874c-492b-b04d-ab87d138a893'
}

// =============================================================================
// Resources
// =============================================================================
resource rg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: names.rg
  location: location
  tags: tags
}

module law 'modules/monitoring/log-analytics.bicep' = {
  scope: rg
  params: {
    name: names.law
    location: location
    tags: tags
    retentionInDays: logRetentionDays
    publicNetworkAccessForQuery: monitorPrivatePath ? 'Disabled' : 'Enabled'
    publicNetworkAccessForIngestion: monitorPrivatePath ? monitorPublicIngestion : 'Enabled'
  }
}

module egress 'modules/networking/egress.bicep' = if (privateNetwork) {
  scope: rg
  params: {
    namePrefix: environmentName
    location: location
    tags: tags
    egressMode: egressMode
    hubFirewallPrivateIp: hubFirewallPrivateIp
  }
}

module vnet 'modules/networking/vnet.bicep' = if (privateNetwork) {
  scope: rg
  params: {
    name: names.vnet
    location: location
    tags: tags
    addressPrefixes: [vnetAddressPrefix]
    dnsServers: customDnsServerList
    peSubnetPrefix: peSubnetPrefix
    agentSubnetPrefix: deployAgentSubnet ? agentSubnetPrefix : ''
    managementSubnetPrefix: deployJumpbox ? managementSubnetPrefix : ''
    bastionSubnetPrefix: deployBastion ? bastionSubnetPrefix : ''
    appSubnetPrefix: effectiveAppSubnetPrefix
    appPort: ragAppPort
    integrationSubnetPrefix: integrationSubnetPrefix
    adminSourcePrefixes: adminSourcePrefixes
    managementInternetEgress: egressMode != 'none'
    natGatewayId: egress!.outputs.natGatewayId
    routeTableId: egress!.outputs.routeTableId
  }
}

module dns 'modules/private-dns/zones.bicep' = if (privateNetwork) {
  scope: rg
  params: {
    tags: tags
    zoneNames: allDnsZones
    mode: privateDnsZoneMode
    vnetIdsToLink: [vnet!.outputs.vnetId]
    existingZoneIds: existingPrivateDnsZoneIdMap
  }
}

module account 'modules/foundry/account.bicep' = {
  scope: rg
  params: {
    name: names.account
    location: location
    tags: tags
    agentSubnetId: privateNetwork ? vnet!.outputs.agentSubnetId : ''
    publicAccess: isPublic
    allowedIps: publicAllowedIpList
    managedNetwork: deployManagedNetwork
    networkAclsBypass: networkAclsBypass
  }
  // Module 5, standalone: the monitor private endpoint + DNS records must exist BEFORE the VNet-injected
  // agent runtime starts. Otherwise the runtime resolves the App Insights ingestion endpoint to its public
  // IP (rejected: public ingestion disabled) and keeps using that path -> no server-side traces
  // (observed 2026-11-18/19 on a from-scratch deployment; see docs/modules/monitoring.md).
  dependsOn: [peAmpls]
}

module diagnostics 'modules/monitoring/foundry-diagnostics.bicep' = {
  scope: rg
  params: {
    accountName: account.outputs.name
    workspaceId: law.outputs.id
  }
}

// Account-level operations are serialised: model -> account PE -> project (+connections)
// -> project MI RBAC -> capability host -> container-scoped RBAC.
module model 'modules/foundry/model-deployment.bicep' = {
  scope: rg
  params: {
    accountName: account.outputs.name
    deploymentName: modelName
    modelFormat: modelFormat
    modelName: modelName
    modelVersion: modelVersion
    deploymentType: modelDeploymentType
    capacity: modelCapacity
  }
}

module accountPe 'modules/private-endpoints/private-endpoint.bicep' = if (privateNetwork) {
  scope: rg
  params: {
    name: 'pe-${names.account}'
    location: location
    tags: tags
    subnetId: vnet!.outputs.peSubnetId
    privateLinkResourceId: account.outputs.id
    groupId: 'account'
    privateDnsZoneIds: [for z in foundryDnsZones: dns!.outputs.zoneIds[z]]
  }
  dependsOn: [model]
}

// ----------------------------------------------------------------------------- Standard agent setup
module agentDeps 'modules/agents/standard-dependencies.bicep' = if (agentsEnabled) {
  scope: rg
  params: {
    location: location
    tags: tags
    storageName: names.storage
    cosmosName: names.cosmos
    searchName: names.search
    workspaceId: law.outputs.id
    searchSku: agentSearchSku
    storageSkuName: agentStorageSku
    storageNetworkBypass: agentStorageNetworkBypass
  }
}

module storagePe 'modules/private-endpoints/private-endpoint.bicep' = if (agentsEnabled) {
  scope: rg
  params: {
    name: 'pe-${names.storage}-blob'
    location: location
    tags: tags
    subnetId: vnet!.outputs.peSubnetId
    privateLinkResourceId: agentDeps!.outputs.storageId
    groupId: 'blob'
    privateDnsZoneIds: [dns!.outputs.zoneIds[agentDnsZones.blob]]
  }
}

module cosmosPe 'modules/private-endpoints/private-endpoint.bicep' = if (agentsEnabled) {
  scope: rg
  params: {
    name: 'pe-${names.cosmos}'
    location: location
    tags: tags
    subnetId: vnet!.outputs.peSubnetId
    privateLinkResourceId: agentDeps!.outputs.cosmosId
    groupId: 'Sql'
    privateDnsZoneIds: [dns!.outputs.zoneIds[agentDnsZones.cosmos]]
  }
}

module searchPe 'modules/private-endpoints/private-endpoint.bicep' = if (agentsEnabled) {
  scope: rg
  params: {
    name: 'pe-${names.search}'
    location: location
    tags: tags
    subnetId: vnet!.outputs.peSubnetId
    privateLinkResourceId: agentDeps!.outputs.searchId
    groupId: 'searchService'
    privateDnsZoneIds: [dns!.outputs.zoneIds[agentDnsZones.search]]
  }
}

module project 'modules/foundry/project.bicep' = {
  scope: rg
  params: {
    accountName: account.outputs.name
    name: projectName
    location: location
    tags: tags
    displayName: 'Private Foundry demo (${environmentName})'
    projectDescription: 'Network-isolated Foundry project deployed by azure-foundry-private-networking.'
    agentDependencies: agentsEnabled
      ? {
          cosmosId: agentDeps!.outputs.cosmosId
          cosmosName: agentDeps!.outputs.cosmosName
          cosmosEndpoint: agentDeps!.outputs.cosmosEndpoint
          storageId: agentDeps!.outputs.storageId
          storageName: agentDeps!.outputs.storageName
          storageBlobEndpoint: agentDeps!.outputs.storageBlobEndpoint
          searchId: agentDeps!.outputs.searchId
          searchName: agentDeps!.outputs.searchName
        }
      : {}
  }
  // managed VNet: account-level writes are serialised; creating project connections while the managed
  // network provisions fails with 409 (observed 2026-11-19), so the project waits for it.
  dependsOn: [accountPe, storagePe, cosmosPe, searchPe, managedNetwork]
}

module projectDependencyRbac 'modules/agents/project-dependency-rbac.bicep' = if (agentsEnabled) {
  scope: rg
  params: {
    projectPrincipalId: project.outputs.principalId
    storageName: agentDeps!.outputs.storageName
    cosmosName: agentDeps!.outputs.cosmosName
    searchName: agentDeps!.outputs.searchName
  }
}

// ----------------------------------------------------------------------------- managed VNet (preview)
// Agent runtime in a Microsoft-managed VNet (AllowOnlyApprovedOutbound). Required outbound rules
// (Cosmos DB, Storage, agent Search, Entra ID) are created by the service; optional targets the agent
// must reach privately get explicit managed private endpoint rules.
var managedNetworkPeRules = concat(
  // Hosted agents call the project endpoint (storage, conversations, toolbox) from the managed VNet;
  // without this private endpoint back to the account they fail (connection reset -> HTTP 500).
  [{ name: 'pe-foundry-account', resourceId: account.outputs.id, subresource: 'account' }],
  aiSearchOn ? [{ name: 'pe-knowledge-search', resourceId: knowledgeSearch!.outputs.id, subresource: 'searchService' }] : [],
  createAmpls ? [{ name: 'pe-ampls', resourceId: ampls!.outputs.id, subresource: 'azuremonitor' }] : [],
  joinAmpls ? [{ name: 'pe-ampls', resourceId: existingAmplsId, subresource: 'azuremonitor' }] : []
)

module managedNetwork 'modules/foundry/managed-network.bicep' = if (deployManagedNetwork) {
  scope: rg
  params: {
    accountName: account.outputs.name
    accountPrincipalId: account.outputs.principalId
    privateEndpointRules: managedNetworkPeRules
  }
  dependsOn: [accountPe, agentDeps, storagePe, cosmosPe, searchPe, knowledgeSearchPe, peAmpls]
}

module capabilityHost 'modules/foundry/capability-host.bicep' = if (agentsEnabled) {
  scope: rg
  params: {
    accountName: account.outputs.name
    projectName: project.outputs.name
    cosmosConnectionName: project.outputs.cosmosConnectionName
    storageConnectionName: project.outputs.storageConnectionName
    searchConnectionName: project.outputs.searchConnectionName
  }
  // managed VNet: the managed network (and its outbound rules) must exist before the capability host.
  dependsOn: [projectDependencyRbac, managedNetwork]
}

module projectDataRbac 'modules/agents/project-data-rbac.bicep' = if (agentsEnabled) {
  scope: rg
  params: {
    projectPrincipalId: project.outputs.principalId
    workspaceIdGuid: project.outputs.workspaceIdGuid
    storageName: agentDeps!.outputs.storageName
    cosmosName: agentDeps!.outputs.cosmosName
  }
  dependsOn: [capabilityHost]
}

module bastion 'modules/bastion/bastion.bicep' = if (deployBastion) {
  scope: rg
  params: {
    name: names.bastion
    location: location
    tags: tags
    subnetId: vnet!.outputs.bastionSubnetId
    workspaceId: law.outputs.id
    readerPrincipals: deployJumpbox && !empty(principalId) ? [{ principalId: principalId, principalType: principalType }] : []
  }
}

module jumpbox 'modules/jumpbox/jumpbox.bicep' = if (deployJumpbox) {
  scope: rg
  params: {
    name: names.jumpbox
    location: location
    tags: tags
    subnetId: vnet!.outputs.managementSubnetId
    vmSize: jumpboxVmSize
    adminPassword: jumpboxAdminPassword
    autoShutdownTime: jumpboxAutoShutdownTime
    loginPrincipals: empty(principalId) ? [] : [{ principalId: principalId, principalType: principalType }]
  }
}

var humanAssignments = empty(principalId)
  ? []
  : [
      {
        principalId: principalId
        principalType: principalType
        roleDefinitionId: roles.foundryUser
        scope: 'project'
        purpose: 'Demo user: build and run in the Foundry project'
      }
      {
        principalId: principalId
        principalType: principalType
        roleDefinitionId: roles.openAiUser
        scope: 'account'
        purpose: 'Demo user: model inference on account endpoints'
      }
    ]

// Validation client = the jumpbox MI, or (no jumpbox) an existing private client MI. Data-plane roles only, scoped per resource.
var validationClientPrincipalId = !grantJumpboxValidationRoles ? '' : (deployJumpbox ? jumpbox!.outputs.principalId : privateClientPrincipalId)
var grantValidationRoles = !empty(validationClientPrincipalId)
var jumpboxAssignments = grantValidationRoles
  ? [
      {
        principalId: validationClientPrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: roles.openAiUser
        scope: 'account'
        purpose: 'Validation client: in-VNet model inference tests'
      }
      {
        principalId: validationClientPrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: roles.foundryUser
        scope: 'project'
        purpose: 'Validation client: in-VNet project/agent tests'
      }
    ]
  : []

module rbac 'modules/identity/foundry-rbac.bicep' = {
  scope: rg
  params: {
    accountName: account.outputs.name
    projectName: project.outputs.name
    assignments: concat(humanAssignments, jumpboxAssignments)
  }
}

// ----------------------------------------------------------------------------- optional module 1: AI Search
module knowledgeSearch 'modules/ai-search/search.bicep' = if (aiSearchOn) {
  scope: rg
  params: {
    name: names.knowledgeSearch
    location: location
    tags: tags
    workspaceId: law.outputs.id
    sku: aiSearchSku
  }
}

module knowledgeSearchPe 'modules/private-endpoints/private-endpoint.bicep' = if (aiSearchOn) {
  scope: rg
  params: {
    name: 'pe-${names.knowledgeSearch}'
    location: location
    tags: tags
    subnetId: vnet!.outputs.peSubnetId
    privateLinkResourceId: knowledgeSearch!.outputs.id
    groupId: 'searchService'
    privateDnsZoneIds: [dns!.outputs.zoneIds[agentDnsZones.search]]
  }
}

module knowledgeSearchConnection 'modules/foundry/connection-search.bicep' = if (aiSearchOn) {
  scope: rg
  params: {
    accountName: account.outputs.name
    projectName: project.outputs.name
    searchName: knowledgeSearch!.outputs.name
    searchId: knowledgeSearch!.outputs.id
    location: location
  }
  dependsOn: [capabilityHost]
}

// ----------------------------------------------------------------------------- optional module 6: Foundry IQ
module knowledgeBaseConnection 'modules/foundry/connection-knowledge-base.bicep' = if (deployFoundryIq) {
  scope: rg
  params: {
    accountName: account.outputs.name
    projectName: project.outputs.name
    searchName: knowledgeSearch!.outputs.name
    knowledgeBaseName: foundryIqKnowledgeBaseName
  }
  // Serialize project connection writes.
  dependsOn: [capabilityHost, knowledgeSearchConnection]
}

// Option A+ (LLM query planning): Search calls the model at query time over a shared private link.
module foundryIqSpl 'modules/ai-search/shared-private-link.bicep' = if (deployFoundryIqPlanning) {
  scope: rg
  params: {
    searchName: knowledgeSearch!.outputs.name
    name: foundryIqSplName
    privateLinkResourceId: account.outputs.id
    groupId: 'openai_account'
    requestMessage: 'Foundry IQ query planning from ${names.knowledgeSearch} (${environmentName})'
  }
  // Search accepts one write at a time: create the link after the inbound private endpoint.
  dependsOn: [knowledgeSearchPe]
}

module foundryIqModelRbac 'modules/ai-search/search-model-rbac.bicep' = if (deployFoundryIqPlanning) {
  scope: rg
  params: {
    accountName: account.outputs.name
    searchPrincipalId: knowledgeSearch!.outputs.principalId
  }
}

// ----------------------------------------------------------------------------- optional module 5: advanced monitoring
module appInsights 'modules/monitoring/app-insights.bicep' = if (deployMonitoring) {
  scope: rg
  params: {
    name: names.appInsights
    location: location
    tags: tags
    workspaceId: law.outputs.id
    publicNetworkAccessForIngestion: monitorPrivatePath ? monitorPublicIngestion : 'Enabled'
    publicNetworkAccessForQuery: monitorPrivatePath ? 'Disabled' : 'Enabled'
  }
}

module ampls 'modules/monitoring/ampls.bicep' = if (createAmpls) {
  scope: rg
  params: {
    name: names.ampls
    tags: tags
    scopedResourceIds: [law.outputs.id, appInsights!.outputs.id]
  }
}

module peAmpls 'modules/private-endpoints/private-endpoint.bicep' = if (createAmpls) {
  scope: rg
  params: {
    name: 'pe-${names.ampls}'
    location: location
    tags: tags
    subnetId: vnet!.outputs.peSubnetId
    privateLinkResourceId: ampls!.outputs.id
    groupId: 'azuremonitor'
    privateDnsZoneIds: [for z in amplsDnsZones: dns!.outputs.zoneIds[z]]
  }
}

module amplsJoin 'modules/monitoring/ampls-scoped-resources.bicep' = if (joinAmpls) {
  scope: resourceGroup(split(existingAmplsId, '/')[2], split(existingAmplsId, '/')[4])
  params: {
    amplsName: last(split(existingAmplsId, '/'))
    scopedResourceIds: [law.outputs.id, appInsights!.outputs.id]
  }
}

module appInsightsConnection 'modules/foundry/connection-appinsights.bicep' = if (deployMonitoring) {
  scope: rg
  params: {
    accountName: account.outputs.name
    projectName: project.outputs.name
    appInsightsName: appInsights!.outputs.name
  }
  // Serialize project connection writes.
  dependsOn: [capabilityHost, knowledgeSearchConnection, knowledgeBaseConnection]
}

module monitoringRbac 'modules/monitoring/monitoring-rbac.bicep' = if (deployMonitoring) {
  scope: rg
  params: {
    appInsightsName: appInsights!.outputs.name
    workspaceName: law.outputs.name
    assignments: concat(
      [
        {
          principalId: project.outputs.principalId
          principalType: 'ServicePrincipal'
          roleDefinitionId: roles.monitoringMetricsPublisher
          target: 'appInsights'
          purpose: 'Project MI: Entra-authenticated server-side agent trace ingestion'
        }
      ],
      empty(principalId)
        ? []
        : [
            {
              principalId: principalId
              principalType: principalType
              roleDefinitionId: roles.logAnalyticsReader
              target: 'appInsights'
              purpose: 'Demo user: view agent traces in the Foundry portal'
            }
            {
              principalId: principalId
              principalType: principalType
              roleDefinitionId: roles.logAnalyticsReader
              target: 'workspace'
              purpose: 'Demo user: run saved monitoring queries'
            }
          ],
      grantValidationRoles
        ? [
            {
              principalId: validationClientPrincipalId
              principalType: 'ServicePrincipal'
              roleDefinitionId: roles.logAnalyticsReader
              target: 'appInsights'
              purpose: 'Validation client: verify agent traces are stored (query over AMPLS)'
            }
            {
              principalId: validationClientPrincipalId
              principalType: 'ServicePrincipal'
              roleDefinitionId: roles.logAnalyticsReader
              target: 'workspace'
              purpose: 'Validation client: verify resource logs still arrive (query over AMPLS)'
            }
          ]
        : []
    )
  }
}

module alerts 'modules/monitoring/alerts.bicep' = if (deployMonitoring) {
  scope: rg
  params: {
    namePrefix: environmentName
    location: location
    tags: tags
    accountId: account.outputs.id
    alertEmail: monitorAlertEmail
  }
}

var searchAssignments = concat(
  [
    // Documented requirement of the Foundry IQ / Azure AI Search agent tool (keyless auth):
    // https://learn.microsoft.com/azure/foundry/agents/how-to/tools/ai-search#troubleshooting
    // Index Data Reader alone fails with 403 on Indexes.Get (observed live). Admin keys are
    // unusable because the service has disableLocalAuth=true; scope is this service only.
    {
      principalId: project.outputs.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: roles.searchIndexDataContributor
      purpose: 'Foundry project MI: knowledge index access for agents (AI Search tool, documented requirement)'
    }
    {
      principalId: project.outputs.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: roles.searchServiceContributor
      purpose: 'Foundry project MI: read knowledge index definitions for agents (AI Search tool, documented requirement)'
    }
  ],
  empty(principalId)
    ? []
    : [
        {
          principalId: principalId
          principalType: principalType
          roleDefinitionId: roles.searchIndexDataReader
          purpose: 'Demo user: query knowledge index'
        }
      ],
  grantValidationRoles
    ? [
        {
          principalId: validationClientPrincipalId
          principalType: 'ServicePrincipal'
          roleDefinitionId: roles.searchServiceContributor
          purpose: 'Validation client: create sample index from inside the VNet'
        }
        {
          principalId: validationClientPrincipalId
          principalType: 'ServicePrincipal'
          roleDefinitionId: roles.searchIndexDataContributor
          purpose: 'Validation client: upload synthetic documents from inside the VNet'
        }
      ]
    : []
)

module knowledgeSearchRbac 'modules/ai-search/search-rbac.bicep' = if (aiSearchOn) {
  scope: rg
  params: {
    searchName: knowledgeSearch!.outputs.name
    assignments: searchAssignments
  }
}

// ----------------------------------------------------------------------------- optional module 3: RAG demo
module ragVm 'modules/rag/rag-vm.bicep' = if (deployRag) {
  scope: rg
  params: {
    name: names.rag
    location: location
    tags: union(tags, { 'demo-app': 'rag' })
    subnetId: vnet!.outputs.appSubnetId
    vmSize: ragVmSize
    adminPassword: ragVmAdminPassword
    autoShutdownTime: jumpboxAutoShutdownTime
  }
}

module ragFoundryRbac 'modules/identity/foundry-rbac.bicep' = if (deployRag) {
  scope: rg
  params: {
    accountName: account.outputs.name
    projectName: project.outputs.name
    assignments: [
      {
        principalId: ragVm!.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: roles.openAiUser
        scope: 'account'
        purpose: 'RAG demo app MI: model inference over the private endpoint'
      }
    ]
  }
}

module ragSearchRbac 'modules/ai-search/search-rbac.bicep' = if (deployRag) {
  scope: rg
  params: {
    searchName: knowledgeSearch!.outputs.name
    assignments: [
      {
        principalId: ragVm!.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: roles.searchIndexDataReader
        purpose: 'RAG demo app MI: query the knowledge index (read-only)'
      }
    ]
  }
}

module spokeToHubPeering 'modules/networking/spoke-to-hub-peering.bicep' = if (isHub && enableHubPeering && !empty(existingHubVnetId)) {
  scope: rg
  params: {
    spokeVnetName: vnet!.outputs.vnetName
    hubVnetId: existingHubVnetId
    useRemoteGateways: useHubGateway
  }
}

module hubToSpokePeering 'modules/networking/hub-to-spoke-peering.bicep' = if (isHub && enableHubSidePeering && !empty(existingHubVnetId)) {
  scope: resourceGroup(split(existingHubVnetId, '/')[2], split(existingHubVnetId, '/')[4])
  params: {
    hubVnetName: last(split(existingHubVnetId, '/'))
    spokeVnetId: vnet!.outputs.vnetId
    allowGatewayTransit: useHubGateway
  }
}

// =============================================================================
// Outputs (no secrets)
// =============================================================================
output AZURE_RESOURCE_GROUP string = rg.name
output DEPLOYED_NETWORK_MODE string = networkMode
output DEPLOYED_OUTBOUND_NETWORK_MODE string = outboundNetworkMode
output DEPLOYED_MANAGED_NETWORK_RULES string = deployManagedNetwork ? join(map(managedNetworkPeRules, r => r.name), ',') : ''
output EGRESS_MODE string = egressMode
output VNET_NAME string = privateNetwork ? vnet!.outputs.vnetName : ''
output VNET_ID string = privateNetwork ? vnet!.outputs.vnetId : ''
output DEPLOYED_PE_SUBNET_PREFIX string = peSubnetPrefix
output AZURE_AI_ACCOUNT_NAME string = account.outputs.name
output AZURE_AI_PROJECT_NAME string = project.outputs.name
output AZURE_AI_PROJECT_ENDPOINT string = project.outputs.endpoint
output AZURE_OPENAI_ENDPOINT string = 'https://${account.outputs.name}.openai.azure.com/'
output AZURE_AI_MODEL_DEPLOYMENT_NAME string = model.outputs.name
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = law.outputs.id
output AGENT_STORAGE_ACCOUNT_NAME string = agentsEnabled ? agentDeps!.outputs.storageName : ''
output AGENT_COSMOS_ACCOUNT_NAME string = agentsEnabled ? agentDeps!.outputs.cosmosName : ''
output AGENT_SEARCH_SERVICE_NAME string = agentsEnabled ? agentDeps!.outputs.searchName : ''
output DEPLOYED_AI_SEARCH bool = aiSearchOn
output KNOWLEDGE_SEARCH_NAME string = aiSearchOn ? knowledgeSearch!.outputs.name : ''
output KNOWLEDGE_SEARCH_INDEX string = aiSearchOn ? aiSearchIndexName : ''
output RAG_VM_NAME string = deployRag ? ragVm!.outputs.name : ''
output RAG_VM_ID string = deployRag ? ragVm!.outputs.id : ''
output RAG_APP_URL string = deployRag ? 'https://${ragVm!.outputs.privateIp}:${ragAppPort}/' : ''
output DEPLOYED_RAG_APP_PORT int = ragAppPort
output KNOWLEDGE_SEARCH_CONNECTION_ID string = aiSearchOn ? knowledgeSearchConnection!.outputs.id : ''
output DEMO_AGENT_NAME string = (enableAgentDemo && aiSearchOn && agentsEnabled) ? demoAgentName : ''
output DEPLOYED_ADVANCED_MONITORING bool = deployMonitoring
output FOUNDRY_IQ_KNOWLEDGE_BASE string = deployFoundryIq ? foundryIqKnowledgeBaseName : ''
output FOUNDRY_IQ_MCP_CONNECTION string = deployFoundryIq ? knowledgeBaseConnection!.outputs.name : ''
output FOUNDRY_IQ_MCP_URL string = deployFoundryIq ? knowledgeBaseConnection!.outputs.target : ''
output DEPLOYED_FOUNDRY_IQ_REASONING string = deployFoundryIq ? foundryIqReasoning : ''
output DEPLOYED_HOSTED_AGENT_DEMO bool = deployHostedAgentDemo
output FOUNDRY_IQ_SPL_NAME string = deployFoundryIqPlanning ? foundryIqSpl!.outputs.name : ''
output DEPLOYED_MODEL_NAME string = modelName
output APPLICATIONINSIGHTS_NAME string = deployMonitoring ? appInsights!.outputs.name : ''
output APPLICATIONINSIGHTS_APP_ID string = deployMonitoring ? appInsights!.outputs.appId : ''
output AMPLS_ID string = createAmpls ? ampls!.outputs.id : (joinAmpls ? existingAmplsId : '')
output BASTION_NAME string = deployBastion ? bastion!.outputs.name : ''
output JUMPBOX_VM_NAME string = deployJumpbox ? jumpbox!.outputs.name : ''
output JUMPBOX_VM_ID string = deployJumpbox ? jumpbox!.outputs.id : ''
