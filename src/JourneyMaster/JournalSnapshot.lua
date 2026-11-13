-- JourneyMaster journal snapshot. Shipped empty; the app on your PC replaces this file with the summaries of your play
-- sessions, and the game reads it at the next /reload or login. Keep it when updating the add-on.
local _, ns = ...
ns.journalSnapshot = {
    schema = 1,
    revision = 0,
    written = 0,
    characters = {},
}
