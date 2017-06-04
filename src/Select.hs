{-|
Module      : Select
Description : AST for top level Select queries
Copyright   : (c) LeapYear Technologies 2016
Maintainer  : eitan@leapyear.io
Stability   : experimental
Portability : POSIX

ASTs for Selects
-}

{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module Select
  ( Select(..)
  , SelectIdentifier
  , PredicateException(..)
  , execute
  , trim
  ) where

import Control.Exception
import Control.Monad
import Control.Monad.Identity
import Data.Char (isSpace)
import Data.Maybe
import Data.Dynamic
import Data.List
import Data.Maybe
import Data.Proxy
import Data.Typeable
import Debug.Trace
import Pipes hiding (Proxy)
import Pipes.Prelude (toList)
import Text.CSV
import Text.Read
import Unsafe.Coerce

import Select.Expression
import Select.Relation

-- | Top level `Select` AST
newtype Select scope variable table
  = SELECT (Relation scope variable table)

-- | Identifier for SELECT
type SelectIdentifier = Select String String FilePath

trim :: String -> String
trim = f . f
f = reverse . dropWhile isSpace

data PredicateException = PredicateException deriving (Show, Typeable)

instance Exception PredicateException

convertFilepathToTable :: FilePath -> IO CSVTable
convertFilepathToTable path = do
  csvString <- readFile path
  let Right res = parseCSV path $ trim csvString
  return $ CSVTable res

-- | `execute` should take in a Select AST and a CSV filename for output
-- and execute the select statement to create a new tabular dataset which
-- it will populate the output file with
execute
  :: SelectIdentifier
  -> FilePath -- output
  -> IO ()
execute (SELECT rel) output = do
  converted <- convertRelation convertFilepathToTable rel
  let p = relationToRowProducer [] converted
  case p of
    Right producer -> do
      let finalTable = toList $ rowProducer producer
          printValue dyn = fromMaybe (show dyn) $ fromDynamic dyn
          csvObj = (map fst $ columnTypes producer):map (map writeDynamic) finalTable
          makeLine = intercalate ","
          csvString = intercalate "\n" $ map makeLine csvObj
      -- writeFile output $ show finalTable
      writeFile output $ csvString
    Left e -> writeFile output $ show e
  return ()

readDynamic :: TypeRep -> String -> Maybe Dynamic
readDynamic t s
  | t == stringType = Just $ toDyn s
  | t == intType = toDyn <$> (readMaybe s :: Maybe Int)
  | t == realType = toDyn <$> (readMaybe s :: Maybe Double)
  | t == boolType = toDyn <$> (readMaybe s :: Maybe Bool)
  | otherwise = Nothing

writeDynamic :: Dynamic -> String
writeDynamic d =
  fromMaybe "" $ (helper $ dynTypeRep d)
  where helper t
          | t == stringType = fromDynamic d
          | t == intType = show <$> (fromDynamic d :: Maybe Int)
          | t == realType = show <$> (fromDynamic d :: Maybe Double)
          | t == boolType = show <$> (fromDynamic d :: Maybe Bool)
          | otherwise = Nothing

data CSVTable = CSVTable [[String]]
stringType = typeRep (Proxy :: Proxy String)
intType = typeRep (Proxy :: Proxy Int)
realType = typeRep (Proxy :: Proxy Double)
boolType = typeRep (Proxy :: Proxy Bool)

instance BuildsRowProducer CSVTable Identity String where
  getRowProducer (CSVTable table) reqs =
    let actualNames = head table
        requiredNames = map fst reqs
        getTypeForName name = fromMaybe stringType $ lookup name reqs
        getPairForName name = (name, getTypeForName name)
        typedNames = map getPairForName actualNames
        types = map snd typedNames
        tryRead tr s =
          if tr == stringType
            then Right $ toDyn s
            else maybe (Left $ BadValueError s) Right $ readDynamic tr s
        typeRow row = zipWithM tryRead types row
        typedTableOrError = mapM typeRow $ tail table
        makeProducer valueTable =
          Right $
          TypedRowProducer
          {columnTypes = typedNames, rowProducer = each valueTable}
    in if all (flip elem actualNames) requiredNames
         then typedTableOrError >>= makeProducer
         else Left BadExpressionError -- TODO: give some info here
