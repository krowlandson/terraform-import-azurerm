#######################
# Module dependencies #
#######################

using module Az.Accounts

############################################
# Custom enum data sets used within module #
############################################

enum SkipCache {
    SkipCache
}

enum Release {
    stable
    latest
}

#####################################
# Custom classes used within module #
#####################################

# AzOpsProviders class is used to create cache of latest API version for all Azure Providers
# This can be used to dynamically retrieve the latest or stable API version in string format
# Can also output the API version as a param string for use within a Rest API request
# To minimise the number of Rest API requests needed, this class creates a cache and populates
# it with all results from the request. The cache is then used to return the requested result.
class AzOpsProviders {

    # Public class properties
    [String]$Provider
    [String]$ResourceType
    [String]$Type
    [String]$ApiVersion
    [Release]$Release

    # Static properties
    hidden static [AzOpsProviders[]]$Cache
    hidden static [String]$ProvidersApiVersion = "2020-06-01"

    # Default empty constructor
    AzOpsProviders() {
    }

    # Default constructor using PSCustomObject to populate object
    AzOpsProviders([PSCustomObject]$PSCustomObject) {
        $this.Provider = $PSCustomObject.Provider
        $this.ResourceType = $PSCustomObject.ResourceType
        $this.Type = $PSCustomObject.Type
        $this.ApiVersion = $PSCustomObject.ApiVersion
        $this.Release = $PSCustomObject.Release
    }

    # Static method to check for presence of Type in Cache
    hidden static [Boolean] InCache([String]$Type) {
        if ($Type -in [AzOpsProviders]::Cache.Type) {
            Write-Verbose "Resource Type [$Type] found in cache."
            return $true
        }
        else {
            Write-Verbose "Resource Type [$Type] not found in cache."
            return $false
        }
    }

    # Static method to get latest stable Api Version using Type
    static [String] GetApiVersionByType([String]$Type) {
        return [AzOpsProviders]::GetApiVersionByType($Type, "stable")
    }

    # Static method to get Api Version using Type
    static [String] GetApiVersionByType([String]$Type, [Release]$Release) {
        if (-not [AzOpsProviders]::InCache($Type)) {
            [AzOpsProviders]::UpdateCache()
        }
        $private:AzOpsProvidersFromCache = [AzOpsProviders]::Cache `
        | Where-Object -Property Type -EQ $Type `
        | Where-Object -Property Release -EQ $Release
        return $private:AzOpsProvidersFromCache.ApiVersion
    }

    # Static method to get Api Params String using Type
    static [String] GetApiParamsByType([String]$Type) {
        return "?api-version={0}" -f [AzOpsProviders]::GetApiVersionByType($Type)
    }

    # Static method to update Cache using current Subscription from context
    static [Void] UpdateCache() {
        $private:SubscriptionId = (Get-AzContext).Subscription.Id
        [AzOpsProviders]::UpdateCache($private:SubscriptionId)
    }

    # Static method to update Cache using specified SubscriptionId
    static [Void] UpdateCache([String]$SubscriptionId) {
        $private:Method = "GET"
        $private:Path = "/subscriptions/$subscriptionId/providers?api-version=$([AzOpsProviders]::ProvidersApiVersion)"
        $private:PSHttpResponse = Invoke-AzRestMethod -Method $private:Method -Path $private:Path
        $private:PSHttpResponseContent = $private:PSHttpResponse.Content
        $private:Providers = ($private:PSHttpResponseContent | ConvertFrom-Json).value
        if ($private:Providers) {
            [AzOpsProviders]::ClearCache()
        }
        foreach ($private:Provider in $private:Providers) {
            Write-Verbose "Processing Provider Namespace [$($private:Provider.namespace)]"
            foreach ($private:Type in $private:Provider.resourceTypes) {
                # Check for latest ApiVersion and add to cache
                $private:LatestApiVersion = ($private:Type.apiVersions `
                    | Sort-Object -Descending `
                    | Select-Object -First 1)
                if ($private:LatestApiVersion) {
                    [AzOpsProviders]::AddToCache(
                        $private:Provider.namespace.ToString(),
                        $private:Type.resourceType.ToString(),
                        $private:LatestApiVersion.ToString(),
                        "latest"
                    )
                }
                # Check for stable ApiVersion and add to cache
                $private:StableApiVersion = ($private:Type.apiVersions `
                    | Sort-Object -Descending `
                    | Where-Object { $_ -match "^(\d{4}-\d{2}-\d{2})$" } `
                    | Select-Object -First 1)
                if ($private:StableApiVersion) {
                    [AzOpsProviders]::AddToCache(
                        $private:Provider.namespace.ToString(),
                        $private:Type.resourceType.ToString(),
                        $private:StableApiVersion.ToString(),
                        "stable"
                    )
                }
            }
        }
    }

    # Static method to add provider instance to Cache
    hidden static [Void] AddToCache([String]$Provider, [String]$ResourceType, [String]$ApiVersion, [String]$Release) {
        Write-Debug "Adding [$($Provider)/$($ResourceType)] to cache with $Release Api-Version [$ApiVersion]"
        $private:AzOpsProviderObject = [PsCustomObject]@{
            Provider     = "$Provider"
            ResourceType = "$ResourceType"
            Type         = "$Provider/$ResourceType"
            ApiVersion   = "$ApiVersion"
            Release      = "$Release"
        }
        [AzOpsProviders]::Cache += [AzOpsProviders]::new($private:AzOpsProviderObject)
    }

    # Static method to show all entries in Cache
    static [AzOpsProviders[]] ShowCache() {
        return [AzOpsProviders]::Cache
    }

    # Static method to show all entries in Cache matching the specified release type (latest|stable)
    static [AzOpsProviders[]] ShowCache([Release]$Release) {
        return [AzOpsProviders]::Cache | Where-Object -Property Release -EQ $Release
    }

    # Static method to show all entries in Cache matching the specified type using default stable release type
    static [AzOpsProviders[]] SearchCache([String]$Type) {
        return [AzOpsProviders]::SearchCache($Type, "stable")
    }

    # Static method to show all entries in Cache matching the specified type using the specified release type
    static [AzOpsProviders[]] SearchCache([String]$Type, [Release]$Release) {
        return [AzOpsProviders]::Cache `
        | Where-Object -Property Type -EQ $Type `
        | Where-Object -Property Release -EQ $Release
    }

    # Static method to clear all entries from Cache
    static [Void] ClearCache() {
        [AzOpsProviders]::Cache = @()
    }

}

# AzOpsState class used to create and update new AsOpsState objects
# This is the primary module class containing all logic for managing AzOpsState for Azure Resources
class AzOpsState {

    # Public class properties
    [String]$Id
    [String]$Type
    [String]$Name
    [Object]$Properties
    [Object]$ExtendedProperties
    # [String]$Location
    # [String]$Tags
    # [Object]$Raw
    [String]$Provider
    [Object[]]$Children
    [Object[]]$LinkedResources
    [String]$Parent
    [Object[]]$Parents
    [String]$ParentPath
    [String]$ResourcePath

    # Static properties
    static [AzOpsState[]]$Cache

    # Hidden class properties
    # hidden [Boolean]$UsingCache = $false
    hidden static [String[]]$DefaultProperties = "Id", "Type", "Name", "Properties"

    # Regex patterns for use within methods
    hidden static [Regex]$RegexBeforeLastForwardSlash = "(?i)^.*(?=\/)"
    hidden static [Regex]$RegexIsGuid = "[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}"
    hidden static [Regex]$RegexProviderTypeFromId = "(?i)(?<=\/providers\/)(?!.*\/providers\/)[^\/]+\/[\w-]+"
    hidden static [Regex]$RegexIsSubscription = "(?i)(\/subscriptions)(?!\/.*\/)"
    hidden static [Regex]$RegexIsResourceGroup = "(?i)(\/resourceGroups)(?!\/.*\/)"
    hidden static [Regex]$RegexIsResource = "(?i)(\/resources)(?!\/.*\/)"

    hidden [PSCustomObject]$SupportedProviders = @{
        GetChildrenByType = @(
            "Microsoft.Authorization/policyDefinitions"
            "Microsoft.Authorization/policySetDefinitions"
            "Microsoft.Authorization/policyAssignments"
            # "Microsoft.Authorization/roleDefinitions"
            # "Microsoft.Authorization/roleAssignments"        
        )
    }

    # Default empty constructor
    AzOpsState() {
    }

    # Default constructor with Resource Id input
    # Uses Update() method to auto-populate from Resource Id if resource not found in Cache
    AzOpsState([String]$Id) {
        if ([AzOpsState]::InCache($Id)) {
            Write-Verbose "Returning AzOpsState from cache for [$Id]"
            $private:CachedResource = [AzOpsState]::SearchCache($Id)
            $this.Initialize($private:CachedResource, $true)
        }
        else {
            $this.Update($Id)
        }
    }

    # Default constructor with Resource Id and IgnoreCache input
    # Uses Update() method to auto-populate from Resource Id
    # Ignores Cache for Resource Id only (parent and child resources still pulled from cache if present)
    AzOpsState([String]$Id, [SkipCache]$SkipCache) {
        $this.Update($Id)
    }

    AzOpsState([PSCustomObject]$PSCustomObject) {
        foreach ($property in [AzOpsState]::DefaultProperties) {
            $this.$property = $PSCustomObject.$property
        }
        $this.Initialize()
    }

    AzOpsState([AzOpsState]$AzOpsState) {
        foreach ($property in [AzOpsState]::DefaultProperties) {
            $this.$property = $AzOpsState.$property
        }
        $this.Initialize()
    }

    [Void] Initialize() {
        # Used to set values on variables which require internal methods
        $this.SetProvider()
        $this.SetChildren()
        $this.SetParent()
        $this.SetParents()
        $this.SetResourcePath()
        # After the state object is initialized, add to the Cache array
        if ($this.Id -notin ([AzOpsState]::Cache).Id) {
            [AzOpsState]::Cache += $this
        }
    }

    # [Void] Initialize([AzOpsState]$AzOpsState) {
    #     $this.Initialize($AzOpsState, $false)
    # }

    # [Void] Initialize([AzOpsState]$AzOpsState, [Boolean]$UsingCache) {
    #     # Using a foreach loop to set all properties dynamically
    #     if ($UsingCache) {
    #         foreach ($property in $this.psobject.Properties.Name) {
    #             $this.$property = $AzOpsState.$property
    #         }    
    #     }
    #     else {
    #         $this.SetDefaultProperties($AzOpsState)    
    #         $this.Initialize()
    #     }  
    # }

    [Void] Initialize([PsCustomObject]$PsCustomObject) {
        $this.Initialize($PsCustomObject, $false)
    }

    [Void] Initialize([PsCustomObject]$PsCustomObject, [Boolean]$UsingCache) {
        # Using a foreach loop to set all properties dynamically
        if ($UsingCache) {
            foreach ($property in $this.psobject.Properties.Name) {
                $this.$property = $PsCustomObject.$property
            }    
        }
        else {
            $this.SetDefaultProperties($PsCustomObject)    
            $this.Initialize()
        }  
    }

    # [Void] Initialize([PsCustomObject]$PsCustomObject, [Boolean]$UsingCache) {
    #     $this.SetDefaultProperties($PsCustomObject)
    #     # Using a foreach loop to set all properties dynamically
    #     # foreach ($property in [AzOpsState]::DefaultProperties) {
    #     #     $this.$property = $PsCustomObject.$property
    #     # }
    #     if (-not $UsingCache) {
    #         $this.Initialize()
    #     }  
    # }

    # Update method used to update existing [AzOpsState] object using the existing Resource Id
    [Void] Update() {
        if ($this.Id) {
            $this.Update($this.Id)            
        }
        else {
            Write-Error "Unable to update AzOpsState. Please set a valid resource Id in the AzOpsState object, or provide as an argument."
        }
    }

    # Update method used to update existing [AzOpsState] object using the provided Resource Id
    # IMPROVEMENT - need to investigate how to handle multiple resources in scope of Id
    [Void] Update([String]$Id) {
        $private:GetAzConfig = [AzOpsState]::GetAzConfig($Id)
        if ($private:GetAzConfig.Count -eq 1) {
            $this.Initialize($private:GetAzConfig[0])
        }
        else {
            Write-Error "Unable to update multiple items. Please update ID to specific resource instance."
            break
        }
    }

    hidden [Void] SetDefaultProperties([PsCustomObject]$PsCustomObject) {
        foreach ($private:Property in [AzOpsState]::DefaultProperties) {
            $this.$private:Property = $PSCustomObject.$private:Property
        }
        switch -regex ($PsCustomObject.Id) {
            # ([AzOpsState]::RegexProviderTypeFromId).ToString() { <# pending development #> }
            # ([AzOpsState]::RegexIsResourceGroup).ToString() { <# pending development #> }
            ([AzOpsState]::RegexIsSubscription).ToString() {
                $this.Type = [AzOpsState]::GetTypeFromId($PsCustomObject.Id)
                $this.Name = $PsCustomObject.displayName
                $this.ExtendedProperties = $PsCustomObject
            }
            Default {
                $this.ExtendedProperties = [PsCustomObject]@{}
                foreach ($private:Property in $PsCustomObject.psobject.Properties) {
                    if ($private:Property -notin [AzOpsState]::DefaultProperties) {
                        $this.ExtendedProperties | Add-Member -NotePropertyName $private:Property.Name -NotePropertyValue $private:Property.Value
                    }
                }
            }
        }
    }

    hidden [Void] SetProvider() {
        $this.Provider = ([AzOpsProviders]::SearchCache($this.Type)).Provider
    }

    hidden [Object[]] GetChildren() {
        switch ($this.Type) {
            "Microsoft.Management/managementGroups" {
                $private:children = [AzOpsState]::GetAzConfig("$($this.Id)/descendants")
            }
            "Microsoft.Resources/subscriptions" {
                $private:children = [AzOpsState]::GetAzConfig("$($this.Id)/resourceGroups")
            }
            "Microsoft.Resources/resourceGroups" {
                $private:children = [AzOpsState]::GetAzConfig("$($this.Id)/resources")
            }
            Default { $private:children = $null }
        }
        return $private:children
    }

    hidden [Void] SetChildren() {
        $private:GetChildren = $this.GetChildren()
        switch ($this.Type) {
            "Microsoft.Management/managementGroups" {
                $private:GetChildrenFiltered = $private:GetChildren | Where-Object { $_.properties.parent.id -EQ $this.Id }
                $this.Children = $private:GetChildrenFiltered
                $this.LinkedResources = $private:GetChildren
                $this.GetChildrenByType("Microsoft.Authorization/policyDefinitions")
                $this.GetChildrenByType("Microsoft.Authorization/policySetDefinitions")
                $this.GetChildrenByType("Microsoft.Authorization/policyAssignments")
            }
            Default {
                $this.Children = $private:GetChildren
                $this.LinkedResources = $null
            }
        }
    }

    # Method to determine the parent resource for the current AzOpsState instance
    # Different resource types use different methods to determine the parent
    hidden [String] GetParent() {
        switch ($this.Type) {
            "Microsoft.Management/managementGroups" { $private:parent = $this.Properties.details.parent.id }
            Default { $private:parent = $null }
        }
        return $private:parent
    }


    hidden [String] GetParent([String]$Id) {
        # Need to wrap in Try/Catch block to gracefully handle limited permissions on parent resources
        try {
            $private:Parent = [AzOpsState]::new($Id).GetParent()
        }
        catch {
            Write-Warning $_.Exception.Message
            return $null
        }
        return $private:Parent
    }

    hidden [Void] SetParent() {
        $this.Parent = $this.GetParent().ToString()
    }

    hidden [System.Collections.Specialized.OrderedDictionary] GetParents() {
        # Need to create an ordered Hashtable to ensure correct order of parents when reversing
        $private:parents = [ordered]@{}
        # Start by setting the current parentId from the current [AzOpsState]
        $private:parentId = $this.GetParent()
        $private:count = 0
        # Start a loop to find the next parentId from the current parentId
        while ($private:parentId) {
            $private:count ++
            Write-Verbose "Adding [$($private:parentId)] ($($private:count))"
            $private:parents += @{ $private:count = $private:parentId }
            $private:parentId = $this.GetParent($private:parentId)
        }
        return $private:parents
    }

    hidden [Void] SetParents() {
        # Get Parents
        [System.Collections.Specialized.OrderedDictionary]$private:GetParents = $this.GetParents()
        [String[]]$private:parents = @()
        # Return all parent IDs to $this.Parents as string array
        foreach ($parent in $private:GetParents.GetEnumerator() | Sort-Object -Property Key -Descending) {
            $private:parents += $parent.value.ToString()
        }
        $this.Parents = $private:parents
        # Create an ordered path of parent names from the parent IDs in string format
        [String]$private:parentPath = ""
        foreach ($parent in $private:parents) {
            $private:parentPath = $private:parentPath + [AzOpsState]::RegexBeforeLastForwardSlash.Replace($parent, "")
        }
        $this.ParentPath = $private:parentPath.ToString()
    }

    hidden [String] GetResourcePath() {
        $private:ResourcePath = $this.ParentPath + "/" + $this.Name
        return $private:ResourcePath
    }

    hidden [Void] SetResourcePath() {
        $this.ResourcePath = $this.GetResourcePath().ToString()
    }

    hidden [AzOpsState[]] GetChildrenByType([String]$Type) {
        if ($Type -notin $this.SupportedProviders.GetChildrenByType) {
            Write-Warning "Resource type [$($Type)] not currently supported in method GetChildrenByType()"
            break
        }
        [AzOpsState[]]$private:GetChildrenByType = @()
        # Initialize private variables to manage
        $private:ApiVersion = $this.ApiVersion."$Type"
        $private:Method = "GET"
        $private:Path = "$($this.Id)/providers/$($Type)?api-version=$($private:ApiVersion)" # May want to put some more error checking around this but should be OK
        Write-Verbose "Rest API $($private:Method) [AzOpsState]: $($private:Path)"
        $private:AzRestMethod = Invoke-AzRestMethod -Path $private:Path -Method $private:Method -ErrorAction Stop
        # Check for errors in response
        if ($private:AzRestMethod.StatusCode -ne 200) {
            $private:ErrorBody = ($private:AzRestMethod.Content | ConvertFrom-Json).error
            Write-Error "Invalid response from API:`n StatusCode=$($private:AzRestMethod.StatusCode)`n ErrorCode=$($private:ErrorBody.code)`n ErrorMessage=$($private:ErrorBody.message)"
            break
        }
        # Extract resource(s) from AzRestMethod response and create new AzOpsState for each
        $private:AzRestMethodContent = $private:AzRestMethod.Content | ConvertFrom-Json
        if ($private:AzRestMethodContent.value) {
            Write-Verbose "Found [$($private:AzRestMethodContent.value.Count)] resources in response"
            $private:AzRestMethodContent = $private:AzRestMethodContent.value
        }
        foreach ($private:AzRestMethodValue in $private:AzRestMethodContent) {
            Write-Verbose "Found [$($Type)] Child Resource [$($private:AzRestMethodValue.Id)]"
            $private:GetChildrenByType += [AzOpsState]::new($private:AzRestMethodValue)
        }        
        return $private:GetChildrenByType
    }

    hidden [Void] SetChildrenByType($Type) {
        # Create array of objects containing required properties from GetChildrenByType() response
        $private:SetChildrenByType = $this.GetChildrenByType($Type) `
        | Select-Object -Property name, id, type, properties
        # Add to $this.Children if not already exists
        foreach ($private:Child in $private:SetChildrenByType) {
            $private:ChildNotSet = $private:Child.Id -notin $this.Children.Id
            $private:ChildInScope = $private:Child.Id -ilike "$($this.Id)/providers/$($Type)"
            # Need to consider how to handle update scenarios where a child item may need to be removed from Children or LinkedResources
            if ($private:ChildNotSet -and $private:ChildInScope) {
                $this.Children += $private:Child
            }
            $private:LinkedResourceNotSet = $private:Child.Id -notin $this.LinkedResources.Id
            if ($private:LinkedResourceNotSet) {
                $this.LinkedResources += $private:Child                
            }
        }
    }

    # IMPROVEMENT: Consider moving to new class for [Terraform]
    hidden [String] Terraform() {
        $private:dotTf = @()
        switch ($this.Type) {
            "Microsoft.Management/managementGroups" {
                $private:subscriptions = $this.Children `
                | Where-Object { $_.type -match "/subscriptions$" } `
                | Where-Object { $_.properties.parent.id -EQ $this.Id }
                $private:dotTf += "resource `"azurerm_management_group`" `"{0}`" {{" -f $this.Name
                $private:dotTf += "  display_name = `"{0}`"" -f $this.Name
                $private:dotTf += ""
                if ($this.Parent) {
                    $private:dotTf += "  parent_management_group_id = `"{0}`"" -f $this.Parent
                    $private:dotTf += ""                    
                }
                if ($private:subscriptions) {
                    $private:dotTf += "  subscription_ids = ["
                    foreach ($private:subscription in $private:subscriptions) {
                        $private:dotTf += "    `"{0}`"" -f $private:subscription.Id
                    }
                    $private:dotTf += "  ]"
                }
                $private:dotTf += "}"
            }
            Default {
                Write-Warning "Resource type [$($this.Type)] not currently supported in method Terraform()"
                $private:dotTf = $null
            }
        }
        return $private:dotTf -join "`n"
    }

    [Void] SaveTerraform([String]$Path) {
        # WIP: Requires additional work
        if (-not (Test-Path -Path $Path -PathType Container)) {
            $this.Terraform() | Out-File -FilePath $Path -Encoding "UTF8" -NoClobber            
        }
    }

    # Static method to get "Type" value from "Id" using RegEx pattern matching
    # IMPROVEMENT - need to consider situations where an ID may contain multi-level
    # Resource Types within the same provider
    hidden static [String] GetTypeFromId([String]$Id) {
        switch -regex ($Id) {
            ([AzOpsState]::RegexProviderTypeFromId).ToString() {
                $private:TypeFromId = [AzOpsState]::RegexProviderTypeFromId.Match($Id).Value
            }
            ([AzOpsState]::RegexIsResource).ToString() {
                $private:TypeFromId = "Microsoft.Resources/resources"
            }
            ([AzOpsState]::RegexIsResourceGroup).ToString() {
                $private:TypeFromId = "Microsoft.Resources/resourceGroups"
            }
            ([AzOpsState]::RegexIsSubscription).ToString() {
                $private:TypeFromId = "Microsoft.Resources/subscriptions"
            }
            Default { $private:TypeFromId = $null }
        }
        Write-Verbose "Resource Type [$private:TypeFromId] identified from Id [$Id]"
        return $private:TypeFromId
    }

    # Static method to get "Path" value from Id and Type, for use with Invoke-AzRestMethod
    # Relies on the following additional static methods:
    #  -- [AzOpsProviders]::GetApiParamsByType(Id, Type)
    hidden static [String] GetAzRestMethodPath([String]$Id, [String]$Type) {
        $private:AzRestMethodPath = $Id + [AzOpsProviders]::GetApiParamsByType($Type)
        Write-Verbose "Resource Path [$private:AzRestMethodPath]"
        return $private:AzRestMethodPath
    }
    
    # Static method to get "Path" value from Id, for use with Invoke-AzRestMethod
    # Relies on the following additional static methods:
    #  -- [AzOpsState]::GetTypeFromId(Id)
    #    |-- [AzOpsState]::GetAzRestMethodPath(Id, Type)
    #       |-- [AzOpsProviders]::GetApiParamsByType(Id, Type)
    hidden static [String] GetAzRestMethodPath([String]$Id) {
        $private:Type = [AzOpsState]::GetTypeFromId($Id)
        return [AzOpsState]::GetAzRestMethodPath($Id, $private:Type)
    }

    # Static method to simplify running Invoke-AzRestMethod using provided Id only
    # Relies on the following additional static methods:
    #  -- [AzOpsState]::GetAzRestMethodPath(Id)
    #    |-- [AzOpsState]::GetTypeFromId(Id)
    #       |-- [AzOpsState]::GetAzRestMethodPath(Id, Type)
    #          |-- [AzOpsProviders]::GetApiParamsByType(Id, Type)
    hidden static [Microsoft.Azure.Commands.Profile.Models.PSHttpResponse] GetAzRestMethod([String]$Id) {
        $private:PSHttpResponse = Invoke-AzRestMethod -Method GET -Path ([AzOpsState]::GetAzRestMethodPath($Id))
        if ($private:PSHttpResponse.StatusCode -ne 200) {
            $private:ErrorBody = ($private:PSHttpResponse.Content | ConvertFrom-Json).error
            Write-Error "Invalid response from API:`n StatusCode=$($private:PSHttpResponse.StatusCode)`n ErrorCode=$($private:ErrorBody.code)`n ErrorMessage=$($private:ErrorBody.message)"
            break
        }
        return $private:PSHttpResponse
    }

    # Static method to return Resource configuration from Azure using provided Id to modify scope
    # Will return multiple items for IDs scoped at a Resource Type level (e.g. "/subscriptions")
    # Will return a single item for IDs scoped at a Resource level (e.g. "/subscriptions/{subscription_id}")
    # Relies on the following additional static methods:
    #  -- [AzOpsState]::GetAzRestMethod(Id)
    #    |-- [AzOpsState]::GetAzRestMethodPath(Id)
    #       |-- [AzOpsState]::GetTypeFromId(Id)
    #          |-- [AzOpsState]::GetAzRestMethodPath(Id, Type)
    #             |-- [AzOpsProviders]::GetApiParamsByType(Id, Type)
    hidden static [PSCustomObject[]] GetAzConfig([String]$Id) {
        $private:AzConfigJson = ([AzOpsState]::GetAzRestMethod($Id)).Content
        if ($private:AzConfigJson | Test-Json) {
            $private:AzConfig = $private:AzConfigJson | ConvertFrom-Json
        }
        else {
            Write-Error "Unknown content type found in response."
            break
        }
        if ($private:AzConfig.value.Count -gt 1) {
            $private:AzConfigResourceCount = $private:AzConfig.value.Count
            Write-Verbose "GetAzConfig [$Id] contains [$private:AzConfigResourceCount] resources."
            return $private:AzConfig.Value
        }
        else {
            return $private:AzConfig
        }
    }

    # Static method to show all entries in Cache
    static [AzOpsState[]] ShowCache() {
        return [AzOpsState]::Cache
    }

    # Static method to show all entries in Cache matching the specified resource Id
    static [AzOpsState[]] SearchCache([String]$Id) {
        return [AzOpsState]::Cache | Where-Object -Property Id -EQ $Id
    }

    # Static method to return [Boolean] for Resource in Cache query
    static [Boolean] InCache([String]$Id) {
        if ([AzOpsState]::SearchCache([String]$Id)) {
            return $true
        }
        else {
            return $false
        }
    }

    # Static method to update all entries in Cache
    static [Void] UpdateCache() {
        $private:IdListFromCache = [AzOpsState]::ShowCache().Id
        [AzOpsState]::ClearCache()
        foreach ($private:Id in $private:IdListFromCache) {
            [AzOpsState]::new($private:Id)
        }
    }

    # Static method to clear all entries from Cache
    static [Void] ClearCache() {
        [AzOpsState]::Cache = @()
    }
    
}
