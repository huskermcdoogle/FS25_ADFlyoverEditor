-- Sourced by Prelude.lua for one purpose: to discover which Lua environment a runtime source()
-- call actually lands in. FS25 sets a mod environment during mod load; whether it does so for a
-- source() issued from an update() tick is undocumented, and getting it wrong publishes the
-- editor's globals somewhere this mod cannot see them.
--
-- It answers via the ROOT table rather than a global of its own, because a global of its own would
-- be just as unreachable as the problem it is diagnosing. getfenv(0) is the same table from every
-- environment, so the answer always comes back.
getfenv(0).__ADFlyoverEnvProbe = getfenv(1)
