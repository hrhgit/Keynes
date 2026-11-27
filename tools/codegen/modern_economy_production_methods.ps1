# Cross-era hand-authored upgrade families for food, livestock, leather, and textiles.
Add-Building 'pastoral_camp' '游牧营地' 'collector' 'pastoralist' 'pastoralist' @() @('livestock_products') @('pasture') @('capacity') 'consume_local_resources' 'food' 'livestock_husbandry' 1
Add-Building 'manorial_pasture' '庄园牧场' 'collector' 'landlord' 'pastoralist' @() @('livestock_products') @('pasture') @('capacity') 'consume_local_resources' 'food' 'livestock_husbandry' 2
Add-Building 'ranching_station' '机械化牧场' 'collector' 'landlord' 'agricultural_worker' @('agricultural_machinery') @('livestock_products') @('pasture') @('capacity') 'consume_local_resources' 'food' 'livestock_husbandry' 3
Add-Building 'horse_breeding_camp' '马匹繁育营地' 'collector' 'pastoralist' 'pastoralist' @() @('horses') @('pasture') @('capacity') 'consume_local_resources' 'primary' 'horse_breeding' 1 'tech.bronze_casting'
Add-Building 'horse_breeder' '养马场' 'collector' 'landlord' 'pastoralist' @() @('horses') @('pasture') @('capacity') 'consume_local_resources' 'primary' 'horse_breeding' 2
Add-Building 'mechanized_farm' '机械化农场' 'collector' 'landlord' 'agricultural_worker' @('agricultural_machinery') @('grain','vegetables') @('arable_land','fertile_soil') @('capacity','capacity') 'consume_local_resources' 'food' 'field_crop_farming' 1
Add-Building 'intensive_farm' '电气化集约农场' 'collector' 'landlord' 'agricultural_worker' @('fertilizer','agricultural_machinery','electricity') @('grain','vegetables') @('arable_land','fertile_soil') @('capacity','capacity') 'consume_local_resources' 'food' 'field_crop_farming' 2

Add-Building 'bakery' '面包坊' 'industrial' 'artisan' 'artisan' @('wheat_grain') @('bread') @() @() 'none' 'food' 'bread_baking' 1
Add-Building 'bread_plant' '面包厂' 'industrial' 'industrialist' 'industrial_worker' @('wheat_grain','packaging') @('bread') @() @() 'none' 'food' 'bread_baking' 2
Add-Building 'staple_kitchen' '主食厨房' 'industrial' 'artisan' 'artisan' @('grain') @('prepared_staples') @() @() 'none' 'food' 'staple_preparation' 1
Add-Building 'staple_food_plant' '主食加工厂' 'industrial' 'industrialist' 'industrial_worker' @('grain','packaging') @('prepared_staples') @() @() 'none' 'food' 'staple_preparation' 2
Add-Building 'slaughterhouse' '屠宰场' 'industrial' 'artisan' 'artisan' @('livestock_products') @('meat','raw_hide') @() @() 'none' 'food' 'meat_processing' 1
Add-Building 'mechanized_slaughterhouse' '工业屠宰场' 'industrial' 'industrialist' 'industrial_worker' @('livestock_products','industrial_machinery') @('meat','raw_hide') @() @() 'none' 'food' 'meat_processing' 2
Add-Building 'creamery' '乳品工坊' 'industrial' 'artisan' 'artisan' @('livestock_products') @('dairy_products') @() @() 'none' 'food' 'dairy_processing' 1
Add-Building 'dairy_products_plant' '乳制品厂' 'industrial' 'industrialist' 'industrial_worker' @('livestock_products','packaging') @('dairy_products') @() @() 'none' 'food' 'dairy_processing' 2

Add-Building 'wool_shed' '羊毛棚' 'industrial' 'artisan' 'artisan' @('livestock_products') @('wool') @() @() 'none' 'textile' 'wool_processing' 1
Add-Building 'tannery' '制革工坊' 'industrial' 'artisan' 'artisan' @('raw_hide') @('leather') @() @() 'none' 'textile' 'leather_processing' 1
Add-Building 'leather_plant' '制革厂' 'industrial' 'industrialist' 'artisan' @('raw_hide','industrial_chemicals') @('leather') @() @() 'none' 'textile' 'leather_processing' 2
Add-Building 'guild_weaving_house' '行会织造坊' 'industrial' 'artisan' 'artisan' @('flax_fiber') @('cloth') @() @() 'none' 'textile' 'cloth_weaving' 1
Add-Building 'textile_mill' '蒸汽纺织厂' 'industrial' 'industrialist' 'artisan' @('flax_fiber','coal') @('cloth') @() @() 'none' 'textile' 'cloth_weaving' 2
Add-Building 'cloth_plant' '电力纺织厂' 'industrial' 'industrialist' 'artisan' @('flax_fiber','electricity') @('cloth') @() @() 'none' 'textile' 'cloth_weaving' 3
Add-Building 'synthetic_textile_mill' '合成纤维织造厂' 'industrial' 'industrialist' 'industrial_worker' @('synthetic_fiber','electricity') @('cloth') @() @() 'none' 'textile' 'cloth_weaving' 4
Add-Building 'tailor_shop' '裁缝铺' 'industrial' 'artisan' 'artisan' @('cloth') @('clothing') @() @() 'none' 'textile' 'garment_making' 1
Add-Building 'clothing_plant' '制衣厂' 'industrial' 'industrialist' 'artisan' @('cloth') @('clothing') @() @() 'none' 'textile' 'garment_making' 2
Add-Building 'cobbler_shop' '鞋匠铺' 'industrial' 'artisan' 'artisan' @('leather') @('footwear') @() @() 'none' 'textile' 'footwear_making' 1
Add-Building 'footwear_plant' '制鞋厂' 'industrial' 'industrialist' 'artisan' @('leather','latex') @('footwear') @() @() 'none' 'textile' 'footwear_making' 2

Add-Building 'rag_paper_workshop' '碎布造纸工坊' 'industrial' 'guild_master' 'artisan' @('flax_fiber') @('paper') @() @() 'none' 'forestry' 'paper_making' 1
Add-Building 'paper_plant' '造纸厂' 'industrial' 'industrialist' 'artisan' @('logs','industrial_chemicals') @('paper') @() @() 'none' 'forestry' 'paper_making' 2
Add-Building 'brewery' '酿酒坊' 'industrial' 'artisan' 'artisan' @('grain') @('beverages') @() @() 'none' 'food' 'beverage_making' 1
Add-Building 'distillery' '蒸馏酒坊' 'industrial' 'guild_master' 'artisan' @('grain','pottery') @('beverages') @() @() 'none' 'food' 'beverage_making' 2
Add-Building 'beverages_plant' '酿造厂' 'industrial' 'industrialist' 'industrial_worker' @('grain','packaging') @('beverages') @() @() 'none' 'food' 'beverage_making' 3
Add-Building 'composting_yard' '堆肥场' 'industrial' 'artisan' 'agricultural_worker' @('livestock_products') @('fertilizer') @() @() 'none' 'chemicals' 'fertilizer_making' 1
Add-Building 'fertilizer_plant' '化肥厂' 'industrial' 'industrialist' 'chemist' @('phosphate_rock','natural_gas','electricity') @('fertilizer') @() @() 'none' 'chemicals' 'fertilizer_making' 2
Add-Building 'industrial_chemicals_plant' '化学工场' 'industrial' 'guild_master' 'chemist' @('sulfur','salt') @('industrial_chemicals') @() @() 'none' 'chemicals' 'chemical_industry' 1
Add-Building 'electrochemical_works' '电化工厂' 'industrial' 'industrialist' 'chemist' @('salt','electricity') @('industrial_chemicals') @() @() 'none' 'chemicals' 'chemical_industry' 2
Add-Building 'early_oil_well' '蒸汽钻井场' 'collector' 'industrialist' 'petroleum_worker' @('steel','precision_tools','steam_engines') @('crude_oil') @('oil') @('extract') 'consume_local_resources' 'primary' 'oil_extraction' 1
Add-Building 'industrial_salt_mine' '深井盐矿' 'collector' 'industrialist' 'miner' @('tools','explosives') @('salt') @('salt') @('extract') 'consume_local_resources' 'primary' 'salt_extraction' 2
Add-Building 'goldsmith_workshop' '金银器工坊' 'industrial' 'artisan' 'artisan' @('gold') @('jewelry') @() @() 'none' 'consumer' 'jewelry_making' 1
Add-Building 'jewelry_plant' '珠宝厂' 'industrial' 'industrialist' 'artisan' @('gold') @('jewelry') @() @() 'none' 'consumer' 'jewelry_making' 2
Add-Building 'court_tailor' '宫廷裁缝坊' 'industrial' 'guild_master' 'artisan' @('cloth','fur') @('fine_clothing') @() @() 'none' 'textile' 'fine_clothing_making' 1
Add-Building 'fine_clothing_plant' '高级成衣厂' 'industrial' 'industrialist' 'artisan' @('cloth','industrial_chemicals','electricity') @('fine_clothing') @() @() 'none' 'textile' 'fine_clothing_making' 2
Add-Building 'cabinetmaker_workshop' '细木家具工坊' 'industrial' 'guild_master' 'artisan' @('lumber','cloth') @('fine_furniture') @() @() 'none' 'consumer' 'fine_furniture_making' 1
Add-Building 'fine_furniture_plant' '高级家具厂' 'industrial' 'industrialist' 'artisan' @('lumber','cloth','industrial_chemicals') @('fine_furniture') @() @() 'none' 'consumer' 'fine_furniture_making' 2
Add-Building 'construction_components_plant' '建筑构件厂' 'industrial' 'industrialist' 'construction_worker' @('concrete','steel','glass') @('construction_components') @() @() 'none' 'construction' 'construction_methods' 3
Add-Building 'ore_bronzesmith_camp' '露天青铜作坊' 'industrial' 'artisan' 'artisan' @('copper_ore','tin_ore','logs') @('bronze_tools') @() @() 'none' 'tools'
Add-Building 'early_iron_mine' '浅层铁矿' 'collector' 'artisan' 'miner' @('bronze_tools') @('iron_ore') @('iron_ore') @('extract') 'consume_local_resources' 'primary' 'iron_extraction' 1
Add-Building 'iron_tool_workshop' '铁制工具工坊' 'industrial' 'artisan' 'artisan' @('iron_ore','logs') @('tools') @() @() 'none' 'machinery' 'metal_toolmaking' 1
Add-Building 'canning_workshop' '罐头工坊' 'industrial' 'guild_master' 'artisan' @('fish','salt','packaging','tools') @('canned_fish') @() @() 'none' 'food' 'fish_canning' 1
Add-Terminal-Upgrade-Family 'glassware_making' 'glassware' '玻璃器皿' 'glassware' 'glass'
Add-Terminal-Upgrade-Family 'metal_housewares_making' 'metal_housewares' '金属家用器皿' 'metal_housewares' 'wrought_iron'
Add-Terminal-Upgrade-Family 'leather_goods_making' 'leather_goods' '皮革制品' 'leather_goods' 'leather'

$explicitIndustryGoods = @(
    'adobe_brick','grain','bread','prepared_staples','livestock_products','meat','dairy_products','raw_hide',
    'wool','leather','cloth','clothing','footwear','paper','beverages','fertilizer',
    'industrial_chemicals','jewelry','fine_clothing','fine_furniture','construction_components',
    'glassware','metal_housewares','leather_goods'
)
foreach ($category in $processedGroups.Keys) {
    foreach ($good in $processedGroups[$category]) {
        if ($good -in @('fur','adobe_brick') -or $good -in $explicitIndustryGoods) { continue }
        $id = "${good}_plant"
        $worker = Worker-For-Output $good $category
        $displayName = if ($good -eq 'electricity') { '燃煤发电厂' } elseif ($good -eq 'tools') { '钢制工具厂' } `
            elseif ($good -eq 'steel') { '电弧炉炼钢厂' } elseif ($good -eq 'glass') { '玻璃厂' } `
            elseif ($good -eq 'railway_equipment') { '铁路设备厂' } `
            elseif ($good -eq 'edible_oil') { '榨油坊' } elseif ($good -eq 'soap') { '制皂工坊' } `
            elseif ($good -eq 'aluminum') { '电解铝厂' } elseif ($good -eq 'copper') { '炼铜厂' } `
            elseif ($good -eq 'tin') { '炼锡厂' } elseif ($good -eq 'lead') { '炼铅厂' } `
            elseif ($good -eq 'zinc') { '炼锌厂' } elseif ($good -eq 'coke') { '焦化厂' } `
            elseif ($good -eq 'lubricants') { '润滑油厂' } elseif ($good -eq 'petrochemicals') { '石油化工厂' } `
            elseif ($good -eq 'refined_fuel') { '炼油厂' } elseif ($good -eq 'machine_parts') { '机械零件厂' } `
            elseif ($good -eq 'wire') { '线材厂' } elseif ($good -eq 'processed_food') { '综合食品厂' } `
            elseif ($good -eq 'lumber') { '锯木场' } elseif ($good -eq 'bricks') { '制砖厂' } `
            elseif ($good -eq 'printed_materials') { '印刷厂' } elseif ($good -eq 'canned_fish') { '鱼类罐头厂' } `
            elseif ($good -eq 'pharmaceuticals') { '制药厂' } `
            elseif ($good -eq 'rare_earth_metals') { '战略金属冶炼厂' } `
            else { "$($goodNames[$good])厂" }
        $family = switch ($good) {
            'tools' { 'metal_toolmaking' } 'canned_fish' { 'fish_canning' }
            'glass' { 'glassmaking' } 'steel' { 'steelmaking' }
            'railway_equipment' { 'railway_equipment_making' } default { '' }
        }
        $tier = if ($family -eq '') { 0 } else { 2 }
        Add-Building $id $displayName 'industrial' 'industrialist' $worker @($deps[$good]) @($good) @() @() 'none' $category $family $tier
    }
}
foreach ($power in @(
    @('gas_power_plant','燃气发电厂','natural_gas'),
    @('oil_power_plant','燃油发电厂','refined_fuel'),
    @('nuclear_power_plant','核电站','nuclear_fuel')
)) {
    $powerInputs = if ($power[0] -eq 'nuclear_power_plant') {
        @('nuclear_fuel','reactor_components')
    } else {
        @($power[2])
    }
    Add-Building $power[0] $power[1] 'industrial' 'industrialist' 'electrician' $powerInputs @('electricity') @() @() 'none' 'energy'
}

Write-SelfSufficientBuilding 'gathering_ground' '采集营地' 'tech.gathering' `
    'subsistence_food' 1 'forager' @('gathered_plants') @(7000) @('fertile_soil') @(1000) 2
Write-SelfSufficientBuilding 'subsistence_farm' '自给农庄' 'tech.pottery' `
    'subsistence_food' 2 'subsistence_farmer' @('grain','vegetables') @(4000,4000) @('arable_land','fertile_soil') @(10000,10000)
Write-SelfSufficientBuilding 'three_field_smallholding' '三圃制小农场' 'tech.guild_organization' `
    'subsistence_food' 3 'subsistence_farmer' @('grain','vegetables') @(6000,6000) @('arable_land','fertile_soil') @(8000,8000)
Write-SelfSufficientBuilding 'improved_smallholding' '改良小农场' 'tech.steam_power' `
    'subsistence_food' 4 'subsistence_farmer' @('grain','vegetables') @(8000,8000) @('arable_land','fertile_soil') @(6000,6000)
Write-Utf8 (Join-Path $buildingsDir 'household_weaving_shelter.tres') @"
[gd_resource type="Resource" script_class="BuildingProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"household_weaving_shelter"
display_name = "家庭织造棚"
building_kind = "industrial"
technology_tags = PackedStringArray("tech.gathering")
upgrade_family_id = &"household_cloth"
upgrade_tier = 1
construction_days = 0
construction_good_ids = PackedStringArray("logs", "gathered_plants")
construction_quantities = PackedInt64Array(2000, 4000)
owner_profession_id = &"artisan"
owner_slots_per_building = 1
employee_profession_ids = PackedStringArray()
employee_slots_per_building = PackedInt64Array()
employee_wage_policy_ids = PackedStringArray()
input_good_ids = PackedStringArray("gathered_plants")
input_quantities_per_day = PackedInt64Array(120)
output_good_ids = PackedStringArray("cloth")
output_quantities_per_day = PackedInt64Array(110)
output_cost_shares_q16 = PackedInt32Array()
target_operating_margin_q16 = 6554
supply_price_elasticity_q16 = 32768
resource_ids = PackedStringArray()
resource_quantities_per_day = PackedInt64Array()
resource_interaction_modes = PackedStringArray()
resource_access_modes = PackedStringArray()
resource_generation_ids = PackedStringArray()
resource_generation_quantities_per_day = PackedInt64Array()
resource_generation_floor_q16 = 0
behavior_id = "none"
wage_policy_id = "none"
"@
Write-SelfSufficientBuilding 'household_loom' '家用织机' 'tech.pottery' `
    'household_cloth' 2 'artisan' @('cloth') @(1320) @('arable_land','fertile_soil') @(10000,10000)
Write-SelfSufficientBuilding 'cottage_weaving' '家庭纺织坊' 'tech.guild_organization' `
    'household_cloth' 3 'artisan' @('cloth') @(2400) @('arable_land','fertile_soil') @(8000,8000)
Write-SelfSufficientBuilding 'improved_domestic_loom' '改良家用织机' 'tech.steam_power' `
    'household_cloth' 4 'artisan' @('cloth') @(3600) @('arable_land','fertile_soil') @(6000,6000)
foreach ($id in @('gathering_ground','subsistence_farm','three_field_smallholding','improved_smallholding',
    'household_weaving_shelter','household_loom','cottage_weaving','improved_domestic_loom')) {
    if (-not $buildingIds.Add($id)) { throw "duplicate subsistence building id: $id" }
}
if ($buildingIds.Count -lt 90) { throw "building count below target: $($buildingIds.Count)" }

$generatedResourceIds = @('marine_fish','arable_land','paddy_land','plantation_land','pasture',
    'bauxite','limestone','silica_sand','phosphate_rock','tin_ore','lead_ore',
    'zinc_ore','manganese_ore','sulfur')
$newResources = $naturalResourceRows | Where-Object { $_[0] -in $generatedResourceIds }
foreach ($row in $newResources) {
    $id = $row[0]
    $resourcePath = Join-Path $resourcesDir "$id.tres"
    # Resource profiles contain hand-tuned geography, climate and ecology
    # parameters.  The economy generator may verify their presence but must
    # never replace those parameters with its coarse fallback template.
    if (Test-Path -LiteralPath $resourcePath) {
        [void]$managedPaths.Add([System.IO.Path]::GetFullPath($resourcePath))
        continue
    }
    $habitat = if ($id -eq 'marine_fish') { 'coastal_land' } else { 'land' }
    $genBase=0.0; $genSelf=0.0; $decaySelf=0.0
    $initBase=-120000.0; $initTemp=0.0; $initMoisture=0.0; $initElevation=0.0
    $initRiver=0.0; $initVolcano=0.0; $initClimateFit=0.0
    $initNoise=100000.0; $noiseScale=0.07
    $family=''; $province=0.0; $belt=0.0; $provinceScale=0.012; $beltScale=0.035
    $tempOpt=0.5; $tempTol=1.0; $moistureOpt=0.5; $moistureTol=1.0
    $minCoverage=0.005; $minReserve=10000.0
    $ecologyCapacity=0.0; $ecologyGrowth=0.0; $ecologyImmigration=0.0; $ecologyStressMortality=0.0
    $reserveScale = if ($id -eq 'marine_fish') { 2.0 } elseif ($id -in @('arable_land','paddy_land','plantation_land','pasture')) { 1.0 } else { 8.0 }
    switch ($id) {
        'marine_fish' { $genBase=0.0; $genSelf=0.0; $decaySelf=0.0; $initBase=400.0; $initNoise=1200.0; $noiseScale=0.045; $minCoverage=1.0; $minReserve=3000.0; $ecologyCapacity=5000.0; $ecologyGrowth=0.02; $ecologyImmigration=0.2; $ecologyStressMortality=0.01 }
        'arable_land' { $initBase=-40.0; $initMoisture=25.0; $initElevation=-35.0; $initRiver=30.0; $initClimateFit=140.0; $initNoise=30.0; $tempOpt=0.55; $tempTol=0.42; $moistureOpt=0.55; $moistureTol=0.4; $minCoverage=0.6; $minReserve=1250.0 }
        'paddy_land' { $initBase=-90.0; $initMoisture=70.0; $initElevation=-25.0; $initRiver=180.0; $initClimateFit=120.0; $initNoise=20.0; $tempOpt=0.68; $tempTol=0.32; $moistureOpt=0.78; $moistureTol=0.28; $minCoverage=0.2; $minReserve=600.0 }
        'plantation_land' { $initBase=-85.0; $initMoisture=55.0; $initElevation=-20.0; $initClimateFit=150.0; $initNoise=35.0; $tempOpt=0.72; $tempTol=0.3; $moistureOpt=0.7; $moistureTol=0.3; $minCoverage=0.2; $minReserve=1400.0 }
        'pasture' { $initBase=-55.0; $initMoisture=15.0; $initElevation=-20.0; $initRiver=20.0; $initClimateFit=150.0; $initNoise=35.0; $tempOpt=0.52; $tempTol=0.45; $moistureOpt=0.48; $moistureTol=0.45; $minCoverage=0.6; $minReserve=1250.0 }
        'bauxite' { $family='laterite'; $initBase=-380000.0; $initMoisture=180000.0; $initElevation=80000.0; $province=220000.0; $belt=100000.0; $initNoise=180000.0; $minCoverage=0.04 }
        'limestone' { $family='sedimentary'; $initBase=-260000.0; $province=300000.0; $belt=140000.0; $initNoise=180000.0; $minCoverage=0.05 }
        'silica_sand' { $family='surface'; $initBase=-190000.0; $initRiver=100000.0; $province=120000.0; $belt=80000.0; $initNoise=220000.0; $minCoverage=0.05 }
        'phosphate_rock' { $family='sedimentary'; $initBase=-330000.0; $province=260000.0; $belt=160000.0; $initNoise=180000.0; $minCoverage=0.04 }
        'tin_ore' { $family='felsic'; $initBase=-360000.0; $initElevation=90000.0; $initRiver=50000.0; $province=190000.0; $belt=230000.0; $initNoise=160000.0; $minCoverage=0.03 }
        'lead_ore' { $family='hydrothermal'; $initBase=-350000.0; $initElevation=70000.0; $province=180000.0; $belt=250000.0; $initNoise=160000.0; $minCoverage=0.03 }
        'zinc_ore' { $family='hydrothermal'; $initBase=-330000.0; $province=190000.0; $belt=240000.0; $initNoise=170000.0; $minCoverage=0.03 }
        'manganese_ore' { $family='mafic'; $initBase=-340000.0; $province=210000.0; $belt=210000.0; $initNoise=170000.0; $minCoverage=0.03 }
        'sulfur' { $family='hydrothermal'; $initBase=-300000.0; $initVolcano=180000.0; $province=160000.0; $belt=230000.0; $initNoise=160000.0; $minCoverage=0.03 }
    }
    Write-Utf8 (Join-Path $resourcesDir "$id.tres") @"
[gd_resource type="Resource" script_class="ResourceProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/resource_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$id"
display_name = "$($row[1])"
reserve_component = &"cell.res_${id}_reserve"
habitat_mode = "$habitat"
init_reserve_scale = $reserveScale
init_min_coverage = $minCoverage
init_min_reserve = $minReserve
    temp_lo = 0.0
    temp_hi = 1.0
gen_base = $genBase
gen_self = $genSelf
decay_self = $decaySelf
init_base = $initBase
init_temp = $initTemp
init_moisture = $initMoisture
init_elevation = $initElevation
init_river = $initRiver
init_volcano = $initVolcano
init_climate_fit = $initClimateFit
init_noise = $initNoise
init_noise_scale = $noiseScale
geology_family_id = &"$family"
init_province = $province
init_province_scale = $provinceScale
init_belt = $belt
init_belt_scale = $beltScale
climate_temp_opt = $tempOpt
climate_temp_tol = $tempTol
climate_moisture_opt = $moistureOpt
climate_moisture_tol = $moistureTol
ecology_capacity = $ecologyCapacity
ecology_growth_rate = $ecologyGrowth
ecology_immigration = $ecologyImmigration
ecology_stress_mortality_rate = $ecologyStressMortality
"@
}

function Content-Scalar-String([string]$Content, [string]$Field) {
    $pattern = '(?m)^{0} = &?"([^"]*)"\r?$' -f [regex]::Escape($Field)
    $match = [regex]::Match($Content, $pattern)
    return $(if ($match.Success) { $match.Groups[1].Value } else { '' })
}

function Rank-From-Profile-Content([string]$Content) {
    $rank = -1
    foreach ($tag in @(Content-Strings $Content 'technology_tags')) {
        if ($tag.StartsWith('tech.')) { $rank = [Math]::Max($rank, (Technology-Rank $tag)) }
    }
    return $rank
}

function Industry-For-Good([string]$GoodId) {
    if ($goods.Contains($GoodId)) { return [string]$goods[$GoodId].category }
    $curatedIndustry = @{
        advanced_chips='machinery'; autonomous_systems='machinery'; bronze_tools='machinery';
        chipped_stone_tools='machinery'; coke='energy'; flint='primary'; gathered_plants='food';
        insulated_cable='machinery'; manuscripts='forestry'; oceanic_vessels='machinery';
        pottery='consumer'; precision_tools='machinery'; seed_cotton='textile';
        radio_equipment='machinery'; reactor_components='machinery';
        scientific_instruments='machinery'; steam_engines='machinery'
    }
    if ($curatedIndustry.ContainsKey($GoodId)) { return $curatedIndustry[$GoodId] }
    throw "good lacks industry during method generation: $GoodId"
}

function Good-Rank-From-File([string]$GoodId) {
    $content = [System.IO.File]::ReadAllText((Join-Path $goodsDir "$GoodId.tres"))
    $rank = Rank-From-Profile-Content $content
    if ($rank -lt 0 -or $rank -gt 10) { throw "good lacks valid rank during method generation: $GoodId" }
    return $rank
}

function Worker-For-Method([string]$Kind, [string]$Category, [string[]]$Resources) {
    if ($Kind -eq 'collector') {
        if ($Resources -contains 'wild_game') { return 'hunter' }
        if (@($Resources | Where-Object { $_ -in @('arable_land','paddy_land','plantation_land','pasture','fertile_soil') }).Count -gt 0) { return 'agricultural_worker' }
        if ($Resources -contains 'marine_fish') { return 'fisher' }
        if ($Resources -contains 'timber') { return 'forestry_worker' }
        if (@($Resources | Where-Object { $_ -in @('oil','natural_gas') }).Count -gt 0) { return 'petroleum_worker' }
        return 'miner'
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

$methodTechnologyByRank = @{
    1='tech.bronze_casting'; 2='tech.masonry'; 3='tech.guild_organization'; 4='tech.screw_press_printing';
    5='tech.precision_engineering'; 6='tech.steam_power'; 7='tech.electrification';
    8='tech.advanced_metallurgy'; 9='tech.networked_computing'; 10='tech.autonomous_systems'
}
$methodEnablerByRank = @{
    1='bronze_tools'; 2='bronze_tools'; 3='bronze_tools'; 4='tools'; 5='tools'; 6='steam_engines';
    7='electricity'; 8='electric_motor'; 9='computers'; 10='autonomous_systems'
}
$methodTechnologyOverrides = @{
    method_lumber_plant_r6='tech.steam_sawmilling'
}
$methodPrefixByRank = @{
    1='青铜改良'; 2='古典改良'; 3='行会化'; 4='商贸化'; 5='科学化'; 6='蒸汽化';
    7='电气化'; 8='先进化'; 9='数字化'; 10='智能化'
}
$methodEnablersBySource = @{
    landed_estate=@('agricultural_machinery'); potato_collector=@('agricultural_machinery')
    cotton_collector=@('agricultural_machinery'); rubber_tree_collector=@('agricultural_machinery')
    spice_plants_collector=@('agricultural_machinery')
    medicinal_herbs_collector=@('fertilizer','electricity')
    edible_oil_plant=@('industrial_machinery'); soap_plant=@('industrial_machinery')
    bricks_plant=@('industrial_machinery'); lime_plant=@('industrial_machinery')
    limestone_collector=@('industrial_machinery')
}
$methodNameOverrides = @{
    method_gathering_ground_r1='定居采集营地'; method_flint_quarry_r1='改良燧石矿坑'
    method_stone_age_hunting_camp_r4='商业狩猎与毛皮站'; method_pottery_kiln_r3='行会陶窑'
    method_landed_estate_r6='机械化玉米农场'; method_potato_collector_r6='机械化马铃薯农场'
    method_cotton_collector_r6='机械化棉花农场'; method_rubber_tree_collector_r6='机械化橡胶种植园'
    method_spice_plants_collector_r6='机械化香料种植园'
    method_medicinal_herbs_collector_r7='受控环境药材农场'
    method_edible_oil_plant_r6='工业榨油厂'; method_soap_plant_r6='工业制皂厂'
    method_packaging_plant_r7='电气化包装厂'; method_printed_materials_plant_r7='电气印刷厂'
    method_oceanic_shipyard_r7='电气化造船厂'; method_bricks_plant_r6='工业砖厂'
    method_lime_plant_r6='工业石灰厂'; method_limestone_collector_r6='工业石灰岩矿场'
    method_lumber_plant_r2='改良锯木场'; method_lumber_plant_r4='水力锯木场'
    method_lumber_plant_r6='蒸汽锯木厂'
    method_timber_collector_r2='组织化伐木场'; method_timber_collector_r4='商营伐木场'
    method_stone_collector_r2='石料场'; method_stone_collector_r4='规模化采石场'
    method_marine_fish_collector_r2='帆船渔场'; method_marine_fish_collector_r4='远洋渔场'
    method_wheat_farm_r3='佃作小麦庄园'; method_wheat_farm_r5='改良轮作小麦庄园'
    method_rice_collector_r3='佃作稻庄'; method_rice_collector_r5='精耕稻庄'
    method_flax_collector_r3='亚麻庄园'; method_flax_collector_r5='改良亚麻庄园'
    method_wool_shed_r3='羊毛行会作坊'; method_wool_shed_r5='精梳羊毛作坊'
    method_bauxite_collector_r9='自动化铝土矿'; method_lead_ore_collector_r9='自动化铅矿'
    method_manganese_ore_collector_r10='智能锰矿'; method_natural_gas_collector_r10='智能天然气田'
    method_phosphate_rock_collector_r9='自动化磷矿'; method_rare_earth_collector_r10='智能战略矿山'
    method_saltpeter_collector_r8='现代硝石矿'; method_saltpeter_collector_r10='智能硝石矿'
    method_sulfur_collector_r8='现代硫矿'; method_sulfur_collector_r10='智能硫矿'
    method_zinc_ore_collector_r9='自动化锌矿'
    method_coke_ovens_r9='自动化焦化厂'; method_cement_plant_r9='自动化水泥厂'
    method_concrete_plant_r9='自动化混凝土厂'; method_lubricants_plant_r9='自动化润滑油厂'
    method_machine_parts_plant_r9='自动化机械零件厂'; method_lead_plant_r9='自动化炼铅厂'
    method_zinc_plant_r9='自动化炼锌厂'; method_steam_engine_works_r9='自动化蒸汽机厂'
    method_explosives_plant_r8='现代炸药厂'; method_explosives_plant_r10='自动化炸药厂'
    method_precision_tool_workshop_r8='精密工具厂'; method_precision_tool_workshop_r10='智能工具厂'
    method_scientific_instrument_works_r8='精密仪器厂'; method_scientific_instrument_works_r10='智能仪器厂'
    method_aluminum_plant_r10='智能冶铝厂'; method_petrochemicals_plant_r10='智能石油化工厂'
    method_refined_fuel_plant_r10='智能炼油厂'; method_rare_earth_metals_plant_r10='智能战略金属冶炼厂'
}

function Add-Production-Method([string]$SourceId, [int]$TargetRank) {
    $sourcePath = Join-Path $buildingsDir "$SourceId.tres"
    $content = [System.IO.File]::ReadAllText($sourcePath)
    $name = Content-Scalar-String $content 'display_name'
    $kind = Content-Scalar-String $content 'building_kind'
    $owner = Content-Scalar-String $content 'owner_profession_id'
    $inputs = @(Content-Strings $content 'input_good_ids')
    [long[]]$inputQuantities = @(Content-Numbers $content 'input_quantities_per_day')
    $outputs = @(Content-Strings $content 'output_good_ids')
    $resources = @(Content-Strings $content 'resource_ids')
    $resourceModes = @(Content-Strings $content 'resource_interaction_modes')
    $behavior = Content-Scalar-String $content 'behavior_id'
    if ($outputs.Count -eq 0) { throw "method source lacks output: $SourceId" }
    $category = Industry-For-Good $outputs[0]
    $enablers = if ($SourceId -eq 'lumber_plant' -and $TargetRank -eq 6) {
        @('steam_engines','coal')
    } elseif ($methodEnablersBySource.ContainsKey($SourceId)) {
        @($methodEnablersBySource[$SourceId])
    } else { @($methodEnablerByRank[$TargetRank]) }
    $toolGoods = @('chipped_stone_tools','bronze_tools','tools','precision_tools')
    foreach ($enabler in $enablers) {
        if ($enabler -in $toolGoods) {
            $existingToolIndexes = @(for ($i = 0; $i -lt $inputs.Count; $i++) {
                if ($inputs[$i] -in $toolGoods) { $i }
            })
            if ($existingToolIndexes.Count -gt 0) {
                $firstToolIndex = [int]$existingToolIndexes[0]
                $normalizedInputs = @(); [long[]]$normalizedQuantities = @()
                for ($i = 0; $i -lt $inputs.Count; $i++) {
                    if ($i -eq $firstToolIndex) {
                        $normalizedInputs += 'tools'; $normalizedQuantities += [long]$inputQuantities[$i]
                    } elseif ($i -notin $existingToolIndexes) {
                        $normalizedInputs += $inputs[$i]; $normalizedQuantities += [long]$inputQuantities[$i]
                    }
                }
                $inputs = $normalizedInputs; $inputQuantities = $normalizedQuantities
            } else {
                $inputs += 'tools'; $inputQuantities += [long]500
            }
        } elseif ($enabler -notin $inputs) {
            $inputs += $enabler; $inputQuantities += [long]500
        }
    }
    $worker = if ($kind -eq 'collector') {
        Worker-For-Method $kind $category $resources
    } else {
        Worker-For-Output $outputs[0] $category
    }
    if ($SourceId -eq 'gathering_ground') { $worker = 'forager' }
    $methodId = "method_${SourceId}_r${TargetRank}"
    if ($methodId -eq 'method_lumber_plant_r6') { $worker = 'machinist' }
    $methodName = if ($methodNameOverrides.ContainsKey($methodId)) {
        $methodNameOverrides[$methodId]
    } else { "$($methodPrefixByRank[$TargetRank])$name" }
    $methodTechnology = if ($methodTechnologyOverrides.ContainsKey($methodId)) {
        $methodTechnologyOverrides[$methodId]
    } else { $methodTechnologyByRank[$TargetRank] }
    Add-Building $methodId $methodName $kind $owner $worker $inputs $outputs $resources $resourceModes `
        $behavior $category '' 0 $methodTechnology $inputQuantities $SourceId
}

Sync-CuratedDirectory (Join-Path $curatedContentDir 'goods') $goodsDir
Sync-CuratedDirectory (Join-Path $curatedContentDir 'buildings') $buildingsDir

# Resource geography remains hand-authored.  Only the technology discovery
# contract is synchronized from the authoritative technology network.
foreach ($profile in Get-ChildItem -LiteralPath $resourcesDir -Filter '*.tres' -File) {
    [void]$managedPaths.Add([System.IO.Path]::GetFullPath($profile.FullName))
    $content = [System.IO.File]::ReadAllText($profile.FullName)
    $resourceId = Content-Scalar-String $content 'id'
    if (-not $resourceDiscoveryTechnologyById.ContainsKey($resourceId)) { continue }
    $technologyTags = @($resourceDiscoveryTechnologyById[$resourceId])
    $expectedLine = 'discovery_technology_tags = ' + (PSArray $technologyTags)
    if ([regex]::IsMatch($content,
        '(?m)^discovery_technology_tags = PackedStringArray\(.*\)\r?$')) {
        $content = [regex]::Replace($content,
            '(?m)^discovery_technology_tags = PackedStringArray\(.*\)\r?$',
            $expectedLine)
    } else {
        $content = [regex]::Replace($content, '(?m)^(id = &"[^"]+"\r?)$',
            "`$1`n$expectedLine")
    }
    Write-Utf8 $profile.FullName $content
}

# Curated profiles share the same explicit sector contract as generated
# profiles.  Normalize missing legacy fields after copying templates so the
# economy catalog never has to infer a sector from a building name.
foreach ($profile in Get-ChildItem -LiteralPath $buildingsDir -Filter '*.tres' -File) {
    $content = [System.IO.File]::ReadAllText($profile.FullName)
    if ([regex]::IsMatch($content, '(?m)^economic_sector_id = "[^"]+"\r?$')) { continue }
    $kind = Content-Scalar-String $content 'building_kind'
    $resources = @(Content-Strings $content 'resource_ids')
    $outputs = @(Content-Strings $content 'output_good_ids')
    $agriculturalResources = @('arable_land','paddy_land','plantation_land','pasture','fertile_soil')
    $sector = if ($kind -eq 'collector' -and
        @($resources | Where-Object { $_ -in $agriculturalResources }).Count -gt 0) {
        'agriculture'
    } elseif ($kind -eq 'collector') {
        'extractive'
    } elseif ($outputs -contains 'electricity') {
        'energy'
    } elseif ($outputs -contains 'technology_points' -or $kind -eq 'service') {
        'knowledge'
    } else {
        'manufacturing'
    }
    $content = [regex]::Replace($content, '(?m)^(building_kind = "[^"]+"\r?)$',
        "`$1`neconomic_sector_id = `"$sector`"")
    Write-Utf8 $profile.FullName $content
}

# Every pre-Information single-route good must declare a lifecycle. Persistent
# macro sectors use the normal cross-era schedule; bounded sectors name their
# exact final methods. Unclassified content fails instead of silently acquiring
# digital or autonomous pseudo-industries.
$baseBuildingIds = [System.Collections.Generic.List[string]]::new()
foreach ($id in @($buildingIds | Sort-Object)) { $baseBuildingIds.Add($id) }
foreach ($template in Get-ChildItem -LiteralPath (Join-Path $curatedContentDir 'buildings') -Filter '*.tres' -File | Sort-Object Name) {
    if (-not $buildingIds.Add($template.BaseName)) { throw "generated/curated building collision: $($template.BaseName)" }
    $baseBuildingIds.Add($template.BaseName)
}
$baseProducers = @{}
$baseProfiles = @{}
foreach ($id in $baseBuildingIds) {
    $content = [System.IO.File]::ReadAllText((Join-Path $buildingsDir "$id.tres"))
    $baseProfiles[$id] = $content
    foreach ($output in @(Content-Strings $content 'output_good_ids')) {
        if (-not $baseProducers.ContainsKey($output)) { $baseProducers[$output] = [System.Collections.Generic.List[string]]::new() }
        $baseProducers[$output].Add($id)
    }
}
$singleMethodSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($goodId in @($baseProducers.Keys | Sort-Object)) {
    if ($baseProducers[$goodId].Count -eq 1 -and (Good-Rank-From-File $goodId) -lt 9) {
        [void]$singleMethodSources.Add($baseProducers[$goodId][0])
    }
}
$boundedMethodTargets = @{
    knapping_workshop=@(); freshwater_fishing_camp=@(); placer_gold_working=@(); surface_silver_working=@(); gold_mine=@(); silver_mine=@(); gathering_ground=@(1); flint_quarry=@(1); stone_age_hunting_camp=@(4); pottery_kiln=@(3)
    landed_estate=@(6); potato_collector=@(6); cotton_collector=@(6); rubber_tree_collector=@(6)
    spice_plants_collector=@(6); medicinal_herbs_collector=@(7)
    edible_oil_plant=@(6); soap_plant=@(6); packaging_plant=@(7); printed_materials_plant=@(7)
    oceanic_shipyard=@(7); bricks_plant=@(6); lime_plant=@(6); limestone_collector=@(6)
    lumber_plant=@(2,4,6)
}
$persistentMethodSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($sourceId in @(
    'agricultural_machinery_plant','aluminum_plant','automobiles_plant','batteries_plant',
    'bauxite_collector','cement_plant','coke_ovens','concrete_plant','detergent_plant',
    'electric_motor_plant','electronic_components_plant','engines_plant','explosives_plant',
    'flax_collector','household_appliances_plant','industrial_machinery_plant',
    'insulated_cable_plant','lead_ore_collector','lead_plant','lubricants_plant','lumber_plant',
    'machine_parts_plant','manganese_ore_collector','marine_fish_collector',
    'natural_gas_collector','nuclear_fuel_plant','petrochemicals_plant','processed_food_plant',
    'phosphate_rock_collector','plastics_plant','precision_tool_workshop','radio_equipment_works',
    'rare_earth_collector','rare_earth_metals_plant','reactor_component_works',
    'refined_fuel_plant','rice_collector','saltpeter_collector','scientific_instrument_works',
    'stainless_steel_plant','steam_engine_works','stone_collector','sulfur_collector',
    'synthetic_fiber_plant','synthetic_rubber_plant','timber_collector','wheat_farm','wire_plant',
    'wool_shed','zinc_ore_collector','zinc_plant'
)) { [void]$persistentMethodSources.Add($sourceId) }
# Freshwater fishing is a separate local-resource route, but it must not retire
# the established marine fishing technology progression merely because fish now
# has more than one producer family.
[void]$singleMethodSources.Add('marine_fish_collector')
foreach ($sourceId in @($singleMethodSources | Sort-Object)) {
    $sourceRank = Rank-From-Profile-Content $baseProfiles[$sourceId]
    $targets = if ($boundedMethodTargets.ContainsKey($sourceId)) {
        @($boundedMethodTargets[$sourceId])
    } elseif ($persistentMethodSources.Contains($sourceId)) {
        @(switch ($sourceRank) {
            0 { 2; 4 }
            1 { 3; 5 }
            2 { 4; 5; 8 }
            3 { 5; 8; 9 }
            4 { 7; 8; 9 }
            5 { 8; 10 }
            6 { 9 }
            7 { 10 }
            8 { 10 }
            9 { 10 }
            default { throw "unsupported persistent source rank: $sourceId -> $sourceRank" }
        })
    } else {
        throw "single-method source lacks lifecycle classification: $sourceId"
    }
    foreach ($targetRank in $targets) { Add-Production-Method $sourceId $targetRank }
}
