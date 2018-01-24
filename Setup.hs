{-# LANGUAGE CPP #-}
{-# LANGUAGE TupleSections #-}

#ifndef MIN_VERSION_Cabal
-- MIN_VERSION_Cabal is defined and available to custom Setup.hs scripts
-- if either GHC >= 8.0 or cabal-install >= 1.24 is used.
-- So if it isn't defined, it's very likely we don't have Cabal >= 2.0.
#define MIN_VERSION_Cabal(x,y,z) 0
#endif

import Distribution.Simple
import Distribution.Simple.Setup (ConfigFlags(..), toFlag)
import Distribution.Simple.LocalBuildInfo (localPkgDescr)

#if MIN_VERSION_Cabal(2,0,0)
import Distribution.PackageDescription (FlagName(..), mkFlagName)
#else
import Distribution.PackageDescription (FlagName(..))
#endif

#if MIN_VERSION_Cabal(2,1,0)
import Distribution.PackageDescription (mkFlagAssignment, unFlagAssignment)
#else
import Distribution.PackageDescription (FlagAssignment)
#endif

import Distribution.Verbosity (silent)
import System.Info (os)
import qualified Control.Exception as E (tryJust, throw)
import System.IO.Error (isUserError)
import Control.Monad (forM)
import Data.List

#if !(MIN_VERSION_Cabal(2,0,0))
mkFlagName = FlagName
#endif

#if !(MIN_VERSION_Cabal(2,1,0))
mkFlagAssignment :: [(FlagName, Bool)] -> FlagAssignment
mkFlagAssignment = id

unFlagAssignment :: FlagAssignment -> [(FlagName, Bool)]
unFlagAssignment = id
#endif

-- On macOS we're checking whether OpenSSL library is avaiable
-- and if not, we're trying to find Homebrew or MacPorts OpenSSL installations.
--
-- Method is dumb -- set homebrew-openssl or macports-openssl flag and try
-- to configure and check C libs.
--
-- If no or multiple libraries are found we display error message
-- with instructions.

main
    | os == "darwin" =
        defaultMainWithHooks simpleUserHooks { confHook = conf }
    | otherwise =
        defaultMain

flags = ["homebrew-openssl", "macports-openssl"]

conf descr cfg = do
    c <- tryConfig descr cfg
    case c of
        Right lbi -> return lbi -- library was found
        Left e
            | unFlagAssignment (configConfigurationsFlags cfg)
              `intersect` [(mkFlagName f, True) | f <- flags] /= [] ->
                E.throw e
                -- flag was set but library still wasn't found
            | otherwise -> do
                r <- forM flags $ \ f ->
                    fmap (f,) $ tryConfig descr $
                    setFlag (mkFlagName f) cfg { configVerbosity = toFlag silent }
                    -- TODO: configure is a long operation
                    -- while checkForeignDeps is fast.
                    -- Perhaps there is a way to configure once
                    -- and only apply flags to result and check.
                    -- However, additional `configure`s happen only on macOS
                    -- and only when library wasn't found.
                case [(f,r) | (f, Right r) <- r] of
                    [(_,lbi)] ->
                        return lbi -- library was found
                    [] ->
                        fail notFound
                    fs ->
                        fail $ multipleFound fs

notFound = unlines
    [ "Can't find OpenSSL library,"
    , "install it via 'brew install openssl' or 'port install openssl'"
    , "or use --extra-include-dirs= and --extra-lib-dirs="
    , "to specify location of installed OpenSSL library."
    ]

multipleFound fs = unlines
    [ "Multiple OpenSSL libraries were found,"
    , "use " ++ intercalate " or " ["'-f " ++ f ++ "'" | (f,_) <- fs]
    , "to specify location of installed OpenSSL library."
    ]

setFlag f c = c { configConfigurationsFlags = mkFlagAssignment
                                            $ go
                                            $ unFlagAssignment
                                            $ configConfigurationsFlags c }
    where go [] = []
          go (x@(n, _):xs)
              | n == f = (f, True) : xs
              | otherwise = x : go xs

tryConfig descr flags = do
    lbi <- confHook simpleUserHooks descr flags
    -- confHook simpleUserHooks == Distribution.Simple.Configure.configure

    -- Testing whether C lib and header dependencies are working.
    -- We check exceptions only here, to check C libs errors but not other
    -- configuration problems like not resolved .cabal dependencies.
    E.tryJust ue $ do
        postConf simpleUserHooks [] flags (localPkgDescr lbi) lbi
        -- postConf simpleUserHooks ~==
        --   Distribution.Simple.Configure.checkForeignDeps

        return lbi

    where ue e | isUserError e = Just e
               | otherwise = Nothing
