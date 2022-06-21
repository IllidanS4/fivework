-- imports

local cor = coroutine
local cor_create = cor.create
local cor_resume = cor.resume
local cor_yield = cor.yield
local cor_running = cor.running
local cor_status = cor.status
local error = _ENV.error
local assert = _ENV.assert
local tostring = _ENV.tostring
local rawset = _ENV.rawset
local pcall = _ENV.pcall
local xpcall = _ENV.xpcall
local ipairs = _ENV.ipairs
local setmetatable = _ENV.setmetatable
local type = _ENV.type
local t_pack = table.pack
local t_unpack_orig = table.unpack
local t_insert = table.insert
local t_concat = table.concat
local d_getinfo = debug.getinfo
local d_getlocal = debug.getlocal
local d_traceback = debug.traceback
local m_huge = math.huge

local GetHashKey = _ENV.GetHashKey
local GetGameTimer = _ENV.GetGameTimer

local Cfx_SetTimeout = Citizen.SetTimeout
local Cfx_CreateThread = Citizen.CreateThread
local Cfx_Await = Citizen.Await

local function t_unpack(t, i)
  return t_unpack_orig(t, i or 1, t.n)
end

-- configuration

FW_ErrorLog = print

local monitor_interval = 100

function FW_SetTimeMonitor(interval)
  monitor_interval = interval
end

do
  local stackdump_mt = {}

  function FW_Traceback(thread, message, level)
    local thread_type = type(thread)
    if thread_type == 'table' and getmetatable(thread) == stackdump_mt then
      return message
    end
    if thread_type == 'thread' then
      level = (level or 1) + 1
    else
      message = (message or 1) + 1
    end
    return d_traceback(thread, message, level)
  end

  function FW_StackDump(thread, level)
    level = level or 1
    
    local data = setmetatable({}, stackdump_mt)
    
    for i = level + 1, m_huge do
      local info = thread and d_getinfo(thread, i, 'nlStuf') or d_getinfo(i, 'nlStuf')
      if not info then
        break
      end
      t_insert(data, info)
      
      local args = {}
      info.args = args
      
      local function add_arg(j)
        local name, value
        if thread then name, value = d_getlocal(thread, i + 1, j) else name, value = d_getlocal(i + 1, j) end
        if not name then
          return false
        end
        t_insert(args, {name, value})
        return true
      end
      
      for j = 1, what == 'C' and m_huge or info.nparams do
        if not add_arg(j) then break end
      end
      
      if info.isvararg then
        local args_over = 0
        for j = -1, -m_huge, -1 do
          if not add_arg(j) then break end
          if j < -8 then
            args[#args] = nil
            args_over = args_over + 1
          end
        end
        info.args_over = args_over
      end
    end
    
    return data
  end
  
  local string_escape_pattern = "([\"\\\a\b\f\n\r\t\v])"
  local string_escapes = {
    ["\""]="\\\"", ["\\"]="\\\\",
    ["\a"]="\\a", ["\b"]="\\b", ["\f"]="\\f", ["\n"]="\\n", ["\r"]="\\r", ["\t"]="\\t", ["\v"]="\\v"
  }
  
  function FW_PrettyTraceback(thread, message, level)
    local thread_type = type(thread)
    local is_dump = thread_type == 'table' and getmetatable(thread) == stackdump_mt
    if thread_type ~= 'thread' and not is_dump then
      message, level = thread, message
      thread = nil
    end
    
    if message ~= nil and type(message) ~= 'string' then
      return message
    end
    
    level = level or 1
    
    local data = is_dump and thread or FW_StackDump(thread, level + 1)
    
    local lines = {}
    if message then
      t_insert(lines, message)
    end
    
    for i, info in ipairs(data) do
      if i >= level then
        local func = info.func
        
        if func == pcall or func == xpcall then
          break
        end
        
        if func ~= error and func ~= assert then
          local what, name, namewhat = info.what, info.name, info.namewhat
          if not name then
            if what == 'main' then
              name = "<"..what..">"
            elseif func then
              name = tostring(func):gsub('^function: 0?x?0*', '$')
              namewhat = nil
            end
          end
          
          local args = {}
          
          for i, v in ipairs(info.args) do
            local name, value = t_unpack(v)
            local value_type = type(value)
            if value_type == 'nil' or value_type == 'boolean' or value_type == 'number' then
              value = tostring(value)
            elseif value_type == 'string' then
              if #value > 32 then
                value = value:sub(1, 29)
                value = "\""..value:gsub(string_escape_pattern, string_escapes).."\"..."
              else
                value = "\""..value:gsub(string_escape_pattern, string_escapes).."\""
              end
            else
              value = tostring(value):gsub('^'..value_type..': 0?x?0*', '$')
              value = value_type.."("..value..")"
            end
            local str
            if name:sub(1, 1) == '(' then
              str = value
            else
              str = name.." = "..value
            end
            t_insert(args, str)
          end
          
          local args_over = info.args_over
          if args_over and args_over > 0 then
            t_insert(args, "... ("..args_over.." more)")
          end
          
          local location = info.short_src
          local line, linestart, lineend = info.currentline, info.linedefined, info.lastlinedefined
          if line and line >= 0 then
            location = location..":"..line
          elseif linestart and linestart >= 0 then
            location = location..":"..linestart..".."..lineend
          end
          
          local fields = {"at", name.."("..t_concat(args, ", ")..")"}
          t_insert(fields, "in")
          t_insert(fields, location)
          if info.istailcall then
            t_insert(fields, "(tail call)")
          end
          t_insert(lines, t_concat(fields, " "))
        end
      end
    end
    return t_concat(lines, "\n")
  end
end

-- async processing

local active_threads = setmetatable({}, {
  __mode = 'k'
})

local function thread_func(func, ...)
  return xpcall(func, FW_Traceback, ...)
end

local function function_info(func)
  local info = d_getinfo(func)
  return "running "..info.what.." function "..info.namewhat.." in "..info.short_src..":"..info.linedefined..".."..info.lastlinedefined
end

local function check_time(start_time, func, thread)
  if monitor_interval then
    local time = GetGameTimer()
    if time > start_time + monitor_interval then
      local traceback
      if cor_status(thread) ~= 'dead' then
        traceback = FW_Traceback(thread)
      else
        local ok
        ok, traceback = pcall(function_info, func)
      end
      FW_ErrorLog("Warning: coroutine code took", time - start_time, "ms to execute:\n", traceback)
    end
  end
end

function FW_Async(func, ...)
  local thread = cor_create(thread_func)
  active_threads[thread] = true
  local on_yield
  local function schedule(scheduler, ...)
    return scheduler(function(...)
      return on_yield(GetGameTimer(), cor_resume(thread, ...))
    end, ...)
  end
  on_yield = function(start_time, status, ok_or_scheduler, ...)
    check_time(start_time, func, thread)
    if not status then
      active_threads[thread] = nil
      return false, FW_ErrorLog("Unexpected error from coroutine:\n", ok_or_scheduler, ...)
    end
    if cor_status(thread) ~= 'dead' then
      return false, schedule(ok_or_scheduler, ...)
    end
    active_threads[thread] = nil
    if not ok_or_scheduler then
      return false, FW_ErrorLog("Error from coroutine:\n", ...)
    end
    return true, ...
  end
  return on_yield(GetGameTimer(), cor_resume(thread, func, ...))
end
local FW_Async = _ENV.FW_Async

function FW_IsAsync()
  return active_threads[cor_running()] or false
end
local FW_IsAsync = _ENV.FW_IsAsync

function FW_Schedule(scheduler, ...)
  if not FW_IsAsync() then
    return error("attempted to perform asynchronous operation from non-asynchronous context; use FW_Async")
  end
  return cor_yield(scheduler, ...)
end

local function immediate(done, ...)
  return ...
end

local function log_error(status, ...)
  if status then
    return status, ...
  end
  return false, FW_ErrorLog("Error from handler:\n", ...)
end

local function call_or_wrap_async(func, ...)
  if FW_IsAsync() then
    return log_error(xpcall(func, FW_Traceback, ...))
  else
    return FW_Async(func, ...)
  end
end

do
  local GetCurrentResourceName = _ENV.GetCurrentResourceName
  AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
      call_or_wrap_async = function(func, ...)
        return log_error(xpcall(func, FW_Traceback, ...))
      end
      local function disabled()
        return error('this function cannot be used while the script is stopping')
      end
      cor_create = disabled
      cor_resume = disabled
      Cfx_SetTimeout = disabled
      Cfx_CreateThread = disabled
      Cfx_Await = disabled
    end
  end)
end

local function sleep_scheduler(func, ms, ...)
  return Cfx_SetTimeout(ms, function(...)
    func(...)
  end, ...)
end

function Sleep(...)
  return FW_Schedule(sleep_scheduler, ...)
end
local Sleep = _ENV.Sleep

local function handle_yield_result(args, done, ...)
  if done then
    return ...
  else
    return t_unpack(args)
  end
end

local function yield_scheduler(func, args)
  return handle_yield_result(args, func())
end

function Yield(...)
  return FW_Schedule(yield_scheduler, t_pack(...))
end

local function threaded_scheduler(func, threadFunc, args)
  return Cfx_CreateThread(function()
    return func(threadFunc(t_unpack(args)))
  end)
end

function FW_Threaded(func, ...)
  return FW_Schedule(threaded_scheduler, func, t_pack(...))
end

local function on_next(obj, onresult, onerror)
  local result = obj.__result
  if result then
    if result[1] then
      if onresult then
        onresult(t_unpack(result, 2))
      end
    else
      if onerror then
        onerror(t_unpack(result, 2))
      end
    end
  else
    local cont = obj.__cont
    if not cont then
      cont = {}
      obj.__cont = cont
    end
    t_insert(cont, {onresult, onerror})
  end
  return obj
end

local function make_promise(func, ...)
  local obj = {next = on_next}
  return obj, FW_Async(function(...)
    local result = t_pack(pcall(func, ...))
    obj.__result = result
    local cont = obj.__cont
    if cont then
      obj.__cont = nil
      for i, c in ipairs(cont) do
        local onresult, onerror = c[1], c[2]
        if result[1] then
          if onresult then
            onresult(t_unpack(result, 2))
          end
        else
          if onerror then
            onerror(t_unpack(result, 2))
          end
        end
      end
    end
  end, ...)
end

function FW_Awaited(func, ...)
  return Cfx_Await(make_promise(func, ...))
end

-- events

local registered_events = {}

public = setmetatable({}, {
  __newindex = function(self, key, value)
    if not registered_events[key] then
      registered_events[key] = FW_CreateCallbackHandler(key, function(...)
        local func = self[key]
        if func then
          return immediate(FW_Async(func, ...))
        end
      end)
    end
    return rawset(self, key, value)
  end
})
local public = _ENV.public

function FW_TriggerCallback(name, ...)
  local handler = public[name]
  if handler then
    return immediate(call_or_wrap_async(handler, ...))
  end
end
local FW_TriggerCallback = _ENV.FW_TriggerCallback

-- commands

local registered_commands = {}

local function after_command(source, rawCommand, status, ...)
  local result = FW_TriggerCallback('OnPlayerPerformedCommand', source, rawCommand, status, ...)
  if not status and not result then
    return FW_ErrorLog("Error from command '"..tostring(rawCommand).."':\n", ...)
  end
end

local function call_command(source, args, result, ...)
  if result == true then
    return after_command(source, args, xpcall(args.handler, FW_Traceback, source, args, ...))
  elseif result ~= false then
    return after_command(source, args, xpcall(args.handler, FW_Traceback, source, args, t_unpack(args)))
  end
end

local command_mt = {
  __tostring = function(self)
    return self.raw or ""
  end,
  __index = function(self, key)
    local raw = self.raw
    if type(raw) == 'string' then
      local value
      if key == 'rawName' then
        local pos, _, match = raw:find('^%s*([^%s]+)%s*')
        if pos then
          value = match
        end
      elseif key == 'rawArgs' then
        value = raw:gsub('^%s*[^%s]+%s*', '')
      end
      rawset(self, key, value)
      return value
    end
  end
}

local function cmd_newindex(restricted)
  return function(self, key, value)
    if not registered_commands[key] then
      registered_commands[key] = RegisterCommand(key, function(source, args, rawCommand)
        local func = self[key]
        if func then
          args.raw = rawCommand
          args.handler = func
          args.name = key
          setmetatable(args, command_mt)
          return immediate(FW_Async(function(...)
            Sleep(0)
            return call_command(source, args, FW_TriggerCallback('OnPlayerReceivedCommand', source, args, ...))
          end, t_unpack(args)))
        end
      end, restricted)
    end
    return rawset(self, key, value)
  end
end

cmd = setmetatable({}, {
   __newindex = cmd_newindex(false)
})

cmd_ac = setmetatable({}, {
   __newindex = cmd_newindex(true)
})

local cmd, cmd_ac = _ENV.cmd, _ENV.cmd_ac

function FW_TriggerCommand(name, ...)
  local handler = cmd[name] or cmd_ac[name]
  if handler then
    return immediate(call_or_wrap_async(handler, ...))
  end
end

-- misc

local TriggerEvent = _ENV.TriggerEvent
local TriggerServerEvent = _ENV.TriggerServerEvent
local TriggerClientEvent = _ENV.TriggerClientEvent
local WasEventCanceled = _ENV.WasEventCanceled

do
  local function event_table(trigger, prefix, separator, parent)
    return setmetatable({}, {
      __call = function(self, arg, ...)
        if arg == parent then
          trigger(prefix, ...)
        else
          trigger(prefix, arg, ...)
        end
        return not WasEventCanceled()
      end,
      __index = function(self, key)
        local t = event_table(trigger, prefix..separator..key, separator, self)
        rawset(self, key, t)
        return t
      end
    })
  end
  
  function EventsFor(prefix, separator)
    return event_table(TriggerEvent, prefix, separator)
  end
  
  if TriggerServerEvent then
    function ServerEventsFor(prefix, separator)
      return event_table(TriggerServerEvent, prefix, separator)
    end
  end
  
  if TriggerClientEvent then
    function ClientEventsFor(playerid, prefix, separator)
      return event_table(function(name, ...)
        return TriggerClientEvent(name, playerid, ...)
      end, prefix, separator)
    end
  end
end

local AddEventHandler = _ENV.AddEventHandler
local CancelEvent = _ENV.CancelEvent
do
  local function create_event_cache(registerer)
    return setmetatable({}, {
      __mode = 'k',
      __index = function(self, func)
        local name = 'fivework_func:'..tostring(func)
        registerer(name, function(...)
          local result = immediate(FW_Async(func, ...))
          if result == false then
            CancelEvent()
          end
        end)
        rawset(self, func, name)
        return name
      end
    })
  end

  local event_cache = create_event_cache(AddEventHandler)
  
  function GetFunctionEvent(func)
    return event_cache[func]
  end
end