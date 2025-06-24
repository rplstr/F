package.path = "source/lua/?.lua;" .. package.path

local event = require "event"
local logger = f.log.new("demo")

logger:info("hi")

event.on(f.event.Kind.key_down, function(ev)
    if ev.p0 == f.input.Key.f then
        logger:info("F pressed")
    end
end)

function update()
    event.dispatch()
end
