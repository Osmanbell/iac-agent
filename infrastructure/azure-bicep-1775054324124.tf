This Bicep implementation follows a modular, production-ready structure. It is divided into modules to ensure reusability and clean orchestration.

### **Folder Structure**
*   `main.bicep`: The entry point orchestrating all resources.
*   `modules/monitoring.bicep`: Log Analytics and Sentinel.
*   `modules/networking.bicep`: VNet, Subnet, and NSG.
*   `modules/compute.bicep`: Virtual Machine and AMA Extensions.
*   `modules/dcr.bicep`: Data Collection Rules and Associations.
*   `modules/security.bicep`: Defender for Cloud (Subscription-level).

---

### **1. Main Orchestrator (`main.bicep`)**
This file links all components together.

```bicep
targetScope = 'resourceGroup'

@description('The location for all resources.')
param location string = resourceGroup().location

@description('Prefix for resource naming.')
param prefix string = 'sec'

@description('Admin username for the VM.')
param adminUsername string = 'azureuser'

@description('Admin password for the VM.')
@secure()
param adminPassword string

// 1. Networking Module
module network './modules/networking.bicep' = {
  name: 'networkDeployment'
  params: {
    location: location
    prefix: prefix
  }
}

// 2. Monitoring Backend (LAW + Sentinel)
module monitoring './modules/monitoring.bicep' = {
  name: 'monitoringDeployment'
  params: {
    location: location
    prefix: prefix
  }
}

// 3. Compute Layer (VM + AMA)
module compute './modules/compute.bicep' = {
  name: 'computeDeployment'
  params: {
    location: location
    prefix: prefix
    subnetId: network.outputs.subnetId
    adminUsername: adminUsername
    adminPassword: adminPassword
  }
}

// 4. Data Collection Rules & Associations
module dcr './modules/dcr.bicep' = {
  name: 'dcrDeployment'
  params: {
    location: location
    prefix: prefix
    workspaceResourceId: monitoring.outputs.workspaceId
    vmName: compute.outputs.vmName
  }
}

output workspaceId string = monitoring.outputs.workspaceId
output vmPublicIP string = compute.outputs.vmPublicIP
```

---

### **2. Monitoring Module (`modules/monitoring.bicep`)**
Configures Log Analytics and onboards Sentinel.

```bicep
param location string
param prefix string

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${prefix}-law-${uniqueString(resourceGroup().id)}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Enable Sentinel on the Workspace
resource sentinel 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: 'SecurityInsights(${logAnalyticsWorkspace.name})'
  location: location
  properties: {
    workspaceResourceId: logAnalyticsWorkspace.id
  }
  plan: {
    name: 'SecurityInsights(${logAnalyticsWorkspace.name})'
    product: 'OMSGallery/SecurityInsights'
    promotionCode: ''
    publisher: 'Microsoft'
  }
}

output workspaceId string = logAnalyticsWorkspace.id
output workspaceName string = logAnalyticsWorkspace.name
```

---

### **3. Networking Module (`modules/networking.bicep`)**
Sets up the secure VNet and NSG.

```bicep
param location string
param prefix string

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: '${prefix}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowRDP'
        properties: {
          priority: 1000
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: 'VirtualNetwork' // Best practice: limit to your IP
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: '${prefix}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'default-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

output subnetId string = vnet.properties.subnets[0].id
```

---

### **4. Compute Module (`modules/compute.bicep`)**
Deploys the VM with Managed Identity and the Azure Monitor Agent (AMA).

```bicep
param location string
param prefix string
param subnetId string
param adminUsername string
@secure()
param adminPassword string

resource nic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: '${prefix}-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-07-01' = {
  name: '${prefix}-vm'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: { vmSize: 'Standard_D2s_v3' }
    osProfile: {
      computerName: '${prefix}-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
  }
}

// Azure Monitor Agent Extension (Successor to MMA)
resource ama 'Microsoft.Compute/virtualMachines/extensions@2023-07-01' = {
  parent: vm
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

output vmName string = vm.name
output vmId string = vm.id
```

---

### **5. Data Collection Rules Module (`modules/dcr.bicep`)**
Defines what logs are sent to the Workspace.

```bicep
param location string
param prefix string
param workspaceResourceId string
param vmName string

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: '${prefix}-dcr'
  location: location
  properties: {
    dataSources: {
      windowsEventLogs: [
        {
          streams: [ 'Microsoft-WindowsEvent' ]
          scheduledTransferPeriod: 'PT1M'
          selNames: [ 'System!*', 'Security!*', 'Application!*' ]
          name: 'eventLogsDataSource'
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspaceResourceId
          name: 'la-destination'
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-WindowsEvent' ]
        destinations: [ 'la-destination' ]
      }
    ]
  }
}

// Associate the DCR with the VM
resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'assoc-${vmName}'
  scope: resourceSymbolicName // This is applied to the VM resource
  properties: {
    dataCollectionRuleId: dcr.id
    description: 'Association of VM to DCR for Sentinel logging'
  }
}

// Helper to reference existing VM
resource resourceSymbolicName 'Microsoft.Compute/virtualMachines@2023-07-01' existing = {
  name: vmName
}
```

---

### **6. Defender for Cloud (Subscription Level)**
To enable Defender, you must deploy this with `targetScope = 'subscription'`.

```bicep
targetScope = 'subscription'

resource defenderServers 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'VirtualMachines'
  properties: {
    pricingTier: 'Standard' // This is the Defender for Servers plan
    subPlan: 'P1'
  }
}
```

---

### **Summary of Implementation Highlights**
1.  **Security**: The VM uses a **System-Assigned Managed Identity**, required by the Azure Monitor Agent to authenticate against the DCR.
2.  **Modernity**: Uses the **Azure Monitor Agent (AMA)** rather than the deprecated Log Analytics Agent (MMA/OMS).
3.  **Sentinel**: Automatically onboarded via the `SecurityInsights` solution.
4.  **Scalability**: The DCR is decoupled from the VM, allowing you to associate multiple VMs with the same logging policy easily.
5.  **Governance**: Networking is isolated with an NSG, and Defender for Cloud is enabled to provide Security Posture Management.