-- LockOnGuard configuration
-- Edit these values, then restart the game (or the mod via the UE4SS GUI).

return {
    -- Master switch on load. Also "lockonguard on|off" in the console.
    Enabled = true,

    -- States in which rotation is left to the game even while guard is held.
    SkipTags = {
        "Ability.State.Attack",
        "Ability.State.Hit",
        "Ability.State.Down",
        "Ability.State.Dead",
        "Ability.State.Stun",
        "Ability.State.Tsubazeri",
        "Ability.State.Move.Dodge",
        "Ability.State.Move.Jump",
        "Ability.State.InAir",
        "Ability.State.Attached",
        "Ability.State.JustPowerGuard",
    },

    -- Print state changes to the UE4SS console.
    Debug = false,
}
