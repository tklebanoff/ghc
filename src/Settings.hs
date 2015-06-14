{-# LANGUAGE FlexibleInstances #-}

module Settings (
    settings, ways, packages,

    cabalSettings, ghcPkgSettings
    ) where

import Base hiding (arg, args, Args)
import Oracles.Builder
import Ways
import Util
import Targets
import Package
import Switches
import Oracles.Base
import Settings.Util
import UserSettings
import Expression hiding (when, liftIO)

settings :: Settings
settings = defaultSettings <> userSettings

ways :: Ways
ways = targetWays <> userWays

packages :: Packages
packages = targetPackages <> userPackages

defaultSettings :: Settings
defaultSettings = do
    stage <- asks getStage
    mconcat [ builder GhcCabal ? cabalSettings
            , builder (GhcPkg stage) ? ghcPkgSettings ]

-- Builder settings

-- TODO: Isn't vanilla always built? If yes, some conditions are redundant.
librarySettings :: Settings
librarySettings = do
    ways            <- fromDiff Settings.ways
    ghcInterpreter  <- ghcWithInterpreter
    dynamicPrograms <- dynamicGhcPrograms
    append [ if vanilla `elem` ways
             then  "--enable-library-vanilla"
             else "--disable-library-vanilla"
           , if vanilla `elem` ways && ghcInterpreter && not dynamicPrograms
             then  "--enable-library-for-ghci"
             else "--disable-library-for-ghci"
           , if profiling `elem` ways
             then  "--enable-library-profiling"
             else "--disable-library-profiling"
           , if dynamic `elem` ways
             then  "--enable-shared"
             else "--disable-shared" ]

configureSettings :: Settings
configureSettings = do
    let conf key = appendSubD $ "--configure-option=" ++ key
    stage <- asks getStage
    mconcat
        [ conf "CFLAGS"   ccSettings
        , conf "LDFLAGS"  ldSettings
        , conf "CPPFLAGS" cppSettings
        , appendSubD "--gcc-options" $ ccSettings <> ldSettings
        , conf "--with-iconv-includes"  $ argConfig "iconv-include-dirs"
        , conf "--with-iconv-libraries" $ argConfig "iconv-lib-dirs"
        , conf "--with-gmp-includes"    $ argConfig "gmp-include-dirs"
        , conf "--with-gmp-libraries"   $ argConfig "gmp-lib-dirs"
        -- TODO: why TargetPlatformFull and not host?
        , crossCompiling ? (conf "--host" $ argConfig "target-platform-full")
        , conf "--with-cc" . argM . showArg $ Gcc stage ]

bootPackageDbSettings :: Settings
bootPackageDbSettings = do
    sourcePath <- lift $ askConfig "ghc-source-path"
    arg $ "--package-db=" ++ sourcePath </> "libraries/bootstrapping.conf"

dllSettings :: Settings
dllSettings = arg ""

with' :: Builder -> Settings
with' builder = appendM $ with builder

packageConstraints :: Settings
packageConstraints = do
    pkgs <- fromDiff targetPackages
    constraints <- lift $ forM pkgs $ \pkg -> do
        let cabal  = pkgPath pkg </> pkgCabal pkg
            prefix = dropExtension (pkgCabal pkg) ++ " == "
        need [cabal]
        content <- lines <$> liftIO (readFile cabal)
        let vs = filter (("ersion:" `isPrefixOf`) . drop 1) content
        case vs of
            [v] -> return $ prefix ++ dropWhile (not . isDigit) v
            _   -> redError $ "Cannot determine package version in '"
                            ++ cabal ++ "'."
    args $ concatMap (\c -> ["--constraint", c]) $ constraints

cabalSettings :: Settings
cabalSettings = do
    stage <- asks getStage
    pkg   <- asks getPackage
    mconcat [ arg "configure"
            , arg $ pkgPath pkg
            , arg $ targetDirectory stage pkg
            , dllSettings
            , with' $ Ghc stage
            , with' $ GhcPkg stage
            , customConfigureSettings
            , Expression.stage Stage0 ? bootPackageDbSettings
            , librarySettings
            , configKeyNonEmpty "hscolour" ? with' HsColour -- TODO: generalise?
            , configureSettings
            , Expression.stage Stage0 ? packageConstraints
            , with' $ Gcc stage
            , notStage Stage0 ? with' Ld
            , with' Ar
            , with' Alex
            , with' Happy ] -- TODO: reorder with's

ghcPkgSettings :: Settings
ghcPkgSettings = do
    stage <- asks getStage
    pkg   <- asks getPackage
    let dir = pkgPath pkg </> targetDirectory stage pkg
    mconcat [ arg "update"
            , arg "--force"
            , Expression.stage Stage0 ? bootPackageDbSettings
            , arg $ dir </> "inplace-pkg-config" ]

ccSettings :: Settings
ccSettings = do
    let gccGe46 = liftM not gccLt46
    mconcat
        [ package integerLibrary ? arg "-Ilibraries/integer-gmp2/gmp"
        , builder GhcCabal ? argStagedConfig "conf-cc-args"
        , validating ? mconcat
            [ notBuilder GhcCabal ? arg "-Werror"
            , arg "-Wall"
            , gccIsClang ??
              ( arg "-Wno-unknown-pragmas" <>
                gccGe46 ? windowsHost ? arg "-Werror=unused-but-set-variable"
              , gccGe46 ? arg "-Wno-error=inline" )]
        ]

ldSettings :: Settings
ldSettings = builder GhcCabal ? argStagedConfig "conf-gcc-linker-args"

cppSettings :: Settings
cppSettings = builder GhcCabal ? argStagedConfig "conf-cpp-args"
