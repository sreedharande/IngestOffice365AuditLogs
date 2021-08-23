# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' porperty is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# Write an information log with the current time.
Write-Host "PowerShell timer trigger function ran! TIME: $currentUTCtime"

# Main
if ($env:MSI_SECRET -and (Get-Module -ListAvailable Az.Accounts)){
    Connect-AzAccount -Identity
}

#region Environment Variables

$Office365ContentTypes = $env:contentTypes
$Office365RecordTypes = $env:recordTypes
$Office365CustomLog = $env:customLogName
$LAWorkspaceId = $env:workspaceID
$LAWorkspaceKey = $env:workspaceKey
$AADAppClientId = $env:clientID 
$AADAppClientSecret = $env:clientSecret 
$AADAppClientDomain = $env:domain
$AADAppPublisher = $env:publisher
$AzureTenantId = $env:tenantGuid
$LAUri = $env:LAUri
$AzureAADLoginUri = $env:AzureAADLoginUri
$OfficeLoginUri = $env:OfficeLoginUri
$azstoragestring = $env:WEBSITE_CONTENTAZUREFILECONNECTIONSTRING
#endregion

if (-Not [string]::IsNullOrEmpty($LAUri)){
	if($LAUri.Trim() -notmatch 'https:\/\/([\w\-]+)\.ods\.opinsights\.azure.([a-zA-Z\.]+)$')
	{
		Write-Error -Message "O365Data: Invalid Log Analytics Uri." -ErrorAction Stop
		Exit
	}
}

function Write-OMSLogfile {
    <#
    .SYNOPSIS
    Inputs a hashtable, date and workspace type and writes it to a Log Analytics Workspace.
    .DESCRIPTION
    Given a  value pair hash table, this function will write the data to an OMS Log Analytics workspace.
    Certain variables, such as Customer ID and Shared Key are specific to the OMS workspace data is being written to.
    This function will not write to multiple OMS workspaces.  Build-signature and post-analytics function from Microsoft documentation
    at https://docs.microsoft.com/en-us/azure/log-analytics/log-analytics-data-collector-api
    .PARAMETER DateTime
    date and time for the log.  DateTime value
    .PARAMETER Type
    Name of the logfile or Log Analytics "Type".  Log Analytics will append _CL at the end of custom logs  String Value
    .PARAMETER LogData
    A series of key, value pairs that will be written to the log.  Log file are unstructured but the key should be consistent
    withing each source.
    .INPUTS
    The parameters of data and time, type and logdata.  Logdata is converted to JSON to submit to Log Analytics.
    .OUTPUTS
    The Function will return the HTTP status code from the Post method.  Status code 200 indicates the request was received.
    .NOTES
    Version:        2.0
    Author:         Travis Roberts
    Creation Date:  7/9/2018
    Purpose/Change: Crating a stand alone function.
    .EXAMPLE
    This Example will log data to the "LoggingTest" Log Analytics table
    $type = 'LoggingTest'
    $dateTime = Get-Date
    $data = @{
        ErrorText   = 'This is a test message'
        ErrorNumber = 1985
    }
    $returnCode = Write-OMSLogfile $dateTime $type $data -Verbose
    write-output $returnCode
    #>
        [cmdletbinding()]
        Param(
            [Parameter(Mandatory = $true, Position = 0)]
            [datetime]$dateTime,
            [parameter(Mandatory = $true, Position = 1)]
            [string]$type,
            [Parameter(Mandatory = $true, Position = 2)]
            [psobject]$logdata,
            [Parameter(Mandatory = $true, Position = 3)]
            [string]$CustomerID,
            [Parameter(Mandatory = $true, Position = 4)]
            [string]$SharedKey
        )
        Write-Verbose -Message "DateTime: $dateTime"
        Write-Verbose -Message ('DateTimeKind:' + $dateTime.kind)
        Write-Verbose -Message "Type: $type"
        write-Verbose -Message "LogData: $logdata"
        
		# Supporting Functions
		
        # Function to create the auth signature
        function Build-signature ($CustomerID, $SharedKey, $Date, $ContentLength, $method, $ContentType, $resource) {
            $xheaders = 'x-ms-date:' + $Date
            $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
            $bytesToHash = [text.Encoding]::UTF8.GetBytes($stringToHash)
            $keyBytes = [Convert]::FromBase64String($SharedKey)
            $sha256 = New-Object System.Security.Cryptography.HMACSHA256
            $sha256.key = $keyBytes
            $calculateHash = $sha256.ComputeHash($bytesToHash)
            $encodeHash = [convert]::ToBase64String($calculateHash)
            $authorization = 'SharedKey {0}:{1}' -f $CustomerID,$encodeHash
            return $authorization
        }
		
        # Function to create and post the request
        Function Post-LogAnalyticsData ($CustomerID, $SharedKey, $Body, $Type) {
            $method = "POST"
            $ContentType = 'application/json'
            $resource = '/api/logs'
            $rfc1123date = ($dateTime).ToString('r')
            $ContentLength = $Body.Length
            $signature = Build-signature `
                -customerId $CustomerID `
                -sharedKey $SharedKey `
                -date $rfc1123date `
                -contentLength $ContentLength `
                -method $method `
                -contentType $ContentType `
                -resource $resource
			            
			# Compatible with previous version and supports both Azure Commercial and Azure Gov
			if ([string]::IsNullOrEmpty($LAUri)){
				$uri = "https://" + $CustomerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
			}
			else
			{
				$uri = $LAURI + $resource + "?api-version=2016-04-01"
			}
			
            $headers = @{
                "Authorization" = $signature;
                "Log-Type" = $type;
                "x-ms-date" = $rfc1123date
                "time-generated-field" = $dateTime
            }
            $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $ContentType -Headers $headers -Body $body -UseBasicParsing
            Write-Verbose -message ('Post Function Return Code ' + $response.statuscode)
            return $response.statuscode
        }

        # Check if time is UTC, Convert to UTC if not.
        # $dateTime = (Get-Date)
        if ($dateTime.kind.tostring() -ne 'Utc'){
            $dateTime = $dateTime.ToUniversalTime()
            Write-Verbose -Message $dateTime
        }

        # Add DateTime to hashtable
        #$logdata.add("DateTime", $dateTime)
        $logdata | Add-Member -MemberType NoteProperty -Name "DateTime" -Value $dateTime

        #Build the JSON file
        $logMessage = ($logdata | ConvertTo-Json -Depth 20)
        Write-Verbose -Message $logMessage

        #Submit the data
        #$returnCode = Post-LogAnalyticsData -CustomerID $CustomerID -SharedKey $SharedKey -Body ([System.Text.Encoding]::UTF8.GetBytes($logMessage)) -Type $type
        $returnCode = Post-LogAnalyticsData -CustomerID $CustomerID -SharedKey $SharedKey -Body $logMessage -Type $type
        Write-Verbose -Message "Post Statement Return Code $returnCode"
        return $returnCode
    }

function Get-AuthToken{
    [cmdletbinding()]
        Param(
            [Parameter(Mandatory = $true, Position = 0)]
            [string]$ClientID,
            [parameter(Mandatory = $true, Position = 1)]
            [string]$ClientSecret,
            [Parameter(Mandatory = $true, Position = 2)]
            [string]$tenantdomain,
            [Parameter(Mandatory = $true, Position = 3)]
            [string]$TenantGUID
        )
    
    $body = @{grant_type="client_credentials";resource=$OfficeLoginUri;client_id=$ClientID;client_secret=$ClientSecret}
    $oauth = Invoke-RestMethod -Method Post -Uri $AzureAADLoginUri/$tenantdomain/oauth2/token?api-version=1.0 -Body $body
    $headerParams = @{'Authorization'="$($oauth.token_type) $($oauth.access_token)"}
    return $headerParams 
}

function SendToLogA { 
	[cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$o365Data,
        [parameter(Mandatory = $true, Position = 1)]
        [string]$customLogName
    )
    #Test Size; Log A limit is 30MB
    $tempdata = @()
    $tempDataSize = 0
    
    if ((($o365Data |  Convertto-json -depth 20).Length) -gt 25MB) {        
		Write-Host "Upload is over 25MB, needs to be split"									 
        foreach ($record in $o365Data) {            
            $tempdata += $record
            $tempDataSize += ($record | ConvertTo-Json -depth 20).Length
            if ($tempDataSize -gt 25MB) {
                Write-OMSLogfile -dateTime (Get-Date) -type $customLogName -logdata $tempdata -CustomerID $LAWorkspaceId -SharedKey $LAWorkspaceKey
                write-Host "Sending data = $TempDataSize"
                $tempdata = $null
                $tempdata = @()
                $tempDataSize = 0
            }
        }
        Write-Host "Sending left over data = $Tempdatasize"
        Write-OMSLogfile -dateTime (Get-Date) -type $customLogName -logdata $o365Data -CustomerID $LAWorkspaceId -SharedKey $LAWorkspaceKey
    }
    Else {
        #Send to Log A as is        
        Write-OMSLogfile -dateTime (Get-Date) -type $customLogName -logdata $o365Data -CustomerID $LAWorkspaceId -SharedKey $LAWorkspaceKey
    }
}

function Get-O365Data{
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$startTime,
        [parameter(Mandatory = $true, Position = 1)]
        [string]$endTime,
        [Parameter(Mandatory = $true, Position = 2)]
        [psobject]$headerParams,
        [parameter(Mandatory = $true, Position = 3)]
        [string]$tenantGuid
    )
    #List Available Content
    $contentTypes = $Office365ContentTypes.split(",")
    #Loop for each content Type like Audit.General;
	
	#API front end for GCC-High is “manage.office365.us” instead of the commercial “manage.office.com”. 
	if ($OfficeLoginUri.split('.')[2] -eq "us") {
		$OfficeLoginUri = "https://manage.office365.us"
	}
	
	#Loop for each content Type like Audit.General; DLP.ALL
    foreach($contentType in $contentTypes){
        $listAvailableContentUri = "$OfficeLoginUri/api/v1.0/$tenantGUID/activity/feed/subscriptions/content?contentType=$contentType&PublisherIdentifier=$AADAppPublisher&startTime=$startTime&endTime=$endTime"
        Write-Host "***************************************"
		Write-Host $listAvailableContentUri
		
		do {
            #List Available Content
            $contentResult = Invoke-RestMethod -Method GET -Headers $headerParams -Uri $listAvailableContentUri
            $contentResult.Count
            #Loop for each Content
            foreach($obj in $contentResult){
                #Retrieve Content
                $data = Invoke-RestMethod -Method GET -Headers $headerParams -Uri ($obj.contentUri)
                $data.Count
                #Loop through each Record in the Content
                foreach($event in $data){
                    #Filtering for Recrord types
                    #Get all Record Types
                    if($Office365RecordTypes -eq "0"){
                        #We dont need Cloud App Security Alerts due to MCAS connector
                        if(($event.Source) -ne "Cloud App Security"){
                            #Write each event to Log A
                            $writeResult = SendToLogA $event $Office365CustomLog
                            #$writeResult
                        }
                    }
                    else{
                        #Get only certain record types
                        $types = ($Office365RecordTypes).split(",")
                        if(($event.RecordType) -in $types){
                            #We dont need Cloud App Security Alerts due to MCAS connector
                            if(($event.Source) -ne "Cloud App Security"){
                                #write each event to Log A
                                $writeResult = SendToLogA $event $Office365CustomLog
                                #$writeResult
                            }
                        }
                        
                    }
                }
            }
            
            #Handles Pagination
            $nextPageResult = Invoke-WebRequest -Method GET -Headers $headerParams -Uri $listAvailableContentUri
            If(($nextPageResult.Headers.NextPageUrl) -ne $null){
                $nextPage = $true
                $listAvailableContentUri = $nextPageResult.Headers.NextPageUrl
            }
            Else{$nextPage = $false}
        } until ($nextPage -eq $false)
    }
}


#add last run time to blob file to ensure no missed packages
$endTime = $currentUTCtime | Get-Date -Format yyyy-MM-ddThh:mm:ss
$Context = New-AzStorageContext -ConnectionString $azstoragestring

if((Get-AzStorageContainer -Context $Context).Name -contains "lastlog"){
    #Set Container
    $Blob = Get-AzStorageBlob -Context $Context -Container (Get-AzStorageContainer -Name "lastlog" -Context $Context).Name -Blob "lastlog.log"
    $lastlogTime = $blob.ICloudBlob.DownloadText()
    $startTime = $lastlogTime | Get-Date -Format yyyy-MM-ddThh:mm:ss
    $endTime | Out-File "$env:TEMP\lastlog.log"
    Set-AzStorageBlobContent -file "$env:TEMP\lastlog.log" -Container (Get-AzStorageContainer -Name "lastlog" -Context $Context).Name -Context $Context -Force
}
else {
    #create container
    $azStorageContainer = New-AzStorageContainer -Name "lastlog" -Context $Context
    $endTime | Out-File "$env:TEMP\lastlog.log"
    Set-AzStorageBlobContent -file "$env:TEMP\lastlog.log" -Container $azStorageContainer.name -Context $Context -Force
    $startTime = $currentUTCtime.AddSeconds(-300) | Get-Date -Format yyyy-MM-ddThh:mm:ss
}

$headerParams = Get-AuthToken $AADAppClientId $AADAppClientSecret $AADAppClientDomain $AzureTenantId
Get-O365Data $startTime $endTime $headerParams $AzureTenantId

# Write an information log with the current time.
Write-Host "PowerShell timer trigger function ran! TIME: $currentUTCtime"