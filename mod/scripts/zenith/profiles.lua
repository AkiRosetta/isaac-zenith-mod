-- 各把剑的外观配置，数值取自泰拉原版 FinalFractalHelper：刀身长度（泰拉像素）和拖尾颜色。
-- 所有剑伤害相同，只有外观不同。

local Profiles = {}

local ZENITH = 4956

-- 顺序与原版字典一致，随机抽取时使用
local LIST = {
    { id = 65,   name = "Starfury",             blade = 48, color = { 236, 62, 192 } },
    { id = 1123, name = "Bee Keeper",           blade = 48, color = { 255, 231, 69 } },
    { id = 46,   name = "Light's Bane",         blade = 48, color = { 122, 66, 191 } },
    { id = 121,  name = "Volcano",              blade = 76, color = { 254, 158, 35 } },
    { id = 190,  name = "Blade of Grass",       blade = 70, color = { 107, 203, 0 } },
    { id = 368,  name = "Excalibur",            blade = 70, color = { 236, 200, 19 } },
    { id = 674,  name = "True Excalibur",       blade = 70, color = { 236, 200, 19 } },
    { id = 273,  name = "Night's Edge",         blade = 70, color = { 179, 54, 201 } },
    { id = 675,  name = "True Night's Edge",    blade = 70, color = { 179, 54, 201 } },
    { id = 2880, name = "Influx Waver",         blade = 70, color = { 84, 234, 245 } },
    { id = 989,  name = "Enchanted Sword",      blade = 48, color = { 91, 158, 232 } },
    { id = 1826, name = "The Horseman's Blade", blade = 76, color = { 252, 95, 4 } },
    { id = 3063, name = "Meowmere",             blade = 76, color = { 254, 194, 250 } },
    { id = 3065, name = "Star Wrath",           blade = 70, color = { 237, 63, 133 } },
    { id = 757,  name = "Terra Blade",          blade = 70, color = { 80, 222, 122 } },
    { id = 155,  name = "Muramasa",             blade = 70, color = { 56, 78, 210 } },
    { id = 795,  name = "Blood Butcherer",      blade = 70, color = { 237, 28, 36 } },
    { id = 3018, name = "Seedler",              blade = 80, color = { 143, 215, 29 } },
    { id = 4144, name = "Terragrim",            blade = 45, color = { 178, 255, 180 } },
    { id = 3507, name = "Copper Shortsword",    blade = 45, color = { 235, 166, 135 } },
    { id = ZENITH, name = "Zenith",             blade = 86, color = { 178, 255, 180 } },
}

local byId = {}
for _, p in ipairs(LIST) do
    p.anm2 = "gfx/zenith/sword_" .. p.id .. ".anm2"
    p.r, p.g, p.b = p.color[1] / 255, p.color[2] / 255, p.color[3] / 255
    byId[p.id] = p
end

-- 联动换成的原版模型（不参与随机抽取）。blade 只用于拖尾宽度和刀尖星闪位置；
-- model：anim = 播放的动画，rotation = 刀尖朝右时精灵要转的角度，scale = 绘制倍率，tipOffset = 精灵中心点到刀身中点的距离（屏幕像素，沿刀尖方向）
local C = include("scripts.zenith.config")
local function special(id, name, blade, anm2, color, model)
    byId[id] = {
        id = id, name = name, blade = blade, anm2 = anm2, model = model,
        r = color[1] / 255, g = color[2] / 255, b = color[3] / 255,
    }
end
Profiles.KNIFE, Profiles.SPIRIT_SWORD, Profiles.SWORD_BEAM = "knife", "spirit", "beam"
special(Profiles.KNIFE, "Mom's Knife", 60, C.KNIFE_ANM2, C.KNIFE_COLOR, { anim = "Idle", rotation = -90, scale = C.KNIFE_SCALE, tipOffset = 0 })
special(Profiles.SPIRIT_SWORD, "Spirit Sword", 90, C.SPIRIT_SWORD_ANM2, C.SPIRIT_SWORD_COLOR,
    { anim = "IdleRight", rotation = -90, scale = C.SPIRIT_SWORD_SCALE, tipOffset = 20 })
special(Profiles.SWORD_BEAM, "Sword Beam", 90, C.SWORD_BEAM_ANM2, C.SWORD_BEAM_COLOR,
    { anim = "Idle", rotation = 0, scale = C.SWORD_BEAM_SCALE, tipOffset = 0 })

Profiles.ZENITH = ZENITH
Profiles.LIST = LIST

function Profiles.Get(id)
    return byId[id] or byId[ZENITH]
end

-- 与原版一致：抽到天顶剑本体时重抽一次（本体仍有极小概率出现）
function Profiles.RandomId(rng)
    local index = rng:RandomInt(#LIST) + 1
    if LIST[index].id == ZENITH then
        index = rng:RandomInt(#LIST - 1) + 1
    end
    return LIST[index].id
end

return Profiles
