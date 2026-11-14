-- JourneySizeProbe, first file: the clock and the list of time stamps.
-- Every generated data file begins with ns.Stamp(name). The time between one stamp and the one before it is the time the
-- game needed to read and compile that file (the file before it only runs one cheap assignment).
--
-- Abbreviations: SV = SavedVariables. KB = kilobytes (1,024 bytes).
local _, ns = ...
ns.text = {}      -- level name -> the text, filled by the generated data files
ns.stamps = {}    -- { name, t (milliseconds), mem (KB of Lua memory in use) } in the order the files loaded
ns.now = debugprofilestop or function() return GetTime() * 1000 end
function ns.Stamp(name)
    ns.stamps[#ns.stamps + 1] = { name = name, t = ns.now(), mem = collectgarbage("count") }
end
ns.Stamp("start")
