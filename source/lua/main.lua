local logger = f.log.new("test")
logger:info("this will work")

local a = 1
local b = nil

local c = a + b

logger:info(c)


    