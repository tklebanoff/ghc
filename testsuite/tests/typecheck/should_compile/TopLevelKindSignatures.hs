{-# LANGUAGE TypeFamilies, MultiParamTypeClasses, PolyKinds, ConstraintKinds, GADTs, ExplicitForAll #-}

module TopLevelKindSignatures where

import Data.Kind (Type, Constraint)

type MonoTagged :: Type -> Type -> Type
data MonoTagged t x = MonoTagged x

type Id :: forall k. k -> k
type family Id x where
  Id x = x

type C :: (k -> Type) -> k -> Constraint
class C a b where
  f :: a b

type TypeRep :: forall k. k -> Type
data TypeRep a where
  TyInt   :: TypeRep Int
  TyMaybe :: TypeRep Maybe
  TyApp   :: TypeRep a -> TypeRep b -> TypeRep (a b)

-- type D :: j -> Constraint -- #16571
type D :: Type -> Constraint
type D = C TypeRep
