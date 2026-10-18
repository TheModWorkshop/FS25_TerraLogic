# TerraLogic

TerraLogic brings your soil to life in Farming Simulator 25. Fields remember how you work them: wheel tracks, seedbed preparation, crop rotation and weather shape the conditions for the next operation and the next harvest. A loose but rough ploughed field, a carefully prepared seedbed and a heavily travelled headland no longer behave alike.

Machinery and soil influence one another. Implement type, working depth, speed, condition, tires and changing loads determine what a pass leaves behind. That soil then affects seed placement, pulling resistance, work quality and crop growth. Between operations, roots, soil biology and weather gradually change it further.

The aim is to make different equipment and farming systems useful in different situations. Conventional tillage, reduced tillage and direct drilling each have advantages and trade-offs. Good soil conditions and careful work can produce **up to 10% more yield** than the same field would deliver under otherwise identical conditions without TerraLogic.

## Acknowledgements

Thanks to **astro80** for providing Italian translations!

## At a glance

- Five persistent soil maps: surface compaction, deep compaction, tilth, evenness and resilience.
- Dynamic compaction from vehicle and implement loads, tire footprints, tracks and axle loads.
- Distinct soil effects for ploughs, cultivators, harrows, subsoilers, seeders, rollers and other supported equipment.
- Adjustable working speed for supported, manually driven implements, with consequences for quality, soil, wear and damage.
- Locally recorded fieldwork and visible missed areas where equipment can leave seed, crop or material behind.
- Field-by-field water reserves, influenced by weather, soil type and the crop growing there.
- Soil moisture, temperature and frost that affect fieldwork, natural recovery and crop growth.
- Long-term effects from biological continuity, living roots, cover crops and crop rotation.
- An in-game field analysis menu with a planner, explanations and practical recommendations.
- Contextual tutorials, a browsable tutorial library and detailed in-game help.
- Live topsoil and subsoil compaction indicators, including during transport without a supported working implement.
- Adjustable compaction intensity and precipitation effect to suit your preferred balance.
- Singleplayer and multiplayer support, optional Precision Farming and Moisture System integration, and adjustable soil map update speed.

## Contents

- [Installation](#installation)
- [Your first field](#your-first-field)
- [Controls](#controls)
- [Reading the soil](#reading-the-soil)
- [The field analysis menu](#the-field-analysis-menu)
- [Choosing equipment and preparing a seedbed](#choosing-equipment-and-preparing-a-seedbed)
- [Traffic, tires and tramlines](#traffic-tires-and-tramlines)
- [Working speed, quality and damage](#working-speed-quality-and-damage)
- [Weather and soil conditions](#weather-and-soil-conditions)
- [Resilience, biological continuity and recovery](#resilience-biological-continuity-and-recovery)
- [Understanding yield](#understanding-yield)
- [Tutorials and settings](#tutorials-and-settings)
- [Compatibility and multiplayer](#compatibility-and-multiplayer)
- [Troubleshooting and feedback](#troubleshooting-and-feedback)
- [Copyright](#copyright)

## Installation

1. Download the release ZIP from the [TerraLogic GitHub repository](https://github.com/Saibotsu/FS25_TerraLogic).
2. Place `FS25_TerraLogic.zip` in your Farming Simulator 25 `mods` folder.
3. Enable TerraLogic when creating or loading a savegame.
4. Start with the guided introduction or open **Help → TerraLogic** in the game.

Precision Farming is optional. With it enabled, its soil types influence TerraLogic's moisture response, pulling resistance, compaction and recovery. Without it, TerraLogic uses a balanced generic soil profile and the core simulation remains available.

Use a release ZIP for installation. If you package the source yourself, `modDesc.xml` must be directly at the root of the ZIP.

When updating, replace the previous TerraLogic ZIP rather than keeping multiple copies active. Back up an existing savegame before changing its mod setup.

## Your first field

You do not need to understand every number before starting. Use this simple routine:

1. **Inspect the field.** Stand on it, open the ESC menu and select the TerraLogic icon. Read **Overview**, then check **Weather and Effects**. Is the main problem compaction, a rough seedbed, wet soil or frost?
2. **Find the affected area.** Activate a soil map with `ALT + T`. Compare the map with the field average. One damaged wheel track is different from a problem across the whole field.
3. **Choose a suitable operation.** Use **Planner** to compare equipment. Address the property that needs attention: deep compaction, upper-soil compaction, coarse tilth or unevenness.
4. **Set your working speed deliberately.** Start within the recommended range shown in the work HUD, then watch Work Quality and the warnings. The speed bar shows your speed relative to that range; it is not a quality indicator. Difficult soil conditions or worn equipment may require slower work even within the green range.
5. **Check what changed.** Look at the soil map after the pass. Later, use **Work and Yield** to see the recorded work and the developing yield estimate.

For example, ploughing can leave loose topsoil but a coarse, uneven surface. A conventional seeder may need to slow down considerably on that ground. A suitable shallow cultivator or harrow adds a pass but can improve seed placement. On an already suitable stubble field, direct drilling may save that preparation altogether.

## Controls

These are the default bindings. Keyboard bindings use the left `CTRL` and `ALT` keys and can be changed in the game's control settings.

| Action | Default binding |
| --- | --- |
| Cycle through soil maps and off | `ALT + T` |
| Cycle backward | `CTRL + ALT + T` |
| Surface compaction map | `CTRL + ALT + 1` |
| Deep compaction map | `CTRL + ALT + 2` |
| Tilth map | `CTRL + ALT + 3` |
| Evenness map | `CTRL + ALT + 4` |
| Resilience map | `CTRL + ALT + 5` |

Press the direct-selection shortcut for the active map again to switch it off. The game's normal map-view control, `9` by default, changes the minimap view.

While a tutorial card or its topic index is visible, a short **right-click** toggles the mouse cursor. Use it to click the tutorial buttons. Right-click again or close the tutorial to release it. Mouse movement does not rotate the on-foot or vehicle camera while the tutorial owns the cursor.

With the tutorial cursor enabled, hold the left mouse button on the window's top bar to drag it. Release the button to leave it in the new position.

## Reading the soil

TerraLogic tracks local conditions rather than assigning one uniform score to a field. A narrow tire lane can be compacted while the ground beside it stays loose. Adjacent operations with different equipment can leave different seedbeds.

The five maps describe separate properties:

| Soil property | What it means | How to read the value |
| --- | --- | --- |
| Surface compaction | Compression of the upper soil, reducing the spaces through which roots can grow. Tire contact pressure is an important cause. | Lower is better: near 0% is loose, near 100% is heavily compacted. |
| Deep compaction | Compression below the normal shallow working layer. High axle loads can restrict rooting even when the surface looks loose. | Lower is better. Severe deep compaction is harder to relieve. |
| Tilth | How coarse or fine the soil aggregates are. Large clods hinder seed placement; excessively pulverized soil is also undesirable. | Around 50% is the aim. Near 0% is very coarse; near 100% is too fine. |
| Evenness | How level and consistent the worked surface is. Rough ground makes reliable contact harder for sensitive equipment. | Higher values, toward 100%, mean a more even surface. |
| Resilience | The ability of the established soil structure to withstand new loads. Roots and soil life help develop it over time. | Higher values, toward 100%, mean greater resistance to new compaction. |

A field can be even but compacted, loose but coarse, or resilient while still carrying old compaction. Read the values together.

### Maps, local values and field averages

With a soil map active, the field-information HUD shows the five soil values beneath you when on foot. The field analysis menu instead assesses the selected connected field area. A local value can therefore differ considerably from the field average.

The maps show the simulated soil, not just the game's visible ground texture. Newly initialized fields may look fairly uniform until traffic, work and weather create differences. Normal fields receive starting conditions suited to their field state; new areas created with a plough also receive soil data.

Use map colours to locate differences, then use the values and question-mark explanations to judge their significance. A small red area does not automatically justify another full-field operation.

## The field analysis menu

Open the **ESC menu → TerraLogic icon** to inspect a field. When available, the analysis starts with the connected field area beneath you. Use the dropdown at the top to select another available field or section.

Separate sections of the same native field receive distinct names, such as **Field 2-1** and **Field 2-2**. These names help identify them in Field Analysis and its selection list; they do not replace the field labels on the game's minimap.

The five pages answer different questions:

| Page | What it helps you understand |
| --- | --- |
| Overview | The field's soil condition, biological continuity, yield estimate and main recommendations. |
| Work and Yield | Recorded work quality, yield deductions and the existing crop's share of the selected area. |
| Weather and Effects | Moisture, temperatures in different soil layers and their consequences for traffic and fieldwork. |
| Planner | The likely result of a selected operation under the current conditions. |
| Recommendations | Suggested actions and their explanations, ordered by urgency and practical relevance. |

Question-mark buttons explain the meaning and practical use of individual values.

The Recommendations page pairs each suggested action with an explanation of the problem and how the action can help. Advice to prevent immediate damage comes first, followed by suitable preparation and longer-term soil care. This is guidance, not a mandatory sequence. Check whether the advice applies to unsown ground or an existing crop before making another pass.

### Compare operations before driving

In **Planner**, choose the operation and implement type. Where possible, your attached supported implement is selected automatically.

The planner shows recommended speed, achievable work quality, expected missed areas, pulling resistance and the predicted soil condition after a pass. It also rates how strongly the implement affects resilience and disturbs biological continuity.

While you are in a vehicle, the current-setup column helps compare vehicle and implement mass, total combination mass, maximum axle load, ground contact pressure and compaction risk. Vehicle values remain available without a supported working implement, so you can also inspect a tractor and trailer. Unavailable implement-specific values appear as a dash.

Compaction-risk factors on the weather page describe the influence of the soil and conditions. They are not the final result of a vehicle pass: load, tires, tracks and resilience matter too. Use the live HUD indicators to assess the combination you are actually driving, and the soil maps to inspect the condition left behind.

Use these forecasts to choose a suitable tool, then check the actual result. Extra turns, overlapping passes, changing loads and driving speed can all change what happens in practice.

### Read missing and preliminary values correctly

**Not recorded** means that TerraLogic has no work record for that operation on the assessed area. It does not mean the work was poor or prove that the operation was never performed. Recorded work quality is evaluated where records exist. Open the operation's question-mark explanation to check its recorded area coverage.

With no active crop, no crop yield estimate is available. Once a crop is present, the estimate applies to that crop, not to unsown parts of the field. Crop information shows how much of the selected area is covered.

**Overview** and **Work and Yield** use the same yield estimate. Work and Yield adds the breakdown of soil, water and fieldwork deductions. The estimate can change as more growing conditions are recorded.

## Choosing equipment and preparing a seedbed

TerraLogic gives soil-working implements different roles. Working depth, intensity and current conditions determine how effectively they loosen, crumble, mix, level or consolidate the ground.

| Implement | Main role | What to consider next |
| --- | --- | --- |
| Plough | Strong topsoil loosening and inversion. | Usually leaves coarse, uneven ground and strongly disturbs established soil structure. Check the seedbed before sowing. |
| Subsoiler | Targeted relief of deep compaction. | Useful where deep damage warrants repair, but its result is not a finished seedbed. |
| Cultivator | Loosening moderate topsoil compaction, mixing and levelling. | Suitable when upper-soil repair and seedbed preparation are both needed. |
| Shallow cultivator | Gentler refinement and levelling at reduced depth. | Useful on soil that is already loose enough; less effective against strong compaction. |
| Disc harrow | Shallow mixing, crumbling and levelling. | A seedbed option when deeper loosening is unnecessary. Repeated work can over-refine suitable soil. |
| Power harrow | Intensive refinement and levelling. | Can prepare coarse ground well, but an already fine seedbed may need no further refinement. |
| Spader | Strong loosening and mixing. | Changes the soil differently from a plough while still substantially disturbing established structure. |
| Arable roller | Surface consolidation, levelling and improved seed contact. | Can help before or after sowing, but also firms the soil and can add compaction. |

Moisture, soil type and frost shift the outcome. Very dry ground may remain hard or become too fine under intensive work; wet cohesive soil can clump and smear. A second pass is useful only if it addresses a remaining problem.

### Conventional seeding and precision planting

Conventional seeders work best on a prepared seedbed. Precision planters are particularly sensitive to unevenness and unsuitable tilth because individual seed placement must remain consistent.

There are two different consequences to watch:

- **Lower sowing quality:** seed is present, but placement and establishment are less favourable.
- **Unsown gaps:** no seed was placed, so there are no plants to harvest there.

Slowing down can prevent contact-related misses. It cannot always overcome an unsuitable seedbed, poor moisture, frost or worn equipment. Compare the cost of slower sowing with the benefit of an appropriate preparation pass.

### Rolling before and after sowing

Arable rollers can level and reconsolidate suitable soil **before sowing**.

**After sowing**, they can also recover part of the sowing-quality loss caused by poor seedbed contact. The game's regular rolling bonus remains available when its requirements are met.

A roller cannot replace missing seed or repair placement errors caused by excessive sowing speed or implement wear. Wet conditions, excessive rolling speed and unnecessary repeat passes can reduce its benefit or create additional compaction.

### Choosing a working sequence

- **Plough → seed:** possible, but slower sowing may be needed and seed placement can remain limited.
- **Plough → suitable cultivator or harrow → seed:** more work and traffic, but often a better seedbed for conventional or precision seeding.
- **Cultivator → seed:** a practical option when moderate upper-soil work is sufficient.
- **Harvest → direct drill:** saves preparation when the remaining soil conditions suit the drill.

Choose the sequence for the field's current condition. The long-term differences between these systems are explained under [Resilience, biological continuity and recovery](#resilience-biological-continuity-and-recovery).

## Traffic, tires and tramlines

Compaction changes dynamically with the load carried by the vehicle and its equipment. Fuel, ballast, seed, fertilizer, a filling grain tank or a loaded trailer can change how the same combination affects the soil.

**Ground contact pressure** describes how concentrated the load is beneath tires or tracks. It mainly affects the upper soil. **Axle load** matters more for deeper compaction. The planner's contact-pressure value is an estimate of pressure on the ground, not tire inflation pressure.

TerraLogic reads the current load supported by each wheel from the game's physics. It estimates the tire contact area from tire dimensions and load, then calculates average ground contact pressure. The pressure shown is therefore a modelled ground-pressure value, not a direct pressure reading from the engine or the tire's inflation pressure.

Deep compaction depends on axle load and how that load spreads into the soil. Contact width and length both matter: a long track or a large tire distributes the load differently from a smaller footprint. TerraLogic considers the complete track assembly rather than treating its support wheels as separate compacting axles. The pressure shown in the planner is still a surface value, not a direct measurement of pressure in the subsoil.

Soil type, moisture, frost and resilience further modify the response. Repeated passes can accumulate compaction, but a lighter vehicle does not loosen soil that was already compacted by a heavier load.

Wide tires, dual wheels and tracks spread weight over a larger contact area and can reduce compaction. Narrow crop-care tires can protect suitable standing crops from wheel damage, but concentrate the load on less soil. A large tracked machine can therefore have an advantage over a similarly loaded wheeled machine, but neither wide tires nor tracks make a very heavy load harmless on wet ground.

### Why fixed traffic lanes matter

The first pass over loose soil often causes the largest increase in compaction. Five tracks in different places reach more fresh soil than five trips along the same track. Repeated passes still add damage within a lane, especially at depth, but leave more of the surrounding field untouched.

**Tramlines have a physical purpose in TerraLogic.** Reusing them for fertilizing and crop protection concentrates compaction instead of spreading it through the crop. Precision Farming tramlines can also keep those lanes unsown, placing repeated traffic where no harvest is growing.

Unsown tramlines reduce planted area. Their benefit depends on load, tires, moisture and the number of passes, rather than a guaranteed yield bonus.

Practical ways to reduce traffic damage:

- Use suitable tires and only the ballast and vehicle size the job requires.
- Plan crop-care and unloading routes around existing lanes.
- Avoid unnecessary headland turns and overlap.
- Unload heavy vehicles earlier where practical.
- Give wet soil time to dry when the operation can wait.

Tires can also change tilth and evenness. Gentle consolidation differs from heavy traffic that creates ruts or damages the seedbed.

## Working speed, quality and damage

For supported, manually driven implements, TerraLogic removes the usual working-speed restriction. The shop speed remains a useful reference, but conditions determine the quality and cost of working at that speed.

Combines and standard crop harvesters retain their usual working-speed and damage behaviour. TerraLogic's soil, crop and yield effects still apply to their harvest results.

### Use the work HUD

The compact work HUD separates speed guidance from the result of the operation:

- **Recommended speed, on the left:** the numbers show the recommended working range. The bar shows your current speed relative to that range. Read your actual speed on the game's speedometer.
- **Work Quality, on the right:** describes how well the operation is being carried out. The speed bar does not represent this percentage.
- **Compaction icons beside Work Quality:** show the severity of loading on the topsoil and subsoil under the current conditions. The wheel symbol refers to the upper layer; the axle symbol refers to the deeper layer.
- **Warnings, above the HUD:** explain problems such as unsuitable soil conditions, high implement load, damaging overload or stone impacts. Mechanical load and wear are no longer shown as permanent readouts.

The green speed range is guidance, not a guarantee of perfect quality or safe load. Soil conditions, moisture, frost and equipment wear can still require slower work.

With several recognized implements, the HUD shows their count. Speed guidance follows the limiting implement, while Work Quality shows the lowest currently assessed quality. For balers and loading wagons, **Material pickup** describes collection performance rather than sowing or application quality. A dash means that no applicable quality value is currently available.

The HUD also works during transport and without a supported working implement. Recommended speed and Work Quality show a dash when they do not apply, while the compaction icons can still help you judge a loaded trailer or other heavy combination.

The compaction icons describe the combination's potential effect on the soil beneath you, not the amount of old compaction already present or just the small increase added to an existing track. Driving along an already compacted tramline therefore does not make a damaging combination appear harmless. Use the soil maps to see the actual condition of each area. When you start moving, the indicators briefly wait for a completed soil-cell passage rather than showing a misleading low reading.

Warning cards have a fixed height and room for two lines. When several messages are queued, they rotate using your selected warning duration. Compaction warnings can also appear while driving without an active working implement.

Yellow advisories normally appear once while a problem continues. They can appear again after the cause has been absent for at least 30 seconds while the relevant system is being monitored. Red warnings remain active for as long as a serious problem persists. Individual events, such as new stone impacts, can still produce new notifications.

The HUD temporarily steps aside for important vanilla messages, including the attach-implement prompt. This also applies in Always visible mode; it does not switch off the simulation.

Set cruise control to a sensible starting speed, then adjust it while watching the result. Small cruise-control fluctuations do not necessarily require intervention; sustained overload and meaningful quality losses do.

Choose how much of the HUD to display in [Tutorials and settings](#tutorials-and-settings).

### Different jobs have different consequences

Speed and wear affect many operations, but the mechanism depends on the equipment:

- Seeders can place seed poorly or leave unsown patches.
- Sprayers and spreaders can leave untreated areas.
- Hoes and weeders can leave weeds standing.
- Mowers, tedders, windrowers and pickups can leave crop or swath material behind.
- Soil-working tools can loosen, refine or level less effectively.

Sowing and supported application qualities are recorded locally and can affect the later harvest. Material left behind is an immediate, visible loss. A completed ground texture alone does not prove that the work was effective.

### Pulling resistance and implement condition

The same implement can be harder to pull in compacted, very dry, wet cohesive or frozen soil. Working depth, soil type, speed and implement condition also matter.

A larger tractor may maintain speed under those conditions, but the forces transmitted can overload the implement. Higher engine power is useful only when the equipment and soil can support the work.

For soil-engaging tools, lowered ground contact can create resistance and wear even when an implement such as a seeder is switched off. Raise it for travel.

### Wear and stones

TerraLogic adds work-related abrasion, overload and stone impacts to ordinary wear. High pulling resistance, long working distances and abrasive soil increase wear; severe overload can cause structural damage. Worn equipment can work less effectively and need more pulling power.

Visible field stones and simulated underground stones are separate risks. A stone picker reduces visible surface stones. Deep-working tools can still strike stones below the surface, while powered rotating parts can experience strong impacts even at a low travel speed.

If field stones are disabled in the game settings, visible-stone damage is absent. Underground stone impacts remain separate. The stone-impact warning option controls notifications, not the damage itself.

## Weather and soil conditions

TerraLogic's soil moisture and temperature respond to the game's weather with a delay. The surface changes faster than deeper layers, so the air-temperature display or a rain icon does not tell the whole story.

### Each field has its own water reserve

Water is tracked separately for the upper 15 cm and the layer from 15 to 60 cm. Rain and melting snow enter from above, seep down and drain away when there is more water than the soil can retain. Some water can also move back upward when the surface is drier than the soil below.

Each field develops its own conditions. A growing crop draws water through its roots, while its leaves shade the surface and reduce evaporation from the soil. Crop type, growth stage, harvest and regrowth all change that balance. A bare field and an established grass field can therefore respond differently to the same weather. Unknown crops from mod maps use a general crop profile.

With Precision Farming, the soil types within a field keep separate water reserves. Without it, the same system works with a representative default soil. When fields are joined or split, existing water reserves are carried across according to the area involved. Newly created ground starts with the current background moisture for its soil type.

These are field averages by soil type, not a separate simulation of every puddle or wheel track. Soil mechanics use the moisture of the field and soil type beneath the vehicle; the compaction maps still record local traffic damage.

### Reading moisture values

Moisture is shown in **vol.%**. A reading of 25 vol.% means that water occupies 25 litres of every 100 litres of soil. It is not 25% of a full water tank, and it is not the moisture of the harvested crop.

The meaning depends on soil type. A value that is normal for a clay-rich soil may already be wet for a sandy soil. Field Analysis adds a **Dry, Normal, Moist or Wet** assessment and its moisture question-mark opens a table with current values and normal ranges for the soil types in the selected field.

The normal range runs from half of the plant-available water reserve to field capacity, the level above which excess water drains away. Moist and Wet describe progressively wetter conditions. They are a guide to moisture, not a guarantee that a particular machine can drive without damage. If the field contains soils with different assessments, the summary can show **Mixed**.

### Moisture and work timing

Wet, unfrozen soil is more vulnerable to compaction and deformation. Tillage can smear or clump it. Very dry soil may resist penetration or break down poorly. Check **Weather and Effects** before committing heavy equipment to a difficult field.

For rain-sensitive applications, rain or wet plants can reduce application quality. The consequences depend on the type of application; follow the relevant HUD warning.

If the weather on your map makes fields feel too dry or too wet, the **Precipitation effect** setting offers Dry, Normal and Moist. It changes how much water precipitation contributes, not how often it rains. Existing water reserves are not suddenly rescaled when you change it. This option applies when TerraLogic supplies soil moisture; when Moisture System supplies it, its moisture signal remains in control.

### Frost and thaw

Frozen ground can resist compaction more strongly, while also being harder to penetrate and requiring more pulling force. Layers may freeze or thaw at different times, so a frozen surface does not guarantee protection of the subsoil.

Freezing followed by thawing can contribute some natural loosening. Cold conditions meanwhile slow biological recovery. Waiting for the worked layer to thaw is often preferable to forcing an implement through it.

Both soil temperatures update continuously. With short months, their response is sped up so the soil can follow the changing seasons rather than staying warm through most of winter. With longer months, the loosening from each freeze-thaw cycle is reduced to account for the additional days. Staying frozen does not repeatedly loosen the soil; it needs to thaw before that effect occurs.

### Water during growth

Water supply matters throughout crop growth. Each field's daily averages and moisture history contribute to its crop's water-related yield effect. A shower just before harvest cannot erase an earlier dry spell, and a dry harvest day does not cancel a season of adequate water.

The **Soil moisture affects yield** setting lets you disable the weather-related yield effect if the map's weather does not suit your preferred experience. Moisture still affects traffic, soil work and pulling resistance.

With Moisture System installed, this setting defaults to Off to avoid overlapping water-related yield losses. You can turn it back on, and your explicit choice is saved. See [Moisture System](#moisture-system) for how the two mods work together.

## Resilience, biological continuity and recovery

These three ideas explain why immediate soil repair and long-term management are different:

- **Resilience** is the strength of the established soil structure. Higher resilience reduces new compaction under comparable traffic.
- **Biological continuity** describes how undisturbed roots, pores and soil life have been able to develop. Strong disturbance slows their contribution until continuity rebuilds.
- **Natural recovery** gradually changes existing soil conditions through roots, biological activity and physical processes such as settling and freeze–thaw action.

Resilient soil is not automatically loose. It may withstand future loads better while still carrying compaction from earlier work.

### Resilience and drainage

Resilience also helps the field deal with excess rainwater. High resilience allows it to move through the soil and drain away somewhat faster; low resilience slows that movement. The effect is calculated for each field and soil type, and existing compaction limits the benefit.

At the extremes, the change is up to 15% slower or 30% faster transport. This changes the length of wet periods rather than increasing the soil's water-storage capacity. It does not add extra drying to already dry soil. Good structure can help a field recover after rain, but it cannot make a wet field safe for every load.

### Disturbance and rebuilding

An implement can solve an immediate physical problem while disturbing the structure that supports longer-term recovery. Depth and intensity matter: ploughing has a different effect from shallow cultivation, seeding or rolling.

Repeated shallow work adds disturbance with diminishing effect as the same layer is already worked; it does not endlessly act like fresh deep inversion. The planner's resilience and continuity ratings help compare the general impact of implement classes.

Wheel traffic can damage physical soil condition and, under damaging loads, resilience. Driving over the soil does not itself reset biological continuity.

Favourable moisture, warmth and living roots support rebuilding. Cold, unsuitable moisture and repeated disturbance slow it. Deep compaction is particularly persistent, so compare trends across seasons rather than expecting every soil value to improve overnight.

### Crop rotation and cover crops

Varying crop groups and rooting patterns supports resilience and natural soil development. Cover crops use the gap between main crops; perennial cover can give the soil a longer period of undisturbed rooting.

Living cover generally contributes more than crop residues alone. Once the game classifies oilseed radish as withered, TerraLogic treats it as residue rather than living roots. Its fertilization effect when incorporated is a separate benefit.

A cover crop also requires another machinery pass. Light, suitably equipped sowing and gentle incorporation help retain its advantage. Where supported, direct drilling can combine incorporation with sowing the next main crop.

### Direct drilling over several seasons

Direct drilling saves seedbed-preparation passes, working time and fuel. It preserves more biological continuity, allowing natural recovery and resilience development to work with less interruption.

Its own machinery still creates compaction. Vehicle weight, fill level, tires and crop-care lanes are therefore important, even when the number of operations is small.

After a switch to direct drilling, compaction can initially rise and yield can fall. With appropriate traffic and rotation, new compaction and recovery may eventually balance, allowing yield to stabilize or recover somewhat. This is not guaranteed for every load, soil or climate; serious deep damage can still justify targeted loosening.

Conventional tillage offers quicker mechanical correction but needs more work and repeatedly disturbs the soil. Direct drilling can remain worthwhile even with somewhat lower harvested volumes because it saves operations. With Precision Farming, a good environmental score can also improve profitability; it does not guarantee compensation for every compaction loss.

## Understanding yield

The base game, and Precision Farming when enabled, calculate their normal yield. TerraLogic applies its own result on top, based on soil conditions during growth, water supply and recorded fieldwork.

| TerraLogic final yield potential | Meaning |
| --- | --- |
| 100% | Preserves the yield already calculated without TerraLogic's adjustment. |
| Up to 110% | Excellent soil conditions and careful work can improve that result by up to 10%. |
| Down toward 60% | Combined severe soil, water and fieldwork problems can substantially reduce it. |

These percentages are relative factors, not promised litres or tonnes per hectare. Missing plants produce no harvest, so unsown gaps are additional to the 60% floor.

### Where the result comes from

- **Root development:** surface and deep compaction can restrict growth. Conditions during the growing period matter, so later loosening cannot simply undo earlier losses.
- **Water supply:** drought and prolonged wetness can affect development when moisture-related yield effects are enabled.
- **Fieldwork:** recorded sowing and supported application quality contribute according to the operation.

The calculation starts at **110% yield potential**. Deductions for soil conditions, water supply and fieldwork are subtracted in percentage points.

For example, deductions of 2 points for soil, 1 point for water and 3 points for fieldwork produce **104%**: four percent more than the yield calculated without TerraLogic under otherwise identical conditions.

The resulting factor is limited to **60–110%**. Missing plants remain a separate loss: the lower limit does not create a harvest on unsown ground. The breakdown explains the same TerraLogic factor used by the harvest calculation and Precision Farming integration.

Resilience and crop rotation affect yield through the soil, including its water balance. They add no separate direct yield bonus or penalty. Well-loosened, well-prepared soil can therefore support a good crop even before high resilience has developed.

Individual quality indicators stop at 100%, while final yield potential can reach 110% because it uses a different reference: the harvest without TerraLogic.

Use **Work and Yield** to identify the main causes. Also check the base game or Precision Farming requirements, including pH, nutrients and weed control. Good TerraLogic soil does not replace those jobs.

## Tutorials and settings

Find TerraLogic's options in the normal game settings menu, grouped into Display, Tutorials, Simulation, Compatibility and Diagnostics. Compatibility options appear when the relevant mod is installed. Display preferences are personal; in multiplayer, shared gameplay and map-update settings are controlled by the server administrator.

### Learn at your own pace

The tutorial offers three modes:

- **Introduction and contextual tips:** learn the controls and basic concepts, followed by topics relevant to your work.
- **Contextual tips only:** skip the introductory sequence.
- **Off:** disable automatic cards while keeping the tutorial library available.

Cards stay open until you dismiss them. **The game continues running**, so stop safely before reading at length. Right-click to enable the cursor, then use **Next**, **Back**, **Got it** or **Topics**. The X closes a card without marking the topic as read.

The first introduction card also offers a button to disable tutorials. You can revisit topics through the library in settings, reset the tutorial later, or read the more detailed **Help → TerraLogic** pages. Resetting the tutorial does not reset soil or field data.

Tutorial cards and the topic library share a locally saved window position. Future tutorials open in the same place, including after restarting the game.

Movement is limited so that part of the window and a usable section of its top bar remain accessible. If you want to restore the original position, use **Reset tutorial position** in TerraLogic's settings. This does not reset tutorial progress or affect soil, field or vehicle data.

### Main settings

| Setting | Purpose and initial default |
| --- | --- |
| TerraLogic tutorial | Introduction and contextual tips. |
| Work HUD | Dynamic by default. Also offers Always visible, Warnings only and Off. |
| Reset tutorial position | Returns the tutorial window to its default position without resetting reading progress. |
| Warning display duration | 5 seconds; adjustable from 1 to 10 seconds. |
| Soil map minimap zoom | 4x while a TerraLogic soil map is active. |
| Soil map updates | Normal by default; Fast refreshes maps sooner but uses more processing power and, in multiplayer, more network traffic. |
| Soil resilience development | Normal (8x); 4x and Realistic (1x) are available for slower development. |
| Compaction intensity | 100%; choose 50%, 75%, 100%, 125% or 150% to adjust new wheel and axle compaction. |
| Precipitation effect | Normal; Dry and Moist reduce or increase water supplied by precipitation when TerraLogic supplies moisture. |
| Soil moisture affects yield | On without Moisture System; defaults to Off when MS is detected unless you have made an explicit choice. |
| Soil moisture source | TerraLogic by default; Moisture System becomes selectable when installed. |
| Visible-stone damage | Extended stone damage; base-game damage behaviour is also selectable. |
| Stone-impact warnings | On. |

**Dynamic** shows the work HUD when useful, including relevant soil loading during transport. During steady work within the recommended range, it can fade when no warning, increased wear or other condition requires attention. Leaving the range or changing cruise speed brings it back.

**Always visible** keeps the HUD available while you are in a vehicle, even with a raised implement or no supported working implement. Important overlapping vanilla messages can still temporarily hide it.

**Warnings only** hides the speed and quality display while retaining warning cards.

**Off** hides both the work HUD and TerraLogic's HUD warnings. These display modes do not disable the simulation.

The resilience-development setting scales biological gains and soil-disturbance losses together. It does not accelerate the physical recovery of compaction, tilth or evenness.

Compaction intensity lets you make new traffic damage more forgiving or demanding without changing the compaction already stored in the field. HUD indicators and compaction warnings follow the same setting. Natural recovery, seedbed preparation and machinery wear are not directly increased or reduced by this option.

If More Realistic is installed, an additional setting selects which mod controls pulling resistance. Existing saved preferences are retained after updates.

### Soil map refresh and performance

**Normal** and **Fast** work in both singleplayer and multiplayer. Fast updates the soil maps sooner, but uses more processing power and, in multiplayer, more network traffic. The server administrator can switch during play without restarting.

Nearby and recently changed areas receive attention first, while background work also progresses across distant areas. Field-boundary cleanup gradually removes outdated map coverage from ground that is no longer a field. This background maintenance continues when the minimap is hidden.

A full-map view may still take time to catch up, especially after loading or extensive changes. Choosing Normal reduces update load; it does not reduce soil-calculation accuracy or change yield.

## Compatibility and multiplayer

### Precision Farming

Precision Farming remains responsible for its own soil sampling, pH, nitrogen and environmental systems. TerraLogic uses its soil types to vary moisture behaviour, draft, traffic sensitivity and recovery.

A TerraLogic soil map temporarily replaces Precision Farming's coloured overlay while active. Switch it off to return to the other view; Precision Farming's gameplay remains active.

### Moisture System

The two mods can work together without giving up TerraLogic's soil mechanics. When Moisture System is installed, **Soil moisture source** lets you choose which mod provides the moisture input. Both choices respond to the game's weather, including weather generated by Moisture System's selected climate profile. A wetter climate can therefore give TerraLogic wetter working conditions even if TerraLogic remains the moisture source.

With **TerraLogic** selected, its field water balance continues to handle rain, soil types, seepage, drainage and plant water use. Newly delivered MS irrigation adds water to the relevant field reserves. Booking irrigation does not instantly wet the field; delivery needs to take place.

With **Moisture System** selected, its local field moisture guides TerraLogic's topsoil water balance. Water can then move into the subsoil, be taken up by plants and drain away, including the influence of resilience. Rain and MS irrigation are not added a second time. Field Analysis marks these values with **MS**. They are converted TL soil-moisture values, not the percentages shown by Moisture System, and they can differ as the field's own water balance develops.

To avoid overlapping water-related yield losses, **Soil moisture affects yield** defaults to Off when MS is detected. You can explicitly switch it on or off, and that choice is retained when you reload or change the mod combination. This also applies when either mod is added later to an existing savegame. Switching off this option does not disable MS's own crop effects or TerraLogic's yield consequences from compaction and fieldwork.

Moisture System keeps control of crop withering, grain moisture, quality grades, drying, hay, bales and storage. TerraLogic does not change those systems. Without MS, the field-water model continues to work independently.

### Multiplayer

The server calculates and saves the shared soil state. Players receive updated soil information while retaining their own map selection, display preferences and tutorial progress.

Shared settings apply across the server. Use Normal soil map updates if the server is under load and Fast when sufficient capacity is available.

### Other equipment and mods

TerraLogic recognizes supported equipment through its game functions rather than requiring a separate entry for every vehicle name. Supported combinations can account for multiple operations, such as cultivation followed by seeding.

Unusual modded machinery or special DLC functions may need additional compatibility work. AI helpers and some specialized carrier systems retain their own speed limits.

When using More Realistic, select the desired pulling-resistance provider in TerraLogic's settings. If vehicle behaviour is unexpected, check the selection and possible interactions with other physics or machinery mods.

## Troubleshooting and feedback

| What you notice | What to check |
| --- | --- |
| A red strip but a reasonable field average | Inspect the local map: the strip may be one traffic lane. Consider its area before adding a full-field pass. |
| A high compaction icon on an already compacted tramline | The icon assesses the current combination, not just the small amount of extra damage possible in that lane. Reusing the lane still protects the rest of the field. |
| Compaction icons briefly show a dash when starting | Allow the combination to pass over a complete soil cell. The HUD waits for a usable reading instead of assuming Low. |
| Low sowing quality or gaps at shop speed | Check tilth, evenness, compaction, moisture, frost and implement wear. Try a lower speed or suitable seedbed preparation. |
| Persistent deep compaction | Reduce heavy axle loads and repeated traffic; consider targeted subsoiling where natural recovery is insufficient. |
| Unexpectedly high draft or damage | Check soil conditions, actual working speed, implement wear, load and stone warnings. More horsepower does not remove the cause. |
| Soil map does not match the visible texture | The map records TerraLogic soil history. Changing a field's appearance with an admin tool does not necessarily change those soil values. |
| No crop yield estimate | Check whether there is an active crop. Growing crops begin with a preliminary estimate before growth history is available. |
| Maps take time to update | Allow refresh work to progress; try Fast if the PC or server has capacity. |
| Tutorial cursor seems unavailable | A card or topic index must be visible. Use a short right-click to toggle it. |
| Warnings appear, but the speed and quality display is missing | Check whether Work HUD is set to Warnings only. |
| The work HUD disappears during normal work | Dynamic mode fades it after steady work within the recommended range when no warning or increased wear requires attention. |
| The HUD disappears near an attach-implement prompt | TerraLogic temporarily steps aside for important vanilla messages, including in Always visible mode. |
| Speed and quality show a dash while towing a trailer | These values may not apply to the attached equipment. The compaction indicators can still show its effect on the soil. |
| The same vol.% has a different assessment on another field | Soil types hold water differently. Use the moisture question-mark table to compare their normal ranges. |
| TL and MS show different moisture numbers | MS percentages and TL vol.% use different scales. TL also retains its own field water use and subsoil response. |
| Soil moisture affects yield is Off after adding MS | This is the default to avoid overlapping water-related penalties. Turn it on explicitly if you want both mods' effects. |
| No TerraLogic HUD warnings appear | Check whether Work HUD is set to Off. Stone-impact notifications also have their own setting. |
| The tutorial window is in an inconvenient position | Enable the cursor with a short right-click and drag the top bar, or use Reset tutorial position in settings. |
| Several entries belong to the same field number | They may be separate connected sections. Use the numbered section names in the field dropdown to distinguish them. |

For bugs, feedback or feature suggestions, use the [TerraLogic GitHub repository](https://github.com/Saibotsu/FS25_TerraLogic).

Include the TerraLogic version, map, affected machine and configuration, active mods, singleplayer or multiplayer mode, and clear reproduction steps. Screenshots and the game log help; additional audit recordings are only needed when requested for diagnosis.

## Copyright

Copyright © 2026 The Mod Workshop. All rights reserved.

This repository is source-available for inspection; it is **not** released under an open-source license. See [`LICENSE`](LICENSE) for the applicable terms.
