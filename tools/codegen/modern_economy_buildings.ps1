function Write-Building([string]$Id,[string]$Name,[string]$Kind,[string]$Owner,[string]$Worker,
    [string[]]$Inputs,[string[]]$Outputs,[string[]]$Resources,[string[]]$ResourceModes,
    [string]$Behavior,[string]$Category,[string]$Family = '',[int]$Tier = 0,
    [string]$TechnologyOverride = '',[long[]]$InputQuantityOverride = @(),
    [string]$RecipeSourceId = '', [string[]]$TechnologyTagsOverride = @(),
    [string[]]$RequiredTechnologyTags = @(), [int[]]$InputRequiredQ16Override = @(),
    [object[]]$InputCandidateOverride = @(), [string[]]$EmployeeProfessionIdsOverride = @(),
    [long[]]$EmployeeSlotsOverride = @(), [string[]]$EmployeeWagePolicyIdsOverride = @(),
    [switch]$PreserveWorkforce) {
    $requestedOwner = $Owner
    $unitQty = switch ($Id) {
        'marine_fish_collector' { [long]3600 }
        'pastoral_camp' { [long]3000 } 'manorial_pasture' { [long]5000 }
        'ranching_station' { [long]9000 } 'horse_breeding_camp' { [long]700 }
        'horse_breeder' { [long]1200 }
        'mechanized_farm' { [long]9000 }
        'intensive_farm' { [long]12000 }
        'village_mill' { [long]3000 } 'bakery' { [long]2500 } 'rice_kitchen' { [long]2500 }
        'corn_grinding_house' { [long]2500 } 'potato_kitchen' { [long]2500 }
        'slaughterhouse' { [long]5000 } 'creamery' { [long]4000 } 'tannery' { [long]3000 }
        'wool_shed' { [long]2500 } 'flax_spinning_shed' { [long]2500 }
        'flour_plant' { [long]11000 } 'bread_plant' { [long]11000 }
        'rice_food_plant' { [long]10000 } 'corn_food_plant' { [long]10000 }
        'potato_food_plant' { [long]10000 } 'mechanized_slaughterhouse' { [long]12000 }
        'dairy_products_plant' { [long]11000 } 'leather_plant' { [long]10000 }
        'flax_yarn_plant' { [long]10000 } 'textile_mill' { [long]11000 }
        'synthetic_textile_mill' { [long]13000 }
        'cloth_plant' { [long]11000 } 'clothing_plant' { [long]9000 } 'footwear_plant' { [long]9000 }
        'electricity_plant' { [long]9000 } 'gas_power_plant' { [long]12000 }
        'oil_power_plant' { [long]10500 } 'nuclear_power_plant' { [long]18000 }
        default { [long]10000 }
    }
    [string[]]$directTechnologies = @($TechnologyTagsOverride)
    $technology = $TechnologyOverride
    if ($directTechnologies.Count -eq 0 -and $technology -ne '') {
        $directTechnologies = @($technology)
    }
    if ($directTechnologies.Count -eq 0) { $technology = Technology-For-Building $Id }
    if ($directTechnologies.Count -eq 0 -and $technology -eq '') {
        if ($Outputs.Count -eq 0) { throw "building lacks output technology: $Id" }
        $technology = Technology-For-Good $Outputs[0]
    }
    if ($directTechnologies.Count -eq 0) { $directTechnologies = @($technology) }
    $technology = $directTechnologies[0]
    $rank = Technology-Rank $technology
    [long[]]$inputQtySeed = if ($Inputs.Count -eq 0) {
        @()
    } elseif ($InputQuantityOverride.Count -gt 0) {
        @($InputQuantityOverride | ForEach-Object { [long]$_ })
    } else {
        @($Inputs | ForEach-Object { [long]1000 })
    }
    if ($InputQuantityOverride.Count -gt 0 -and $InputQuantityOverride.Count -ne $Inputs.Count) {
        throw "input quantity override mismatch: $Id"
    }
    $workshopToolUsers = @('guild_weaving_house','tailor_shop','cobbler_shop','brewery','distillery',
        'rag_paper_workshop','goldsmith_workshop','court_tailor','cabinetmaker_workshop',
        'composting_yard','tannery','wool_shed','edible_oil_plant','soap_plant',
        'packaging_plant','printed_materials_plant','industrial_chemicals_plant',
        'explosives_plant','pharmaceuticals_plant')
    if ($Kind -eq 'industrial' -and $Id -in $workshopToolUsers -and
        $Outputs -notcontains 'tools' -and $Inputs -notcontains 'tools') {
        $Inputs += 'tools'; $inputQtySeed += [long]250
    }
    # Factory operating inputs model maintenance/tooling, installed machinery,
    # and electric drive without creating a second production subsystem.
    $isTerminalFamily = $Family -in @('glassware_making','metal_housewares_making','leather_goods_making')
    if (-not $isTerminalFamily -and $Kind -eq 'industrial' -and $rank -ge 6 -and
        $Outputs -notcontains 'tools' -and $Inputs -notcontains 'tools') {
        $Inputs += 'tools'; $inputQtySeed += [long]300
    }
    if (-not $isTerminalFamily -and $Kind -eq 'industrial' -and $rank -ge 7 -and
        $Outputs -notcontains 'electricity' -and $Inputs -notcontains 'electricity') {
        $Inputs += 'electricity'; $inputQtySeed += [long]600
    }
    if (-not $isTerminalFamily -and $Kind -eq 'industrial' -and $rank -ge 7 -and
        $Outputs -notcontains 'electricity' -and $Outputs -notcontains 'industrial_machinery' -and
        $Inputs -notcontains 'industrial_machinery') {
        $Inputs += 'industrial_machinery'; $inputQtySeed += [long]200
    }
    [long[]]$inputQty = $inputQtySeed
    $outputQty = @($Outputs | ForEach-Object { $unitQty })
    $outputTotal = [long](($outputQty | Measure-Object -Sum).Sum)
    $extractCount = @($ResourceModes | Where-Object { $_ -eq 'extract' }).Count
    $extractionRatio = Extraction-Ratio-For-Building $Id
    $extractQty = if ($extractCount -gt 0) {
        [long][Math]::Max(1, [Math]::Floor($outputTotal / ($extractionRatio * $extractCount)))
    } else { [long]0 }
    $resourceQty = @(
        for ($i = 0; $i -lt $Resources.Count; $i++) {
            if ($ResourceModes[$i] -eq 'extract') { $extractQty } else { $unitQty }
        }
    )
    if ($Id -eq 'marine_fish_collector') { $resourceQty = @([long]242) }
    for ($i = 0; $i -lt $Outputs.Count; $i++) {
        if ($Outputs[$i] -in $foodOutputGoodIds) {
            $outputQty[$i] = [long]$outputQty[$i] * 2
        }
    }
    $resourceAccessModes = @($Resources | ForEach-Object { 'local' })
    [string[]]$roleIds = @()
    [long[]]$roleSlots = @()
    [string[]]$roleWagePolicies = @()
    if ($Outputs.Count -eq 1 -and $Outputs[0] -in @('gold','silver') -and
        $Kind -eq 'collector' -and $rank -lt 6) {
        $Owner = 'merchant'
    } elseif ($rank -eq 0) {
        # Stone-age production is owner-operated. Choose the producer cohort
        # that performs the work instead of manufacturing an employer class.
        if ($Kind -eq 'collector') {
            if ($Id -eq 'timber_collector') { $Owner = 'forager' }
            elseif ($Worker -ne '') { $Owner = $Worker }
        } else {
            $Owner = 'artisan'
        }
    } elseif ($Id -in @('rice_collector','potato_collector','fertile_soil_collector','wheat_farm','flax_collector')) {
        $Owner = 'subsistence_farmer'
    } elseif ($Id -in @('landed_estate','manorial_pasture')) {
        $Owner = 'landlord'; $roleIds = @('serf'); $roleSlots = @(10)
        $roleWagePolicies = @('fixed')
    } elseif ($Id -in @('pastoral_camp','horse_breeding_camp')) {
        $Owner = 'pastoralist'
    } elseif ($Id -eq 'horse_breeder') {
        $Owner = 'landlord'; $roleIds = @('pastoralist'); $roleSlots = @(8)
        $roleWagePolicies = @('fixed')
    } elseif ($Id -in @('cotton_collector','spice_plants_collector','rubber_tree_collector','medicinal_herbs_collector')) {
        $Owner = 'landlord'; $roleIds = @('indentured_laborer'); $roleSlots = @(10)
        $roleWagePolicies = @('fixed')
    } elseif ($Id -eq 'flax_collector') {
        $Owner = 'subsistence_farmer'
    } elseif ($Id -eq 'timber_collector') {
        $Owner = 'forager'
    } elseif ($Kind -eq 'collector' -and
        @($Resources | Where-Object { $_ -in @('arable_land','paddy_land','plantation_land','pasture') }).Count -gt 0) {
        # Mechanization changes farm labor and capital inputs, not land ownership.
        # Keep commercial land-based agriculture landlord-owned unless a distinct
        # farm-owner/corporate-agriculture profession is modeled explicitly.
        if ($rank -lt 6) {
            $Owner = 'landlord'; $roleIds = @('tenant_farmer')
            $roleSlots = @((12 + 2 * [Math]::Max(0, $rank - 3)))
            $roleWagePolicies = @('fixed')
        } else {
            $Owner = 'landlord'; $roleIds = @('agricultural_worker','manager')
            $roleSlots = @((24 + 4 * ($rank - 6)), (2 + [Math]::Floor(($rank - 6) / 2)))
            $roleWagePolicies = @('adaptive','adaptive')
        }
    } elseif ($Id -eq 'lumber_plant') {
        $Owner = 'artisan'; $roleIds = @('forestry_worker'); $roleSlots = @(4)
        $roleWagePolicies = @('fixed')
    } elseif ($Id -in @('bakery','staple_kitchen','slaughterhouse','creamery')) {
        $Owner = 'artisan'; $roleIds = @('apprentice'); $roleSlots = @(3)
        $roleWagePolicies = @('fixed')
    } elseif ($Kind -eq 'collector' -and $rank -lt 6) {
        if ($Worker -ne '') { $Owner = $Worker }
        if ($Worker -ne '') {
            $roleIds = @($Worker); $roleSlots = @(8)
            $roleWagePolicies = @('fixed')
        }
    } elseif ($Kind -eq 'collector') {
        $Owner = 'industrialist'; $roleIds = @($Worker, 'manager'); $roleSlots = @(14, 2)
        $roleWagePolicies = @('adaptive', 'adaptive')
    } else {
        if ($rank -lt 3) {
            $Owner = 'artisan'
        } elseif ($rank -lt 6) {
            $Owner = 'guild_master'; $roleIds = @('apprentice', 'journeyman'); $roleSlots = @(6, 4)
            $roleWagePolicies = @('fixed', 'fixed')
        } else {
            $Owner = 'industrialist'
        }
        if ($rank -lt 3) {
            if ($Id -notin @('knapping_workshop','communal_hearth','ore_bronzesmith_camp')) {
                $roleIds = @('apprentice'); $roleSlots = @(3)
                $roleWagePolicies = @('fixed')
            }
        } elseif ($rank -lt 6) {
            $roleIds = @('apprentice','journeyman')
            $roleSlots = @((6 + [Math]::Max(0, $rank - 3)), (6 + [Math]::Max(0, $rank - 3)))
            $roleWagePolicies = @('fixed','fixed')
        } elseif ($rank -eq 6 -and $Worker -eq 'industrial_worker') {
            $roleIds = @('industrial_worker', 'manager'); $roleSlots = @(20, 2)
            $roleWagePolicies = @('adaptive', 'adaptive')
        } elseif ($rank -eq 6) {
            $roleIds = @('industrial_worker', $Worker, 'manager'); $roleSlots = @(16, 6, 2)
            $roleWagePolicies = @('adaptive', 'adaptive', 'adaptive')
        } elseif ($rank -le 8) {
            $roleIds = if ($Worker -eq 'technician') {
                @('industrial_worker','technician','engineer','manager')
            } elseif ($Worker -eq 'industrial_worker') {
                @('industrial_worker','technician','manager')
            } else { @('industrial_worker',$Worker,'technician','manager') }
            $roleSlots = if ($Worker -eq 'technician') {
                @((24 + 4 * ($rank - 7)), (8 + 2 * ($rank - 7)), 4, 3)
            } elseif ($Worker -eq 'industrial_worker') {
                @((28 + 4 * ($rank - 7)), (4 + 2 * ($rank - 7)), 3)
            } else { @((24 + 4 * ($rank - 7)), (8 + 2 * ($rank - 7)), 4, 3) }
            $roleWagePolicies = @($roleIds | ForEach-Object { 'adaptive' })
        } else {
            $roleIds = if ($Worker -eq 'technician') {
                @('industrial_worker','technician','engineer','researcher','manager')
            } elseif ($Worker -eq 'industrial_worker') {
                @('industrial_worker','technician','engineer','manager')
            } else { @('industrial_worker',$Worker,'technician','engineer','manager') }
            $roleSlots = if ($rank -eq 9) {
                if ($Worker -eq 'technician') { @(24,12,8,4,4) }
                elseif ($Worker -eq 'industrial_worker') { @(34,8,5,4) }
                else { @(30,10,7,4,4) }
            } else {
                if ($Worker -eq 'technician') { @(26,16,10,6,4) }
                elseif ($Worker -eq 'industrial_worker') { @(36,12,8,4) }
                else { @(32,12,9,6,4) }
            }
            $roleWagePolicies = @($roleIds | ForEach-Object { 'adaptive' })
        }
    }
    if ($PreserveWorkforce -or $isTerminalFamily) {
        if ($EmployeeProfessionIdsOverride.Count -ne $EmployeeSlotsOverride.Count -or
            $EmployeeProfessionIdsOverride.Count -ne $EmployeeWagePolicyIdsOverride.Count) {
            throw "workforce override columns mismatch: $Id"
        }
        $Owner = $requestedOwner
        $roleIds = @($EmployeeProfessionIdsOverride)
        $roleSlots = @($EmployeeSlotsOverride | ForEach-Object { [long]$_ })
        $roleWagePolicies = @($EmployeeWagePolicyIdsOverride)
    }
    $roleLivingCosts = @($roleIds | ForEach-Object {
        Reference-Living-Cost-For-Profession $_
    })
    for ($roleIndex = 0; $roleIndex -lt $roleIds.Count; $roleIndex++) {
        $roleLivingCosts[$roleIndex] = [Math]::Max(
            [long]$roleLivingCosts[$roleIndex],
            (Reference-Living-Cost-For-Profession $roleIds[$roleIndex]))
    }
    $candidateOffsets = @(0); $candidateGoodIds = @(); $candidateEfficiencies = @()
    $candidateSpecs = @()
    $recipeKey = if ([string]::IsNullOrWhiteSpace($RecipeSourceId)) { $Id } else { $RecipeSourceId }
    if ($InputCandidateOverride.Count -gt 0) {
        foreach ($candidateSlot in $InputCandidateOverride) { $candidateSpecs += ,$candidateSlot }
    } elseif ($explicitInputCandidates.ContainsKey($recipeKey)) {
        $rawCandidateSpecs = $explicitInputCandidates[$recipeKey]
        if ($rawCandidateSpecs -is [hashtable]) {
            $candidateSpecs += ,$rawCandidateSpecs
        } else {
            foreach ($candidateSlot in $rawCandidateSpecs) { $candidateSpecs += ,$candidateSlot }
        }
    }
    if ($candidateSpecs.Count -gt $Inputs.Count) {
        throw "explicit input candidate slot mismatch: $Id candidates=$($candidateSpecs.Count) inputs=$($Inputs.Count)"
    }
    while ($candidateSpecs.Count -gt 0 -and $candidateSpecs.Count -lt $Inputs.Count) {
        $candidateSpecs += ,$null
    }
    [string[]]$categoryOverrides = if ($inputCategoryOverrides.ContainsKey($recipeKey)) {
        $inputCategoryOverrides[$recipeKey]
    } else { @() }
    if ($categoryOverrides.Count -gt $Inputs.Count) {
        throw "input category slot mismatch: $Id categories=$($categoryOverrides.Count) inputs=$($Inputs.Count)"
    }
    while ($categoryOverrides.Count -gt 0 -and $categoryOverrides.Count -lt $Inputs.Count) {
        $categoryOverrides += ''
    }
    $inputCategories = @()
    for ($inputIndex = 0; $inputIndex -lt $Inputs.Count; $inputIndex++) {
        $candidateSpec = if ($candidateSpecs.Count -gt 0) { $candidateSpecs[$inputIndex] } else { $null }
        $categoryOverride = if ($categoryOverrides.Count -gt 0) { $categoryOverrides[$inputIndex] } else { '' }
        if ($null -ne $candidateSpec -and @($candidateSpec.goods).Count -gt 0) {
            if (-not [string]::IsNullOrWhiteSpace($categoryOverride)) {
                throw "explicit candidates cannot share an input slot with a category: $Id input $inputIndex"
            }
            $candidateGoods = @($candidateSpec.goods); $candidateEfficiency = @($candidateSpec.efficiencies)
            if ($candidateGoods.Count -ne $candidateEfficiency.Count -or $Inputs[$inputIndex] -notin $candidateGoods) {
                throw "invalid explicit input candidate definition: $Id"
            }
            $candidateGoodIds += $candidateGoods
            $candidateEfficiencies += $candidateEfficiency
            $inputCategories += ''
        } else {
            $inputCategories += $(if (-not [string]::IsNullOrWhiteSpace($categoryOverride)) {
                $categoryOverride
            } elseif ($Inputs[$inputIndex] -eq 'tools') { 'tools' } else { '' })
        }
        $candidateOffsets += $candidateGoodIds.Count
    }
    $inputMinLevels = @($Inputs | ForEach-Object {
        if ($_ -ne 'tools') { 0 } else { Tool-Min-Quality-For-Rank $rank }
    })
    if ($Id -eq 'ore_bronzesmith_camp') {
        $inputQty = [long[]]@(500, 500, 500)
    }
    $jobs = [long]1 + [long](($roleSlots | Measure-Object -Sum).Sum)
    for ($inputIndex = 0; $inputIndex -lt $Inputs.Count; $inputIndex++) {
        $isTool = $Inputs[$inputIndex] -in @(
            'chipped_stone_tools','bronze_tools','tools','precision_tools') -or
            ($inputIndex -lt $inputCategories.Count -and
             $inputCategories[$inputIndex] -eq 'tools')
        if (-not $isTool) { continue }
        $inputQty[$inputIndex] = [Math]::Min(
            [long]$inputQty[$inputIndex], [long][Math]::Max(1, $jobs * 100))
    }
    $generationIds = @(); $generationQty = @(); $floor = 0
    $targetMargin = if ($Kind -eq 'collector') { 6554 } else { 9830 }
    $supplyElasticity = if ($Kind -eq 'collector') { 32768 } else { 65536 }
    if ($Outputs -contains 'electricity') { $targetMargin = 5243; $supplyElasticity = 16384 }
    if ($Outputs | Where-Object { $_ -in @('jewelry','fine_clothing','fine_furniture') }) {
        $targetMargin = 13107
    }
    $dailyInputCost = [long]0
    for ($inputIndex = 0; $inputIndex -lt $Inputs.Count; $inputIndex++) {
        $effectivePrice = [double](Default-Price-For-Good $Inputs[$inputIndex])
        if ($candidateSpecs.Count -gt 0 -and $null -ne $candidateSpecs[$inputIndex] -and
            @($candidateSpecs[$inputIndex].goods).Count -gt 0) {
            $effectivePrice = [double]::PositiveInfinity
            $candidateGoods = @($candidateSpecs[$inputIndex].goods)
            $candidateEfficienciesForCost = @($candidateSpecs[$inputIndex].efficiencies)
            for ($candidateIndex = 0; $candidateIndex -lt $candidateGoods.Count; $candidateIndex++) {
                $candidateTechnology = Technology-For-Good $candidateGoods[$candidateIndex]
                if ((Technology-Rank $candidateTechnology) -gt $rank) { continue }
                $effectivePrice = [Math]::Min($effectivePrice,
                    [double](Default-Price-For-Good $candidateGoods[$candidateIndex]) * 65536.0 /
                    [double]$candidateEfficienciesForCost[$candidateIndex])
            }
            if ([double]::IsPositiveInfinity($effectivePrice)) {
                throw "no era-compatible candidate during calibration: $Id input $inputIndex"
            }
        } elseif ($inputIndex -lt $inputCategories.Count -and
            -not [string]::IsNullOrWhiteSpace($inputCategories[$inputIndex])) {
            $effectivePrice = if ($inputCategories[$inputIndex] -eq 'tools') {
                Cheapest-Tool-Effective-Price $rank $inputMinLevels[$inputIndex]
            } else {
                Cheapest-Category-Effective-Price $inputCategories[$inputIndex] $rank $inputMinLevels[$inputIndex]
            }
        }
        $dailyInputCost += [long][Math]::Ceiling(
            [double]$inputQty[$inputIndex] * $effectivePrice / 1000.0)
    }
    $dailyLivingCost = [long]0
    for ($roleIndex = 0; $roleIndex -lt $roleSlots.Count; $roleIndex++) {
        $dailyLivingCost += [long]$roleSlots[$roleIndex] * [long]$roleLivingCosts[$roleIndex]
    }
    $dailyCost = $dailyInputCost + $dailyLivingCost
    $ownerLivingCost = Reference-Living-Cost-For-Profession $Owner
    if (-not ($Outputs | Where-Object { $_ -in @('gold','silver') })) {
        $outputPriceTotal = [long]0
        foreach ($output in $Outputs) { $outputPriceTotal += Default-Price-For-Good $output }
        $marginRevenue = [long][Math]::Ceiling(
            [double]$dailyCost * 65536.0 / [Math]::Max(1, 65536 - $targetMargin))
        $breakEvenRevenue = [long][Math]::Max(
            $marginRevenue, [Math]::Ceiling([double]$dailyCost + $ownerLivingCost))
        $requiredRevenue = [long][Math]::Ceiling(
            [double]$breakEvenRevenue * 65536.0 / $DesignSellThroughQ16)
        $unitQty = [long][Math]::Ceiling(
            [double]$requiredRevenue * 1000.0 * 65536.0 / [Math]::Max(1.0, [double]$outputPriceTotal * 62259.0))
        if ($Id -eq 'marine_fish_collector') {
            # A coastal fishing unit is intentionally a small owner-operated
            # producer. Keep a modest food buffer without the former three-owner
            # cost multiplier or an industrial-scale catch.
            $unitQty = [Math]::Max([long]2000, $unitQty)
        }
        if ($unitQty -lt 1) { $unitQty = 1 }
        if ($unitQty -gt 10000000) { throw "implausible calibrated output quantity: $Id -> $unitQty" }
        $calibratedRevenue = [double]$unitQty * [double]$outputPriceTotal / 1000.0 * 62259.0 / 65536.0
        if ($calibratedRevenue -le $dailyCost) {
            throw "unprofitable generated recipe after calibration: $Id revenue=$calibratedRevenue cost=$dailyCost"
        }
        if ($isTerminalFamily -and $Family -ne '' -and $Tier -gt 0) {
            $key = "${Family}:$Tier"
            if ($Tier -gt 1 -and $script:terminalOutputByFamilyTier.ContainsKey("${Family}:$($Tier - 1)")) {
                $previous = [long]$script:terminalOutputByFamilyTier["${Family}:$($Tier - 1)"]
                # The balance audit measures value per total labor, so the
                # authored output floor must also cover each tier's larger
                # workforce. Tier 3 has the industrial workforce jump.
                $productivityFloor = switch ($Tier) {
                    2 { 2.01 } # 1.34 * 15 / 10
                    3 { 3.58 } # 1.34 * 40 / 15
                    4 { 2.05 } # 1.34 * 61 / 40
                    default { 1.34 }
                }
                $unitQty = [Math]::Max($unitQty, [long][Math]::Ceiling($previous * $productivityFloor))
            }
            $script:terminalOutputByFamilyTier[$key] = [long]$unitQty
        }
        $outputQty = @($Outputs | ForEach-Object { $unitQty })
        $outputTotal = [long](($outputQty | Measure-Object -Sum).Sum)
        $extractQty = if ($extractCount -gt 0) {
            [long][Math]::Max(1, [Math]::Floor($outputTotal / ($extractionRatio * $extractCount)))
        } else { [long]0 }
        $resourceQty = @(
            for ($i = 0; $i -lt $Resources.Count; $i++) {
                if ($ResourceModes[$i] -eq 'extract') { $extractQty } else { $unitQty }
            }
        )
    }
    if ($Behavior -eq 'cultivate_local_resources') {
        $generationIds = $Resources; $generationQty = @($Resources | ForEach-Object { [long]1050 }); $floor = 6554
    }
    # The steam-era ocean fishery operates an installed fleet. Its authored
    # replacement flow is a real terminal sink for ocean-going vessels.
    $maintenanceLines = if ($Id -eq 'method_marine_fish_collector_r4') {
        "maintenance_good_ids = PackedStringArray(`"oceanic_vessels`")`n" +
        "maintenance_quantities_per_day = PackedInt64Array(40)"
    } else { '' }
    # Timber collection remains viable without tools; tools scale the remaining
    # half of capacity through the existing soft-input contract.
    $inputRequiredQ16 = if ($InputRequiredQ16Override.Count -gt 0) {
        @($InputRequiredQ16Override | ForEach-Object { [int]$_ })
    } elseif ($Id -eq 'timber_collector') { @(32768) } else { @() }
    if ($inputRequiredQ16.Count -gt 0 -and $inputRequiredQ16.Count -ne $Inputs.Count) {
        throw "input required q16 mismatch: $Id"
    }
    $agriculturalResources = @('arable_land','paddy_land','plantation_land','pasture','fertile_soil')
    $economicSector = if ($Kind -eq 'collector' -and
        @($Resources | Where-Object { $_ -in $agriculturalResources }).Count -gt 0) {
        'agriculture'
    } elseif ($Kind -eq 'collector') {
        'extractive'
    } elseif ($Category -eq 'energy') {
        'energy'
    } else {
        'manufacturing'
    }
    # Wage policy is an emergent labour-market quote.  Legacy fixed policy
    # entries remain readable, but generated employee roles are always adaptive.
    if ($roleIds.Count -gt 0) {
        $roleWagePolicies = @($roleIds | ForEach-Object { 'adaptive' })
    }
    Write-Utf8 (Join-Path $buildingsDir "$Id.tres") @"
[gd_resource type="Resource" script_class="BuildingProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$Id"
display_name = "$Name"
building_kind = "$Kind"
economic_sector_id = "$economicSector"
technology_tags = PackedStringArray("industry.$Category", $(($directTechnologies | ForEach-Object { '"' + $_ + '"' }) -join ', '))
$(if ($RequiredTechnologyTags.Count -gt 0) { 'required_technology_tags = ' + (PSArray $RequiredTechnologyTags) } else { '' })
upgrade_family_id = &"$Family"
upgrade_tier = $Tier
construction_days = 0
$maintenanceLines
owner_profession_id = &"$Owner"
owner_slots_per_building = 1
employee_profession_ids = $(PSArray $roleIds)
employee_slots_per_building = $(PI64 $roleSlots)
employee_wage_policy_ids = $(PSArray $roleWagePolicies)
input_good_ids = $(PSArray $Inputs)
input_quantities_per_day = $(PI64 $inputQty)
input_required_q16 = $(PI32 $inputRequiredQ16)
input_category_ids = $(PSArray $inputCategories)
input_min_quality_levels = $(PI32 $inputMinLevels)
input_candidate_offsets = $(PI32 $candidateOffsets)
input_candidate_good_ids = $(PSArray $candidateGoodIds)
input_candidate_efficiency_q16 = $(PI32 $candidateEfficiencies)
output_good_ids = $(PSArray $Outputs)
output_quantities_per_day = $(PI64 $outputQty)
target_operating_margin_q16 = $targetMargin
supply_price_elasticity_q16 = $supplyElasticity
resource_ids = $(PSArray $Resources)
resource_quantities_per_day = $(PI64 $resourceQty)
resource_interaction_modes = $(PSArray $ResourceModes)
resource_access_modes = $(PSArray $resourceAccessModes)
resource_generation_ids = $(PSArray $generationIds)
resource_generation_quantities_per_day = $(PI64 $generationQty)
resource_generation_floor_q16 = $floor
behavior_id = "$Behavior"
"@
}

$buildingIds = [System.Collections.Generic.HashSet[string]]::new()
$script:terminalOutputByFamilyTier = @{}
function Add-Building([string]$Id,[string]$Name,[string]$Kind,[string]$Owner,[string]$Worker,
    [string[]]$Inputs,[string[]]$Outputs,[string[]]$Resources,[string[]]$ResourceModes,
    [string]$Behavior,[string]$Category,[string]$Family = '',[int]$Tier = 0,
    [string]$TechnologyOverride = '',[long[]]$InputQuantityOverride = @(),
    [string]$RecipeSourceId = '', [string[]]$TechnologyTagsOverride = @(),
    [string[]]$RequiredTechnologyTags = @(), [int[]]$InputRequiredQ16Override = @(),
    [object[]]$InputCandidateOverride = @(), [string[]]$EmployeeProfessionIdsOverride = @(),
    [long[]]$EmployeeSlotsOverride = @(), [string[]]$EmployeeWagePolicyIdsOverride = @(),
    [switch]$PreserveWorkforce) {
    if (-not $buildingIds.Add($Id)) { throw "duplicate building id: $Id" }
    Write-Building -Id $Id -Name $Name -Kind $Kind -Owner $Owner -Worker $Worker -Inputs $Inputs -Outputs $Outputs -Resources $Resources -ResourceModes $ResourceModes -Behavior $Behavior -Category $Category -Family $Family -Tier $Tier -TechnologyOverride $TechnologyOverride -InputQuantityOverride $InputQuantityOverride -RecipeSourceId $RecipeSourceId -TechnologyTagsOverride $TechnologyTagsOverride -RequiredTechnologyTags $RequiredTechnologyTags -InputRequiredQ16Override $InputRequiredQ16Override -InputCandidateOverride $InputCandidateOverride -EmployeeProfessionIdsOverride $EmployeeProfessionIdsOverride -EmployeeSlotsOverride $EmployeeSlotsOverride -EmployeeWagePolicyIdsOverride $EmployeeWagePolicyIdsOverride -PreserveWorkforce:$PreserveWorkforce
}

function Add-Terminal-Upgrade-Family([string]$Family, [string]$Token, [string]$DisplayName,
    [string]$OutputGood, [string]$PrimaryInput, [string]$Category = 'consumer') {
    $familySpecs = @(
        @{ id="${Token}_workshop"; name="${DisplayName}小作坊"; tier=1;
           tech=@("tech.application.${Token}_workshop_kingdom");
           inputs=@($PrimaryInput,'tools'); qty=@(1000,250); req=@(65536,32768);
           roles=@('artisan','apprentice'); slots=@(6,3); wages=@('fixed','fixed') },
        @{ id="${Token}_manufactory"; name="${DisplayName}工场"; tier=2;
           tech=@("tech.application.${Token}_manufactory_exploration");
           inputs=@($PrimaryInput,'tools'); qty=@(1600,350); req=@(65536,32768);
           roles=@('artisan','journeyman'); slots=@(8,6); wages=@('fixed','fixed') },
        @{ id="${Token}_factory"; name="${DisplayName}工厂"; tier=3;
           tech=@("tech.application.${Token}_factory_steam","tech.application.${Token}_factory_electrical");
           inputs=@($PrimaryInput,'tools','steam_engines','coal'); qty=@(2400,500,300,600); req=@(65536,32768,32768,32768);
           roles=@('industrial_worker','technician','manager'); slots=@(28,8,3); wages=@('adaptive','adaptive','adaptive') },
        @{ id="smart_${Token}_factory"; name="智能${DisplayName}工厂"; tier=4;
           tech=@("tech.application.${Token}_smart_factory");
           inputs=@($PrimaryInput,'tools','electricity','autonomous_systems'); qty=@(3200,700,900,300); req=@(65536,32768,32768,32768);
           roles=@('industrial_worker','technician','engineer','manager'); slots=@(36,12,8,4); wages=@('adaptive','adaptive','adaptive','adaptive') }
    )
    if ($Token -eq 'metal_housewares') {
        $familySpecs[0].inputs = @('wrought_iron','tools')
        $familySpecs[1].inputs = @('wrought_iron','tools')
        $familySpecs[2].inputs = @('wrought_iron','tools','steam_engines','coal')
        $familySpecs[3].inputs = @('wrought_iron','tools','electricity','autonomous_systems')
        $familySpecs[1].qty=@(1600,350); $familySpecs[1].req=@(65536,32768)
        $familySpecs[2].qty=@(2400,500,300,600); $familySpecs[2].req=@(65536,32768,32768,32768)
        $familySpecs[3].inputs=@('wrought_iron','tools','electricity','autonomous_systems')
    }
    if ($Token -eq 'leather_goods') {
        $familySpecs[1].inputs += 'industrial_chemicals'; $familySpecs[1].qty += 150; $familySpecs[1].req += 32768
        $familySpecs[2].inputs += 'industrial_chemicals'; $familySpecs[2].qty += 250; $familySpecs[2].req += 32768
        $familySpecs[3].inputs += 'industrial_chemicals'; $familySpecs[3].qty += 400; $familySpecs[3].req += 32768
    }
    foreach ($spec in $familySpecs) {
        $candidateOverride = @()
        if ($Token -eq 'metal_housewares' -and $spec.tier -ge 2) {
            $candidateOverride = if ($spec.tier -eq 2) {
                @(@{ goods=@('wrought_iron','steel','stainless_steel','aluminum'); efficiencies=@(65536,65536,65536,65536) }, $null)
            } elseif ($spec.tier -eq 3) {
                @(@{ goods=@('wrought_iron','steel','stainless_steel','aluminum'); efficiencies=@(65536,65536,65536,65536) }, $null,
                  @{ goods=@('steam_engines','electric_motor'); efficiencies=@(65536,65536) },
                  @{ goods=@('coal','electricity'); efficiencies=@(65536,65536) })
            } else {
                @(@{ goods=@('wrought_iron','steel','stainless_steel','aluminum'); efficiencies=@(65536,65536,65536,65536) }, $null, $null, $null)
            }
        } elseif ($Token -eq 'leather_goods' -and $spec.tier -eq 4) {
            $candidateOverride = @(@{ goods=@('leather','synthetic_fiber'); efficiencies=@(65536,49152) }, $null, $null, $null, $null)
        } elseif ($spec.tier -eq 3) {
            $candidateOverride = @($null, $null,
                @{ goods=@('steam_engines','electric_motor'); efficiencies=@(65536,65536) },
                @{ goods=@('coal','electricity'); efficiencies=@(65536,65536) })
        }
        Add-Building -Id $spec['id'] -Name $spec['name'] -Kind 'industrial' `
            -Owner $(if ($spec['tier'] -le 2) { 'guild_master' } else { 'industrialist' }) `
            -Worker 'artisan' -Inputs $spec['inputs'] -Outputs @($OutputGood) -Resources @() `
            -ResourceModes @() -Behavior 'none' -Category $Category -Family $Family -Tier $spec['tier'] `
            -TechnologyTagsOverride $spec['tech'] -InputQuantityOverride $spec['qty'] `
            -InputRequiredQ16Override $spec['req'] -InputCandidateOverride $candidateOverride `
            -EmployeeProfessionIdsOverride $spec['roles'] -EmployeeSlotsOverride $spec['slots'] `
            -EmployeeWagePolicyIdsOverride $spec['wages'] `
            -PreserveWorkforce
    }
}

function Write-SelfSufficientBuilding([string]$Id, [string]$Name, [string]$Technology, [string]$Family,
    [int]$Tier, [string]$Owner, [string[]]$Outputs, [long[]]$OutputQty,
    [string[]]$Resources, [long[]]$ResourceQty, [int]$OwnerSlots = 1) {
    # Caller quantities are already full-tool yields for capacity farms.
    # Soft tools (required=32768) make bare-handed yield half of that rate;
    # do not double capacity-farm outputs here.
    $skipSoftTools = $Family -eq 'household_cloth'
    [double]$baseRevenue = 0
    for ($i = 0; $i -lt $Outputs.Count; $i++) {
        $buyFactor = Good-Integer-Field $Outputs[$i] 'merchant_buy_price_factor_q16' 62259
        $baseRevenue += [double]$OutputQty[$i] *
            [double](Default-Price-For-Good $Outputs[$i]) / 1000.0 *
            [double]$buyFactor / 65536.0
    }
    $ownerLivingCost = [double](Reference-Living-Cost-For-Profession $Owner) * [Math]::Max(1, $OwnerSlots)
    $requiredRevenue = $ownerLivingCost * 65536.0 / $DesignSellThroughQ16
    if ($baseRevenue -le 0) { throw "self-sufficient output value missing: $Id" }
    if ($baseRevenue -lt $requiredRevenue) {
        $scale = $requiredRevenue / $baseRevenue
        $OutputQty = @($OutputQty | ForEach-Object {
            [long][Math]::Max(1, [Math]::Ceiling([double]$_ * $scale))
        })
    }
    $shares = if ($Outputs.Count -eq 2) { @(32768, 32768) } else { @() }
    $laborSlots = [Math]::Max(1, $OwnerSlots)
    $toolQty = [long](100 * $laborSlots)
    $inputGoodsLine = if ($skipSoftTools) {
        'input_good_ids = PackedStringArray()'
    } else {
        'input_good_ids = PackedStringArray("tools")'
    }
    $inputQtyLine = if ($skipSoftTools) {
        'input_quantities_per_day = PackedInt64Array()'
    } else {
        "input_quantities_per_day = PackedInt64Array($toolQty)"
    }
    $inputRequiredLine = if ($skipSoftTools) {
        'input_required_q16 = PackedInt32Array()'
    } else {
        'input_required_q16 = PackedInt32Array(32768)'
    }
    $inputCategoryLine = if ($skipSoftTools) {
        'input_category_ids = PackedStringArray()'
    } else {
        'input_category_ids = PackedStringArray("tools")'
    }
    $inputMinLine = if ($skipSoftTools) {
        'input_min_quality_levels = PackedInt32Array()'
    } else {
        'input_min_quality_levels = PackedInt32Array(1)'
    }
    $inputOffsetsLine = if ($skipSoftTools) {
        'input_candidate_offsets = PackedInt32Array(0)'
    } else {
        'input_candidate_offsets = PackedInt32Array(0, 0)'
    }
    Write-Utf8 (Join-Path $buildingsDir "$Id.tres") @"
[gd_resource type="Resource" script_class="BuildingProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$Id"
display_name = "$Name"
building_kind = "collector"
technology_tags = PackedStringArray("$Technology")
upgrade_family_id = &"$Family"
upgrade_tier = $Tier
construction_days = 0
owner_profession_id = &"$Owner"
owner_slots_per_building = $OwnerSlots
employee_profession_ids = PackedStringArray()
employee_slots_per_building = PackedInt64Array()
employee_wage_policy_ids = PackedStringArray()
$inputGoodsLine
$inputQtyLine
$inputRequiredLine
$inputCategoryLine
$inputMinLine
$inputOffsetsLine
input_candidate_good_ids = PackedStringArray()
input_candidate_efficiency_q16 = PackedInt32Array()
output_good_ids = $(PSArray $Outputs)
output_quantities_per_day = $(PI64 $OutputQty)
output_cost_shares_q16 = $(PI32 $shares)
target_operating_margin_q16 = 6554
supply_price_elasticity_q16 = 32768
resource_ids = $(PSArray $Resources)
resource_quantities_per_day = $(PI64 $ResourceQty)
resource_interaction_modes = $(PSArray @($Resources | ForEach-Object { 'capacity' }))
resource_access_modes = $(PSArray @($Resources | ForEach-Object { 'local' }))
resource_generation_ids = PackedStringArray()
resource_generation_quantities_per_day = PackedInt64Array()
resource_generation_floor_q16 = 0
behavior_id = "consume_local_resources"
wage_policy_id = "none"
"@
}

foreach ($row in $resourceRows) {
    $sourceRid = $row[0]
    if ($sourceRid -eq 'wild_game') { continue }
    $rid = $sourceRid
    $outputs = @($row[2])
    $buildingResources = @($rid); $resourceModes = @('extract')
    if ($sourceRid -in @('wheat','corn','potato','flax','cotton','fertile_soil')) {
        $buildingResources = @('arable_land','fertile_soil'); $resourceModes = @('capacity','capacity')
    } elseif ($sourceRid -eq 'rice') {
        $buildingResources = @('paddy_land'); $resourceModes = @('capacity')
    } elseif ($sourceRid -in @('spice_plants','rubber_tree','medicinal_herbs')) {
        $buildingResources = @('plantation_land','fertile_soil'); $resourceModes = @('capacity','capacity')
    }
    $owner = if ($sourceRid -eq 'corn') { 'landlord' } elseif ($sourceRid -in @('rice','potato','fertile_soil')) { 'subsistence_farmer' } elseif ($sourceRid -in @('spice_plants','flax','cotton','medicinal_herbs')) { 'landlord' } else { 'industrialist' }
    $behavior = if ($sourceRid -in $cultivatedResourceIds -or $sourceRid -eq 'fertile_soil') { 'consume_local_resources' } elseif ($sourceRid -eq 'timber') { 'cultivate_local_resources' } else { 'consume_local_resources' }
    $collectorInputs = @()
    if ($rid -eq 'timber') { $collectorInputs = @('tools') }
    elseif ($rid -in @('oil','natural_gas')) { $collectorInputs = @('industrial_machinery','electricity') }
    elseif ($rid -in @('gold_ore','silver_ore')) { $collectorInputs = @('tools') }
    elseif ($rid -in @('rare_earth','bauxite','phosphate_rock','lead_ore','zinc_ore','manganese_ore')) {
        $collectorInputs = @('tools','explosives')
    }
    elseif ($rid -eq 'sulfur') { $collectorInputs = @('tools') }
    elseif ($rid -in @('copper_ore','iron_ore','tin_ore','coal','clay','silica_sand','saltpeter','stone')) { $collectorInputs = @('tools') }
    $collectorWorker = if ($sourceRid -eq 'corn') { '' } else { Worker-For-Resource $sourceRid }
    $collectorFamily = switch ($rid) {
        'oil' { 'oil_extraction' } 'salt' { 'salt_extraction' }
        'gold_ore' { 'gold_extraction' } 'silver_ore' { 'silver_extraction' }
        'clay' { 'clay_extraction' } 'copper_ore' { 'copper_extraction' }
        'tin_ore' { 'tin_extraction' } 'silica_sand' { 'silica_extraction' }
        default { '' }
    }
    $collectorTier = if ($collectorFamily -eq '') { 0 } elseif ($rid -eq 'salt') { 1 } else { 2 }
    Add-Building (Collector-Id $sourceRid) (Collector-Display-Name $sourceRid $row[1]) 'collector' $owner $collectorWorker `
        $collectorInputs $outputs $buildingResources $resourceModes $behavior 'primary' $collectorFamily $collectorTier
}
