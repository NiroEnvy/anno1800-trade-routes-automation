local Anno = require("trade_route_automation/anno_interface");
local AnnoInfo = require("trade_route_automation/generator/products");

local AreaRequests = {
    __Internal = {
        ProductGUID_Unknown = {},
    }
};

function AreaRequests.Population(L, region)
    local ret = {};
    local q = Anno.Region_ResidenceGUIDs(region);
    for areaID, residenceGUIDs in pairs(q) do
        for _, guid in pairs(residenceGUIDs) do
            local residence = AnnoInfo.Residence(L, region, tonumber(guid));
            if residence == nil or residence.Request == nil then
                L.logf("Warning: Residence GUID %d not found in AnnoInfo.ResidencesInfo", tonumber(guid));
                goto continue;
            end
            for _, product in pairs(residence.Request) do
                local areaID_num = tonumber(areaID);
                if ret[areaID_num] == nil then
                    ret[areaID_num] = {};
                end
                if ret[areaID_num][product.Guid] == nil then
                    ret[areaID_num][product.Guid] = {};
                end
                table.insert(ret[areaID_num][product.Guid], {
                    type = "Population",
                    name = residence.Name or ("GUID:" .. tostring(guid))
                });
            end
            :: continue ::
        end
    end
    return ret;
end

function AreaRequests.Production(L, region)
    local ret = {};
    local q = Anno.Region_ProductionGUIDs(region);
    for areaID, productionGUIDs in pairs(q) do
        for _, guid in pairs(productionGUIDs) do
            local production = AnnoInfo.Factory(L, region, guid);
            if production == nil then
                if AreaRequests.__Internal.ProductGUID_Unknown[tonumber(guid)] == nil then
                    AreaRequests.__Internal.ProductGUID_Unknown[tonumber(guid)] = true;
                    L.logf("Warning: Production GUID %d not found in AnnoInfo.FactoriesInfo", tonumber(guid));
                end
                goto continue;
            end

            for _, product in pairs(production.Consumption) do
                local areaID_num = tonumber(areaID);
                if ret[areaID_num] == nil then
                    ret[areaID_num] = {};
                end
                if ret[areaID_num][tonumber(product.Guid)] == nil then
                    ret[areaID_num][tonumber(product.Guid)] = {};
                end
                table.insert(ret[areaID_num][tonumber(product.Guid)], {
                    type = "Production",
                    name = production.Name or ("GUID:" .. tostring(guid))
                });
            end

            :: continue ::
        end
    end
    return ret;
end

--- The goods every island needs in order to BUILD, as opposed to to live or to produce. Module
--- level because the `(hc)` hub marker means "bring construction goods here" and needs the same
--- list -- see TradePlannerLL.Hubs.
AreaRequests.ConstructionGoods = {
    120008,  -- Wood
    1010196, -- Timber
    1010205, -- Bricks
    1010218, -- Steel Beams
    1010207, -- Windows
    1010202, -- Reinforced Concrete
    134623,  -- Elevator
    1010224, -- Steam Motors
    838,     -- Aluminium Profiles
};

--- What a particular region builds with ON TOP of the nine above. Enbesa's two building materials
--- are useless anywhere else, so a region-wide list would have the Old World standing around
--- asking for timber it cannot lay a brick with.
---
--- Additive rather than replacing, deliberately: Enbesa's higher tiers still want Steel Beams and
--- Windows, and its harbour buildings still want Wood and Bricks. Dropping goods from an island's
--- list stops deliveries that currently work, which is the worse way to be wrong -- asking for
--- something an island rarely uses costs nothing, because no surplus means no voyage.
local CONSTRUCTION_GOODS_EXTRA = {
    [Anno.Region_Enbesa] = {
        114356, -- Wanza Timber
        114402, -- Mud Bricks
    },
};

--- KNOWN GAP, scoped out rather than overlooked: `TradePlannerLL.Hubs` resolves the `(hc)` marker
--- off `AreaRequests.ConstructionGoods` above and has no region in hand, so an `(hc)` hub in
--- Enbesa collects the base nine and not these two. Only the base request path is region-aware.
---@param region RegionID|nil  nil yields the base list, which is also what an unlisted region gets
---@return ProductGUID[]
function AreaRequests.ConstructionGoodsFor(region)
    local extra = nil;
    if region ~= nil then
        extra = CONSTRUCTION_GOODS_EXTRA[region];
    end
    if extra == nil then
        return AreaRequests.ConstructionGoods;
    end

    local ret = {};
    for _, guid in ipairs(AreaRequests.ConstructionGoods) do
        table.insert(ret, guid);
    end
    for _, guid in ipairs(extra) do
        table.insert(ret, guid);
    end
    return ret;
end

function AreaRequests.Construction(L, region)
    local ret = {};
    local areas = Anno.Region_AreaID_To_OID(region);

    local _constructionGoods = AreaRequests.ConstructionGoodsFor(region);

    for areaID, areaOID in pairs(areas) do
        areaID = tonumber(areaID);
        if ret[areaID] == nil then
            ret[areaID] = {};
        end

        for _, guid in pairs(_constructionGoods) do
            ret[areaID][guid] = { {
                type = "Construction",
            } }
        end
    end
    return ret;
end

function AreaRequests.TradeUnionAlikeReplacements(L, region)
    local ret = {};
    local buildings = Anno.Region_BuildingsWithSockets(region);
    for areaIdStr, items in pairs(buildings) do
        local areaID = tonumber(areaIdStr);
        for _, socketItemGuid in pairs(items) do
            local reps = Anno.SocketItemGuidsToInputReplacements(socketItemGuid);
            if #(reps) == 0 then
                goto continue;
            end
            if ret[areaID] == nil then
                ret[areaID] = {};
            end
            for _, rep in pairs(reps) do
                local productGuid = tonumber(rep.Guid);
                if ret[areaID][productGuid] == nil then
                    ret[areaID][productGuid] = {};
                end
                table.insert(ret[areaID][productGuid], {
                    type = "TradeUnion",
                    name = tostring(socketItemGuid)
                });
            end
            :: continue ::
        end
    end
    return ret;
end

function AreaRequests.All(L, region)
    local population = AreaRequests.Population(L, region);
    local production = AreaRequests.Production(L, region);
    local construction = AreaRequests.Construction(L, region);
    local tu = AreaRequests.TradeUnionAlikeReplacements(L, region);

    local rs = { population, production, construction, tu };

    local ret = {};
    for _, r in pairs(rs) do
        for areaID, products in pairs(r) do
            if ret[areaID] == nil then
                ret[areaID] = {};
            end
            for productGuid, infos in pairs(products) do
                if ret[areaID][productGuid] == nil then
                    ret[areaID][productGuid] = {};
                end
                for _, info in pairs(infos) do
                    table.insert(ret[areaID][productGuid], info);
                end
            end
        end
    end
    return ret;
end

return AreaRequests;
