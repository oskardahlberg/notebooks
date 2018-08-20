#!/usr/bin/env nix-shell
#! nix-shell -i runhaskell
#! nix-shell -p nix
#! nix-shell -p "haskellPackages.ghcWithPackages (self: with self; [ aeson-pretty microlens-aeson optparse-applicative req ])"

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Maybe
import Data.Aeson
import Data.Aeson.Types
import Data.Aeson.Encode.Pretty
import Data.ByteString.Lazy (readFile, writeFile)
import Data.Default.Class
import Data.Maybe (maybe)
import Data.Semigroup ((<>))
import Data.Text (Text, intercalate, pack, unpack)
import GHC.Generics
import Lens.Micro
import Lens.Micro.Aeson
import Network.HTTP.Req
import Options.Applicative hiding (header)
import Prelude hiding (readFile, writeFile)
import System.Environment (getArgs)
import System.Process

data Project = Project { owner, repo, rev, sha256 :: Text }
    deriving (Generic, FromJSON, ToJSON)

data Opts = Opts { fname :: FilePath, pname, bname :: Text, extract :: Bool }

r :: MonadHttp m => Project -> Text -> m (JsonResponse Value)
r Project{ owner, repo } b = req GET
    (https "api.github.com" /: "repos" /: owner /: repo /: "branches" /: b)
    NoReqBody jsonResponse (header "User-Agent" "vaibhavsagar")

getSha256 :: Project -> Bool -> IO Text
getSha256 Project{ owner, repo, rev } doUnpack = pack . init <$>
    readProcess "nix-prefetch-url" (["--unpack" | doUnpack] ++ [unpack url]) ""
    where url = "https://github.com"
            <> intercalate "/" [owner, repo, "archive", rev] <> ".tar.gz"

modify :: Opts -> MaybeT IO Value
modify Opts{ fname, pname, bname, extract } = do
    versions <- MaybeT $ decode <$> readFile fname
    project <- MaybeT . pure $ parseMaybe parseJSON =<< versions ^? key pname
    rev <- MaybeT $ responseBody <$> runReq def (r project bname) >>=
        pure . (^? key "commit" . key "sha" . _String)
    sha256 <- lift $ getSha256 project { rev } extract
    pure $ versions & key pname .~ toJSON project { rev, sha256 }

update :: Opts -> IO ()
update opts = runMaybeT (modify opts) >>= maybe (pure ())
    (writeFile (fname opts) . encodePretty' defConfig
        { confIndent = Spaces 2, confCompare = compare })

main :: IO ()
main = update =<< execParser (info (helper <*> parser) mempty)
    where parser = Opts
            <$> argument str
                (metavar "FILE" <> help "The file containing version data")
            <*> argument str
                (metavar "PROJECT" <> help "The project whose hashes to update")
            <*> argument str
                (metavar "BRANCH" <> help "The branch to use" <> value "master")
            <*> flag True False (short 'n' <> long "no-unpack" <>
                    help "Don't unpack before computing hashes")
