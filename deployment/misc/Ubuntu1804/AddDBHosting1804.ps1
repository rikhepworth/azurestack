﻿[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [String] $ASDKpath,

    [Parameter(Mandatory = $true)]
    [String] $deploymentMode,

    [Parameter(Mandatory = $true)]
    [ValidateSet("MySQL", "SQLServer")]
    [String] $dbHost,

    [parameter(Mandatory = $true)]
    [String] $tenantID,

    [parameter(Mandatory = $true)]
    [securestring] $secureVMpwd,

    [parameter(Mandatory = $true)]
    [pscredential] $asdkCreds,
    
    [parameter(Mandatory = $true)]
    [String] $ScriptLocation,

    [parameter(Mandatory = $false)]
    [String] $skipMySQL,

    [parameter(Mandatory = $false)]
    [String] $skipMSSQL,

    [Parameter(Mandatory = $true)]
    [String] $branch,

    [Parameter(Mandatory = $true)]
    [String] $sqlServerInstance,

    [Parameter(Mandatory = $true)]
    [String] $databaseName,

    [Parameter(Mandatory = $true)]
    [String] $tableName,

	# RegionName for if you need to override the default 'local'
    [Parameter(Mandatory = $false)]
    [string] $regionName = 'local',
    
    # External Domain Suffix for if you need to override the default 'azurestack.external'
    [Parameter(Mandatory = $false)]
    [string] $externalDomainSuffix = 'azurestack.external',

	# Github Account to override Matt's repo for download
	[Parameter(Mandatory = $false)]
    [String] $gitHubAccount = 'rikhepworth'
)

$Global:VerbosePreference = "Continue"
$Global:ErrorActionPreference = 'Stop'
$Global:ProgressPreference = 'SilentlyContinue'

$logFolder = "$($dbHost)AddHosting"
$logName = $logFolder
$progressName = $logFolder
$skipRP = $false

if ($dbHost -eq "MySQL") {
    if ($skipMySQL -eq $true) {
        $skipRP = $true
    }
}
elseif ($dbHost -eq "SQLServer") {
    if ($skipMSSQL -eq $true) {
        $skipRP = $true
    }
}

### SET LOG LOCATION ###
$logDate = Get-Date -Format FileDate
New-Item -ItemType Directory -Path "$ScriptLocation\Logs\$logDate\$logFolder" -Force | Out-Null
$logPath = "$ScriptLocation\Logs\$logDate\$logFolder"

### START LOGGING ###
$runTime = $(Get-Date).ToString("MMdd-HHmmss")
$fullLogPath = "$logPath\$($logName)$runTime.txt"
Start-Transcript -Path "$fullLogPath" -Append -IncludeInvocationHeader

$progressStage = $progressName
$progressCheck = CheckProgress -progressStage $progressStage

if ($progressCheck -eq "Complete") {
    Write-Verbose -Message "ASDK Configurator Stage: $progressStage previously completed successfully"
}
elseif (($skipRP -eq $false) -and ($progressCheck -ne "Complete")) {
    # We first need to check if in a previous run, this section was skipped, but now, the user wants to add this, so we need to reset the progress.
    if ($progressCheck -eq "Skipped") {
        Write-Verbose -Message "Operator previously skipped this step, but now wants to perform this step. Updating ConfigASDK database to Incomplete."
        # Update the ConfigASDK database back to incomplete
        StageReset -progressStage $progressStage
        $progressCheck = CheckProgress -progressStage $progressStage
    }
    if (($progressCheck -eq "Incomplete") -or ($progressCheck -eq "Failed")) {
        try {
            if ($progressCheck -eq "Failed") {
                # Update the ConfigASDK database back to incomplete status if previously failed
                StageReset -progressStage $progressStage
                $progressCheck = CheckProgress -progressStage $progressStage
            }
            # Need to ensure this stage doesn't start before the database SKU has been added
            $dbSkuJobCheck = $progressCheck = CheckProgress -progressStage "$($dbHost)SKUQuota"
            while ($dbSkuJobCheck -ne "Complete") {
                Write-Verbose -Message "The $($dbHost)SKUQuota stage of the process has not yet completed. Checking again in 20 seconds"
                Start-Sleep -Seconds 20
                $dbSkuJobCheck = $progressCheck = CheckProgress -progressStage "$($dbHost)SKUQuota"
                if ($dbSkuJobCheck -eq "Failed") {
                    throw "The $($dbHost)SKUQuota stage of the process has failed. This should fully complete before the $dbHost database host has been deployed. Check the $($dbHost)SKUQuota log, ensure that step is completed first, and rerun."
                }
            }
            # Need to ensure this stage doesn't start before the database host has finished deployment
            $dbHostJobCheck = CheckProgress -progressStage "$($dbHost)DBVM"
            while ($dbHostJobCheck -ne "Complete") {
                Write-Verbose -Message "The $($dbHost)DBVM stage of the process has not yet completed. Checking again in 20 seconds"
                Start-Sleep -Seconds 20
                $dbHostJobCheck = CheckProgress -progressStage "$($dbHost)DBVM"
                if ($dbHostJobCheck -eq "Failed") {
                    throw "The $($dbHost)DBVM stage of the process has failed. This should fully complete before the $dbHost database host has been deployed. Check the $($dbHost)DBVM log, ensure that step is completed first, and rerun."
                }
            }
            $ArmEndpoint = "https://adminmanagement.$regionName.$externalDomainSuffix"
            Add-AzureRMEnvironment -Name "AzureStackAdmin" -ArmEndpoint "$ArmEndpoint" -ErrorAction Stop
            Add-AzureRmAccount -EnvironmentName "AzureStackAdmin" -TenantId $tenantID -Credential $asdkCreds -ErrorAction Stop | Out-Null
            $dbrg = "azurestack-dbhosting"
            if ($dbHost -eq "MySQL") {
                $hostingJobCheck = "MySQLDBVM"
                $hostingPath = "MySQLHosting"
                $hostingTemplate = "mySqlHostingTemplate.json"
                $dbFqdn = (Get-AzureRmPublicIpAddress -Name "mysql_ip" -ResourceGroupName $dbrg).DnsSettings.Fqdn
            }
            elseif ($dbHost -eq "SQLServer") {
                $hostingJobCheck = "SQLServerDBVM"
                $hostingPath = "SQLHosting"
                $hostingTemplate = "sqlHostingTemplate.json"
                $dbFqdn = (Get-AzureRmPublicIpAddress -Name "sql_ip" -ResourceGroupName $dbrg).DnsSettings.Fqdn
            }
            # Need to ensure this stage doesn't start before the Ubuntu Server images have been put into the PIR
            $addHostingJobCheck = CheckProgress -progressStage "$hostingJobCheck"
            while ($addHostingJobCheck -ne "Complete") {
                Write-Verbose -Message "The $hostingJobCheck stage of the process has not yet completed. Checking again in 20 seconds"
                Start-Sleep -Seconds 20
                $addHostingJobCheck = CheckProgress -progressStage "$hostingJobCheck"
                if ($addHostingJobCheck -eq "Failed") {
                    throw "The $hostingJobCheck stage of the process has failed. This should fully complete before the database VMs can be deployed. Check the $hostingJobCheck log, ensure that step is completed first, and rerun."
                }
            }
            # Add host server to MySQL RP
            Write-Verbose -Message "Attaching $dbHost hosting server to $dbHost resource provider"
            if ($deploymentMode -eq "Online") {
                $templateURI = "https://raw.githubusercontent.com/$gitHubAccount/azurestack/$branch/deployment/templates/$hostingPath/azuredeploy.json"
            }
            elseif (($deploymentMode -eq "PartialOnline") -or ($deploymentMode -eq "Offline")) {
                $templateURI = Get-ChildItem -Path "$ASDKpath\templates" -Recurse -Include "$hostingTemplate" | ForEach-Object { $_.FullName }
            }
            if ($dbHost -eq "MySQL") {
                New-AzureRmResourceGroupDeployment -Name AddMySQLHostingServer -ResourceGroupName $dbrg -TemplateUri $templateURI `
                    -username "root" -password $secureVMpwd -hostingServerName $dbFqdn -totalSpaceMB 20480 `
                    -skuName "MySQL8" -Mode Incremental -Verbose -ErrorAction Stop
            }
            elseif ($dbHost -eq "SQLServer") {
                New-AzureRmResourceGroupDeployment -Name AddSQLServerHostingServer -ResourceGroupName $dbrg -TemplateUri $templateURI `
                    -hostingServerName $dbFqdn -hostingServerSQLLoginName "sa" -hostingServerSQLLoginPassword $secureVMpwd -totalSpaceMB 20480 `
                    -skuName "MSSQL2017" -Mode Incremental -Verbose -ErrorAction Stop
            }
            # Update the ConfigASDK database with successful completion
            $progressStage = $progressName
            StageComplete -progressStage $progressStage
        }
        catch {
            StageFailed -progressStage $progressStage
            Set-Location $ScriptLocation
            throw $_.Exception.Message
            return
        }
    }
}
elseif (($skipRP) -and ($progressCheck -ne "Complete")) {
    # Update the ConfigASDK database with skip status
    $progressStage = $progressName
    StageSkipped -progressStage $progressStage
}
Set-Location $ScriptLocation
Stop-Transcript -ErrorAction SilentlyContinue