# https://campus.barracuda.com/product/webapplicationfirewall/article/WAF/RESTAPI/
function Get-WafServer {
    param(
        [parameter(Mandatory=$true)]
        [string]$WafBaseUrl,
        [parameter(Mandatory=$true)]
        [hashtable]$AuthHeader,
        [string[]]$ServerName, # Name in WAF is abritrary, but maybe can use "HostName" as an explicit identifier (although it's null by default), checking IP may be the best option here
        [string[]]$ExcludeHostHeader # website1.com, website2.com, etc.
    )

    $isValidBaseUri = Test-BaseUri $WafBaseUrl
    if ($isValidBaseUri -eq $false) {
        Write-Error 'Wrong URL format'
        exit 1
    }
    <#
    VSite ("default")
    └── Service Group ("WEB")
    └── Virtual Service ("WEB443")
        └── Content Rule ("WEB443") - host header can be found here
            └── Rule Group Server ("web01")
    #>
    # $vsitePath = '/restapi/v1/vsites'
    # $vsiteIdPlaceholder = '{vsite_id}'
    # $serviceGroupPath = "/restapi/v1/vsites/$vsiteIdPlaceholder/service_groups"

    $virtualServicePath = '/restapi/v1/virtual_services'
    $vserviceIdPlaceholder = '{virtual_service_id}'
    $serverPath = "$virtualServicePath/$vserviceIdPlaceholder/servers"
    $serverIdPlaceholder = '{server_id}'
    $updateServerPath = "$serverPath/$serverIdPlaceholder"

    $contentRulePath = "$virtualServicePath/$vserviceIdPlaceholder/content_rules"
    $contentRuleIdPlaceholder = '{rule_id}'
    $ruleGroupServerPath = "$contentRulePath/$contentRuleIdPlaceholder/rg_servers"
    $ruleGroupServerIdPlaceholder = '{rg_server_id}'
    $updateRuleGroupServerPath = "$ruleGroupServerPath/$ruleGroupServerIdPlaceholder"

    #Write-Information "Getting all virtual services..."
    $virtualServicesResult = Invoke-RestMethod -Uri $WafBaseUrl$virtualServicePath -Method GET -Headers $AuthHeader -ContentType 'application/json' -ErrorAction Stop
    $vServiceIds = $virtualServicesResult.data | Select-Object -ExpandProperty id
    
    $foundServers = @{}
    $vServiceIds | ForEach-Object {
        $vServiceId = $_
        Write-Information "Inspecting virtual service '$vServiceId'..."

        # Get all SERVERS for this virtual service ID
        $serversUrl = "$WafBaseUrl$($serverPath -replace $vserviceIdPlaceholder, $vServiceId)"
        $serversResult = Invoke-RestMethod -Uri $serversUrl -Method GET -Headers $AuthHeader -ContentType 'application/json' -ErrorAction Stop
        if ($ServerName.Count -gt 0) {
            $filteredServers = $serversResult.data.Where({ $ServerName -contains $_.id })
        }
        else {
            $filteredServers = $serversResult.data
        }
        $serverCount = $filteredServers.Count
        Write-Information "- Found $($serverCount) matching server$(if ($serverCount -ne 1) { 's' })"
        if ($serverCount -gt 0) {
            $filteredServers | ForEach-Object {
                Write-Information $_.id
                # add update URL (key) and JSON object (value) to hashtable
                $serverUpdateUrl = $updateServerPath -replace $vserviceIdPlaceholder, $vServiceId -replace $serverIdPlaceholder, $_.id
                $foundServers.Add($serverUpdateUrl, $_)
            }
        }

        # Get all content rules for this virtual service ID
        $contentRulesUrl = "$WafBaseUrl$($contentRulePath -replace $vserviceIdPlaceholder, $vServiceId)"
        $contentRulesResult = Invoke-RestMethod -Uri $contentRulesUrl -Method GET -Headers $AuthHeader -ContentType 'application/json' -ErrorAction Stop
        $filteredContentRules = Get-FilteredContentRules -ContentRules $contentRulesResult.data -ExcludeHostHeader $ExcludeHostHeader
        $contentRuleIds = $filteredContentRules | Select-Object -ExpandProperty id | Sort-Object
        Write-Information "- Found $($contentRuleIds.Count) content rule$(if ($contentRuleIds.Count -ne 1) { 's' })"
        if ($contentRuleIds.Count -gt 0) {
            $contentRuleIds | ForEach-Object { Write-Information $_ }
        }

        $contentRuleIds | ForEach-Object {
            $contentRuleId = $_
            Write-Information "- Inspecting content rule '$contentRuleId'..."
            # Get all RULE GROUP SERVERS for this content rule ID
            $ruleGroupServersUrl = "$WafBaseUrl$($ruleGroupServerPath -replace $vserviceIdPlaceholder, $vServiceId -replace $contentRuleIdPlaceholder, $contentRuleId)"
            $ruleGroupServersResult = Invoke-RestMethod -Uri $ruleGroupServersUrl -Method GET -Headers $AuthHeader -ContentType 'application/json' -ErrorAction Stop
            if ($ServerName.Count -gt 0) {
                $filteredRuleGroupServers = $ruleGroupServersResult.data.Where({ $ServerName -contains $_.id })
            }
            else {
                $filteredRuleGroupServers = $ruleGroupServersResult.data
            }            
            $ruleGroupServerCount = $filteredRuleGroupServers.Count
            Write-Information "-- Found $($ruleGroupServerCount) matching rule group server$(if ($ruleGroupServerCount -ne 1) { 's' })"
            if ($ruleGroupServerCount -gt 0) {
                $filteredRuleGroupServers | ForEach-Object {
                    Write-Information $_.id
                    # add update URL (key) and JSON object (value) to hashtable
                    $ruleGroupServerUpdateUrl = $updateRuleGroupServerPath -replace $vserviceIdPlaceholder, $vServiceId -replace $contentRuleIdPlaceholder, $contentRuleId -replace $ruleGroupServerIdPlaceholder, $_.id
                    $foundServers.Add($ruleGroupServerUpdateUrl, $_)
                }
            }
        }
    }

    Write-Host "Found $($foundServers.Count) server instances"
    Write-Host
    return $foundServers
}

Enum WafServerStatus
{
    in_service
    # Requests can be forwarded to this server.
    out_of_service_all
    # Requests should not be forwarded to this server. The server is excluded from the group of servers being load-balanced to. All existing connections to this server are immediately terminated.
    out_of_service_maintenance
    # Requests should not be forwarded to this server. The server is excluded form the group of servers being load-balanced to. Existing connections are terminated only after the requests in progress are completed.
    out_of_service_sticky
    # Requests that need to be forwarded to the server to maintain persistency (if persistence is turned on) continue to be sent to the server. The server is excluded from the group of servers being load-balanced to for any new requests without any persistency requirement. Existing connections are not terminated.
}

function Edit-WafServerStatus {
    [cmdletbinding(SupportsShouldProcess=$true)]
    param(
        [parameter(Mandatory=$true)]
        [string]$WafBaseUrl,
        [parameter(Mandatory=$true)]
        [hashtable]$AuthHeader,
        [parameter(Mandatory=$true)]
        [string[]]$ServerName,
        [parameter(Mandatory=$true)]
        [WafServerStatus]$NewServerStatus,
        [string[]]$ExcludeHostHeader
    )
    Write-Host "Searching for server instances..."
    $servers = Get-WafServer -WafBaseUrl $WafBaseUrl -AuthHeader $AuthHeader -ServerName $ServerName -ExcludeHostHeader $ExcludeHostHeader -ErrorAction Stop
    Write-Warning "This operation sets all server instances to the same status regardless of previous status. This could be an issue if, for example, a server started out as disabled and should remain in that state."
    if ($servers.Count -gt 0) {
        $servers.GetEnumerator() | ForEach-Object {
            $updatePath = $_.Name
            $updateUrl = "$WafBaseUrl$updatePath"
            $server = $_.Value
            $currentServerStatus = [WafServerStatus]::($server.status)
            Write-Host "Current status of '$updatePath' = '$currentServerStatus'"
            if ($currentServerStatus -ne $NewServerStatus) {
                # if ($NewServerStatus -like 'out_of_service*' -and $currentServerStatus -notlike 'out_of_service*') {
                    if ($PSCmdlet.ShouldProcess("$updateUrl", "Invoke-RestMethod")) {
                        try {
                            $result = Invoke-RestMethod -Uri $updateUrl -Method PUT -Headers $AuthHeader -ContentType 'application/json' -Body "{`"status`":`"$NewServerStatus`"}" -ErrorAction Stop
                            if ($result) {
                                Write-Host "New status of '$updatePath' = '$NewServerStatus'" -ForegroundColor Green
                            }
                        }
                        catch {
                            Write-Error "An error occurred when calling '$updateUrl'"
                        }
                    }
                # }
                # else {
                #     Write-Warning 'Server status is already in a disabled state'
                # }
            }
            else {
                Write-Warning "Server status is already set to '$currentServerStatus' at path '$updateUrl'"
            }
        }
        Write-Host
    }
    else {
        Write-Warning "No servers found for filter '$ServerName'"
    }
}

# Helper Functions ############################################################

function Get-WafLoginToken {
    param(
        [parameter(Mandatory=$true)]
        [string]$LoginUrl,
        [parameter(Mandatory=$true)]
        [PSCredential]$Credential
    )
    Write-Host "Logging in user '$($Credential.UserName)'..."
    $loginResult = Invoke-WebRequest -Uri $LoginUrl -Method POST -ContentType "application/json" -Body "{`"username`": `"$($Credential.UserName)`", `"password`": `"$($Credential.GetNetworkCredential().Password)`" }" -ErrorAction Stop | ConvertFrom-Json
    $token = $loginResult | Select-Object -ExpandProperty token
    Write-Information "Login token: $($token -Replace '\n', '\n')"
    Write-Host
    return $token
}

function Invoke-WafLogout {
    param(
        [parameter(Mandatory=$true)]
        [string]$LogoutUrl,
        [parameter(Mandatory=$true)]
        [hashtable]$AuthHeader
    )
    Write-Host "Logging out..."
    $logoutResult = Invoke-RestMethod -Uri $LogoutUrl -Method DELETE -Headers $AuthHeader
    Write-Host "Logout message: $($logoutResult | Select-Object -ExpandProperty msg)"
    Write-Host
}

function Get-AuthHeader {
    param(
        [parameter(Mandatory=$true)]
        [string]$AuthToken,
        [parameter(Mandatory=$true)]
        [PSCredential]$Credential
    )
    # https://community.barracudanetworks.com/forum/index.php?/topic/29463-automate-tasks-with-rest-api-and-powershell/
    $base64Token = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($AuthToken):$($Credential.GetNetworkCredential().Password)"))
    $authHeader = @{"Authorization" = "Basic $base64Token"}
    return $authHeader
}

function Test-BaseUri {
    param(
        [parameter(Mandatory=$true,Position=0)]
        [string]$Uri
    )
    $isValid = $false
    if (![System.Uri]::IsWellFormedUriString($Uri, [System.UriKind]::Absolute)) {
        Write-Error "URI '$WafBaseUrl' is not well formed - expecting an absolute URI"
    }
    else {
        $uri = [System.Uri]$Uri
        if ($uri.PathAndQuery) {
            Write-Error "URI should not contain any path or query"
        }
        else {
            $isValid = $true
        }
    }
    return $isValid
}

function Get-FilteredContentRules {
    param(
        [parameter(Mandatory=$true)]
        [PSCustomObject]$ContentRules,
        [string[]]$ExcludeHostHeader
    )
    $filteredRules = @()
    $ContentRules | ForEach-Object {
        $ruleObject = $_
        $ruleHostHeader = $ruleObject.host_match
        $doAdd = $true
        if ($ExcludeHostHeader.Count -gt 0) {
            :hostHeaderLoop foreach ($hostHeaderToExclude in $ExcludeHostHeader) {
                $segments = $hostHeaderToExclude.Split('.')
                if ($segments.Count -gt 2 -and $ruleHostHeader -eq $hostHeaderToExclude) {
                    Write-Information '- Exclude headers exact match'
                    $doAdd = $false
                    break hostHeaderLoop
                }
                else {
                    if ($ruleHostHeader -like "*$hostHeaderToExclude") {
                        Write-Information '- Exclude headers similar match'
                        $doAdd = $false
                        break hostHeaderLoop
                    }
                }
            }
        }
        if ($doAdd) {
            $filteredRules += $ruleObject
        }
        else {
            Write-Host "- SKIPPING content rule '$($ruleObject.id)' for host '$($ruleObject.host_match)'" -ForegroundColor Green
        }
    }
    return $filteredRules
}

# Export Functions ############################################################

$loginPath = "/restapi/v1/login"
$logoutPath = "/restapi/v1/logout"

<#
.SYNOPSIS
Disables servers in a Barracuda Web Application Firewall (WAF).
.DESCRIPTION
Disables all server instances found in a Barracuda Web Application Firewall (WAF). This function supports the -WhatIf parameter. Matching of server names is done optimistically, expecting that the server ID is the same as the server name passed into this function. A possible update to alleviate this issue is to query the server name for IPs and then match on IP address found in the WAF. Unsure if performance would become a factor in doing this.
Example saved for later: 
> GWMI Win32_NetworkAdapterConfiguration -Filter "IPEnabled = $true" | select @{ N = 'IP'; E = { if ($_.IPAddress.Count -gt 1) { $_.IPAddress.split(',')[0] } else { $_.IPAddress }}}
.EXAMPLE
Use the WhatIf parameter to prevent write operations from happening.
Disable-WafServer -WafBaseUrl 'http://barracuda1:8000' -Credential $cred -ServerName 'web01' -ExcludeHostHeader 'website.com' -WhatIf
.EXAMPLE
If ExcludeHostHeader is not included then all server instances will be disabled.
Disable-WafServer -WafBaseUrl $WafBaseUrl -Credential $Credential -ServerName 'web01'
.PARAMETER WafBaseUrl
The base URL to access the Barracuda Web Application Firewall.
Examples: 'http://13.68.88.164:8000', 'http://barracuda1:8000' 
.PARAMETER Credential
The credential needed to login to the WAF. Create from a username and password.
Example: 
> $UserName = 'admin'
> $SecurePassword = ConvertTo-SecureString '<password>' -AsPlainText -Force
> $Credential = New-Object System.Management.Automation.PSCredential -ArgumentList $UserName, $SecurePassword
.PARAMETER ServerName
The name of the server to disabled in the WAF. Can be an array of names.
Note that currently the server name is optimistically matched against the server ID in the WAF. These should be the same, but it is possible for them to be different.
.PARAMETER ExcludeHostHeader
The name of host headers that are configured in the WAF that should be ignored. Can be an array of names.
Examples: 'website.com', 'abc.website.com', '*.website2.com'
Note that if there are two or less segments (as shown in the first example above), then this filter will be applied for all host headers found in the WAF that end with those segments. So specifying 'website.com' will match headers '*.website.com', 'abc.website.com', 'xyz.website.com', etc.
#>
function Disable-WafServer {
    [cmdletbinding(SupportsShouldProcess=$true)]
    param(
        [parameter(Mandatory=$true)]
        [string]$WafBaseUrl,
        [parameter(Mandatory=$true)]
        [PSCredential]$Credential,
        [parameter(Mandatory=$true)]
        [string[]]$ServerName,
        [string[]]$ExcludeHostHeader
    )
    $loginUrl = "$WafBaseUrl$script:loginPath"
    $logoutUrl = "$WafBaseUrl$script:logoutPath"
    $token = Get-WafLoginToken -LoginUrl $loginUrl -Credential $Credential -ErrorAction Stop
    $authHeader = Get-AuthHeader -AuthToken $token -Credential $Credential -ErrorAction Stop

    $newServerStatus = [WafServerStatus]::out_of_service_maintenance
    Edit-WafServerStatus -WafBaseUrl $WafBaseUrl -AuthHeader $authHeader -ServerName $ServerName -NewServerStatus $newServerStatus -ExcludeHostHeader $ExcludeHostHeader -ErrorAction Stop -WhatIf:([bool]$WhatIfPreference.IsPresent)

    Invoke-WafLogout -LogoutUrl $logoutUrl -AuthHeader $authHeader
}

<#
.SYNOPSIS
Enables servers in a Barracuda Web Application Firewall (WAF).
.DESCRIPTION
Enables all server instances found in a Barracuda Web Application Firewall (WAF). This function supports the -WhatIf parameter. Matching of server names is done optimistically, expecting that the server ID is the same as the server name passed into this function. A possible update to alleviate this issue is to query the server name for IPs and then match on IP address found in the WAF. Unsure if performance would become a factor in doing this.
Example saved for later: 
> GWMI Win32_NetworkAdapterConfiguration -Filter "IPEnabled = $true" | select @{ N = 'IP'; E = { if ($_.IPAddress.Count -gt 1) { $_.IPAddress.split(',')[0] } else { $_.IPAddress }}}
.EXAMPLE
Use the WhatIf parameter to prevent write operations from happening.
Enable-WafServer -WafBaseUrl 'http://barracuda1:8000' -Credential $cred -ServerName 'web01' -ExcludeHostHeader 'website.com' -WhatIf
.EXAMPLE
If ExcludeHostHeader is not included then all server instances will be disabled.
Enable-WafServer -WafBaseUrl $WafBaseUrl -Credential $Credential -ServerName 'web01'
.PARAMETER WafBaseUrl
The base URL to access the Barracuda Web Application Firewall.
Examples: 'http://13.68.88.164:8000', 'http://barracuda1:8000' 
.PARAMETER Credential
The credential needed to login to the WAF. Create from a username and password.
.PARAMETER ServerName
The name of the server to enabled in the WAF. Can be an array of names.
Note that currently the server name is optimistically matched against the server ID in the WAF. These should be the same, but it is possible for them to be different.
.PARAMETER ExcludeHostHeader
The name of host headers that are configured in the WAF that should be ignored. Can be an array of names.
Examples: 'website.com', 'abc.website.com', '*.website2.com'
Note that if ther eare two or less segments (as shown in the first example above), then this filter will be applied for all host headers found in the WAF that end with those segments. So specifying 'website.com' will match headers '*.website.com', 'abc.website.com', 'xyz.website.com', etc.
#>
function Enable-WafServer {
    [cmdletbinding(SupportsShouldProcess=$true)]
    param(
        [parameter(Mandatory=$true)]
        [string]$WafBaseUrl,
        [parameter(Mandatory=$true)]
        [PSCredential]$Credential,
        [parameter(Mandatory=$true)]
        [string[]]$ServerName,
        [string[]]$ExcludeHostHeader
    )
    $loginUrl = "$WafBaseUrl$script:loginPath"
    $logoutUrl = "$WafBaseUrl$script:logoutPath"
    $token = Get-WafLoginToken -LoginUrl $loginUrl -Credential $Credential -ErrorAction Stop
    $authHeader = Get-AuthHeader -AuthToken $token -Credential $Credential -ErrorAction Stop

    # consider restricting setting servers to 'in_service' to only those servers that are currently set to 'out_of_service_maintenance' 
    $newServerStatus = [WafServerStatus]::in_service
    Edit-WafServerStatus -WafBaseUrl $WafBaseUrl -AuthHeader $authHeader -ServerName $ServerName -NewServerStatus $newServerStatus -ExcludeHostHeader $ExcludeHostHeader -ErrorAction Stop -WhatIf:([bool]$WhatIfPreference.IsPresent)

    Invoke-WafLogout -LogoutUrl $logoutUrl -AuthHeader $authHeader
}

<#
.SYNOPSIS
Helper function to get PSCredential.
.DESCRIPTION
Helper function to get PSCredential.
.PARAMETER UserName
Self-explanatory.
.PARAMETER SecurePassword
Password must be passed in as a SecureString object.
.EXAMPLE
$pass = ConvertTo-SecureString '<password>' -AsPlainText -Force
$cred = Get-PSCredential -UserName 'admin' -SecurePassword $pass
#>
function Get-PSCredential {
    param(
        [string]$UserName,
        [securestring]$SecurePassword
    )
    return New-Object System.Management.Automation.PSCredential -ArgumentList $UserName, $SecurePassword
}

Export-ModuleMember -Function Disable-WafServer
Export-ModuleMember -Function Enable-WafServer
Export-ModuleMember -Function Get-PSCredential
