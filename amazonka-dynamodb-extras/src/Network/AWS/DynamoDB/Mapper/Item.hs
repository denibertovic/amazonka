{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE UndecidableInstances  #-}

module Network.AWS.DynamoDB.Mapper.Item where
    -- (

    -- -- * Items
    --   ItemError (..)
    -- , Item      (..)

    -- -- * Attributes
    -- , Attribute (..)
    -- ) where

import Control.Applicative (Const (..))
import Control.Exception   (Exception)
import Control.Lens        (ASetter', Getting, set, view, (^.))
import Control.Monad       ((>=>))

import Data.Aeson            (FromJSON (..), ToJSON (..))
import Data.Aeson.Types      (DotNetTime, parseEither)
import Data.Bifunctor        (bimap, first)
import Data.ByteString       (ByteString)
import Data.CaseInsensitive  (CI)
import Data.Coerce           (coerce)
import Data.Foldable         (toList)
import Data.Functor.Identity (Identity (..))
import Data.Hashable         (Hashable)
import Data.HashMap.Strict   (HashMap)
import Data.HashSet          (HashSet)
import Data.Int              (Int, Int16, Int32, Int64, Int8)
import Data.IntMap           (IntMap)
import Data.IntSet           (IntSet)
import Data.List.NonEmpty    (NonEmpty (..))
import Data.Map.Strict       (Map (..))
import Data.Maybe            (catMaybes, fromMaybe, isJust)
import Data.Monoid           (Dual (..), (<>))
import Data.Proxy            (Proxy (..))
import Data.Scientific       (Scientific)
import Data.Sequence         (Seq)
import Data.Set              (Set)
import Data.Tagged           (Tagged (..))
import Data.Text             (Text)
import Data.Time             (Day, LocalTime, NominalDiffTime, TimeOfDay,
                              UTCTime, ZonedTime)
import Data.Typeable         (Typeable)
import Data.Vector           (Vector)
import Data.Version          (Version)
import Data.Word             (Word, Word16, Word32, Word64, Word8)

import Foreign.Storable (Storable)

import Network.AWS.Data.Text
import Network.AWS.DynamoDB  hiding (ScalarAttributeType (..))

import Network.AWS.DynamoDB.Mapper.Value
import Network.AWS.DynamoDB.Mapper.Value.Unsafe

import Numeric.Natural (Natural)

import qualified Data.Aeson             as JS
import qualified Data.ByteString.Lazy   as LBS
import qualified Data.CaseInsensitive   as CI
import qualified Data.Scientific        as Sci
import qualified Data.Text              as Text
import qualified Data.Text.Lazy         as LText
import qualified Data.Text.Lazy.Builder as LText

import qualified Data.HashMap.Strict as HashMap
import qualified Data.HashSet        as HashSet
import qualified Data.IntMap.Strict  as IntMap
import qualified Data.IntSet         as IntSet
import qualified Data.List.NonEmpty  as NE
import qualified Data.Map.Strict     as Map
import qualified Data.Sequence       as Seq
import qualified Data.Set            as Set

import qualified Data.Vector           as Vector
import qualified Data.Vector.Generic   as VectorGen
import qualified Data.Vector.Primitive as VectorPrim
import qualified Data.Vector.Storable  as VectorStore
import qualified Data.Vector.Unboxed   as VectorUnbox

item :: [(Text, Value)] -> HashMap Text Value
item = HashMap.fromList
{-# INLINE item #-}

attr :: DynamoValue a => Text -> a -> (Text, Value)
attr k v = (k, toValue v)
{-# INLINE attr #-}

parse :: DynamoValue a => Text -> HashMap Text Value -> Either ItemError a
parse k m =
    case HashMap.lookup k m of
        Nothing -> Left (MissingAttribute k)
        Just v  -> first (ValueError k) (fromValue v)
{-# INLINE parse #-}

parseMaybe :: DynamoValue a
           => Text
           -> HashMap Text Value
           -> Either ItemError (Maybe a)
parseMaybe k m =
    case HashMap.lookup k m of
        Nothing -> Right Nothing
        Just v  -> bimap (ValueError k) Just (fromValue v)
{-# INLINE parseMaybe #-}

encode :: DynamoItem a => a -> HashMap Text AttributeValue
encode = coerce . toItem
{-# INLINE encode #-}

decode :: DynamoItem a => HashMap Text AttributeValue -> Either ItemError a
decode = HashMap.traverseWithKey go >=> fromItem
  where
    go k = first (ValueError k) . newValue
{-# INLINE decode #-}

-- | You can use this if you know the AttributeValue's are safe, as in they
-- have been returned unmodified from DynamoDB.
unsafeDecode :: DynamoItem a => HashMap Text AttributeValue -> Either ItemError a
unsafeDecode = fromItem . coerce

data ItemError
    = ValueError       Text ValueError
    | MissingAttribute Text
      deriving (Eq, Show, Typeable)

instance Exception ItemError

-- | Serialise a value to a complex DynamoDB item.
--
-- Note about complex types
--
-- The maximum item size in DynamoDB is 400 KB, which includes both attribute name
-- binary length (UTF-8 length) and attribute value lengths (again binary
-- length). The attribute name counts towards the size limit.
--
-- For example, consider an item with two attributes: one attribute named
-- "shirt-color" with value "R" and another attribute named "shirt-size" with
-- value "M". The total size of that item is 23 bytes.
--
-- An 'Item' is subject to the following law:
--
-- @
-- fromItem (toItem x) ≡ Right x
-- @
--
-- That is, you get back what you put in.
class DynamoItem a where
    toItem   :: a -> HashMap Text Value
    fromItem :: HashMap Text Value -> Either ItemError a

instance DynamoValue a => DynamoItem (Map Text a) where
    toItem   = toItem . HashMap.fromList . Map.toList
    fromItem = fmap (Map.fromList . HashMap.toList) . fromItem

instance DynamoValue a => DynamoItem (HashMap Text a) where
    toItem   = HashMap.map toValue
    fromItem = HashMap.traverseWithKey (\k -> first (ValueError k) . fromValue)
