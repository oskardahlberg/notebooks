#!/usr/bin/env nix-shell
#! nix-shell -i runhaskell
#! nix-shell -p nix
#! nix-shell -p "haskellPackages.ghcWithPackages (self: with self; [ aeson-pretty microlens-aeson req ])"

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

import Data.ByteString.Lazy (readFile, writeFile)
import Data.Default.Class
import Data.Aeson
import Data.Aeson.Encode.Pretty
import Data.Monoid ((<>))
import Data.Text (Text, pack, unpack)
import GHC.Generics
import Lens.Micro
import Lens.Micro.Aeson
import Network.HTTP.Req
import Prelude hiding (readFile, writeFile)
import System.Environment (getArgs)
import System.Process

data Project = Project
    { owner  :: Text
    , repo   :: Text
    , rev    :: Text
    , sha256 :: Text
    } deriving (Show, Generic)

instance FromJSON Project
instance ToJSON Project

extractProject :: Value -> Text -> Maybe Project
extractProject versions name = do
    prj <- versions ^? key name
    case fromJSON prj of
        Error _ -> Nothing
        Success p -> Just p

r :: (MonadHttp m, FromJSON a) => Project -> Text -> m (JsonResponse a)
r project branch = req GET
    (  https "api.github.com"
    /: "repos"
    /: owner project
    /: repo project
    /: "branches"
    /: branch
    ) NoReqBody jsonResponse (header "User-Agent" "vaibhavsagar")

getRev :: Project -> Text -> IO (Maybe Text)
getRev project branch = do
    res <- responseBody <$> runReq def (r project branch) :: IO Value
    return $ res ^? key "commit" . key "sha" . _String

buildURL :: Project -> Text
buildURL project
    =  "https://github.com/"
    <> owner project <> "/"
    <> repo project  <> "/"
    <> "archive"     <> "/"
    <> rev project   <> ".tar.gz"

getSha256 :: Text -> Bool -> IO Text
getSha256 url doUnpack = let
    option = if doUnpack then ["--unpack"] else []
    in pack . init <$>
        readProcess "nix-prefetch-url" (option ++ [unpack url]) ""

update :: FilePath -> Text -> Text -> Bool -> IO ()
update filename projectName branchName doUnpack = do
    Just versions <- decode <$> readFile filename :: IO (Maybe Value)
    let (Just project) = extractProject versions projectName
    Just latestRev <- getRev project branchName
    latestSha256 <- getSha256 (buildURL project { rev = latestRev }) doUnpack
    let project' = project { rev = latestRev, sha256 = latestSha256 }
    let versions' = versions & key projectName .~ toJSON project'
    writeFile filename (encodePretty'
        defConfig { confIndent = Spaces 2, confCompare = compare } versions')

main :: IO ()
main = do
    args <- getArgs
    case length args of
        n | n < 2 -> putStrLn "Not enough arguments!"
        2 -> let
            [filename, projectName] = args
            in update filename (pack projectName) "master" False
        3 -> let
            [filename, projectName, branchName] = args
            in update filename (pack projectName) (pack branchName) False
        _ -> putStrLn "Too many arguments!"
