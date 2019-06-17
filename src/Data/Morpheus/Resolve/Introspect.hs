{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}

module Data.Morpheus.Resolve.Introspect
  ( introspectOutputType
  ) where

import           Data.Morpheus.Kind                     (ENUM, INPUT_OBJECT, KIND, OBJECT, SCALAR, UNION, WRAPPER)
import           Data.Morpheus.Resolve.Generics.EnumRep (EnumRep (..))
import           Data.Morpheus.Resolve.Generics.TypeRep (ObjectRep (..), RecSel, SelOf, TypeUpdater, UnionRep (..),
                                                         resolveTypes)
import           Data.Morpheus.Schema.Type              (DeprecationArgs)
import           Data.Morpheus.Schema.TypeKind          (TypeKind (..))
import qualified Data.Morpheus.Types.GQLArgs            as Args (GQLArgs (..))
import           Data.Morpheus.Types.GQLScalar          (GQLScalar (..))
import           Data.Morpheus.Types.GQLType            (GQLType (..))
import           Data.Morpheus.Types.Internal.Data      (DataArguments, DataField (..), DataFullType (..),
                                                         DataLeaf (..), DataTypeWrapper (..), DataValidator)
import           Data.Morpheus.Types.Resolver           (Resolver (..))
import           Data.Proxy                             (Proxy (..))
import           Data.Text                              (Text, pack)
import           GHC.Generics

-- class Types class
type GQL_TYPE a = (Generic a, GQLType a)

type EnumConstraint a = (GQL_TYPE a, EnumRep (Rep a))

type InputObjectConstraint a = (GQL_TYPE a, ObjectRep (Rep a) ())

type ObjectConstraint a = (GQL_TYPE a, ObjectRep (Rep a) DataArguments)

type UnionConstraint a = (GQL_TYPE a, UnionRep (Rep a))

scalarTypeOf :: GQLType a => DataValidator -> Proxy a -> DataFullType
scalarTypeOf validator = Leaf . LeafScalar . buildType validator

enumTypeOf :: GQLType a => [Text] -> Proxy a -> DataFullType
enumTypeOf tags' = Leaf . LeafEnum . buildType tags'

type InputType = ()

type OutputType = DataArguments

type InputOf t = Context t (KIND t) InputType

type OutputOf t = Context t (KIND t) OutputType

introspectOutputType ::
     forall a. Introspect a (KIND a) OutputType
  => Proxy a
  -> TypeUpdater
introspectOutputType _ = introspect (Context :: OutputOf a)

-- | context , like Proxy with multiple parameters
-- contains types of :
-- * 'a': actual gql type
-- * 'kind': object, scalar, enum ...
-- * 'args': InputType | OutputType
data Context a kind args =
  Context

-- |   Generates internal GraphQL Schema for query validation and introspection rendering
-- * 'kind': object, scalar, enum ...
-- * 'args': type of field arguments
--    * '()' for 'input values' , they are just JSON properties and does not have any argument
--    * 'DataArguments' for field Resolvers Types, where 'DataArguments' is type of arguments
class Introspect a kind args where
  __field :: Context a kind args -> Text -> DataField args
    --   generates data field representation of object field
    --   according to parameter 'args' it could be
    --   * input object field: if args is '()'
    --   * object: if args is 'DataArguments'
  introspect :: Context a kind args -> TypeUpdater -- Generates internal GraphQL Schema

type OutputConstraint a = Introspect a (KIND a) DataArguments

--
-- SCALAR
--
instance (GQLScalar a, GQLType a) => Introspect a SCALAR InputType where
  __field _ = field_ SCALAR (Proxy @a) ()
  introspect _ = updateLib (scalarTypeOf (scalarValidator $ Proxy @a)) [] (Proxy @a)

instance (GQLScalar a, GQLType a) => Introspect a SCALAR OutputType where
  __field _ = field_ SCALAR (Proxy @a) []
  introspect _ = updateLib (scalarTypeOf (scalarValidator $ Proxy @a)) [] (Proxy @a)

--
-- ENUM
--
instance EnumConstraint a => Introspect a ENUM InputType where
  __field _ = field_ ENUM (Proxy @a) ()
  introspect _ = introspectEnum (Context :: InputOf a)

instance EnumConstraint a => Introspect a ENUM OutputType where
  __field _ = field_ ENUM (Proxy @a) []
  introspect _ = introspectEnum (Context :: OutputOf a)

introspectEnum ::
     forall a f. (GQLType a, EnumRep (Rep a))
  => Context a (KIND a) f
  -> TypeUpdater
introspectEnum _ = updateLib (enumTypeOf $ getTags (Proxy @(Rep a))) [] (Proxy @a)

--
-- OBJECTS , INPUT_OBJECT
--
instance InputObjectConstraint a => Introspect a INPUT_OBJECT InputType where
  __field _ = field_ INPUT_OBJECT (Proxy @a) ()
  introspect _ = updateLib (InputObject . buildType fields') stack' (Proxy @a)
    where
      (fields', stack') = unzip $ objectFieldTypes (Proxy @(Rep a))

instance ObjectConstraint a => Introspect a OBJECT OutputType where
  __field _ = field_ OBJECT (Proxy @a) []
  introspect _ = updateLib (OutputObject . buildType (__typename : fields')) stack' (Proxy @a)
    where
      __typename =
        ( "__typename"
        , DataField
            {fieldName = "__typename", fieldKind = SCALAR, fieldArgs = [], fieldTypeWrappers = [], fieldType = "String"})
      (fields', stack') = unzip $ objectFieldTypes (Proxy @(Rep a))

-- | recursion for Object types, both of them : 'INPUT_OBJECT' and 'OBJECT'
-- iterates on field types  and introspects them recursively
instance (Selector s, Introspect a (KIND a) f) => ObjectRep (RecSel s a) f where
  objectFieldTypes _ =
    [((name, __field (Context :: Context a (KIND a) f) name), introspect (Context :: Context a (KIND a) f))]
    where
      name = pack $ selName (undefined :: SelOf s)

--
-- UNION
--
-- | recursion for union types
-- iterates on possible types for UNION and introspects them recursively
instance (OutputConstraint a, ObjectConstraint a) => UnionRep (RecSel s a) where
  possibleTypes _ = [(field_ OBJECT (Proxy @a) () "", introspect (Context :: OutputOf a))]

instance UnionConstraint a => Introspect a UNION OutputType where
  __field _ = field_ UNION (Proxy @a) []
  introspect _ = updateLib (Union . buildType fields) stack (Proxy @a)
    where
      (fields, stack) = unzip $ possibleTypes (Proxy @(Rep a))

--
-- WRAPPER : Maybe, LIST , Resolver
--
instance Introspect a (KIND a) f => Introspect (Maybe a) WRAPPER f where
  __field _ name = maybeField $ __field (Context :: Context a (KIND a) f) name
    where
      maybeField :: DataField f -> DataField f
      maybeField field@DataField {fieldTypeWrappers = NonNullType:xs} = field {fieldTypeWrappers = xs}
      maybeField field                                                = field
  introspect _ = introspect (Context :: Context a (KIND a) f)

instance Introspect a (KIND a) f => Introspect [a] WRAPPER f where
  __field _ name = listField (__field (Context :: Context a (KIND a) f) name)
    where
      listField :: DataField f -> DataField f
      listField x = x {fieldTypeWrappers = [NonNullType, ListType] ++ fieldTypeWrappers x}
  introspect _ = introspect (Context :: Context a (KIND a) f)

-- | Introspection Of Resolver ' a ::-> b'
-- introspects 'a' as argument and 'b' as output type
instance (OutputConstraint a, Args.GQLArgs p) => Introspect (Resolver c p a) WRAPPER OutputType where
  __field _ name = (__field (Context :: OutputOf a) name) {fieldArgs = map fst $ Args.introspect (Proxy @p)}
  introspect _ typeLib = resolveTypes typeLib $ inputTypes' ++ [introspect (Context :: OutputOf a)]
    where
      inputTypes' = map snd $ Args.introspect (Proxy @p)

instance Args.GQLArgs DeprecationArgs