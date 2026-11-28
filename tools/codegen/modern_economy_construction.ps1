$constructionRecipeOverrides = @{
    classical_glass_kiln = [ordered]@{ logs=750; raw_stone=500 }
    glassware_workshop = [ordered]@{ logs=500; raw_stone=500 }
    glassware_manufactory = [ordered]@{ lumber=750; bricks=750; tools=250 }
    glassware_factory = [ordered]@{ bricks=750; construction_components=500; steel=500; glass=250 }
    smart_glassware_factory = [ordered]@{ concrete=1000; steel=750; glass=500; electronic_components=300; computers=100 }
    metal_housewares_workshop = [ordered]@{ logs=500; raw_stone=500 }
    metal_housewares_manufactory = [ordered]@{ lumber=750; bricks=750; tools=300 }
    metal_housewares_factory = [ordered]@{ bricks=750; construction_components=500; steel=750; glass=250 }
    smart_metal_housewares_factory = [ordered]@{ concrete=1000; steel=1000; glass=500; electronic_components=300; computers=100 }
    leather_goods_workshop = [ordered]@{ logs=500; raw_stone=500 }
    leather_goods_manufactory = [ordered]@{ lumber=750; bricks=750; tools=250 }
    leather_goods_factory = [ordered]@{ bricks=750; construction_components=500; steel=500; glass=250 }
    smart_leather_goods_factory = [ordered]@{ concrete=1000; steel=750; glass=500; electronic_components=300; computers=100 }
    construction_components_plant = [ordered]@{ lumber=750; bricks=750; steel=500 }
    communal_hearth = [ordered]@{ logs=500; gathered_plants=250 }
    coal_mine = [ordered]@{ lumber=500; bricks=750; construction_components=750 }
    coke_ovens = [ordered]@{ lumber=500; bricks=750; construction_components=750 }
    flint_quarry = [ordered]@{ logs=500; gathered_plants=250 }
    freshwater_fishing_camp = [ordered]@{ logs=500; gathered_plants=250 }
    gathering_ground = [ordered]@{ logs=1000 }
    household_weaving_shelter = [ordered]@{ logs=2000; gathered_plants=4000 }
    knapping_workshop = [ordered]@{ logs=1000; flint=500 }
    lumber_plant = [ordered]@{ logs=500; gathered_plants=250 }
    method_lumber_plant_r6 = [ordered]@{ logs=750; bricks=500 }
    marine_fish_collector = [ordered]@{ logs=500; gathered_plants=250 }
    placer_gold_working = [ordered]@{ logs=1000; gathered_plants=500 }
    stone_age_hunting_camp = [ordered]@{ logs=1000; gathered_plants=500 }
    stone_collector = [ordered]@{ logs=500; gathered_plants=250 }
    surface_silver_working = [ordered]@{ logs=1500; gathered_plants=750 }
    steam_coal_mine = [ordered]@{ lumber=500; bricks=750; construction_components=750 }
    timber_collector = [ordered]@{ gathered_plants=250 }
}

# Construction-material backbone producers may only consume materials from an
# earlier topological layer. This table is deliberately about construction
# reachability, not about their recurring production recipes.
$constructionBackbonePredecessors = @{
    logs = @('gathered_plants','raw_stone','lumber','bricks','construction_components','steel','concrete','glass')
    gathered_plants = @('logs','raw_stone','lumber','bricks','construction_components','steel','concrete','glass')
    raw_stone = @('logs','gathered_plants','lumber','bricks','construction_components','steel','concrete','glass')
    bricks = @('logs','raw_stone','lumber','construction_components')
    lumber = @('logs','raw_stone','bricks')
    construction_components = @('lumber','bricks')
    steel = @('lumber','bricks','construction_components')
    concrete = @('bricks','construction_components','steel')
    glass = @('bricks','construction_components','steel')
}

function Add-Explicit-Construction-Cost([string]$Path) {
    $content = [System.IO.File]::ReadAllText($Path)
    $id = Content-Scalar-String $content 'id'
    $existingGoods = @(Content-Strings $content 'construction_good_ids')
    $existingQuantities = @(Content-Numbers $content 'construction_quantities')
    if ($existingGoods.Count -ne $existingQuantities.Count) {
        throw "construction columns mismatch: $id"
    }

    $rank = Rank-From-Profile-Content $content
    $kind = Content-Scalar-String $content 'building_kind'
    if ($rank -lt 0 -and $kind -eq 'service') { $rank = 0 }
    if ($rank -lt 0 -or $rank -gt 10) { throw "building lacks construction rank: $id" }
    $ownerSlots = [Math]::Max(1, (Content-Integer $content 'owner_slots_per_building' 1))
    $employeeSlots = @(Content-Numbers $content 'employee_slots_per_building')
    [long]$jobs = [long]$ownerSlots + [long](($employeeSlots | Measure-Object -Sum).Sum)
    $outputs = @(Content-Strings $content 'output_good_ids')

    # Material tiers are cumulative and only use goods available before or at
    # the building's technology rank. Quantities are GOODS_SCALE per job, so a
    # larger organization carries a proportionally larger fixed-capital bill.
    $recipe = if ($constructionRecipeOverrides.ContainsKey($id)) {
        $constructionRecipeOverrides[$id]
    } elseif ($rank -eq 0) {
        [ordered]@{ logs=500; gathered_plants=250 }
    } elseif ($rank -eq 1) {
        [ordered]@{ logs=750; raw_stone=500 }
    } elseif ($rank -eq 2) {
        [ordered]@{ logs=750; raw_stone=750; bricks=500 }
    } elseif ($rank -le 5) {
        [ordered]@{ lumber=750; bricks=750; construction_components=500 }
    } elseif ($rank -eq 6) {
        [ordered]@{ lumber=500; bricks=750; construction_components=750; steel=500 }
    } else {
        [ordered]@{ construction_components=1000; steel=750; concrete=750; glass=250 }
    }

    if (-not $constructionRecipeOverrides.ContainsKey($id)) {
        $backboneOutputs = @($outputs | Where-Object {
            $constructionBackbonePredecessors.ContainsKey($_)
        })
        if ($backboneOutputs.Count -gt 0) {
            $allowed = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal)
            foreach ($material in $constructionBackbonePredecessors[$backboneOutputs[0]]) {
                [void]$allowed.Add($material)
            }
            for ($i = 1; $i -lt $backboneOutputs.Count; $i++) {
                [void]$allowed.IntersectWith(
                    [string[]]$constructionBackbonePredecessors[$backboneOutputs[$i]])
            }
            $filteredRecipe = [ordered]@{}
            foreach ($material in $recipe.Keys) {
                if ($allowed.Contains($material)) {
                    $filteredRecipe[$material] = $recipe[$material]
                }
            }
            $recipe = $filteredRecipe
        }
    }

    $constructionGoods = @()
    [long[]]$constructionQuantities = @()
    foreach ($material in $recipe.Keys) {
        # A producer cannot require its own first output as construction input.
        if ($material -in $outputs) { continue }
        if ((Technology-Rank (Technology-For-Good $material)) -gt $rank) {
            throw "construction technology inversion: $id -> $material"
        }
        $constructionGoods += $material
        $constructionQuantities += [long]$recipe[$material] * $jobs
    }
    if ($constructionGoods.Count -eq 0) {
        throw "construction recipe has no acyclic material: id=$id rank=$rank outputs=$($outputs -join ',') candidates=$($recipe.Keys -join ',')"
    }

    $constructionLines = "construction_good_ids = $(PSArray $constructionGoods)`n" +
        "construction_quantities = $(PI64 $constructionQuantities)"
    if ($existingGoods.Count -gt 0) {
        $content = [regex]::Replace($content,
            '(?m)^construction_good_ids = PackedStringArray\(.*\)\r?\nconstruction_quantities = PackedInt64Array\(.*\)\r?$',
            $constructionLines, 1)
    } else {
        $content = [regex]::Replace($content,
            '(?m)^(construction_days = \d+\r?)$', "`$1`n$constructionLines", 1)
    }
    if (-not [regex]::IsMatch($content, '(?m)^construction_good_ids = PackedStringArray\(.+\)\r?$')) {
        throw "failed to write construction cost: $id"
    }
    $script:finalizingConstruction = $true
    try {
        Write-Utf8 $Path $content
    } finally {
        $script:finalizingConstruction = $false
    }
}

# Construction is authored content, not a catalog fallback. Traverse the final
# generated + curated + upgraded building set so every runtime profile is explicit.
foreach ($buildingFile in Get-ChildItem -LiteralPath $buildingsDir -Filter '*.tres' -File | Sort-Object Name) {
    Add-Explicit-Construction-Cost $buildingFile.FullName
}

# Curated technology-contract calibrations that must survive a full content
# rebuild. Identification is a hard technology prerequisite; buildings do not
# repeat it as an invisible runtime-only requirement.
$buildingTechnologyCalibrations = @{
    wild_maize_stand = @{ direct='tech.wild_maize_collection'; required=@() }
    wild_wheat_stand = @{ direct='tech.wild_wheat_collection'; required=@() }
    wild_rice_marsh = @{ direct='tech.wild_rice_collection'; required=@() }
    primitive_gold_sluice = @{ direct='tech.gold_panning'; required=@('tech.composite_tools') }
    landed_estate = @{ direct='tech.estate_cereal_management'; required=@('tech.maize_propagation','tech.rainfed_field_system','tech.estate_accounting','tech.serf_obligations') }
    method_wheat_farm_r3 = @{ direct='tech.estate_cereal_management'; required=@('tech.wheat_propagation','tech.rainfed_field_system','tech.estate_accounting','tech.intensive_crop_rotation') }
    method_wheat_farm_r5 = @{ direct='tech.estate_cereal_management'; required=@('tech.wheat_propagation','tech.rainfed_field_system','tech.estate_accounting','tech.intensive_crop_rotation','tech.crop_breeding','tech.long_term_leases') }
    method_flax_collector_r3 = @{ direct='tech.estate_plantation_management'; required=@('tech.flax_retting','tech.seed_selection','tech.estate_accounting') }
    method_flax_collector_r5 = @{ direct='tech.estate_plantation_management'; required=@('tech.flax_retting','tech.estate_accounting','tech.crop_breeding','tech.long_term_leases') }
    method_rice_collector_r3 = @{ direct='tech.tenant_paddy_management'; required=@('tech.rice_paddy_cultivation','tech.rice_water_control','tech.customary_tenancy') }
    method_rice_collector_r5 = @{ direct='tech.estate_paddy_management'; required=@('tech.rice_water_control','tech.estate_accounting','tech.crop_breeding','tech.long_term_leases') }
    jewelry_plant = @{ direct='tech.mass_production'; required=@('tech.currency','tech.industrial_quality_control','tech.corporate_management') }
    method_oceanic_shipyard_r7 = @{ direct='tech.electric_motors'; required=@('tech.oceanic_ship_design','tech.coastal_shipyards','tech.mass_production','tech.industrial_statistics') }
    footwear_plant = @{ direct='tech.factory_system'; required=@('tech.hide_tanning','tech.textile_machinery','tech.interchangeable_parts') }
    leather_plant = @{ direct='tech.factory_system'; required=@('tech.hide_tanning','tech.industrial_chemistry','tech.interchangeable_parts') }
    cloth_plant = @{ direct='tech.mass_production'; required=@('tech.textile_machinery','tech.corporate_management') }
    fine_clothing_plant = @{ direct='tech.mass_production'; required=@('tech.textile_machinery','tech.corporate_management') }
    method_lead_plant_r9 = @{ direct='tech.digital_control'; required=@('tech.advanced_metallurgy','tech.mineral_spectral_survey','tech.sensor_networks','tech.industrial_quality_control') }
    method_zinc_plant_r9 = @{ direct='tech.digital_control'; required=@('tech.advanced_metallurgy','tech.mineral_spectral_survey','tech.sensor_networks','tech.industrial_quality_control') }
    method_synthetic_fiber_plant_r10 = @{ direct='tech.robotic_manufacturing'; required=@('tech.synthetic_fiber_engineering','tech.machine_learning','tech.digital_control','tech.algorithmic_management') }
    method_synthetic_rubber_plant_r10 = @{ direct='tech.robotic_manufacturing'; required=@('tech.synthetic_materials','tech.machine_learning','tech.digital_control','tech.algorithmic_management') }
    method_aluminum_plant_r10 = @{ direct='tech.robotic_manufacturing'; required=@('tech.advanced_metallurgy','tech.specialty_alloys','tech.digital_control','tech.algorithmic_management','tech.autonomous_labor_coordination') }
    method_stainless_steel_plant_r10 = @{ direct='tech.robotic_manufacturing'; required=@('tech.advanced_metallurgy','tech.specialty_alloys','tech.digital_control','tech.algorithmic_management','tech.autonomous_labor_coordination') }
    method_reactor_component_works_r10 = @{ direct='tech.robotic_manufacturing'; required=@('tech.nuclear_energy','tech.autonomous_systems','tech.digital_control','tech.algorithmic_management') }
    detergent_plant = @{ direct='tech.petrochemical_industry'; required=@('tech.industrial_chemistry','tech.electrochemistry') }
    method_detergent_plant_r10 = @{ direct='tech.petrochemical_industry'; required=@('tech.industrial_chemistry','tech.electrochemistry','tech.machine_learning','tech.robotic_manufacturing','tech.digital_control','tech.algorithmic_management') }
    method_rare_earth_collector_r10 = @{ direct='tech.autonomous_mining'; required=@('tech.mineral_spectral_survey','tech.digital_control') }
    method_zinc_ore_collector_r9 = @{ direct='tech.mineral_spectral_survey'; required=@('tech.mechanized_mining') }
    method_limestone_collector_r6 = @{ direct='tech.geological_prospecting'; required=@('tech.industrial_organization') }
    method_saltpeter_collector_r8 = @{ direct='tech.mechanized_mining'; required=@('tech.geological_prospecting','tech.industrial_chemistry') }
    method_sulfur_collector_r8 = @{ direct='tech.mechanized_mining'; required=@('tech.geological_prospecting','tech.industrial_chemistry') }
    method_cotton_collector_r6 = @{ direct='tech.mechanized_agriculture'; required=@('tech.cotton_gardening','tech.mechanical_threshing') }
    method_potato_collector_r6 = @{ direct='tech.mechanized_agriculture'; required=@('tech.highland_tuber_farming','tech.mechanical_reaping') }
    method_phosphate_rock_collector_r9 = @{ direct='tech.digital_control'; required=@('tech.mineral_spectral_survey','tech.mechanized_mining','tech.fertilizer_processing') }
    batteries_plant = @{ direct='tech.electrochemistry'; required=@() }
    method_rare_earth_metals_plant_r10 = @{ direct='tech.robotic_manufacturing'; required=@('tech.advanced_metallurgy','tech.mineral_spectral_survey','tech.digital_control','tech.algorithmic_management','tech.systems_engineering') }
    method_concrete_plant_r9 = @{ direct='tech.digital_control'; required=@('tech.industrial_quality_control','tech.sensor_networks') }
    method_highland_precision_agriculture = @{ direct='tech.precision_agriculture'; required=@('tech.highland_tuber_farming','tech.geographic_information_systems','tech.biotechnology') }
    method_autonomous_forestry = @{ direct='tech.autonomous_systems'; required=@('tech.satellite_observation','tech.smart_grid','tech.scientific_agents') }
    # 2026-08-24 解锁错位修复（解锁即可建原则）：主解锁移动到与实际能力门槛同代的技术。
    ore_bronzesmith_camp = @{ direct='tech.bronze_casting'; required=@('tech.tin_identification') }
    ranching_station = @{ direct='tech.mechanized_agriculture'; required=@() }
    felt_making_tent = @{ direct='tech.wool_husbandry'; required=@() }
}
foreach ($buildingId in $buildingTechnologyCalibrations.Keys) {
    $path = Join-Path $buildingsDir "$buildingId.tres"
    $content = [System.IO.File]::ReadAllText($path)
    $calibration = $buildingTechnologyCalibrations[$buildingId]
    $content = [regex]::Replace($content,
        '(?m)^technology_tags = PackedStringArray\([^\r\n]*\)\r?$',
        'technology_tags = PackedStringArray("' + $calibration.direct + '")', 1)
    $content = [regex]::Replace($content,
        '(?m)^required_technology_tags = PackedStringArray\([^\r\n]*\)\r?$',
        'required_technology_tags = ' + (PSArray @($calibration.required)), 1)
    Write-Utf8 $path $content
}

# Landlord ownership does not turn cultivated land into extraction. These
# profiles consume agricultural carrying capacity and therefore belong to the
# agriculture sector for both broad output modifiers and UI classification.
foreach ($buildingId in @('landed_estate','medicinal_herbs_collector')) {
    $path = Join-Path $buildingsDir "$buildingId.tres"
    $content = [System.IO.File]::ReadAllText($path)
    $content = [regex]::Replace($content,
        '(?m)^economic_sector_id = "[^"]*"\r?$',
        'economic_sector_id = "agriculture"', 1)
    Write-Utf8 $path $content
}

# Refined bullion is not produced by the surface-collection technology. Keep
# ore/resource access on the starter node and bind refined gold to its assay
# and washing method so the per-technology content fanout remains bounded.
$goodTechnologyCalibrations = @{
    gold = 'tech.weights_and_measures'
}
foreach ($goodId in $goodTechnologyCalibrations.Keys) {
    $path = Join-Path $goodsDir "$goodId.tres"
    $content = [System.IO.File]::ReadAllText($path)
    $technology = $goodTechnologyCalibrations[$goodId]
    $content = [regex]::Replace($content,
        '(?m)^technology_tags = PackedStringArray\("industry\.[^"]+", "tech\.[^"]+"\)\r?$',
        'technology_tags = PackedStringArray("industry.primary", "' + $technology + '")', 1)
    Write-Utf8 $path $content
}
