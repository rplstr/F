package.path = "source/lua/?.lua;" .. package.path

local event = require "event"
local logger = f.log.new("demo")

local ecs = f.ecs


local root = ecs.create()
logger:info("created root entity " .. root)

local Comp = f.ecs.comp
local POS  = Comp.position

ecs.set_comp(root, POS, { x = 0, y = 0 })

local spawn_count = 0

local acc = 0
ecs.register_system(function(dt)
    acc = acc + dt
    if acc >= 1.0 then
        local all = ecs.entities()
        logger:info("alive entities: " .. #all)
        local pos = ecs.get_comp(root, POS)
        if pos then
            pos.x = pos.x + 1
            logger:info(string.format("root position: (%.1f, %.1f)", pos.x, pos.y))
        end
        acc = 0
    end 
end, 0)

event.on(f.event.Kind.key_down, function(ev)
    if ev.p0 == f.input.Key.f then
        local child = ecs.create()
        ecs.set_parent(child, root)

        ecs.set_comp(child, POS, { x = spawn_count, y = 0 })
        spawn_count = spawn_count + 1
        logger:info("spawned child #" .. spawn_count .. " handle " .. child)
    end
    if ev.p0 == f.input.Key.f then
        logger:info("F pressed")
    end
end)

event.on({
    f.event.Kind.component_add,
    f.event.Kind.component_set,
    f.event.Kind.component_remove
}, function(ev)
    local ent_idx = ev.p0
    local ent_gen = ev.p1
    local kind = ev.kind == f.event.Kind.component_add and "add"
        or ev.kind == f.event.Kind.component_set and "set"
        or "remove"
    logger:info(string.format("entity %d (gen %d) %s component id 0x%x%08x", ent_idx, ent_gen, kind, ev.p3, ev.p2))
end)

function update()
    event.dispatch()
end
