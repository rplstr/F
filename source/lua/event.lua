local registry = {}

local function add_handler(kind, fn)
    assert(type(fn) == "function", "handler must be function")
    if type(kind) == "table" then
        for i = 1, #kind do
            add_handler(kind[i], fn)
        end
        return
    end
    assert(type(kind) == "number", "kind must be enum value or list")
    local list = registry[kind]
    if not list then
        list = {}
        registry[kind] = list
    end
    list[#list + 1] = fn
end

local M = {}

function M.on(kind, fn)
    add_handler(kind, fn)
end

function M.dispatch()
    local evs = f.event.poll()
    for i = 1, #evs do
        local ev = evs[i]
        local list = registry[ev.kind]
        if list then
            for j = 1, #list do
                list[j](ev)
            end
        end
    end
end

return M
