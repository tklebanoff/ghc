module Rules.BinaryDist where

import Hadrian.Haskell.Cabal

import Context
import Expression
import Oracles.Setting
import Packages
import Settings
import Target
import Utilities

{-
Note [Binary distributions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Hadrian produces binary distributions under:
  <build root>/bindist/ghc-<X>.<Y>.<Z>-<arch>-<os>.tar.xz

It is generated by creating an archive from:
  <build root>/bindist/ghc-<X>.<Y>.<Z>-<arch>-<os>/

It does so by following the steps below.

- make sure we have a complete stage 2 compiler + haddock

- copy the bin and lib directories of the compiler we built:
    <build root>/stage1/{bin, lib}
  to
    <build root>/bindist/ghc-<X>.<Y>.<Z>-<arch>-<os>/{bin, lib}

- copy the generated docs (user guide, haddocks, etc):
    <build root>/docs/
  to
    <build root>/bindist/ghc-<X>.<Y>.<Z>-<arch>-<os>/docs/

- copy haddock (built by our stage2 compiler):
    <build root>/stage2/bin/haddock
  to
    <build root>/bindist/ghc-<X>.<Y>.<Z>-<arch>-<os>/bin/haddock

- use autoreconf to generate a `configure` script from
  aclocal.m4 and distrib/configure.ac, that we move to:
    <build root>/bindist/ghc-<X>.<Y>.<Z>-<arch>-<os>/configure

- write a (fixed) Makefile capable of supporting 'make install' to:
    <build root>/bindist/ghc-<X>.<Y>.<Z>-<arch>-<os>/Makefile

- write some (fixed) supporting bash code for the wrapper scripts to:
    <build root>/bindist/ghc-<X>.<Y>.<Z>-<arch>-<os>/wrappers/<program>

  where <program> is the name of the executable that the bash file will
  help wrapping.

- copy supporting configure/make related files
  (see @bindistInstallFiles@) to:
    <build root>/bindist/ghc-<X>.<Y>.<Z>-<arch>-<os>/<file>

- create a .tar.xz archive of the directory:
    <build root>/bindist/ghc-<X>.<Y>.<Z>-<arch>-<os>/
  at
    <build root>/bindist/ghc-<X>.<Y>.<Z>-<arch>-<os>.tar.xz


Note [Wrapper scripts and binary distributions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Users of Linux, FreeBSD, Windows and OS X can unpack a
binary distribution produced by hadrian for their arch
and OS and start using @bin/ghc@, @bin/ghc-pkg@ and so on
right away, without even having to configure or install
the distribution. They would then be using the real executables
directly, not through wrapper scripts.

This works because GHCs produced by hadrian on those systems
are relocatable. This means that you can copy the @bin@ and @lib@
dirs anywhere and GHC will keep working, as long as both
directories sit next to each other. (This is achieved by having
GHC look up its $libdir relatively to where the GHC executable
resides.)

It is however still possible (and simple) to install a GHC
distribution that uses wrapper scripts. From the unpacked archive,
you can simply do:

  ./configure --prefix=<path> [... other configure options ...]
  make install

In order to support @bin@ and @lib@ directories that don't sit next to each
other, the install script:
   * installs programs into @LIBDIR/ghc-VERSION/bin@
   * installs libraries into @LIBDIR/ghc-VERSION/lib@
   * installs the wrappers scripts into @BINDIR@ directory

-}

bindistRules :: Rules ()
bindistRules = do
    root <- buildRootRules
    phony "binary-dist" $ do
        -- We 'need' all binaries and libraries
        targets <- mapM pkgTarget =<< stagePackages Stage1
        need targets

        version        <- setting ProjectVersion
        targetPlatform <- setting TargetPlatformFull
        distDir        <- Context.distDir Stage1
        rtsDir         <- pkgIdentifier rts
        windows        <- windowsHost

        let ghcBuildDir      = root -/- stageString Stage1
            bindistFilesDir  = root -/- "bindist" -/- ghcVersionPretty
            ghcVersionPretty = "ghc-" ++ version ++ "-" ++ targetPlatform
            rtsIncludeDir    = ghcBuildDir -/- "lib" -/- distDir -/- rtsDir
                               -/- "include"

        -- We create the bindist directory at <root>/bindist/ghc-X.Y.Z-platform/
        -- and populate it with Stage2 build results
        createDirectory bindistFilesDir
        copyDirectory (ghcBuildDir -/- "bin") bindistFilesDir
        copyDirectory (ghcBuildDir -/- "lib") bindistFilesDir
        copyDirectory (rtsIncludeDir)         bindistFilesDir
        need ["docs"]
        -- TODO: we should only embed the docs that have been generated
        -- depending on the current settings (flavours' "ghcDocs" field and
        -- "--docs=.." command-line flag)
        -- Currently we embed the "docs" directory if it exists but it may
        -- contain outdated or even invalid data.
        whenM (doesDirectoryExist (root -/- "docs")) $ do
          copyDirectory (root -/- "docs") bindistFilesDir
        when windows $ do
          copyDirectory (root -/- "mingw") bindistFilesDir
          -- we use that opportunity to delete the .stamp file that we use
          -- as a proxy for the whole mingw toolchain, there's no point in
          -- shipping it
          removeFile (bindistFilesDir -/- mingwStamp)

        -- We copy the binary (<build root>/stage1/bin/haddock) to
        -- the bindist's bindir (<build root>/bindist/ghc-.../bin/).
        haddockPath <- programPath (vanillaContext Stage1 haddock)
        copyFile haddockPath (bindistFilesDir -/- "bin" -/- "haddock")

        -- We then 'need' all the files necessary to configure and install
        -- (as in, './configure [...] && make install') this build on some
        -- other machine.
        need $ map (bindistFilesDir -/-)
                   (["configure", "Makefile"] ++ bindistInstallFiles)
        need $ map ((bindistFilesDir -/- "wrappers") -/-) ["check-api-annotations"
                   , "check-ppr", "ghc", "ghc-iserv", "ghc-pkg"
                   , "ghci-script", "haddock", "hpc", "hp2ps", "hsc2hs"
                   , "runghc"]

        -- Finally, we create the archive <root>/bindist/ghc-X.Y.Z-platform.tar.xz
        tarPath <- builderPath (Tar Create)
        cmd [Cwd $ root -/- "bindist"] tarPath
            [ "-c", "--xz", "-f"
            , ghcVersionPretty <.> "tar.xz"
            , ghcVersionPretty ]

    -- Prepare binary distribution configure script
    -- (generated under <ghc root>/distrib/configure by 'autoreconf')
    root -/- "bindist" -/- "ghc-*" -/- "configure" %> \configurePath -> do
        ghcRoot <- topDirectory
        copyFile (ghcRoot -/- "aclocal.m4") (ghcRoot -/- "distrib" -/- "aclocal.m4")
        buildWithCmdOptions [] $
            target (vanillaContext Stage1 ghc) (Autoreconf $ ghcRoot -/- "distrib") [] []
        -- We clean after ourselves, moving the configure script we generated in
        -- our bindist dir
        removeFile (ghcRoot -/- "distrib" -/- "aclocal.m4")
        moveFile (ghcRoot -/- "distrib" -/- "configure") configurePath

    -- Generate the Makefile that enables the "make install" part
    root -/- "bindist" -/- "ghc-*" -/- "Makefile" %> \makefilePath ->
        writeFile' makefilePath bindistMakefile

    root -/- "bindist" -/- "ghc-*" -/- "wrappers/*" %> \wrapperPath ->
        writeFile' wrapperPath $ wrapper (takeFileName wrapperPath)

    -- Copy various configure-related files needed for a working
    -- './configure [...] && make install' workflow
    -- (see the list of files needed in the 'binary-dist' rule above, before
    -- creating the archive).
    forM_ bindistInstallFiles $ \file ->
        root -/- "bindist" -/- "ghc-*" -/- file %> \dest -> do
            ghcRoot <- topDirectory
            copyFile (ghcRoot -/- fixup file) dest

  where
    fixup f | f `elem` ["INSTALL", "README"] = "distrib" -/- f
            | otherwise                      = f

-- | A list of files that allow us to support a simple
-- @./configure [...] && make install@ workflow.
bindistInstallFiles :: [FilePath]
bindistInstallFiles =
    [ "config.sub", "config.guess", "install-sh", "mk" -/- "config.mk.in"
    , "mk" -/- "install.mk.in", "mk" -/- "project.mk", "settings.in", "README"
    , "INSTALL" ]

-- | This auxiliary function gives us a top-level 'Filepath' that we can 'need'
-- for all libraries and programs that are needed for a complete build.
-- For libraries, it returns the path to the @.conf@ file in the package
-- database. For programs, it returns the path to the compiled executable.
pkgTarget :: Package -> Action FilePath
pkgTarget pkg
    | isLibrary pkg = pkgConfFile (vanillaContext Stage1 pkg)
    | otherwise     = programPath =<< programContext Stage1 pkg

-- TODO: Augment this Makefile to match the various parameters that the current
-- bindist scripts support.
-- | A trivial Makefile that only takes @$prefix@ into account, and not e.g
-- @$datadir@ (for docs) and other variables, yet.
bindistMakefile :: String
bindistMakefile = unlines
    [ "MAKEFLAGS += --no-builtin-rules"
    , ".SUFFIXES:"
    , ""
    , "include mk/install.mk"
    , "include mk/config.mk"
    , ""
    , ".PHONY: default"
    , "default:"
    , "\t@echo 'Run \"make install\" to install'"
    , "\t@false"
    , ""
    , "#-----------------------------------------------------------------------"
    , "# INSTALL RULES"
    , ""
    , "# Hacky function to check equality of two strings"
    , "# TODO : find if a better function exists"
    , "eq=$(and $(findstring $(1),$(2)),$(findstring $(2),$(1)))"
    , ""
    , "define installscript"
    , "# $1 = package name"
    , "# $2 = wrapper path"
    , "# $3 = bindir"
    , "# $4 = ghcbindir"
    , "# $5 = Executable binary path"
    , "# $6 = Library Directory"
    , "# $7 = Docs Directory"
    , "# $8 = Includes Directory"
    , "# We are installing wrappers to programs by searching corresponding"
    , "# wrappers. If wrapper is not found, we are attaching the common wrapper"
    , "# to it. This implementation is a bit hacky and depends on consistency"
    , "# of program names. For hadrian build this will work as programs have a"
    , "# consistent naming procedure."
    , "\trm -f '$2'"
    , "\t$(CREATE_SCRIPT) '$2'"
    , "\t@echo \"#!$(SHELL)\" >>  '$2'"
    , "\t@echo \"exedir=\\\"$4\\\"\" >> '$2'"
    , "\t@echo \"exeprog=\\\"$1\\\"\" >> '$2'"
    , "\t@echo \"executablename=\\\"$5\\\"\" >> '$2'"
    , "\t@echo \"bindir=\\\"$3\\\"\" >> '$2'"
    , "\t@echo \"libdir=\\\"$6\\\"\" >> '$2'"
    , "\t@echo \"docdir=\\\"$7\\\"\" >> '$2'"
    , "\t@echo \"includedir=\\\"$8\\\"\" >> '$2'"
    , "\t@echo \"\" >> '$2'"
    , "\tcat wrappers/$1 >> '$2'"
    , "\t$(EXECUTABLE_FILE) '$2' ;"
    , "endef"
    , ""
    , "# Hacky function to patch up the 'haddock-interfaces' and 'haddock-html'"
    , "# fields in the package .conf files"
    , "define patchpackageconf"
    , "# $1 = package name (ex: 'bytestring')"
    , "# $2 = path to .conf file"
    , "# $3 = Docs Directory"
    , "\tcat '$2' | sed 's|haddock-interfaces.*|haddock-interfaces: $3/html/libraries/$1/$1.haddock|' \\"
    , "\t         | sed 's|haddock-html.*|haddock-html: $3/html/libraries/$1|' \\"
    , "\t       > '$2.copy'"
    , "\tmv '$2.copy' '$2'"
    , "endef"
    , ""
    , "# QUESTION : should we use shell commands?"
    , ""
    , ""
    , ".PHONY: install"
    , "install: install_lib install_bin install_includes"
    , "install: install_docs install_wrappers install_ghci"
    , "install: install_mingw update_package_db"
    , ""
    , "ActualBinsDir=${ghclibdir}/bin"
    , "ActualLibsDir=${ghclibdir}/lib"
    , "WrapperBinsDir=${bindir}"
    , ""
    , "# We need to install binaries relative to libraries."
    , "BINARIES = $(wildcard ./bin/*)"
    , "install_bin:"
    , "\t@echo \"Copying binaries to $(ActualBinsDir)\""
    , "\t$(INSTALL_DIR) \"$(ActualBinsDir)\""
    , "\tfor i in $(BINARIES); do \\"
    , "\t\tcp -R $$i \"$(ActualBinsDir)\"; \\"
    , "\tdone"
    , ""
    , "install_ghci:"
    , "\t@echo \"Installing ghci wrapper\""
    , "\t@echo \"#!$(SHELL)\" >  '$(WrapperBinsDir)/ghci'"
    , "\tcat wrappers/ghci-script >> '$(WrapperBinsDir)/ghci'"
    , "\t$(EXECUTABLE_FILE) '$(WrapperBinsDir)/ghci'"
    , ""
    , "LIBRARIES = $(wildcard ./lib/*)"
    , "install_lib:"
    , "\t@echo \"Copying libraries to $(ActualLibsDir)\""
    , "\t$(INSTALL_DIR) \"$(ActualLibsDir)\""
    , "\tfor i in $(LIBRARIES); do \\"
    , "\t\tcp -R $$i \"$(ActualLibsDir)/\"; \\"
    , "\tdone"
    , ""
    , "INCLUDES = $(wildcard ./include/*)"
    , "install_includes:"
    , "\t@echo \"Copying libraries to $(includedir)\""
    , "\t$(INSTALL_DIR) \"$(includedir)\""
    , "\tfor i in $(INCLUDES); do \\"
    , "\t\tcp -R $$i \"$(includedir)/\"; \\"
    , "\tdone"
    , ""
    , "DOCS = $(wildcard ./docs/*)"
    , "install_docs:"
    , "\t@echo \"Copying libraries to $(docdir)\""
    , "\t$(INSTALL_DIR) \"$(docdir)\""
    , "\tfor i in $(DOCS); do \\"
    , "\t\tcp -R $$i \"$(docdir)/\"; \\"
    , "\tdone"
    , ""
    , "BINARY_NAMES=$(shell ls ./wrappers/)"
    , "install_wrappers:"
    , "\t@echo \"Installing Wrapper scripts\""
    , "\t$(INSTALL_DIR) \"$(WrapperBinsDir)\""
    , "\t$(foreach p, $(BINARY_NAMES),\\"
    , "\t\t$(call installscript,$p,$(WrapperBinsDir)/$p," ++
      "$(WrapperBinsDir),$(ActualBinsDir),$(ActualBinsDir)/$p," ++
      "$(ActualLibsDir),$(docdir),$(includedir)))"
    , "\trm -f '$(WrapperBinsDir)/ghci-script'" -- FIXME: we shouldn't generate it in the first place
    , ""
    , "PKG_CONFS = $(wildcard $(ActualLibsDir)/package.conf.d/*)"
    , "update_package_db:"
    , "\t@echo \"Updating the package DB\""
    , "\t$(foreach p, $(PKG_CONFS),\\"
    , "\t\t$(call patchpackageconf," ++
      "$(shell echo $(notdir $p) | sed 's/-\\([0-9]*[0-9]\\.\\)*conf//g')," ++
      "$p,$(docdir)))"
    , "\t'$(WrapperBinsDir)/ghc-pkg' recache"
    , ""
    , "# The 'foreach' that copies the mingw directory will only trigger a copy"
    , "# when the wildcard matches, therefore only on Windows."
    , "MINGW = $(wildcard ./mingw)"
    , "install_mingw:"
    , "\t@echo \"Installing MingGW\""
    , "\t$(INSTALL_DIR) \"$(prefix)/mingw\""
    , "\t$(foreach d, $(MINGW),\\"
    , "\t\tcp -R ./mingw \"$(prefix)\")"
    , "# END INSTALL"
    , "# ----------------------------------------------------------------------"
    ]

wrapper :: FilePath -> String
wrapper "ghc"         = ghcWrapper
wrapper "ghc-pkg"     = ghcPkgWrapper
wrapper "ghci-script" = ghciScriptWrapper
wrapper "haddock"     = haddockWrapper
wrapper "hsc2hs"      = hsc2hsWrapper
wrapper "runghc"      = runGhcWrapper
wrapper _             = commonWrapper

-- | Wrapper scripts for different programs. Common is default wrapper.

ghcWrapper :: String
ghcWrapper = "exec \"$executablename\" -B\"$libdir\" ${1+\"$@\"}\n"

ghcPkgWrapper :: String
ghcPkgWrapper = unlines
    [ "PKGCONF=\"$libdir/package.conf.d\""
    , "exec \"$executablename\" --global-package-db \"$PKGCONF\" ${1+\"$@\"}" ]

haddockWrapper :: String
haddockWrapper = "exec \"$executablename\" -B\"$libdir\" -l\"$libdir\" ${1+\"$@\"}\n"

commonWrapper :: String
commonWrapper = "exec \"$executablename\" ${1+\"$@\"}\n"

hsc2hsWrapper :: String
hsc2hsWrapper = unlines
    [ "HSC2HS_EXTRA=\"--cflag=-fno-stack-protector --lflag=-fuse-ld=gold\""
    , "tflag=\"--template=$libdir/template-hsc.h\""
    , "Iflag=\"-I$includedir/\""
    , "for arg do"
    , "    case \"$arg\" in"
    , "# On OS X, we need to specify -m32 or -m64 in order to get gcc to"
    , "# build binaries for the right target. We do that by putting it in"
    , "# HSC2HS_EXTRA. When cabal runs hsc2hs, it passes a flag saying which"
    , "# gcc to use, so if we set HSC2HS_EXTRA= then we don't get binaries"
    , "# for the right platform. So for now we just don't set HSC2HS_EXTRA="
    , "# but we probably want to revisit how this works in the future."
    , "#        -c*)          HSC2HS_EXTRA=;;"
    , "#        --cc=*)       HSC2HS_EXTRA=;;"
    , "        -t*)          tflag=;;"
    , "        --template=*) tflag=;;"
    , "        --)           break;;"
    , "    esac"
    , "done"
    , "exec \"$executablename\" ${tflag:+\"$tflag\"} $HSC2HS_EXTRA ${1+\"$@\"} \"$Iflag\"" ]

runGhcWrapper :: String
runGhcWrapper = "exec \"$executablename\" -f \"$exedir/ghc\" ${1+\"$@\"}\n"

-- | We need to ship ghci executable, which basically just calls ghc with
-- | --interactive flag.
ghciScriptWrapper :: String
ghciScriptWrapper = unlines
    [ "DIR=`dirname \"$0\"`"
    , "executable=\"$DIR/ghc\""
    , "exec $executable --interactive \"$@\"" ]

-- | When not on Windows, we want to ship the 3 flavours of the iserv program
--   in binary distributions. This isn't easily achievable by just asking for
--   the package to be built, since here we're generating 3 different
--   executables out of just one package, so we need to specify all 3 contexts
--   explicitly and 'need' the result of building them.
needIservBins :: Action ()
needIservBins = do
    windows <- windowsHost
    when (not windows) $ do
        rtsways <- interpretInContext (vanillaContext Stage1 ghc) getRtsWays
        need =<< traverse programPath
                   [ Context Stage1 iserv w
                   | w <- [vanilla, profiling, dynamic]
                   , w `elem` rtsways
                   ]
