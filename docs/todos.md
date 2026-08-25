1. features
    - use contract imports as 'request' from islands
    - arctic/enbesa/trelawney support
    - "other mods support" aka automate extracting objects request, don't use statically generated ones <- test this case
    - if ship gets allocated to a trade between two areas and the trade does not use all the ship goods, pick more trades for the same path using the ship remaining capacity
2. observability
    - mod status (regions, areas, ships)
    - extract errors from the game log
    - extract goods icons from game
3. bug fixing
    - enable mod in region without restarting it; aka check what happens if unscanned region has ships, but no areas
      scanned yet
    - names at deficit/surplus web page
    - fail checks to ensure no goods:
      - appear from nowhere if island capacity is lower than what is loaded to ship
      - disappear if island capacity is lower than what is unloaded from ship             <- very important

----

```json
"CTradeContractManager":
[
{
"Alias": "Contracts",
"IsStatic": "true",
"ReturnType" : "CTradeContractManager",
"Comment": "",
"Arguments": {

}
},
{
"Alias": "RemoveContract",
"IsStatic": "false",
"ReturnType": "void",
"Comment": "Destroys the last trade contract in the area",
"Arguments": {
"areaId": {
"Type": "AreaID"
}
}
},
{
"Alias": "TraderGUID",
"IsStatic": "false",
"ReturnType": "void",
"Comment": "Setters for one contract\n\"areaId\" is the area where the contract is located. DebugInfo TextSources do not support AreaID, so we need a version with rdint16 for TextSources.\n\"index\" is the index of the contract in that area (contracts are just a vector)",
"Arguments": {
"areaId": {
"Type": "rdint16"
},
"index": {
"Type": "int"
},
"guid" : {
"Type": "int"
}
}
},
{
"Alias": "ExportGoodGUID",
"IsStatic": "false",
"ReturnType": "void",
"Comment": "",
"Arguments": {
"areaId" : {
"Type": "rdint16"
},
"index": {
"Type": "int"
},
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "ImportGoodGUID",
"IsStatic": "false",
"ReturnType": "void",
"Comment": "",
"Arguments": {
"areaId": {
"Type": "rdint16"
},
"index": {
"Type": "int"
},
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "ExportAmount",
"IsStatic": "false",
"ReturnType": "void",
"Comment": "",
"Arguments":
{
"areaId": {
"Type": "rdint16"
},
"index" : {
"Type": "int"
},
"amount": {
"Type": "int"
}
}
},
{
"Alias": "ImportAmount",
"IsStatic": "false",
"ReturnType": "void",
"Comment": "",
"Arguments": {
"areaId": {
"Type": "rdint16"
},
"index": {
"Type": "int"
},
"amount": {
"Type": "int"
}
}
},
{
"Alias": "TradeHistory",
"IsStatic": "false",
"ReturnType": "TradeHistory",
"Comment": "",
"Arguments": {
"areaId": {
"Type": "AreaID"
},
"contractIndex": {
"Type": "int"
}
}
},
{
"Alias": "DebugSelectGoodForMoreInfo",
"IsStatic": "false",
"ReturnType": "void",
"Comment": "selects a good to display its GoodValue calculation",
"Arguments":
{
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "IncreaseGoodXP",
"IsStatic": "false",
"ReturnType": "void",
"Comment": "Cheats",
"Arguments":
{
"guid": {
"Type": "ProductGUID"
},
"amount" : {
"Type": "ProductAmount"
}
}
},
{
"Alias": "FillPyramid",
"IsStatic": "false",
"ReturnType": "void",
"Comment": "",
"Arguments": {
}
},
{
"Alias": "SkipTransit",
"IsStatic": "false",
"ReturnType": "void",
"Comment": "",
"Arguments" : {
"areaId": {
"Type": "rdint16"
}
}
},
{
"Alias": "SkipLoadingTime",
"IsStatic": "false",
"ReturnType": "void",
"Comment": "",
"Arguments" : {
}
},
{
"Alias": "ToggleSkipTransit",
"IsStatic": "false",
"ReturnType": "void",
"Comment": "",
"Arguments": {
}
},
{
"Alias" : "ConditionForImportGood",
"IsStatic": "false",
"ReturnType": "int",
"Comment": "Conditions",
"Arguments": {
"guid":
{
"Type": "ProductGUID"
}
}
},
{
"Alias" : "IsImportGoodLocked",
"IsStatic": "false",
"ReturnType": "bool",
"Comment": "",
"Arguments": {
"guid":
{
"Type": "ProductGUID"
}
}
},
{
"Alias" : "IsConditionImportCounter",
"IsStatic": "false",
"ReturnType": "bool",
"Comment": "",
"Arguments": {
"guid":
{
"Type": "ProductGUID"
}
}
},
{
"Alias" : "IsConditionExportCounter",
"IsStatic": "false",
"ReturnType": "bool",
"Comment": "",
"Arguments": {
"guid":
{
"Type": "ProductGUID"
}
}
},
{
"Alias" : "IsConditionContractCounter",
"IsStatic": "false",
"ReturnType": "bool",
"Comment": "",
"Arguments": {
"guid":
{
"Type": "ProductGUID"
}
}
},
{
"Alias" : "HighestExportGood",
"IsStatic": "false",
"ReturnType": "CAsset",
"Comment": "",
"Arguments": {
}
},
{
"Alias": "TraderName",
"IsStatic": "false",
"ReturnType": "rdsdk::CRDStringW",
"Comment": "",
"Arguments":
{
"index": {
"Type": "int"
}
}
},
{
"Alias": "TraderDescription",
"IsStatic": "false",
"ReturnType": "rdsdk::CRDStringW",
"Comment": "",
"Arguments":
{
"index": {
"Type": "int"
}
}
},
{
"Alias": "TraderIcon",
"IsStatic": "false",
"ReturnType": "rdsdk::CRDStringW",
"Comment": "",
"Arguments":
{
"index": {
"Type": "int"
}
}
},
{
"Alias": "TraderMoodImage",
"IsStatic": "false",
"ReturnType": "rdsdk::CRDStringW",
"Comment": "",
"Arguments":
{
"index": {
"Type": "int"
}
}
},
{
"Alias": "ExportLevelNameForGood",
"IsStatic": "false",
"ReturnType": "rdsdk::CRDStringW",
"Comment": "Export Good Details",
"Arguments":
{
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "CurrentExportLevelNameForGood",
"IsStatic": "false",
"ReturnType": "rdsdk::CRDStringW",
"Comment": "",
"Arguments":
{
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "LevelName",
"IsStatic": "false",
"ReturnType": "rdsdk::CRDStringW",
"Comment": "",
"Arguments":
{
"level": {
"Type": "int"
}
}
},
{
"Alias": "ExportXPForGood",
"IsStatic": "false",
"ReturnType": "int",
"Comment": "",
"Arguments":
{
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "NeededExportXPForGood",
"IsStatic": "false",
"ReturnType": "int",
"Comment": "",
"Arguments":
{
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "NeededExportXP",
"IsStatic": "false",
"ReturnType": "int",
"Comment": "",
"Arguments":
{
"level": {
"Type": "int"
}
}
},
{
"Alias": "ExportModifierForGood",
"IsStatic": "false",
"ReturnType": "float",
"Comment": "",
"Arguments":
{
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "Modifier",
"IsStatic": "false",
"ReturnType": "float",
"Comment": "",
"Arguments":
{
"level": {
"Type": "int"
}
}
},
{
"Alias": "ModuleUnlocksForGood",
"IsStatic": "false",
"ReturnType": "rdsdk::Vector<CTextSourceListValue>",
"Comment": "",
"Arguments":
{
"areaID": {
"Type": "AreaID"
},
"guid" : {
"Type": "ProductGUID"
}
}
},
{
"Alias": "ModuleUnlocks",
"IsStatic": "false",
"ReturnType": "rdsdk::Vector<CTextSourceListValue>",
"Comment": "",
"Arguments": {
"areaID" : {
"Type": "AreaID"
},
"level": {
"Type": "int"
}
}
},
{
"Alias": "ExportLevelColorForGood",
"IsStatic": "false",
"ReturnType": "rduint",
"Comment": "",
"Arguments": {
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "LevelColor",
"IsStatic": "false",
"ReturnType": "rduint",
"Comment": "",
"Arguments": {
"level": {
"Type": "int"
}
}
},
{
"Alias": "ExchangeRatio",
"IsStatic": "false",
"ReturnType": "rdsdk::CRDStringW",
"Comment": "",
"Arguments": {
"areaID": {
"Type": "AreaID"
},
"index": {
"Type": "int"
}
}
},
{
"Alias": "ProgressForGood",
"IsStatic": "false",
"ReturnType": "float",
"Comment": "returns a float between 0 and 1, representating the progress from the current level to the next level",
"Arguments": {
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "ReachedLevelForProduct",
"IsStatic": "false",
"ReturnType": "int",
"Comment": "returns the \"maximum ever reached\" level for a product",
"Arguments": {
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "IsExportLevel",
"IsStatic": "false",
"ReturnType": "bool",
"Comment": "",
"Arguments": {
"value": {
"Type": "int"
}
}
},
{
"Alias": "ImportLevel",
"IsStatic": "false",
"ReturnType": "int",
"Comment": "",
"Arguments": {
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "IsImporting",
"IsStatic": "false",
"ReturnType": "bool",
"Comment": "Is the good defined as \"import\" in any contract?",
"Arguments": {
"areaID": {
"Type": "AreaID"
},
"guid": {
"Type": "ProductGUID"
}
}
},
{
"Alias": "TraderStatus",
"IsStatic": "false",
"ReturnType": "rdsdk::CRDStringW",
"Comment": "",
"Arguments": {
"areaID": {
"Type": "AreaID"
}
}
}
],
```

try above to maintain contracts import goods


---

```lua
    local _Costs = g_LTL_Serp.GetVectorGuidsFromSessionObject("[ToolOneHelper BuildCost(" .. tostring(GUID) .. ") Costs Count]", { ProductGUID = "integer", Amount = "integer" })
```

consider using the above to detect water objects in the scanner



---

## silent failure: water access point detection

`WaterPoints.Detect` (`mod_map_scanner_hl.lua`) logs `no water access points found, skipping area`
and returns `{}` when an area yields zero water points. Nothing else notices. `Areas_WithWaterPoints`
then drops the area from its return, so the planner simply never sees that island and no route is
ever built for it.

That is exactly how Enbesa stayed broken: every water tile classified as `not_accessible` because
the probe was wrong, three islands silently skipped, no error anywhere. It was only found by reading
the cache files by hand.

An island with land but zero water is not a normal state -- a scanned area you cannot reach by ship
is almost always a broken probe, bad bounds, or too coarse a scan step. Worth notifying the user
rather than logging at the same level as everything else.

Note `mod_map_scanner.lua` now has a measured per-region probe table; a region added without a row
in it falls back to the Old/New World probe, which is precisely the case that fails this way.

## reading a building's PRODUCT costs

The `ToolOneHelper BuildCost(...) Costs Count` note at the end of this file is worth pursuing.
`ts.BuildMode.Costs` is a `CBuildCost` and exposes only money and influence -- `Empty`,
`MoneyCost`, `IsPayable`, `InfluenceCost`, `InfluenceUsageCost`, `InfluencePayback`,
`InfluencePayable`, `HasInfluenceChanges` -- with no product list anywhere on it
(`docs/lua-inspector/ts.BuildMode.yaml:10973-11003`).

That is why identifying Enbesa's quay came down to matching a money value: the Wanza Timber half of
its price is invisible from the Lua side. If the Serp text-source route does return product costs,
it would identify a building by what it actually consumes rather than by a price collision, and
would have settled `117729` vs `1010567` outright.
