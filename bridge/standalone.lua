-- Standalone: Zugriff nur ueber die ACE-Permission (Config.AcePermission),
-- Name und Identifier kommen aus den Fallbacks in Bridge.getOfficer.
Bridge.register('standalone', {
    server = function() return {} end,
    client = function() return {} end,
})
