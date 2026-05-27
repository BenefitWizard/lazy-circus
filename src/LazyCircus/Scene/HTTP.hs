--   PURPOSE: Re-export the public HTTP scripting language so backend scripts can depend on a stable facade instead of the underlying algebra module.
--   SCOPE: Public re-exports for the HTTP language functor, smart constructors, and script alias used by backend scripts.
--   DEPENDS: M-LIB-SCENE-HTTP-LANG

-- | Stable facade for the HTTP scripting language used across backend scripts.
module LazyCircus.Scene.HTTP (
    HTTPLangF (..),
    runClient,
    HTTPScript,
    -- Logging re-exports
    slogInfo,
    slogWarn,
    slogError,
    slogSensitive,
    swithLogCtx,
) where

import LazyCircus.Scene.HTTP.Lang (HTTPLangF (..))


import LazyCircus.Scene.HTTP.Lang (runClient)


import LazyCircus.Scene.HTTP.Lang (HTTPScript)


import LazyCircus.Scene.Log (slogError, slogInfo, slogSensitive, slogWarn, swithLogCtx)
