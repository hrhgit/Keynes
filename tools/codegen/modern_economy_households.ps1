$professionRows = @(
    @('landlord','地主','owner_household','tech.bronze_casting'),
    @('merchant','商人','merchant_household','tech.gathering'),
    @('subsistence_farmer','自给农民','survival_household','tech.pottery'),
    @('worker','工人','industrial_worker_household','tech.steam_power'),
    @('industrialist','工业资本家','owner_household','tech.steam_power'),
    @('agricultural_worker','农业工人','agrarian_household','tech.pottery'),
    @('pastoralist','牧民','agrarian_household','tech.pottery'),
    @('hunter','猎人','hunter_household','tech.hunting'),
    @('fisher','渔民','agrarian_household','tech.hunting'),
    @('forestry_worker','林业工人','agrarian_household','tech.gathering'),
    @('miner','矿工','extractive_household','tech.gathering'),
    @('petroleum_worker','石油工人','extractive_household','tech.steam_power'),
    @('construction_worker','建筑工人','industrial_worker_household','tech.masonry'),
    @('artisan','工匠','artisan_household','tech.gathering'),
    @('industrial_worker','产业工人','industrial_worker_household','tech.steam_power'),
    @('machinist','机械师','technical_household','tech.precision_engineering'),
    @('technician','技术员','technical_household','tech.electrification'),
    @('engineer','工程师','technical_household','tech.precision_engineering'),
    @('chemist','化学家','technical_household','tech.experimental_science'),
    @('metallurgist','冶金师','artisan_household','tech.bronze_casting'),
    @('electrician','电工','technical_household','tech.electrification'),
    @('transport_worker','运输工人','industrial_worker_household','tech.oceanic_navigation'),
    @('guild_master','行会师傅','artisan_household','tech.guild_organization'),
    @('forager','采集者','survival_household','tech.gathering'),
    @('enslaved_laborer','奴隶劳工','survival_household','tech.bronze_casting'),
    @('serf','农奴','survival_household','tech.manuscript_culture'),
    @('tenant_farmer','佃农','agrarian_household','tech.guild_organization'),
    @('indentured_laborer','契约劳工','agrarian_household','tech.oceanic_navigation'),
    @('apprentice','学徒','survival_household','tech.pottery'),
    @('journeyman','熟练工','artisan_household','tech.writing'),
    @('manager','经理','technical_household','tech.steam_power'),
    @('researcher','研究员','technical_household','tech.experimental_science'),
    @('unemployed','失业者','plan_unemployed','')
)
if ($professionRows.Count -ne 33) { throw 'profession catalog baseline must be 33' }
foreach ($row in $professionRows) {
    $professionPath = Join-Path $professionsDir "$($row[0]).tres"
    # Profession profiles carry behavior semantic tags and satisfaction
    # weights consumed by FamilyRuntime.  They are authoritative resources,
    # not disposable rows in the economy content generator.
    if (Test-Path -LiteralPath $professionPath) {
        [void]$managedPaths.Add([System.IO.Path]::GetFullPath($professionPath))
        continue
    }
    Write-Utf8 $professionPath @"
[gd_resource type="Resource" script_class="ProfessionProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/profession_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$($row[0])"
display_name = "$($row[1])"
default_consumption_plan_id = &"$($row[2])"
technology_tags = PackedStringArray()
"@
}

$needRows = @(
    @('staple_food','食品',65536), @('protein','食品',65536),
    @('produce','食品',65536), @('food_fat','食用油脂',65536),
    @('seasoning','调味品',32768), @('clothing','衣着',65536),
    @('housing','居住维护',65536), @('household_goods','家庭用品',32768),
    @('domestic_wares','家用器皿',32768),
    @('hygiene','清洁卫生',65536), @('healthcare','医疗保健',65536),
    @('home_energy','家庭能源',65536), @('transport','个人交通',32768),
    @('communication','通信',32768), @('education_culture','教育与文化',0),
    @('recreation','休闲娱乐',0), @('durable_goods','耐用消费品',0),
    @('work_equipment','职业装备',32768), @('luxury','奢侈消费',0),
    @('status_goods','身份消费',0)
)
foreach ($row in $needRows) {
    Write-Utf8 (Join-Path $needsDir "$($row[0]).tres") @"
[gd_resource type="Resource" script_class="NeedProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/need_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$($row[0])"
display_name = "$($row[1])"
living_cost_weight_q16 = $($row[2])
"@
}

$needSpecs = @(
    @{id='staple_food'; tier='essential'; base=550; wealth=4096; min=49152; max=81920; price=98304; quantityPrice=16384; quantityFloor=32768;
        variants=@(@('prepared_staples'),@('bread'),@('grain'),@('wheat_grain'),
            @('rice_grain'),@('corn_grain'),@('potatoes'),@('gathered_plants'))},
    @{id='protein'; tier='essential'; base=180; wealth=16384; min=32768; max=163840; price=98304; quantityPrice=98304; quantityFloor=9830;
        variants=@(@('game_meat'),@('meat'),@('fish'),@('canned_fish'),@('dairy_products'))},
    @{id='produce'; tier='essential'; base=300; wealth=16384; min=32768; max=163840; price=98304; quantityPrice=65536; quantityFloor=4096;
        variants=@(@('vegetables'),@('processed_food'))},
    @{id='food_fat'; tier='essential'; base=35; wealth=14746; min=32768; max=163840; price=98304; quantityPrice=49152; quantityFloor=8192;
        variants=@(@('edible_oil'))},
    @{id='seasoning'; tier='essential'; base=8; wealth=19661; min=16384; max=196608; price=98304; quantityPrice=65536; quantityFloor=4096;
        variants=@(@('salt'),@('spices'))},
    @{id='clothing'; tier='essential'; base=16; wealth=29491; min=16384; max=393216; price=65536; quantityPrice=32768; quantityFloor=16384;
        variants=@(@('cloth'),@('fur'),@('clothing'),@('footwear'))},
    @{id='housing'; tier='essential'; base=24; wealth=29491; min=16384; max=393216; price=65536;
        variants=@(@('reed_bundle','bast_fiber'),@('turf_block','lumber'),
            @('adobe_brick','lumber'),@('raw_stone','lime','lumber'),
            @('bricks','lime','lumber'),@('cement','glass','steel'),
            @('concrete','steel','glass'),@('construction_components'))},
    @{id='household_goods'; tier='comfort'; base=12; wealth=36045; min=8192; max=655360; price=49152;
        variants=@(@('furniture'),@('leather_goods'))},
    @{id='domestic_wares'; tier='comfort'; base=10; wealth=36045; min=8192; max=655360; price=49152;
        variants=@(@('pottery'),@('glassware'),@('metal_housewares'))},
    @{id='hygiene'; tier='essential'; base=26; wealth=29491; min=16384; max=393216; price=65536;
        variants=@(@('soap'),@('detergent'))},
    @{id='healthcare'; tier='essential'; base=12; wealth=29491; min=16384; max=393216; price=32768;
        variants=@(@('medicinal_herbs'),@('pharmaceuticals'))},
    @{id='home_energy'; tier='essential'; base=180; wealth=29491; min=16384; max=393216; price=65536;
        variants=@(@('logs'),@('charcoal'),@('coal'),@('natural_gas'),@('refined_fuel'),@('electricity'))},
    @{id='transport'; tier='comfort'; base=10; wealth=39322; min=8192; max=786432; price=49152;
        variants=@(@('horses'),@('automobiles','refined_fuel'))},
    @{id='communication'; tier='comfort'; base=6; wealth=42598; min=8192; max=1048576; price=49152;
        variants=@(@('radio_equipment'),@('telecom_equipment'),
            @('radio_equipment','batteries'),
            @('telecom_equipment','batteries'))},
    @{id='education_culture'; tier='comfort'; base=10; wealth=42598; min=8192; max=1048576; price=49152;
        variants=@(@('manuscripts'),@('paper'),@('printed_materials'),@('computers'))},
    @{id='recreation'; tier='comfort'; base=14; wealth=39322; min=8192; max=786432; price=49152;
        variants=@(@('beverages'),@('computers'))},
    @{id='durable_goods'; tier='luxury'; base=6; wealth=49152; min=4096; max=1048576; price=32768;
        variants=@(@('household_appliances'),@('autonomous_systems'))},
    @{id='work_equipment'; tier='comfort'; base=10; wealth=36045; min=8192; max=655360; price=49152;
        variants=@(@('chipped_stone_tools'),@('bronze_tools'),@('tools'),@('precision_tools'))},
    @{id='luxury'; tier='luxury'; base=8; wealth=55706; min=1024; max=2097152; price=32768;
        variants=@(@('beverages'),@('fine_clothing'),@('fine_furniture'))},
    @{id='status_goods'; tier='luxury'; base=6; wealth=55706; min=1024; max=2097152; price=32768;
        variants=@(@('jewelry'),@('fur'))}
)

function Class-Wealth-Delta([string]$PlanId, [string]$GoodId) {
    $base = switch ($PlanId) {
        'plan_unemployed' { -8192 }
        'survival_household' { -4096 }
        'agrarian_household' { 0 }
        'hunter_household' { 0 }
        'extractive_household' { 4096 }
        'industrial_worker_household' { 4096 }
        'artisan_household' { 8192 }
        'scholarly_household' { 8192 }
        'technical_household' { 12288 }
        'merchant_household' { 16384 }
        'owner_household' { 24576 }
        default { 0 }
    }
    if ($GoodId -in @('gathered_plants','game_meat','cloth','logs','chipped_stone_tools')) {
        $base -= 8192
    }
    return [Math]::Max(-65536, [Math]::Min(131072, $base))
}

function Class-Threshold-Factor([string]$PlanId, [string]$GoodId) {
    if ((Household-Savings-Threshold-For-Good $GoodId) -eq 0) { return 0 }
    $factor = switch ($PlanId) {
        'plan_unemployed' { 131072 }
        'survival_household' { 98304 }
        'agrarian_household' { 81920 }
        'hunter_household' { 81920 }
        'extractive_household' { 65536 }
        'industrial_worker_household' { 65536 }
        'artisan_household' { 57344 }
        'scholarly_household' { 49152 }
        'technical_household' { 40960 }
        'merchant_household' { 32768 }
        'owner_household' { 24576 }
        default { 65536 }
    }
    return $factor
}

function Write-Plan([string]$Id, [string]$Name, [string[]]$IncludedNeeds,
        [int]$EssentialScale, [int]$ComfortScale, [int]$LuxuryScale,
        [hashtable]$PreferenceOverrides) {
    $needIds = @(); $priorities = @(); $base = @(); $elasticity = @(); $mins = @(); $maxs = @(); $quantityPrice = @(); $quantityFloor = @(); $env = @()
    $needOffsets = @(0); $variantIds = @(); $preferences = @(); $variantElasticity = @(); $variantEnv = @()
    $variantClassWealthDelta = @(); $variantClassThresholdFactor = @()
    $componentOffsets = @(0); $componentIds = @(); $componentQty = @()
    $v = 0; $c = 0
    foreach ($needId in $IncludedNeeds) {
        $spec = $needSpecs | Where-Object { $_.id -eq $needId } | Select-Object -First 1
        if ($null -eq $spec) { throw "unknown need in plan ${Id}: $needId" }
        $n = $needIds.Count; $needIds += $spec.id; $priorities += $n
        $scale = switch ($spec.tier) {
            'essential' { $EssentialScale }
            'comfort' { $ComfortScale }
            'luxury' { $LuxuryScale }
            default { throw "unknown need tier in plan ${Id}: $($spec.tier)" }
        }
        $scaledBase = [int][Math]::Floor(([int64]$spec.base * $scale + 50) / 100.0)
        $base += [Math]::Max(1, $scaledBase)
        $elasticity += [int]$spec.wealth
        $mins += [int]$spec.min
        $maxs += [int]$spec.max
        $quantityPrice += $(if ($spec.ContainsKey('quantityPrice')) { [int]$spec.quantityPrice } elseif ($spec.tier -eq 'comfort') { 98304 } elseif ($spec.tier -eq 'luxury') { 131072 } else { 65536 })
        $quantityFloor += $(if ($spec.ContainsKey('quantityFloor')) { [int]$spec.quantityFloor } elseif ($spec.tier -eq 'essential') { 4096 } else { 0 })
        $env += $(if ($spec.id -eq 'clothing') { 'cold_clothing_quantity' } else { '' })
        foreach ($variant in $spec.variants) {
            $variantIds += "$($spec.id)_$v"
            $preferenceGood = [string]$variant[0]
            $preferences += $(if ($spec.id -eq 'staple_food') {
                if ($preferenceGood -in @('prepared_staples','bread')) { 131072 }
                elseif ($preferenceGood -in @('grain','wheat_grain','rice_grain',
                        'corn_grain','potatoes')) { 98304 }
                else { 65536 }
            } elseif ($spec.id -eq 'seasoning') {
                if ($preferenceGood -eq 'salt') { 98304 } else { 65536 }
            } elseif ($spec.id -eq 'domestic_wares') {
                switch ($preferenceGood) {
                    'pottery' { 65536 }
                    'glassware' { 73728 }
                    'metal_housewares' { 81920 }
                    default { 65536 }
                }
            } elseif ($spec.id -eq 'home_energy') {
                switch ($preferenceGood) {
                    'logs' { 65536 }
                    'charcoal' { 81920 }
                    'coal' { 81920 }
                    'natural_gas' { 98304 }
                    'refined_fuel' { 90112 }
                    'electricity' { 131072 }
                    default { 65536 }
                }
            } elseif ($PreferenceOverrides.ContainsKey($preferenceGood)) {
                [int]$PreferenceOverrides[$preferenceGood]
            } else { 65536 })
            $variantElasticity += [int]$spec.price
            $variantClassWealthDelta += [int](Class-Wealth-Delta $Id $preferenceGood)
            $variantClassThresholdFactor += [int](Class-Threshold-Factor $Id $preferenceGood)
            $variantEnv += $(if ($spec.id -eq 'clothing' -and $variant -contains 'fur') { 'cold_fur_preference' } elseif ($spec.id -eq 'clothing') { 'warm_cloth_preference' } else { '' })
            foreach ($good in $variant) {
                $componentIds += $good
                $componentQty += $(if ($spec.id -eq 'staple_food') {
                    if ($good -in @('prepared_staples','bread')) { 650 }
                    elseif ($good -in @('grain','wheat_grain','rice_grain',
                            'corn_grain','potatoes')) { 800 }
                    else { 1000 }
                } elseif ($spec.id -eq 'seasoning' -and $good -eq 'spices') { 250
                } elseif ($spec.id -eq 'domestic_wares' -and $good -eq 'glassware') { 800
                } elseif ($spec.id -eq 'domestic_wares' -and $good -eq 'metal_housewares') { 700
                } elseif ($spec.id -eq 'home_energy') {
                    switch ($good) {
                        'logs' { 1000 }
                        'charcoal' { 800 }
                        'coal' { 700 }
                        'natural_gas' { 500 }
                        'refined_fuel' { 500 }
                        'electricity' { 300 }
                        default { 1000 }
                    }
                } elseif ($spec.id -eq 'housing') {
                    switch ($good) {
                        'reed_bundle' { 700 }
                        'bast_fiber' { 300 }
                        'turf_block' { 700 }
                        'adobe_brick' { 800 }
                        'raw_stone' { 700 }
                        'bricks' { 700 }
                        'cement' { 500 }
                        'concrete' { 600 }
                        'lime' { 200 }
                        'lumber' {
                            if ($variant -contains 'turf_block') { 300 }
                            elseif ($variant -contains 'adobe_brick') { 200 }
                            else { 100 }
                        }
                        'steel' { 250 }
                        'glass' { if ($variant -contains 'cement') { 250 } else { 150 } }
                        default { 1000 }
                    }
                } else { 1000 })
                $c++
            }
            if ($Id -eq 'technical_household' -and $spec.id -eq 'education_culture') {
                # Technical households buy a knowledge point alongside every
                # education variant; keep the authored 100-unit service scale.
                $componentIds += 'technology_points'; $componentQty += 100; $c++
            }
            $componentOffsets += $c; $v++
        }
        $needOffsets += $v
    }
    if ($componentIds.Count -gt 128) { throw "plan component limit: $Id" }
    Write-Utf8 (Join-Path $plansDir "$Id.tres") @"
[gd_resource type="Resource" script_class="ConsumptionPlanProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/consumption_plan_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$Id"
display_name = "$Name"
need_ids = $(PSArray $needIds)
priorities = $(PI32 $priorities)
base_qty_per_person = $(PI64 $base)
wealth_elasticity_q16 = $(PI32 $elasticity)
wealth_min_q16 = $(PI32 $mins)
wealth_max_q16 = $(PI32 $maxs)
price_quantity_elasticity_q16 = $(PI32 $quantityPrice)
price_quantity_floor_q16 = $(PI32 $quantityFloor)
quantity_env_curve_ids = $(PSArray $env)
need_variant_offsets = $(PI32 $needOffsets)
variant_ids = $(PSArray $variantIds)
variant_preference_q16 = $(PI32 $preferences)
variant_price_elasticity_q16 = $(PI32 $variantElasticity)
variant_class_wealth_elasticity_delta_q16 = $(PI32 $variantClassWealthDelta)
variant_class_savings_threshold_factor_q16 = $(PI32 $variantClassThresholdFactor)
variant_preference_env_curve_ids = $(PSArray $variantEnv)
variant_component_offsets = $(PI32 $componentOffsets)
component_good_ids = $(PSArray $componentIds)
component_qty_per_need = $(PI64 $componentQty)
"@
}
$survivalFoodNeeds = @('staple_food','protein','produce','food_fat','seasoning')
$coreNeeds = $survivalFoodNeeds + @('clothing','housing','household_goods','domestic_wares',
    'hygiene','healthcare','home_energy')
Write-Plan 'plan_unemployed' '失业者生存消费' $survivalFoodNeeds 80 0 0 @{
    grain=81920; gathered_plants=98304; potatoes=81920
}
Write-Plan 'survival_household' '生存型家庭消费' $coreNeeds 80 35 0 @{
    gathered_plants=98304; grain=81920; potatoes=81920; cloth=81920; fur=73728; logs=98304; medicinal_herbs=81920
}
Write-Plan 'agrarian_household' '农业型家庭消费' `
    ($coreNeeds + @('transport','work_equipment','recreation')) 95 75 0 @{
    prepared_staples=81920; tools=98304; horses=81920; pottery=73728; vegetables=81920
}
Write-Plan 'hunter_household' '狩猎家庭消费' `
    ($coreNeeds + @('work_equipment')) 85 40 0 @{
    gathered_plants=81920; game_meat=98304; fur=81920; logs=81920
    chipped_stone_tools=81920; medicinal_herbs=81920
}
Write-Plan 'extractive_household' '采掘型家庭消费' `
    ($coreNeeds + @('transport','work_equipment')) 105 85 0 @{
    meat=81920; coal=81920; refined_fuel=81920; precision_tools=81920; tools=73728
}
Write-Plan 'industrial_worker_household' '产业工人家庭消费' `
    ($coreNeeds + @('transport','work_equipment')) 100 85 0 @{
    bread=81920; clothing=81920; automobiles=81920; tools=81920
}
Write-Plan 'artisan_household' '工匠型家庭消费' `
    ($coreNeeds + @('education_culture','work_equipment','luxury')) 105 105 80 @{
    clothing=81920; precision_tools=98304; manuscripts=81920; fine_furniture=73728
}
Write-Plan 'scholarly_household' '学术家庭消费' `
    ($coreNeeds + @('education_culture','work_equipment','luxury')) 105 105 80 @{
    clothing=81920; precision_tools=98304; manuscripts=81920; fine_furniture=73728
}
Write-Plan 'technical_household' '技术型家庭消费' `
    ($coreNeeds + @('transport','communication','education_culture','recreation','durable_goods','work_equipment','luxury')) 110 125 120 @{
    precision_tools=81920; computers=98304; telecom_equipment=81920; pharmaceuticals=81920
}
Write-Plan 'merchant_household' '商人家庭消费' `
    ($coreNeeds + @('transport','communication','education_culture','recreation','durable_goods','luxury','status_goods')) 115 150 180 @{
    automobiles=81920; telecom_equipment=81920; beverages=81920; jewelry=98304; spices=81920
}
Write-Plan 'owner_household' '业主家庭消费' `
    ($coreNeeds + @('transport','communication','education_culture','recreation','durable_goods','luxury','status_goods')) 120 175 240 @{
    fine_clothing=98304; fine_furniture=98304; jewelry=98304; fur=81920; automobiles=81920
}
