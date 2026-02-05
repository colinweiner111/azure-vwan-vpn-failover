// =============================================================================
// VMs Module - Test VMs in Branch and Spoke Networks
// =============================================================================
// Creates VMs in:
// - Branch1 ("Simulated ExpressRoute" site)
// - Branch2 ("VPN Backup" site)  
// - On-prem backend (shared network)
// - Spoke VNets (Azure workloads)
// =============================================================================

param location string
param adminUsername string
@secure()
param adminPassword string
param vmSize string
param hubName string

// Cloud-init script to install network diagnostic tools
var cloudInit = base64('''#cloud-config
package_update: true
packages:
  - traceroute
  - mtr
  - tcpdump
  - iperf3
''')

// =============================================================================
// Branch1 VM ("Simulated ExpressRoute" site)
// =============================================================================
resource branch1Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: 'branch1-er'
}

resource branch1Nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'branch1-er-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${branch1Vnet.id}/subnets/main'
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource branch1VM 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'branch1-er-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: 'branch1-er-vm-osdisk'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'branch1-er-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: cloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: branch1Nic.id
        }
      ]
    }
  }
}

// =============================================================================
// Branch2 VM ("VPN Backup" site)
// =============================================================================
resource branch2Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: 'branch2-vpn'
}

resource branch2Nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'branch2-vpn-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${branch2Vnet.id}/subnets/main'
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource branch2VM 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'branch2-vpn-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: 'branch2-vpn-vm-osdisk'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'branch2-vpn-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: cloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: branch2Nic.id
        }
      ]
    }
  }
}

// =============================================================================
// On-Prem Backend VM (shared destination for route testing)
// =============================================================================
resource onpremVnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: 'onprem-backend'
}

resource onpremNic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'onprem-backend-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${onpremVnet.id}/subnets/main'
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.10'  // Fixed IP for testing
        }
      }
    ]
  }
}

resource onpremVM 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'onprem-backend-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: 'onprem-backend-vm-osdisk'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'onprem-backend-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: cloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: onpremNic.id
        }
      ]
    }
  }
}

// =============================================================================
// Spoke1 VM (Azure workload)
// =============================================================================
resource spoke1Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: '${hubName}-spoke1'
}

resource spoke1Nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${hubName}-spoke1-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${spoke1Vnet.id}/subnets/main'
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource spoke1VM 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${hubName}-spoke1-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: '${hubName}-spoke1-vm-osdisk'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: '${hubName}-spoke1-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: cloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: spoke1Nic.id
        }
      ]
    }
  }
}

// =============================================================================
// Spoke2 VM (Azure workload)
// =============================================================================
resource spoke2Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: '${hubName}-spoke2'
}

resource spoke2Nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${hubName}-spoke2-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${spoke2Vnet.id}/subnets/main'
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource spoke2VM 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${hubName}-spoke2-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: '${hubName}-spoke2-vm-osdisk'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: '${hubName}-spoke2-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: cloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: spoke2Nic.id
        }
      ]
    }
  }
}

// =============================================================================
// Outputs
// =============================================================================
output branch1VMId string = branch1VM.id
output branch2VMId string = branch2VM.id
output onpremVMId string = onpremVM.id
output spoke1VMId string = spoke1VM.id
output spoke2VMId string = spoke2VM.id
output onpremVMPrivateIp string = '10.0.1.10'
