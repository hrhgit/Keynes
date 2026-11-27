# Source rows: natural deposits and cultivated outputs. Species-level livestock
# and freshwater are intentionally absent; pasture and water systems are broader
# capacity/geography concepts, not per-species economic resources.
$resourceRows = @(
    @('timber','林木','logs'), @('stone','石材','raw_stone'),
    @('fertile_soil','肥沃土壤','vegetables'), @('wheat','小麦','wheat_grain'),
    @('rice','水稻','rice_grain'), @('corn','玉米','corn_grain'),
    @('potato','马铃薯','potatoes'), @('coal','煤炭','coal'),
    @('oil','石油','crude_oil'), @('natural_gas','天然气','natural_gas'),
    @('copper_ore','铜矿','copper_ore'), @('iron_ore','铁矿','iron_ore'),
    @('gold_ore','金矿','gold'), @('silver_ore','银矿','silver'),
    @('salt','盐矿','salt'), @('rubber_tree','橡胶林','latex'),
    @('saltpeter','硝石矿','saltpeter'), @('rare_earth','战略矿产','rare_earth_ore'),
    @('clay','黏土','clay'), @('wild_game','野生动物','game_meat'),
    @('spice_plants','香料作物','spices'), @('flax','亚麻','flax_fiber'),
    @('cotton','棉花','cotton_fiber'), @('medicinal_herbs','药用植物','medicinal_herbs'),
    @('marine_fish','海洋鱼类','fish'), @('bauxite','铝土矿','bauxite'),
    @('limestone','石灰岩','limestone'), @('silica_sand','硅砂','silica_sand'),
    @('phosphate_rock','磷矿石','phosphate_rock'), @('tin_ore','锡矿','tin_ore'),
    @('lead_ore','铅矿','lead_ore'), @('zinc_ore','锌矿','zinc_ore'),
    @('manganese_ore','锰矿','manganese_ore'), @('sulfur','硫磺矿','sulfur')
)
$cultivatedResourceIds = @('wheat','rice','corn','potato','rubber_tree',
    'spice_plants','flax','cotton','medicinal_herbs')
$naturalResourceRows = @($resourceRows | Where-Object { $_[0] -notin $cultivatedResourceIds })
$naturalResourceRows += @(
    @('arable_land','旱地承载力',''), @('paddy_land','水田承载力',''),
    @('plantation_land','种植园承载力',''), @('pasture','牧场承载力','')
)

$processedGroups = [ordered]@{
    forestry = @('lumber','paper','packaging','printed_materials','furniture')
    construction = @('adobe_brick','bricks','lime','cement','concrete','glass','construction_components')
    food = @('grain','bread','prepared_staples','edible_oil','processed_food',
        'livestock_products','meat','dairy_products','canned_fish','beverages')
    textile = @('fur','raw_hide','leather','wool','cloth','synthetic_fiber','clothing',
        'footwear','fine_clothing')
    chemicals = @('refined_fuel','lubricants','petrochemicals','plastics','synthetic_rubber',
        'industrial_chemicals','fertilizer','explosives','soap','detergent','pharmaceuticals','nuclear_fuel')
    metals = @('steel','stainless_steel','copper','aluminum','tin','lead','zinc',
        'rare_earth_metals','wire')
    machinery = @('tools','machine_parts','industrial_machinery','agricultural_machinery',
        'electric_motor','engines','batteries','electrical_equipment','electronic_components',
        'semiconductors','computers','telecom_equipment','household_appliances','automobiles','railway_equipment')
    consumer = @('jewelry','fine_furniture','glassware','metal_housewares',
        'leather_goods')
    energy = @('electricity')
}

$goodNames = @{
    adobe_brick='日晒土坯';
    logs='原木'; raw_stone='原石'; vegetables='蔬菜'; wheat_grain='小麦';
    rice_grain='稻米'; corn_grain='玉米'; potatoes='马铃薯'; coal='煤炭';
    crude_oil='原油'; natural_gas='天然气'; copper_ore='铜矿石'; iron_ore='铁矿石';
    gold='黄金'; silver='白银'; salt='食盐'; latex='天然乳胶'; saltpeter='硝石';
    rare_earth_ore='战略矿石'; clay='黏土'; horses='马匹'; game_meat='野味';
    spices='香料'; flax_fiber='亚麻纤维'; cotton_fiber='棉纤维'; medicinal_herbs='药材';
    fish='鱼类'; bauxite='铝土矿'; limestone='石灰岩'; silica_sand='硅砂';
    phosphate_rock='磷矿石'; tin_ore='锡矿石'; lead_ore='铅矿石'; zinc_ore='锌矿石';
    manganese_ore='锰矿石'; sulfur='硫磺'; lumber='木材';
    paper='纸张'; packaging='包装材料'; printed_materials='印刷品'; furniture='家具';
    bricks='砖块'; lime='石灰'; cement='水泥'; concrete='混凝土';
    glass='玻璃'; construction_components='建筑构件'; grain='混合谷物';
    bread='面包'; prepared_staples='熟制主食';
    edible_oil='食用油'; processed_food='加工食品'; livestock_products='畜牧产品';
    meat='肉类'; dairy_products='乳制品'; canned_fish='鱼罐头'; beverages='酒饮';
    fur='毛皮'; raw_hide='生皮'; leather='皮革'; wool='羊毛'; cloth='布料';
    synthetic_fiber='合成纤维'; clothing='衣物'; fine_clothing='华服';
    footwear='鞋履'; refined_fuel='精炼燃料'; lubricants='润滑剂';
    petrochemicals='石化产品'; plastics='塑料'; synthetic_rubber='合成橡胶';
    industrial_chemicals='工业化学品'; fertilizer='肥料'; explosives='炸药';
    soap='肥皂'; detergent='洗涤剂'; pharmaceuticals='药品'; nuclear_fuel='核燃料';
    steel='钢材'; stainless_steel='不锈钢'; copper='铜';
    aluminum='铝'; tin='锡'; lead='铅'; zinc='锌';
    rare_earth_metals='战略矿物材料'; wire='金属线材'; tools='金属工具'; machine_parts='机器零件';
    industrial_machinery='工业机械'; agricultural_machinery='农业机械';
    electric_motor='电动机'; engines='发动机'; batteries='电池';
    electrical_equipment='电气设备'; electronic_components='电子元件';
    semiconductors='半导体'; computers='计算机'; telecom_equipment='通信设备';
    household_appliances='家用电器'; automobiles='汽车'; railway_equipment='铁路设备';
    jewelry='珠宝'; fine_furniture='精美家具'; glassware='玻璃器皿';
    metal_housewares='金属家用器皿'; leather_goods='皮革制品'; electricity='电力'
}

# Substitution categories describe recipe roles, not industries. A good may
# fulfil several roles; each recipe input slot still opts into one role, an
# explicit weighted candidate list, or one exact good.
$substitutionCategoriesByGood = @{}
function Add-Substitution-Group([string]$CategoryId, [string[]]$GoodIds) {
    foreach ($goodId in $GoodIds) {
        [string[]]$memberships = @()
        if ($substitutionCategoriesByGood.ContainsKey($goodId)) {
            $memberships = [string[]]$substitutionCategoriesByGood[$goodId]
        }
        if ($CategoryId -notin $memberships) {
            $substitutionCategoriesByGood[$goodId] = [string[]]($memberships + @($CategoryId))
        }
    }
}
Add-Substitution-Group 'tools' @('chipped_stone_tools','bronze_tools','tools','precision_tools')
Add-Substitution-Group 'starchy_staple' @('grain','wheat_grain','rice_grain','corn_grain','potatoes')
Add-Substitution-Group 'cereal_grain' @('grain','wheat_grain','rice_grain','corn_grain')
Add-Substitution-Group 'baking_grain' @('grain','wheat_grain','corn_grain')
Add-Substitution-Group 'brewing_feedstock' @('grain','wheat_grain','rice_grain','corn_grain')
Add-Substitution-Group 'spinnable_fiber' @('flax_fiber','cotton_fiber','wool','synthetic_fiber')
Add-Substitution-Group 'natural_spinnable_fiber' @('flax_fiber','cotton_fiber','wool')
Add-Substitution-Group 'guild_textile_fiber' @('flax_fiber','wool')
Add-Substitution-Group 'rag_paper_fiber' @('flax_fiber','cotton_fiber','cloth')
Add-Substitution-Group 'precious_metal' @('gold','silver')
Add-Substitution-Group 'elastomer' @('latex','synthetic_rubber')
Add-Substitution-Group 'prime_mover' @('steam_engines','electric_motor','engines')
Add-Substitution-Group 'industrial_prime_mover' @('steam_engines','electric_motor')
Add-Substitution-Group 'agricultural_prime_mover' @('steam_engines','engines')
Add-Substitution-Group 'ferrous_stock' @('steel','stainless_steel')
Add-Substitution-Group 'structural_metal' @('steel','stainless_steel','aluminum')
Add-Substitution-Group 'processor_component' @('semiconductors','advanced_chips')

function Substitution-Categories-For-Good([string]$GoodId) {
    if ($substitutionCategoriesByGood.ContainsKey($GoodId)) {
        return @($substitutionCategoriesByGood[$GoodId])
    }
    return @($GoodId)
}

function Primary-Substitution-Category-For-Good([string]$GoodId) {
    $categories = @(Substitution-Categories-For-Good $GoodId)
    return $categories[0]
}

function Normalize-CuratedGood([string]$Content, [string]$Id) {
    $categories = @(Substitution-Categories-For-Good $Id)
    $category = $categories[0]
    if (-not [regex]::IsMatch($Content, '(?m)^category_id = &"[^"]+"\r?$')) {
        throw "curated good lacks category_id: $Id"
    }
    $Content = [regex]::Replace($Content, '(?m)^category_id = &"[^"]+"\r?$',
        "category_id = &`"$category`"")
    $membershipLine = 'substitution_category_ids = ' + (PSArray $categories)
    if ([regex]::IsMatch($Content, '(?m)^substitution_category_ids = PackedStringArray\(.*\)\r?$')) {
        $Content = [regex]::Replace($Content,
            '(?m)^substitution_category_ids = PackedStringArray\(.*\)\r?$', $membershipLine)
    } else {
        $Content = [regex]::Replace($Content, '(?m)^(category_id = &"[^"]+"\r?)$',
            "`$1`n$membershipLine")
    }
    if (-not [regex]::IsMatch($Content, '(?m)^household_wealth_elasticity_q16 = ')) {
        $Content = [regex]::Replace($Content, '(?m)^(technology_tags = .*\r?)$',
            "`$1`nhousehold_wealth_elasticity_q16 = $(Household-Wealth-Elasticity-For-Good $Id)`nhousehold_savings_threshold_months_q16 = $(Household-Savings-Threshold-For-Good $Id)")
    }
    return $Content
}

$goods = [ordered]@{}
function Add-Good([string]$Id, [string]$Name, [string]$Category) {
    if ($goods.Contains($Id)) { throw "duplicate good id: $Id" }
    $goods[$Id] = @{ name=$Name; category=$Category }
}
foreach ($row in $resourceRows) {
    if (-not [string]::IsNullOrWhiteSpace([string]$row[2])) {
        Add-Good $row[2] $goodNames[$row[2]] 'primary'
    }
}
Add-Good 'horses' $goodNames['horses'] 'primary'
foreach ($category in $processedGroups.Keys) {
    foreach ($id in $processedGroups[$category]) {
        if (-not $goods.Contains($id)) {
            Add-Good $id $goodNames[$id] $(if ($id -eq 'tools') { 'tools' } else { $category })
        }
    }
}
if ($goods.Count -lt 100) { throw "generated good baseline unexpectedly small: $($goods.Count)" }

$categoryPrice = @{ primary=10000; forestry=18000; construction=22000; food=16000;
    textile=24000; chemicals=30000; metals=36000; machinery=52000; tools=52000;
    consumer=60000; energy=12000 }
function Technology-For-Good([string]$Id) {
    $technologyByGood = @{
        gathered_plants='tech.gathering'; logs='tech.gathering'; lumber='tech.gathering'; salt='tech.gathering'; gold='tech.gathering'; silver='tech.gathering';
        fish='tech.hunting'; game_meat='tech.hunting'; fur='tech.hunting'; raw_hide='tech.hunting';
        cloth='tech.gathering'; tools='tech.masonry'; clay='tech.pottery';
        raw_stone='tech.stone_knapping'; vegetables='tech.pottery'; wheat_grain='tech.pottery';
        grain='tech.pottery'; bread='tech.pottery'; prepared_staples='tech.pottery';
        rice_grain='tech.pottery'; flax_fiber='tech.pottery';
        livestock_products='tech.pottery'; meat='tech.pottery';
        dairy_products='tech.pottery'; wool='tech.pottery'; leather='tech.pottery';
        processed_food='tech.fire_control'; copper_ore='tech.bronze_casting'; copper='tech.bronze_casting';
        tin_ore='tech.bronze_casting'; tin='tech.bronze_casting'; furniture='tech.pottery';
        adobe_brick='tech.adobe_making'; bricks='tech.masonry'; lime='tech.masonry'; cement='tech.steam_power'; concrete='tech.steam_power';
        limestone='tech.masonry'; silica_sand='tech.masonry'; glass='tech.masonry'; construction_components='tech.masonry';
        corn_grain='tech.manuscript_culture'; horses='tech.bronze_casting';
        potatoes='tech.guild_organization'; edible_oil='tech.guild_organization';
        clothing='tech.guild_organization'; footwear='tech.guild_organization';
        spices='tech.oceanic_navigation'; latex='tech.oceanic_navigation'; medicinal_herbs='tech.oceanic_navigation';
        cotton_fiber='tech.oceanic_navigation';
        paper='tech.writing'; packaging='tech.screw_press_printing'; printed_materials='tech.screw_press_printing'; canned_fish='tech.precision_engineering';
        beverages='tech.guild_organization'; coal='tech.coke_smelting'; coke='tech.coke_smelting';
        iron_ore='tech.masonry'; agricultural_machinery='tech.steam_power';
        industrial_chemicals='tech.experimental_science'; steel='tech.steam_power'; wrought_iron='tech.iron_smelting';
        industrial_machinery='tech.precision_engineering'; railway_equipment='tech.steam_power';
        electricity='tech.electrification'; electrical_equipment='tech.electrification';
        electric_motor='tech.electrification'; batteries='tech.electrochemistry';
        aluminum='tech.electrochemistry'; automobiles='tech.electrification';
        engines='tech.electrification'; wire='tech.electrification'; refined_fuel='tech.electrification';
        lubricants='tech.steam_power'; natural_gas='tech.electrification'; crude_oil='tech.steam_power';
        petrochemicals='tech.electrochemistry'; plastics='tech.electrochemistry';
        fertilizer='tech.guild_organization'; detergent='tech.petrochemical_industry';
        household_appliances='tech.electrification'; fine_clothing='tech.guild_organization';
        fine_furniture='tech.guild_organization'; jewelry='tech.bronze_casting';
        electronic_components='tech.radio'; rare_earth_ore='tech.geological_prospecting';
        rare_earth_metals='tech.advanced_metallurgy'; pharmaceuticals='tech.experimental_science';
        nuclear_fuel='tech.nuclear_fission'; semiconductors='tech.digital_computing';
        computers='tech.digital_computing'; telecom_equipment='tech.networked_computing';
        synthetic_fiber='tech.advanced_metallurgy'; synthetic_rubber='tech.advanced_metallurgy';
        stainless_steel='tech.advanced_metallurgy';
        lead_ore='tech.steam_power'; lead='tech.steam_power'; zinc_ore='tech.steam_power';
        zinc='tech.steam_power'; manganese_ore='tech.geological_prospecting';
        bauxite='tech.steam_power'; phosphate_rock='tech.steam_power'; sulfur='tech.experimental_science';
        saltpeter='tech.experimental_science'; explosives='tech.experimental_science';
        soap='tech.guild_organization'; machine_parts='tech.precision_engineering';
        flint='tech.stone_knapping'; chipped_stone_tools='tech.stone_knapping'; bronze_tools='tech.bronze_casting';
        steam_engines='tech.steam_power'; precision_tools='tech.precision_engineering';
        scientific_instruments='tech.experimental_science';
        glassware='tech.application.glassware_workshop_kingdom';
        metal_housewares='tech.application.metal_housewares_workshop_kingdom';
        leather_goods='tech.application.leather_goods_workshop_kingdom';
        advanced_chips='tech.machine_learning'; autonomous_systems='tech.autonomous_systems'
    }
    if ($technologyByGood.ContainsKey($Id)) { return $technologyByGood[$Id] }
    throw "good lacks explicit technology: $Id"
}

function Inventory-Target-Ratio-For-Good([string]$Id) {
    $essential = @('bread','canned_fish','corn_grain','dairy_products','edible_oil','fish',
        'game_meat','grain','livestock_products','meat','potatoes','prepared_staples',
        'processed_food','rice_grain','salt','vegetables','wheat_grain')
    $important = @('clothing','coal','detergent','footwear','medicinal_herbs',
        'natural_gas','pharmaceuticals','refined_fuel','soap')
    $luxury = @('beverages','fine_clothing','fine_furniture','fur','jewelry','spices')
    if ($essential -contains $Id) { return 98304 } # 1.50 x 30 = 45 days.
    if ($important -contains $Id) { return 81920 } # 1.25 x 30 = 37.5 days.
    if ($luxury -contains $Id) { return 43691 } # Approximately 20 days.
    return 65536 # 1.00 x 30 = 30 days.
}

function Household-Wealth-Elasticity-For-Good([string]$Id) {
    if ($Id -in @('gathered_plants','game_meat','cloth','logs','chipped_stone_tools')) { return 0 }
    if ($Id -in @('grain','wheat_grain','rice_grain','corn_grain','potatoes','salt',
            'vegetables','charcoal','coal')) { return 8192 }
    if ($Id -in @('prepared_staples','bread','edible_oil','meat','fish','dairy_products',
            'clothing','footwear','soap','medicinal_herbs','electricity')) { return 16384 }
    if ($Id -in @('processed_food','canned_fish','detergent','pharmaceuticals','natural_gas',
            'refined_fuel','pottery','leather_goods')) { return 24576 }
    if ($Id -in @('glassware','metal_housewares','printed_materials','radio_equipment',
            'telecom_equipment','household_appliances','automobiles')) { return 32768 }
    if ($Id -in @('fine_clothing','fine_furniture','jewelry','spices','autonomous_systems')) { return 65536 }
    return 16384
}

function Household-Savings-Threshold-For-Good([string]$Id) {
    if ($Id -in @('gathered_plants','prepared_staples','bread','grain','wheat_grain',
            'rice_grain','corn_grain','potatoes','game_meat','meat','fish','dairy_products',
            'vegetables','edible_oil','salt','cloth','clothing','footwear','logs','charcoal','coal')) { return 0 }
    if ($Id -in @('processed_food','canned_fish','soap','medicinal_herbs','pottery','electricity')) { return 32768 }
    if ($Id -in @('detergent','pharmaceuticals','natural_gas','refined_fuel','leather_goods',
            'glassware','metal_housewares','printed_materials')) { return 65536 }
    if ($Id -in @('radio_equipment','telecom_equipment','household_appliances')) { return 131072 }
    if ($Id -in @('automobiles','fine_clothing','fine_furniture')) { return 262144 }
    if ($Id -in @('jewelry','spices','autonomous_systems')) { return 524288 }
    return 65536
}

foreach ($id in $goods.Keys) {
    $g = $goods[$id]
    $substitutionCategories = @(Substitution-Categories-For-Good $id)
    $primarySubstitutionCategory = $substitutionCategories[0]
    $substitutionCategoryArray = PSArray $substitutionCategories
    $price = [int]$categoryPrice[$g.category]
    $technology = Technology-For-Good $id
    $demandElasticity = switch ($g.category) {
        'primary' { 29491 } 'food' { 22938 } 'forestry' { 49152 }
        'construction' { 49152 } 'textile' { 58982 } 'chemicals' { 52429 }
        'metals' { 45875 } 'machinery' { 75366 } 'consumer' { 85197 }
        'energy' { 19661 } default { 65536 }
    }
    $inventoryTargetRatio = Inventory-Target-Ratio-For-Good $id
    $priceAdjust = [Math]::Max(512, [int][Math]::Round(2048.0 * $demandElasticity / 65536.0))
    $issue = if ($id -eq 'gold') { 800000 } elseif ($id -eq 'silver') { 50000 } else { 0 }
    $mode = if ($id -eq 'electricity') { 'cycle_flow' } else { 'stock' }
    # Curated profiles are validated by the authoritative sync at the end of
    # this script. Do not first compare them against a generic intermediate
    # profile in -Check mode.
    if (Test-Path -LiteralPath (Join-Path $curatedContentDir "goods/$id.tres")) {
        continue
    }
    Write-Utf8 (Join-Path $goodsDir "$id.tres") @"
[gd_resource type="Resource" script_class="GoodProfile" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/data/good_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"$id"
display_name = "$($g.name)"
category_id = &"$primarySubstitutionCategory"
substitution_category_ids = $substitutionCategoryArray
technology_tags = PackedStringArray("industry.$($g.category)", "$technology")
production_quality_level = $(if ($id -eq 'tools') { 3 } else { 0 })
production_efficiency_q16 = 65536
storage_mode = "$mode"
monetary_issue_value = $issue
default_price = $price
initial_stock = 0
reference_max_price = $($price * 50)
price_adjust_q16 = $priceAdjust
demand_price_elasticity_q16 = $demandElasticity
household_wealth_elasticity_q16 = $(Household-Wealth-Elasticity-For-Good $id)
household_savings_threshold_months_q16 = $(Household-Savings-Threshold-For-Good $id)
demand_ema_alpha_q16 = 16384
inventory_target_ratio_q16 = $(if ($mode -eq 'cycle_flow') { 0 } else { $inventoryTargetRatio })
inventory_weight_q16 = 32768
shortage_weight_q16 = $(if ($mode -eq 'cycle_flow') { 0 } else { 65536 })
excess_demand_weight_q16 = $(if ($mode -eq 'cycle_flow') { 65536 } else { 8192 })
cost_anchor_weight_q16 = $(if ($issue -gt 0) { 0 } else { 16384 })
inactive_reversion_weight_q16 = 8192
business_demand_ema_alpha_q16 = $(if ($mode -eq 'cycle_flow') { 16384 } else { 8192 })
supply_ema_alpha_q16 = $(if ($mode -eq 'cycle_flow') { 16384 } else { 8192 })
cost_ema_alpha_q16 = 4096
max_price_rise_q16 = 8192
max_price_fall_q16 = 4096
merchant_buy_price_factor_q16 = 62259
"@
}
