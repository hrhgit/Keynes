$deps = @{
    lumber=@('logs'); paper=@('logs','industrial_chemicals');
    packaging=@('paper'); printed_materials=@('paper'); furniture=@('lumber','cloth');
    glassware=@('glass');
    metal_housewares=@('wrought_iron'); leather_goods=@('leather');
    bricks=@('clay'); lime=@('limestone');
    cement=@('lime','clay'); concrete=@('cement','raw_stone'); glass=@('silica_sand');
    construction_components=@('concrete','steel','glass');
    grain=@(); bread=@('wheat_grain'); prepared_staples=@('grain');
    edible_oil=@('corn_grain'); processed_food=@('prepared_staples','meat','vegetables','edible_oil','packaging');
    livestock_products=@(); meat=@('livestock_products'); dairy_products=@('livestock_products');
    canned_fish=@('fish','salt','packaging'); beverages=@('grain','packaging');
    raw_hide=@('livestock_products'); leather=@('raw_hide','industrial_chemicals'); wool=@('livestock_products');
    cloth=@('flax_fiber'); synthetic_fiber=@('petrochemicals'); clothing=@('cloth');
    fine_clothing=@('cloth','fur'); fine_furniture=@('lumber','cloth');
    footwear=@('leather');
    refined_fuel=@('crude_oil'); lubricants=@('crude_oil'); petrochemicals=@('crude_oil','natural_gas');
    plastics=@('petrochemicals'); synthetic_rubber=@('petrochemicals','sulfur');
    industrial_chemicals=@('sulfur','salt'); fertilizer=@('phosphate_rock','natural_gas');
    explosives=@('saltpeter','sulfur'); soap=@('edible_oil','salt'); detergent=@('petrochemicals','industrial_chemicals');
    pharmaceuticals=@('medicinal_herbs','industrial_chemicals'); nuclear_fuel=@('rare_earth_metals');
    steel=@('iron_ore','electricity');
    stainless_steel=@('steel','rare_earth_metals','manganese_ore'); copper=@('copper_ore','coal');
    aluminum=@('bauxite','electricity'); tin=@('tin_ore','coal'); lead=@('lead_ore','coal');
    zinc=@('zinc_ore','coal');
    rare_earth_metals=@('rare_earth_ore'); wire=@('copper');
    tools=@('steel','lumber'); machine_parts=@('steel','lubricants');
    industrial_machinery=@('machine_parts','steam_engines'); agricultural_machinery=@('industrial_machinery','steam_engines');
    electric_motor=@('copper','steel'); engines=@('steel','aluminum','machine_parts','lubricants');
    batteries=@('lead','industrial_chemicals'); electrical_equipment=@('wire','steel','plastics');
    electronic_components=@('copper','tin','zinc','plastics');
    semiconductors=@('silica_sand','industrial_chemicals','electricity');
    computers=@('semiconductors','electronic_components','plastics');
    telecom_equipment=@('semiconductors','electronic_components','wire','batteries','plastics');
    household_appliances=@('electrical_equipment','steel','plastics');
    automobiles=@('engines','steel','batteries','latex');
    railway_equipment=@('steel','electric_motor','tools');
    jewelry=@('gold'); electricity=@('coal')
}

function Collector-Id([string]$Resource) {
    switch ($Resource) {
        'wheat' {'wheat_farm'} 'corn' {'landed_estate'} 'coal' {'coal_mine'}
        'gold_ore' {'gold_mine'} 'silver_ore' {'silver_mine'} default {"${Resource}_collector"}
    }
}
function Collector-Display-Name([string]$Resource,[string]$ResourceName) {
    switch ($Resource) {
        'fertile_soil' {'菜蔬农场'} 'wheat' {'小麦农场'} 'rice' {'稻作农场'}
        'corn' {'玉米庄园'} 'potato' {'马铃薯农场'} 'flax' {'亚麻农场'}
        'cotton' {'棉花农场'} 'spice_plants' {'香料种植园'}
        'rubber_tree' {'橡胶种植园'} 'medicinal_herbs' {'药材种植园'}
        'marine_fish' {'沿岸渔场'} 'timber' {'伐木场'}
        'clay' {'黏土坑'} 'stone' {'采石场'} 'limestone' {'石灰石采石场'}
        'silica_sand' {'硅砂矿'} 'salt' {'盐场'}
        'oil' {'油田'} 'natural_gas' {'天然气田'}
        'coal' {'煤矿'} 'gold_ore' {'金矿'} 'silver_ore' {'银矿'}
        'copper_ore' {'铜矿'} 'iron_ore' {'铁矿'} 'tin_ore' {'锡矿'}
        'lead_ore' {'铅矿'} 'zinc_ore' {'锌矿'} 'manganese_ore' {'锰矿'}
        'bauxite' {'铝土矿'} 'phosphate_rock' {'磷矿'} 'sulfur' {'硫矿'}
        'saltpeter' {'硝石矿'} 'rare_earth' {'战略矿山'}
        default {"${ResourceName}采掘场"}
    }
}
function Worker-For-Resource([string]$Resource) {
    if ($Resource -in @('wheat','rice','corn','potato','fertile_soil','spice_plants','flax','cotton','medicinal_herbs')) { return 'agricultural_worker' }
    if ($Resource -eq 'wild_game') { return 'hunter' }
    if ($Resource -eq 'marine_fish') { return 'fisher' }
    if ($Resource -eq 'stone') { return 'forager' }
    if ($Resource -eq 'timber') { return 'forestry_worker' }
    if ($Resource -in @('oil','natural_gas')) { return 'petroleum_worker' }
    return 'miner'
}
function Worker-For-Output([string]$GoodId,[string]$Category) {
    if ($GoodId -in @('electronic_components','semiconductors','computers','telecom_equipment',
        'advanced_chips','autonomous_systems','radio_equipment','reactor_components')) {
        return 'technician'
    }
    switch ($Category) {
        'construction' { return 'construction_worker' }
        'food' { return 'industrial_worker' }
        'chemicals' { return 'chemist' }
        'metals' { return 'metallurgist' }
        'machinery' { return 'machinist' }
        'energy' { return 'electrician' }
        'forestry' { return 'artisan' }
        'textile' { return 'artisan' }
        'consumer' { return 'artisan' }
        default { return 'technician' }
    }
}
function Technology-For-Building([string]$Id) {
    if ($Id -eq 'marine_fish_collector') { return 'tech.hunting' }
    if ($Id -in @('timber_collector','lumber_plant')) { return 'tech.gathering' }
    if ($Id -in @('stone_collector','flint_quarry')) { return 'tech.stone_knapping' }
    if ($Id -in @('wheat_farm','rice_collector','fertile_soil_collector','flax_collector',
        'pastoral_camp','bakery','staple_kitchen',
        'slaughterhouse','creamery','tannery','wool_shed')) { return 'tech.pottery' }
    if ($Id -in @('early_copper_mine','early_tin_mine','early_copper_smelter','early_tin_smelter')) { return 'tech.bronze_casting' }
    if ($Id -in @('classical_masonry_yard','classical_glass_kiln','classical_silica_pit',
        'early_iron_mine','iron_tool_workshop','clay_collector','copper_ore_collector','tin_ore_collector',
        'bricks_plant','lime_plant','pottery_kiln','salt_collector','limestone_collector')) { return 'tech.masonry' }
    if ($Id -in @('landed_estate','horse_breeder')) { return 'tech.manuscript_culture' }
    if ($Id -in @('potato_collector','manorial_pasture','guild_weaving_house','tailor_shop',
        'cobbler_shop','brewery','composting_yard','court_tailor','cabinetmaker_workshop',
        'soap_plant')) { return 'tech.guild_organization' }
    if ($Id -in @('cotton_collector','spice_plants_collector','rubber_tree_collector','medicinal_herbs_collector')) { return 'tech.oceanic_navigation' }
    if ($Id -in @('packaging_plant','printed_materials_plant',
        'rag_paper_workshop','distillery')) { return 'tech.screw_press_printing' }
    if ($Id -in @('industrial_chemicals_plant','explosives_plant','sulfur_collector',
        'saltpeter_collector','pharmaceuticals_plant','canning_workshop')) { return 'tech.experimental_science' }
    if ($Id -in @('industrial_machinery_plant','machine_parts_plant')) { return 'tech.steam_power' }
    if ($Id -in @('coal_mine','coke_ovens')) { return 'tech.coke_smelting' }
    if ($Id -in @('bread_plant','staple_food_plant','mechanized_farm','mechanized_slaughterhouse',
        'ranching_station','dairy_products_plant','leather_plant','textile_mill','clothing_plant',
        'footwear_plant','steam_coal_mine','steam_iron_mine','steam_steel_works','glass_plant',
        'iron_ore_collector','paper_plant','cement_plant','concrete_plant','construction_components_plant','tools_plant','canned_fish_plant',
        'agricultural_machinery_plant','gold_mine','silver_mine','lubricants_plant','silica_sand_collector',
        'bauxite_collector','lead_ore_collector','lead_plant','zinc_ore_collector','zinc_plant',
        'tin_plant','copper_plant','furniture_plant','early_oil_well','industrial_salt_mine')) { return 'tech.steam_power' }
    if ($Id -in @('electricity_plant','electric_motor_plant','electrical_equipment_plant',
        'engines_plant','automobiles_plant','household_appliances_plant','wire_plant','steel_plant','railway_equipment_plant',
        'oil_collector','natural_gas_collector','refined_fuel_plant',
        'gas_power_plant','oil_power_plant','processed_food_plant','beverages_plant','cloth_plant','intensive_farm',
        'fine_clothing_plant','fine_furniture_plant','jewelry_plant')) { return 'tech.electrification' }
    if ($Id -in @('aluminum_plant','batteries_plant','fertilizer_plant',
        'petrochemicals_plant','plastics_plant','electrochemical_works')) { return 'tech.electrochemistry' }
    if ($Id -eq 'detergent_plant') { return 'tech.petrochemical_industry' }
    if ($Id -eq 'electronic_components_plant') { return 'tech.radio' }
    if ($Id -eq 'rare_earth_collector') { return 'tech.geological_prospecting' }
    if ($Id -eq 'rare_earth_metals_plant') { return 'tech.advanced_metallurgy' }
    if ($Id -in @('manganese_ore_collector','stainless_steel_plant',
        'synthetic_fiber_plant','synthetic_rubber_plant','synthetic_textile_mill')) { return 'tech.advanced_metallurgy' }
    if ($Id -eq 'nuclear_fuel_plant' -or $Id -eq 'nuclear_power_plant') { return 'tech.nuclear_fission' }
    if ($Id -in @('semiconductors_plant','computers_plant')) { return 'tech.digital_computing' }
    if ($Id -eq 'telecom_equipment_plant') { return 'tech.networked_computing' }
    return ''
}
function Technology-Rank([string]$Technology) {
	if ($technologyRankById.ContainsKey($Technology)) { return [int]$technologyRankById[$Technology] }
    $rank = @{
        'tech.hunting'=0; 'tech.gathering'=0; 'tech.stone_knapping'=0; 'tech.fire_control'=0;
        'tech.pottery'=1; 'tech.bronze_casting'=1; 'tech.writing'=2; 'tech.masonry'=2;
        'tech.manuscript_culture'=3; 'tech.guild_organization'=3; 'tech.oceanic_navigation'=4;
        'tech.screw_press_printing'=4; 'tech.experimental_science'=5; 'tech.precision_engineering'=5;
        'tech.coke_smelting'=6; 'tech.steam_power'=6; 'tech.steam_sawmilling'=6;
        'tech.electrification'=7; 'tech.radio'=7;
        'tech.electrochemistry'=7; 'tech.geological_prospecting'=8; 'tech.advanced_metallurgy'=8;
        'tech.nuclear_fission'=8; 'tech.petrochemical_industry'=8;
        'tech.digital_computing'=9; 'tech.networked_computing'=9;
        'tech.machine_learning'=10; 'tech.autonomous_systems'=10
    }
    if ($rank.ContainsKey($Technology)) { return [int]$rank[$Technology] }
    return 99
}

function Tool-Min-Quality-For-Rank([int]$Rank) {
    if ($Rank -le 0) { return 1 }
    if ($Rank -le 3) { return 2 }
    if ($Rank -le 8) { return 3 }
    return 4
}

function Extraction-Ratio-For-Building([string]$Id) {
    if ($Id -eq 'stone_age_hunting_camp') { return 2 }
    if ($Id -in @('early_clay_pit','early_copper_mine','early_tin_mine')) { return 2 }
    if ($Id -eq 'classical_silica_pit') { return 4 }
    if ($Id -in @('steam_coal_mine','steam_iron_mine')) { return 12 }
    if ($Id -eq 'marine_fish_collector') { return 8 }
    if ($Id -in @('clay_collector','limestone_collector','silica_sand_collector','stone_collector','salt_collector')) { return 10 }
    if ($Id -eq 'timber_collector') { return 16 }
    if ($Id -in @('oil_collector','natural_gas_collector','rare_earth_collector')) { return 25 }
    return 20
}

function Default-Price-For-Good([string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id)) { return [long]0 }
    $path = Join-Path $goodsDir "$Id.tres"
    if (-not (Test-Path -LiteralPath $path)) { throw "good price source missing: $Id" }
    $match = [regex]::Match([System.IO.File]::ReadAllText($path), '(?m)^default_price = (\d+)\r?$')
    if (-not $match.Success) { return [long]10000 }
    return [long]$match.Groups[1].Value
}

function Good-Integer-Field([string]$Id, [string]$Field, [int]$DefaultValue) {
    $path = Join-Path $goodsDir "$Id.tres"
    if (-not (Test-Path -LiteralPath $path)) { return $DefaultValue }
    $match = [regex]::Match([System.IO.File]::ReadAllText($path), "(?m)^${Field} = (\d+)\r?$")
    return $(if ($match.Success) { [int]$match.Groups[1].Value } else { $DefaultValue })
}

function Cheapest-Tool-Effective-Price([int]$MaxRank, [int]$MinQuality) {
    $best = [double]::PositiveInfinity
    foreach ($toolId in @('chipped_stone_tools','bronze_tools','tools','precision_tools')) {
        if ((Technology-Rank (Technology-For-Good $toolId)) -gt $MaxRank) { continue }
        $quality = Good-Integer-Field $toolId 'production_quality_level' 0
        if ($quality -lt $MinQuality) { continue }
        $efficiency = Good-Integer-Field $toolId 'production_efficiency_q16' 65536
        $best = [Math]::Min($best,
            [double](Default-Price-For-Good $toolId) * 65536.0 / [Math]::Max(1, $efficiency))
    }
    return $best
}

function Cheapest-Category-Effective-Price([string]$CategoryId, [int]$MaxRank, [int]$MinQuality) {
    $best = [double]::PositiveInfinity
    foreach ($goodId in @($substitutionCategoriesByGood.Keys | Sort-Object)) {
        if ($CategoryId -notin @(Substitution-Categories-For-Good $goodId) -or
            (Technology-Rank (Technology-For-Good $goodId)) -gt $MaxRank) { continue }
        $quality = Good-Integer-Field $goodId 'production_quality_level' 0
        if ($quality -lt $MinQuality) { continue }
        $efficiency = Good-Integer-Field $goodId 'production_efficiency_q16' 65536
        $best = [Math]::Min($best,
            [double](Default-Price-For-Good $goodId) * 65536.0 / [Math]::Max(1, $efficiency))
    }
    if ([double]::IsPositiveInfinity($best)) {
        throw "no era-compatible category candidate during calibration: $CategoryId"
    }
    return $best
}

function Content-Strings([string]$Content, [string]$Field) {
    $match = [regex]::Match($Content, "(?m)^${Field} = PackedStringArray\((.*)\)\r?$")
    if (-not $match.Success) { return @() }
    return @([regex]::Matches($match.Groups[1].Value, '"([^"]*)"') |
        ForEach-Object { $_.Groups[1].Value })
}

function Content-Numbers([string]$Content, [string]$Field) {
    $match = [regex]::Match($Content, "(?m)^${Field} = PackedInt(?:32|64)Array\((.*)\)\r?$")
    if (-not $match.Success) { return @() }
    return @([regex]::Matches($match.Groups[1].Value, '-?\d+') |
        ForEach-Object { [long]$_.Value })
}

function Content-String([string]$Content, [string]$Field, [string]$DefaultValue = '') {
    $pattern = '(?m)^' + [regex]::Escape($Field) + ' = &?"([^"]*)"\r?$'
    $match = [regex]::Match($Content, $pattern)
    return $(if ($match.Success) { $match.Groups[1].Value } else { $DefaultValue })
}

function Content-Integer([string]$Content, [string]$Field, [long]$DefaultValue = 0) {
    $match = [regex]::Match($Content, "(?m)^${Field} = (-?\d+)\r?$")
    return $(if ($match.Success) { [long]$match.Groups[1].Value } else { $DefaultValue })
}

$referenceLivingCostByPlan = @{}
function Reference-Living-Cost-For-Plan([string]$PlanId) {
    if ($referenceLivingCostByPlan.ContainsKey($PlanId)) {
        return [long]$referenceLivingCostByPlan[$PlanId]
    }
    $path = Join-Path $plansDir "$PlanId.tres"
    if (-not (Test-Path -LiteralPath $path)) { throw "living-cost plan missing: $PlanId" }
    $content = [System.IO.File]::ReadAllText($path)
    $needIds = @(Content-Strings $content 'need_ids')
    $baseQty = @(Content-Numbers $content 'base_qty_per_person')
    $variantOffsets = @(Content-Numbers $content 'need_variant_offsets')
    $preferences = @(Content-Numbers $content 'variant_preference_q16')
    $componentOffsets = @(Content-Numbers $content 'variant_component_offsets')
    $componentGoods = @(Content-Strings $content 'component_good_ids')
    $componentQty = @(Content-Numbers $content 'component_qty_per_need')
    if ($needIds.Count -ne $baseQty.Count -or $variantOffsets.Count -ne $needIds.Count + 1) {
        throw "living-cost plan columns mismatch: $PlanId"
    }
    [double]$total = 0
    for ($needIndex = 0; $needIndex -lt $needIds.Count; $needIndex++) {
        $needPath = Join-Path $needsDir "$($needIds[$needIndex]).tres"
        if (-not (Test-Path -LiteralPath $needPath)) {
            throw "living-cost need missing: $($needIds[$needIndex])"
        }
        $needContent = [System.IO.File]::ReadAllText($needPath)
        $livingWeight = Content-Integer $needContent 'living_cost_weight_q16' 0
        if ($livingWeight -le 0) { continue }
        [long]$scoreSum = 0
        [double]$weightedPrice = 0
        for ($variant = [int]$variantOffsets[$needIndex];
                $variant -lt [int]$variantOffsets[$needIndex + 1]; $variant++) {
            [double]$unitPrice = 0
            for ($component = [int]$componentOffsets[$variant];
                    $component -lt [int]$componentOffsets[$variant + 1]; $component++) {
                $unitPrice += [double]$componentQty[$component] *
                    [double](Default-Price-For-Good $componentGoods[$component]) / 1000.0
            }
            $score = [long]$preferences[$variant]
            $scoreSum += $score
            $weightedPrice += $unitPrice * [double]$score
        }
        if ($scoreSum -le 0) { continue }
        $quantity = [double]$baseQty[$needIndex] * [double]$livingWeight / 65536.0
        $total += $quantity * ($weightedPrice / [double]$scoreSum) / 1000.0
    }
    $result = [long][Math]::Ceiling($total)
    $referenceLivingCostByPlan[$PlanId] = $result
    return $result
}

function Reference-Living-Cost-For-Profession([string]$ProfessionId) {
    $path = Join-Path $professionsDir "$ProfessionId.tres"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "living-cost profession missing: $ProfessionId"
    }
    $planId = Content-String ([System.IO.File]::ReadAllText($path)) 'default_consumption_plan_id'
    if ([string]::IsNullOrWhiteSpace($planId)) {
        throw "profession living-cost plan missing: $ProfessionId"
    }
    return Reference-Living-Cost-For-Plan $planId
}

function Calibrate-CuratedBuilding([string]$Content, [string]$Id) {
    $inputs = @(Content-Strings $Content 'input_good_ids')
    $inputQty = @(Content-Numbers $Content 'input_quantities_per_day')
    $inputCategories = @(Content-Strings $Content 'input_category_ids')
    $inputMinLevels = @(Content-Numbers $Content 'input_min_quality_levels')
    $outputs = @(Content-Strings $Content 'output_good_ids')
    $outputQty = @(Content-Numbers $Content 'output_quantities_per_day')
    $roleSlots = @(Content-Numbers $Content 'employee_slots_per_building')
    $roleIds = @(Content-Strings $Content 'employee_profession_ids')
    $technologyTags = @(Content-Strings $Content 'technology_tags')
    $ownerSlots = Content-Integer $Content 'owner_slots_per_building' 1
    $jobs = [long]$ownerSlots + [long](($roleSlots | Measure-Object -Sum).Sum)
    $recipeInputOverrides = @{
        # Keep early local chains financeable without inflating their output merely
        # to pay for excessive intermediate consumption.
        bronze_tool_workshop = [long[]]@(1500, 500)
        ore_bronzesmith_camp = [long[]]@(500, 500, 500)
    }
    if ($recipeInputOverrides.ContainsKey($Id)) {
        $inputQty = @($recipeInputOverrides[$Id])
    }
    for ($i = 0; $i -lt [Math]::Min($inputs.Count, $inputQty.Count); $i++) {
        $isTool = $inputs[$i] -in @('chipped_stone_tools','bronze_tools','tools','precision_tools') -or
            ($i -lt $inputCategories.Count -and $inputCategories[$i] -eq 'tools')
        if (-not $isTool) { continue }
        $toolCap = [Math]::Max(1, $jobs * 100)
        $inputQty[$i] = [Math]::Min([long]$inputQty[$i], [long]$toolCap)
    }
    if ($Id -eq 'stone_age_hunting_camp' -and $inputs.Count -eq 1 -and
            $inputs[0] -eq 'chipped_stone_tools') {
        # One local knapping workshop must be able to equip the resource-supported
        # hunting camps created by the mid-stone bootstrap.
        $inputQty[0] = 5
    }
    if ($inputs.Count -gt 0 -and $inputQty.Count -eq $inputs.Count) {
        $Content = [regex]::Replace($Content,
            '(?m)^input_quantities_per_day = PackedInt64Array\(.*\)\r?$',
            'input_quantities_per_day = ' + (PI64 @($inputQty)))
    }
    $buildingRank = -1
    foreach ($technologyTag in $technologyTags) {
        if ($technologyTag.StartsWith('tech.')) {
            $buildingRank = [Math]::Max($buildingRank, (Technology-Rank $technologyTag))
        }
    }
    if ($inputMinLevels.Count -lt $inputs.Count) {
        $inputMinLevels = @(for ($i = 0; $i -lt $inputs.Count; $i++) {
            if ($i -lt $inputMinLevels.Count) { [int]$inputMinLevels[$i] } else { 0 }
        })
    }
    for ($i = 0; $i -lt [Math]::Min($inputs.Count, $inputCategories.Count); $i++) {
        if ($inputCategories[$i] -eq 'tools') {
            $inputMinLevels[$i] = Tool-Min-Quality-For-Rank $buildingRank
        }
    }
    if ($inputs.Count -gt 0) {
        $minimumLine = 'input_min_quality_levels = ' + (PI32 @($inputMinLevels))
        if ([regex]::IsMatch($Content, '(?m)^input_min_quality_levels = PackedInt32Array\(.*\)\r?$')) {
            $Content = [regex]::Replace($Content,
                '(?m)^input_min_quality_levels = PackedInt32Array\(.*\)\r?$', $minimumLine)
        } elseif (@($inputCategories | Where-Object { $_ -eq 'tools' }).Count -gt 0) {
            $Content = [regex]::Replace($Content,
                '(?m)^(input_category_ids = PackedStringArray\(.*\)\r?)$', "`$1`n$minimumLine")
        }
    }
    if ($outputs.Count -eq 0 -or $outputQty.Count -ne $outputs.Count) { return $Content }
    $cost = [double]0
    for ($i = 0; $i -lt [Math]::Min($inputs.Count, $inputQty.Count); $i++) {
        $effectivePrice = [double](Default-Price-For-Good $inputs[$i])
        if ($i -lt $inputCategories.Count -and $inputCategories[$i] -eq 'tools') {
            $minimum = if ($i -lt $inputMinLevels.Count) { [int]$inputMinLevels[$i] } else { 0 }
            $effectivePrice = Cheapest-Tool-Effective-Price $buildingRank $minimum
        }
        $cost += [double]$inputQty[$i] * $effectivePrice / 1000.0
    }
    # Wage amounts are not authored content. Calibration uses the profession's
    # living-cost floor solely as a deterministic planning estimate.
    $roleLivingCosts = @($roleIds | ForEach-Object {
        Reference-Living-Cost-For-Profession $_
    })
    for ($i = 0; $i -lt [Math]::Min($roleSlots.Count, $roleLivingCosts.Count); $i++) {
        $cost += [double]$roleSlots[$i] * [double]$roleLivingCosts[$i]
    }
    if ($Id -in @('knapping_workshop', 'communal_hearth')) {
        # These Stone Age recipes are physical balance anchors. Price and living-cost
        # calibration must not silently rewrite their audited throughput.
        return Scale-Food-Output-Quantities $Content
    }
    if ($outputs -contains 'gold' -or $outputs -contains 'silver') {
        return Scale-Food-Output-Quantities $Content
    }
    $ownerId = Content-String $Content 'owner_profession_id'
    $ownerSlots = [Math]::Max(1, (Content-Integer $Content 'owner_slots_per_building' 1))
    $ownerLivingCost = [double](Reference-Living-Cost-For-Profession $ownerId) * $ownerSlots
    $marginMatch = [regex]::Match($Content, '(?m)^target_operating_margin_q16 = (\d+)\r?$')
    $targetMargin = if ($marginMatch.Success) { [int]$marginMatch.Groups[1].Value } else { 9830 }
    if (@($outputs | Where-Object { $_ -in @('jewelry','fine_clothing','fine_furniture') }).Count -gt 0) {
        $targetMargin = 13107
    }
    $marginRevenue = [Math]::Ceiling(
        $cost * 65536.0 / [Math]::Max(1, 65536 - $targetMargin))
    $breakEvenRevenue = [Math]::Max(
        $marginRevenue, [Math]::Ceiling($cost + $ownerLivingCost))
    $requiredRevenue = [Math]::Ceiling(
        $breakEvenRevenue * 65536.0 / $DesignSellThroughQ16)
    [double]$baseRevenue = 0
    for ($i = 0; $i -lt $outputs.Count; $i++) {
        $baseRevenue += [double]$outputQty[$i] *
            [double](Default-Price-For-Good $outputs[$i]) / 1000.0 * 62259.0 / 65536.0
    }
    if ($baseRevenue -le 0) { throw "curated building output value missing: $Id" }
    $scale = [double]$requiredRevenue / $baseRevenue
    $scaledOutputQty = @($outputQty | ForEach-Object {
        [long][Math]::Max(1, [Math]::Ceiling([double]$_ * $scale))
    })
    $Content = [regex]::Replace($Content,
        '(?m)^output_quantities_per_day = PackedInt64Array\(.*\)\r?$',
        'output_quantities_per_day = ' + (PI64 @($scaledOutputQty)))
    $resourceModes = @(Content-Strings $Content 'resource_interaction_modes')
    $resourceQty = @(Content-Numbers $Content 'resource_quantities_per_day')
    $extractCount = @($resourceModes | Where-Object { $_ -eq 'extract' }).Count
    if ($extractCount -gt 0 -and $resourceQty.Count -eq $resourceModes.Count) {
        $outputTotal = [long](($scaledOutputQty | Measure-Object -Sum).Sum)
        $extractQty = if ($Id -eq 'stone_age_hunting_camp') {
            # Wild-game capacity is the binding ecological constraint. Preserve
            # the field-tested depletion rate while shifting the catch away from
            # stockpiling hide and fur.
            [long]715
        } else {
            [long][Math]::Max(1, [Math]::Floor(
                $outputTotal / ((Extraction-Ratio-For-Building $Id) * $extractCount)))
        }
        for ($i = 0; $i -lt $resourceModes.Count; $i++) {
            if ($resourceModes[$i] -eq 'extract') { $resourceQty[$i] = $extractQty }
        }
        $Content = [regex]::Replace($Content,
            '(?m)^resource_quantities_per_day = PackedInt64Array\(.*\)\r?$',
            'resource_quantities_per_day = ' + (PI64 @($resourceQty)))
    }
    return Scale-Food-Output-Quantities $Content
}

$explicitInputCandidates = @{
    bakery = @(@{ goods=@('wheat_grain','grain','corn_grain'); efficiencies=@(65536,58982,49152) })
    bread_plant = @(@{ goods=@('wheat_grain','grain','corn_grain'); efficiencies=@(65536,58982,49152) }, $null)
    rag_paper_workshop = @(@{ goods=@('flax_fiber','cotton_fiber','cloth'); efficiencies=@(65536,65536,49152) })
    paper_plant = @(@{ goods=@('logs','flax_fiber','cotton_fiber'); efficiencies=@(65536,49152,49152) }, $null)
    brewery = @(@{ goods=@('grain','wheat_grain','rice_grain','corn_grain'); efficiencies=@(65536,65536,58982,58982) })
    distillery = @(@{ goods=@('grain','wheat_grain','rice_grain','corn_grain'); efficiencies=@(65536,65536,58982,58982) }, $null)
    beverages_plant = @(@{ goods=@('grain','wheat_grain','rice_grain','corn_grain'); efficiencies=@(65536,65536,58982,58982) }, $null)
    processed_food_plant = @(
        @{ goods=@('prepared_staples','bread'); efficiencies=@(65536,58982) },
        @{ goods=@('meat','fish','game_meat','dairy_products'); efficiencies=@(65536,65536,58982,58982) },
        $null, $null, $null)
    footwear_plant = @(
        @{ goods=@('leather','cloth'); efficiencies=@(65536,49152) },
        @{ goods=@('latex','synthetic_rubber'); efficiencies=@(49152,65536) })
    insulated_cable_plant = @(
        $null,
        @{ goods=@('plastics','synthetic_rubber'); efficiencies=@(65536,65536) })
    packaging_plant = @(@{ goods=@('paper','glass','steel','aluminum','plastics'); efficiencies=@(65536,49152,58982,78643,78643) })
    furniture_plant = @($null, @{ goods=@('cloth','leather'); efficiencies=@(65536,65536) })
    cabinetmaker_workshop = @($null, @{ goods=@('cloth','leather'); efficiencies=@(65536,65536) })
    fine_furniture_plant = @($null, @{ goods=@('cloth','leather'); efficiencies=@(65536,65536) }, $null)
    soap_plant = @(@{ goods=@('edible_oil','livestock_products'); efficiencies=@(65536,49152) }, $null)
    tools_plant = @(
        @{ goods=@('steel','stainless_steel'); efficiencies=@(65536,78643) },
        @{ goods=@('lumber','plastics'); efficiencies=@(65536,78643) })
    machine_parts_plant = @(
        @{ goods=@('steel','stainless_steel','aluminum'); efficiencies=@(65536,78643,49152) },
        @{ goods=@('lubricants','edible_oil'); efficiencies=@(65536,32768) })
    wire_plant = @(@{ goods=@('copper','aluminum'); efficiencies=@(65536,49152) })
    batteries_plant = @(@{ goods=@('lead','rare_earth_metals'); efficiencies=@(65536,98304) }, $null)
    electric_motor_plant = @(
        @{ goods=@('copper','aluminum'); efficiencies=@(65536,49152) },
        @{ goods=@('steel','aluminum'); efficiencies=@(65536,58982) })
    construction_components_plant = @(
        $null,
        @{ goods=@('steel','stainless_steel','aluminum'); efficiencies=@(65536,65536,58982) },
        $null)
    copper_plant = @($null, @{ goods=@('coal','coke'); efficiencies=@(65536,78643) })
    tin_plant = @($null, @{ goods=@('coal','coke'); efficiencies=@(65536,78643) })
    lead_plant = @($null, @{ goods=@('coal','coke'); efficiencies=@(65536,78643) })
    zinc_plant = @($null, @{ goods=@('coal','coke'); efficiencies=@(65536,78643) })
    lubricants_plant = @(@{ goods=@('crude_oil','petrochemicals'); efficiencies=@(65536,78643) })
    industrial_machinery_plant = @($null, @{ goods=@('steam_engines','electric_motor'); efficiencies=@(49152,65536) })
    agricultural_machinery_plant = @($null, @{ goods=@('steam_engines','engines'); efficiencies=@(49152,65536) })
    automobiles_plant = @(
        $null,
        @{ goods=@('steel','stainless_steel','aluminum'); efficiencies=@(65536,62259,58982) },
        $null,
        @{ goods=@('latex','synthetic_rubber'); efficiencies=@(49152,65536) })
    electrical_equipment_plant = @(
        $null,
        @{ goods=@('steel','aluminum'); efficiencies=@(65536,58982) },
        $null)
    railway_equipment_plant = @(
        @{ goods=@('steel','stainless_steel'); efficiencies=@(65536,62259) },
        $null,
        $null)
    computers_plant = @(
        @{ goods=@('semiconductors','advanced_chips'); efficiencies=@(65536,131072) },
        $null,
        $null)
    telecom_equipment_plant = @(
        @{ goods=@('semiconductors','advanced_chips'); efficiencies=@(65536,131072) },
        $null,
        $null,
        $null,
        $null)
    household_appliances_plant = @($null, @{ goods=@('steel','stainless_steel','aluminum'); efficiencies=@(49152,65536,58982) }, $null)
    jewelry_plant = @(@{ goods=@('gold','silver','rare_earth_metals'); efficiencies=@(65536,65536,49152) })
    synthetic_textile_mill = @(@{ goods=@('synthetic_fiber','cotton_fiber','flax_fiber','wool'); efficiencies=@(65536,49152,49152,49152) }, $null)
}

# Category slots are used only where every member is genuinely equivalent for
# this recipe. Weighted or narrower choices remain explicit candidates above.
$inputCategoryOverrides = @{
    staple_kitchen = @('starchy_staple')
    staple_food_plant = @('starchy_staple', '')
    goldsmith_workshop = @('precious_metal')
    guild_weaving_house = @('guild_textile_fiber')
    textile_mill = @('natural_spinnable_fiber', '')
    cloth_plant = @('natural_spinnable_fiber', '')
}
