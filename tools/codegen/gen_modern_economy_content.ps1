param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
    [switch]$Check,
    [ValidateSet('All', 'Consumption', 'TerminalChains')]
    [string]$Scope = 'All'
)

$ErrorActionPreference = 'Stop'
$DesignSellThroughQ16 = 52429 # 80%; leaves room for inventory/discard and price noise.
$foodOutputGoodIds = @(
    'prepared_staples','bread','grain','gathered_plants','potatoes',
    'game_meat','meat','fish','canned_fish','dairy_products','vegetables',
    'processed_food','edible_oil','beverages','wheat_grain','rice_grain','corn_grain',
    'livestock_products')
$project = Join-Path $RepoRoot 'Project/project-keynes'
$goodsDir = Join-Path $project 'data/goods'
$buildingsDir = Join-Path $project 'data/economy/buildings'
$professionsDir = Join-Path $project 'data/economy/professions'
$needsDir = Join-Path $project 'data/economy/needs'
$plansDir = Join-Path $project 'data/economy/consumption_plans'
$resourcesDir = Join-Path $project 'data/resources'
$curatedContentDir = Join-Path $PSScriptRoot 'economy_content'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$managedPaths = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$preservedHandAuthoredGoods = @(
    'bast_fiber','brine','charcoal','natural_rubber','reed_bundle',
    'seed_cotton','technology_points','turf_block','wrought_iron'
)
foreach ($goodId in $preservedHandAuthoredGoods) {
    [void]$managedPaths.Add([System.IO.Path]::GetFullPath(
        (Join-Path $goodsDir "$goodId.tres")))
}
$preservedHandAuthoredProfessions = @(
    'ai_researcher','cooperative_member','corvee_worker','data_scientist',
    'household_farmer','lorekeeper','natural_philosopher','research_scientist',
    'scholar','scientist','scribe','sharecropper'
)
foreach ($professionId in $preservedHandAuthoredProfessions) {
    [void]$managedPaths.Add([System.IO.Path]::GetFullPath(
        (Join-Path $professionsDir "$professionId.tres")))
}
[void]$managedPaths.Add([System.IO.Path]::GetFullPath(
    (Join-Path $plansDir 'scholarly_household.tres')))
$script:syncingCurated = $false
$script:finalizingConstruction = $false
$technologyRankById = @{}
$resourceDiscoveryTechnologyById = @{}
$technologyNetworkPath = Join-Path $project 'data/technology/technology_network.json'
if (Test-Path -LiteralPath $technologyNetworkPath) {
    $technologyNetwork = [System.IO.File]::ReadAllText($technologyNetworkPath) | ConvertFrom-Json
    $eraRanks = @{}
    foreach ($era in $technologyNetwork.eras) { $eraRanks[[string]$era.id] = [int]$era.sort_order }
    foreach ($node in $technologyNetwork.nodes) {
        $technologyRankById[[string]$node.id] = [int]$eraRanks[[string]$node.era_id]
        foreach ($binding in @($node.expected_bindings)) {
            if ([int]$binding.kind -ne 3) { continue }
            $resourceId = [string]$binding.id
            if (-not $resourceDiscoveryTechnologyById.ContainsKey($resourceId)) {
                $resourceDiscoveryTechnologyById[$resourceId] = @()
            }
            $technologyId = [string]$node.id
            if ($technologyId -notin @($resourceDiscoveryTechnologyById[$resourceId])) {
                $resourceDiscoveryTechnologyById[$resourceId] = @(
                    $resourceDiscoveryTechnologyById[$resourceId]) + @($technologyId)
            }
        }
    }
}

function Curated-Source-For-Target([string]$Path) {
    $parent = Split-Path -Parent $Path
    $bucket = if ($parent -eq $goodsDir) { 'goods' }
        elseif ($parent -eq $buildingsDir) { 'buildings' }
        elseif ($parent -eq $resourcesDir) { 'resources' }
        else { '' }
    if ($bucket -eq '') { return '' }
    $candidate = Join-Path (Join-Path $curatedContentDir $bucket) (Split-Path -Leaf $Path)
    return $(if (Test-Path -LiteralPath $candidate) { $candidate } else { '' })
}

function Is-Consumption-Path([string]$Path) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    foreach ($directory in @($professionsDir, $needsDir, $plansDir)) {
        $prefix = [System.IO.Path]::GetFullPath($directory).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if ($fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

$terminalChainGoodIds = @('glassware', 'metal_housewares', 'leather_goods')
$terminalChainBuildingIds = @(
    'glassware_workshop', 'glassware_manufactory', 'glassware_factory',
    'smart_glassware_factory', 'metal_housewares_workshop',
    'metal_housewares_manufactory', 'metal_housewares_factory',
    'smart_metal_housewares_factory', 'leather_goods_workshop',
    'leather_goods_manufactory', 'leather_goods_factory',
    'smart_leather_goods_factory')

function Is-Terminal-Path([string]$Path) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $parent = Split-Path -Leaf (Split-Path -Parent $Path)
    if ($parent -eq 'goods') { return $terminalChainGoodIds -contains $name }
    if ($parent -eq 'buildings') { return $terminalChainBuildingIds -contains $name }
    return $false
}

function Is-Scoped-Path([string]$Path) {
    if ($Scope -eq 'Consumption') { return Is-Consumption-Path $Path }
    if ($Scope -eq 'TerminalChains') { return Is-Terminal-Path $Path }
    return $true
}

function Write-Utf8([string]$Path, [string]$Content) {
    if (-not (Is-Scoped-Path $Path)) { return }
    [void]$managedPaths.Add([System.IO.Path]::GetFullPath($Path))
    if ($Check -and -not $script:syncingCurated -and
        (Curated-Source-For-Target $Path) -ne '') { return }
    $expected = $Content.TrimEnd() + "`n"
    if ($Check) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "generated file missing: $Path" }
        $actual = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
        $expectedNormalized = $expected.Replace("`r`n", "`n")
        if ((Split-Path -Parent $Path) -eq $buildingsDir -and
            -not $script:finalizingConstruction) {
            $constructionLines = '(?m)^construction_(good_ids|quantities) = .+\n?'
            $actual = [regex]::Replace($actual, $constructionLines, '')
            $expectedNormalized = [regex]::Replace(
                $expectedNormalized, $constructionLines, '')
        }
        if ($actual -ne $expectedNormalized) {
            throw "generated file stale: $Path"
        }
        return
    }
    if (Test-Path -LiteralPath $Path) {
        $actual = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
        if ($actual -eq $expected.Replace("`r`n", "`n")) { return }
    }
    try {
        [System.IO.File]::WriteAllText($Path, $expected, $utf8)
    } catch {
        if ($_.Exception.Message -like '*user-mapped section open*') {
            Write-Warning "Skipped editor-locked curated file: $Path"
            return
        }
        throw "failed writing generated file: $Path`n$($_.Exception.Message)"
    }
}

function Sync-CuratedDirectory([string]$Source, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "curated content directory missing: $Source" }
    foreach ($template in Get-ChildItem -LiteralPath $Source -Filter '*.tres' -File | Sort-Object Name) {
        $content = [System.IO.File]::ReadAllText($template.FullName)
        if ((Split-Path -Leaf $Source) -eq 'buildings') {
            $content = Calibrate-CuratedBuilding $content $template.BaseName
        } elseif ((Split-Path -Leaf $Source) -eq 'goods') {
            $content = Normalize-CuratedGood $content $template.BaseName
        }
        $script:syncingCurated = $true
        try {
            Write-Utf8 (Join-Path $Target $template.Name) $content
        } finally {
            $script:syncingCurated = $false
        }
    }
}

function Assert-FullyManaged([string]$Directory) {
    if ($Scope -eq 'Consumption' -and
        -not (Is-Consumption-Path (Join-Path $Directory '_scope_probe'))) { return }
    if ($Scope -eq 'TerminalChains' -and
        (Split-Path -Leaf $Directory) -notin @('goods', 'buildings')) { return }
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.tres' -File) {
        if ($Scope -eq 'TerminalChains' -and -not (Is-Terminal-Path $file.FullName)) {
            continue
        }
        if (-not $managedPaths.Contains([System.IO.Path]::GetFullPath($file.FullName))) {
            if ($Check) { throw "retired generated file remains: $($file.FullName)" }
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
}

function PSArray([string[]]$Values) {
    if ($Values.Count -eq 0) { return 'PackedStringArray()' }
    return 'PackedStringArray(' + (($Values | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ')'
}
function PI64([long[]]$Values) {
    if ($Values.Count -eq 0) { return 'PackedInt64Array()' }
    return 'PackedInt64Array(' + ($Values -join ', ') + ')'
}

function Scale-Food-Output-Quantities([string]$Content) {
    # Removed legacy 2x food output inflation so food supply tracks balanced
    # historical people-per-worker ladders without chronic surplus.
    return $Content
}
function PI32([int[]]$Values) {
    if ($Values.Count -eq 0) { return 'PackedInt32Array()' }
    return 'PackedInt32Array(' + ($Values -join ', ') + ')'
}

. (Join-Path $PSScriptRoot 'modern_economy_goods.ps1')
. (Join-Path $PSScriptRoot 'modern_economy_households.ps1')
if ($Scope -eq 'Consumption') {
    foreach ($directory in @($professionsDir, $needsDir, $plansDir)) {
        Assert-FullyManaged $directory
    }
    $planCount = @(Get-ChildItem -LiteralPath $plansDir -Filter '*.tres' -File).Count
    Write-Host "Generated $($professionRows.Count) professions, $($needRows.Count) needs, and $planCount consumption plans."
    return
}

. (Join-Path $PSScriptRoot 'modern_economy_building_inputs.ps1')
. (Join-Path $PSScriptRoot 'modern_economy_buildings.ps1')
. (Join-Path $PSScriptRoot 'modern_economy_production_methods.ps1')
. (Join-Path $PSScriptRoot 'modern_economy_construction.ps1')
foreach ($directory in @($goodsDir, $buildingsDir, $professionsDir, $needsDir, $plansDir, $resourcesDir)) {
    Assert-FullyManaged $directory
}

$fullGoodsCount = @(Get-ChildItem -LiteralPath $goodsDir -Filter '*.tres' -File).Count
$fullBuildingCount = @(Get-ChildItem -LiteralPath $buildingsDir -Filter '*.tres' -File).Count
$fullResourceCount = @(Get-ChildItem -LiteralPath $resourcesDir -Filter '*.tres' -File).Count
if ($Scope -eq 'Consumption') {
    $planCount = @(Get-ChildItem -LiteralPath $plansDir -Filter '*.tres' -File).Count
    Write-Host "Generated $($professionRows.Count) professions, $($needRows.Count) needs, and $planCount consumption plans."
} else {
    Write-Host "Generated $fullGoodsCount goods, $fullBuildingCount buildings, $($professionRows.Count) professions, $($needRows.Count) needs, and $fullResourceCount resources."
}
