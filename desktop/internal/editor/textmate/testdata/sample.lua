-- A comment
--[[ A block
comment ]]
local M = {}
local count = 0x1F + 1.5e3

function M.greet(name, ...)
  local greeting = "Hello, " .. (name or 'world') .. "\n"
  if #greeting > 10 and not false then
    print(greeting)
  end
  for i = 1, 10 do
    count = count + i
  end
  return setmetatable({}, { __index = M })
end

local s = [[long
string]]
return M
