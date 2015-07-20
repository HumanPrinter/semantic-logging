[CmdletBinding()]
Param (
  [Parameter(Mandatory=$True)][string] $CloudServiceName,
  [Parameter(Mandatory=$False)][string] $StorageAccountName,
  [Parameter(Mandatory=$True)][string] $VMSize,
  [Parameter(Mandatory=$True)][string] $vmPrefix,
  [Parameter(Mandatory=$True)][string] $ImageName,
  [Parameter(Mandatory=$False)][int] $SshPort = 50000,
  [Parameter(Mandatory=$False)][string] $gImageName = "elasticSearchBaseline",
  [Parameter(Mandatory=$False)][int] $localPort = 9200,
  [Parameter(Mandatory=$False)][int] $lbPort = 9200,
  [Parameter(Mandatory=$False)][string] $lbName = "myElasticSearchLB",
  [Parameter(Mandatory=$False)][string] $username = "elasticSearch",
  [Parameter(Mandatory=$True)][string] $password,
  [Parameter(Mandatory=$False)][string] $availabilitySetName = "elasticSearchAvailabilitySet",
  [Parameter(Mandatory=$False)][string] $vnetName,
  [Parameter(Mandatory=$False)][string] $subnetName,
  [Parameter(Mandatory=$True)][int] $numInstances,
  [Parameter(Mandatory=$False)][string] $ElasticSearchDebianPackageUrl = "https://download.elasticsearch.org/elasticsearch/elasticsearch/elasticsearch-1.5.2.deb",
  [Parameter(Mandatory=$True)][string] $configFile,
  [Parameter(Mandatory=$False)][int] $NumberOfHardDisks = 0,
  [Parameter(Mandatory=$False)][int] $DiskSizeInGB = 50,
  [switch] $NoMasterGeneration,
  [switch] $NoSshKeyGeneration,
  [switch] $ComputeSharding
)

############################
##
## VM deployment
##
############################
function setup
{
  Param (
    [Parameter(Mandatory=$True)][string] $VMName
  )
  Write-Host -NoNewline (Get-Date).ToString() "- [VM-Configuration] Adding Ssh Endpoint."
  Get-AzureVM -ServiceName $CloudServiceName -Name $VMName -Verbose:$False -EA Stop | Add-AzureEndpoint -Name "ssh" -Protocol "tcp" -PublicPort $SshPort -LocalPort 22 -Verbose:$False -EA Stop | Update-AzureVM -Verbose:$False -EA Stop
  Write-Host " [DONE]"

  Write-Host -NoNewline (Get-Date).ToString() "- [VM-Configuration] Adding Additional HardDrives."
  Add-HardDrives | Update-AzureVM -Verbose:$False -EA Stop
  Update-FsTab # this will make the added hard drives available to linux
  Write-Host " [DONE]"

  Install-ElasticSearch -SshString $sshString -SshPort $SshPort -VMNames $vmNames -ConfigFileLocation $configFile -ElasticSearchDebianPackageUrl $ElasticSearchDebianPackageUrl -NoMasterGeneration:$NoMasterGeneration -NumberOfInstances $numInstances -NumberOfHardDisks $NumberOfHardDisks -ComputeSharding:$ComputeSharding

  createGeneralizedImage -sshString $sshString -sshPort $SshPort -imageName $gImageName -cloudServiceName $CloudServiceName -vmName $VMName 
}

function Update-FsTab
{ # Copy the mount script over
  $MountScriptTransfer = $SshString + ":~/mountDisks.sh" #should be username@host:~/mountDisks.sh 
  Invoke-WrappedCommand -Command {scp  -o ConnectTimeout=360 -o StrictHostKeychecking=no -o UserKnownHostsFile=NUL -i id_rsa -P $SshPort  sh/mountDisks.sh $MountScriptTransfer}
  # Change file permissions to execute and run the script
  Invoke-WrappedCommand -Command {ssh -o ConnectTimeout=360 -o StrictHostKeychecking=no -o UserKnownHostsFile=NUL -i id_rsa -p $SshPort $SshString chmod +x mountDisks.sh}
  Invoke-WrappedCommand -Command {ssh -o ConnectTimeout=360 -o StrictHostKeychecking=no -o UserKnownHostsFile=NUL -i id_rsa -p $SshPort $SshString ./mountDisks.sh}
}

function Add-HardDrives
{
  $VM = Get-AzureVM -ServiceName $CloudServiceName -Name $VMName -Verbose:$False -EA Stop
  $Lun = ($VM | Get-AzureDataDisk | Measure-Object Lun -Maximum).Maximum + 1
  for ($i=0;$i -lt $NumberOfHardDisks; $i++)
  {
    $VM = $VM | Add-AzureDataDisk -CreateNew -DiskSizeInGB $DiskSizeInGB -DiskLabel "datadisk$i" -LUN $Lun -Verbose:$False -EA Stop
    $Lun = $Lun + 1
  }
  $VM
}

function startup
{
  Param (
    [Parameter(Mandatory=$True)][string] $VMName
  )
  Write-Host -NoNewline (Get-Date).ToString() "- [Configuration] Configure ElasticSearch to start up on boot."
  Get-AzureVM -ServiceName $CloudServiceName -Name $VMName -Verbose:$False -EA Stop | Add-AzureEndpoint -Name "ssh" -Protocol "tcp" -PublicPort $SshPort -LocalPort 22 -Verbose:$False -EA Stop | Add-AzureEndpoint -Name $lbName -LocalPort $localPort -PublicPort $lbPort -Protocol tcp -LBSetName $lbName -DefaultProbe -Verbose:$False -EA Stop | Update-AzureVM -Verbose:$False -EA Stop
  Start-ElasticSearch -SshPort $SshPort -SshString $sshString
  Get-AzureVM -ServiceName $CloudServiceName -Name $VMName -Verbose:$False -EA Stop | Remove-AzureEndpoint -Name "ssh" -Verbose:$False -EA Stop | Update-AzureVM -Verbose:$False -EA Stop
  Write-Host " [DONE]"
}

############################
##
## Script start up
##
############################

# Load modules and make sure we have a subscription and storage account context set
.\Init.ps1 -StorageAccountName $StorageAccountName

$vmNames = Get-VMNames -NumInstances $numInstances -VMPrefix $vmPrefix
$sshString = $username + "@" + $CloudServiceName + ".cloudapp.net"

$initialVMname = $vmPrefix + "-baseline"


$ignore = New-LinuxVM -VMName $initialVMname -VMSize $VMSize -CloudServiceName $CloudServiceName -UserName $username -Password $password -vnetName $vnetName -subnetName $subnetName -ImageName $ImageName -NoSshKeyGeneration:$NoSshKeyGeneration -setupFunction ${function:setup}

$ignore = New-LinuxVMCluster -imageName $gImageName -cloudServiceName $CloudServiceName -vmNames $vmNames -VMSize $vmSize -Username $username -Password $password -AvailabilitySetName $availabilitySetName -vnetName $vnetName -subnetName $subnetName -startupFunction ${function:startup}
