local NetworkGetEntityFromNetworkId = _ENV.NetworkGetEntityFromNetworkId
local t_unpack = table.unpack

FW_RegisterCallback('OnEntityCreated', 'entityCreated')
FW_RegisterCallback('OnEntityCreating', 'entityCreating')
FW_RegisterCallback('OnResourceStart', 'onResourceStart')
FW_RegisterCallback('OnResourceStop', 'onResourceStop')
FW_RegisterServerCallback('OnPlayerConnect', 'fivework:PlayerActivated', true)
FW_RegisterCallback('OnPlayerDisconnect', 'playerDropped', true)
FW_RegisterCallback('OnIncomingConnection', 'playerConnecting', true)
FW_RegisterServerCallback('OnPlayerEnterVehicle', 'baseevents:enteredVehicle', true, function(source, localid, seat, modelkey, networkid, ...)
  return source, NetworkGetEntityFromNetworkId(networkid), seat, networkid, localid, modelkey, ...
end)
FW_RegisterServerCallback('OnPlayerExitVehicle', 'baseevents:leftVehicle', true, function(source, localid, seat, modelkey, networkid, ...)
  return source, NetworkGetEntityFromNetworkId(networkid), seat, networkid, localid, modelkey, ...
end)
FW_RegisterNetCallback('OnPlayerInit')
FW_RegisterNetCallback('OnPlayerSpawn')
FW_RegisterNetCallback('OnGameEvent', function(source, name, args)
  return source, name, t_unpack(args)
end)
FW_RegisterNetCallback('OnPlayerKeyStateChange')

FW_RegisterCallback('OnPlayerText', 'chatMessage', false, function(source, author, message, ...)
  return source, message, author, ...
end)

FW_RegisterPlainCallback('OnPlayerDeath')
FW_RegisterNetCallback('OnPlayerUpdate')
FW_RegisterPlainCallback('OnPlayerReceivedCommand')
FW_RegisterPlainCallback('OnPlayerPerformedCommand')
FW_RegisterPlainCallback('OnScriptInit')
FW_RegisterPlainCallback('OnScriptExit')

AddEventHandler('onResourceStart', function(resource)
  if resource == GetCurrentResourceName() then
    FW_TriggerCallback('OnScriptInit')
  end
end)

AddEventHandler('onResourceStop', function(resource)
  if resource == GetCurrentResourceName() then
    FW_TriggerCallback('OnScriptExit')
  end
end)

RegisterServerEvent('baseevents:onPlayerDied')
AddEventHandler('baseevents:onPlayerDied', function(killertype, killerpos)
  FW_TriggerCallback('OnPlayerDeath', source, killertype, nil, killerpos, {})
end)

RegisterServerEvent('baseevents:onPlayerKilled')
AddEventHandler('baseevents:onPlayerKilled', function(killerid, data)
  local killertype, killerpos = data.killertype, data.killerpos
  data.killertype, data.killerpos = nil, nil
  FW_TriggerCallback('OnPlayerDeath', source, killertype, killerid, killerpos, data)
end)
