------------------------------------------------------------------------
-- |
-- Module           : Reopt.CFG.Representation
-- Copyright        : (c) Galois, Inc 2015
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
--
-- This defines the data types needed to represent X86 control flow graps.
------------------------------------------------------------------------
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
module Reopt.CFG.Representation
  ( CFG
  , emptyCFG
  , cfgBlocks
  , cfgBlockEnds
  , insertBlocksForCode
  , traverseBlocks
  , traverseBlockAndChildren
  , findBlock
    -- * Block level declarations
  , BlockLabel(..)
  , isRootBlockLabel
  , rootBlockLabel
  , mkRootBlockLabel
  , Block(..)
  , CodeAddr
  , hasCallComment
  , hasRetComment
    -- * Stmt level declarations
  , Stmt(..)
  , TermStmt(..)
  , Assignment(..)
  , AssignId
  , AssignRhs(..)
  , refsInAssignRhs
    -- * Value
  , Value(..)
  , BVValue
  , valueAsApp
  , valueWidth
  , foldValueCached
  , asBaseOffset
  , asInt64Constant
  , asStackAddrOffset
  , mkLit
  , bvValue
  , ppValueAssignments
  , ppValueAssignmentList
  , refsInValue
  , App(..)
  -- * App
  , appType
  , appWidth
  , mapApp
  , foldApp
  , traverseApp
  -- * Pretty printing
  , ppApp
  , ppAssignId
  , ppLit
  , ppNat
  , ppValue
  , sexpr
  -- * X86 specific
  , X86_64
  , X86Reg(..)
  , X86PrimFn(..)
  , X86PrimLoc(..)
  , X86Stmt(..)
  ) where

import           Control.Applicative
import           Control.Exception (assert)
import           Control.Lens
import           Control.Monad.Identity
import           Control.Monad.State.Strict
import           Data.Bits
import           Data.Int (Int64)
import           Data.List
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (isNothing)
import           Data.Monoid as Monoid
import           Data.Parameterized.NatRepr
import           Data.Parameterized.TH.GADT
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Word
import           GHC.TypeLits
import           Numeric (showHex)
import           Text.PrettyPrint.ANSI.Leijen as PP hiding ((<$>))

import           Data.Parameterized.Classes
import           Data.Parameterized.Map (MapF)
import           Data.Parameterized.Some
import qualified Reopt.Machine.StateNames as N
import           Reopt.Machine.Types
import           Reopt.Machine.X86State
import           Reopt.Utils.PrettyPrint

-- Note:
-- The declarations in this file follow a top-down order, so the top-level
-- definitions should be first.

type Prec = Int

colonPrec :: Prec
colonPrec = 5

-- | An address of a code location.
--
-- This is currently just a Word64, but we may need to switch to a
-- structured representation once dynamic libraries are supported.
type CodeAddr = Word64

-- | Class for pretty printing with a precedence field.
class PrettyPrec v where
  prettyPrec :: Int -> v -> Doc

-- | Pretty print over all instances of a type.
class PrettyF (f :: k -> *) where
  prettyF :: f tp -> Doc

------------------------------------------------------------------------
-- BlockLabel

-- | A label used to identify a block.
--
-- The field is the address width.
data BlockLabel w
     -- | A block that came from an address in the code.
   = GeneratedBlock { labelAddr   :: !w
                    , labelIndex  :: {-# UNPACK #-} !Word64
                    -- ^ A unique identifier for a generated block.
                    }
  deriving Eq

isRootBlockLabel :: BlockLabel w -> Bool
isRootBlockLabel (GeneratedBlock _ w) = w == 0

rootBlockLabel :: BlockLabel w -> BlockLabel w
rootBlockLabel (GeneratedBlock p _) = GeneratedBlock p 0

mkRootBlockLabel :: w -> BlockLabel w
mkRootBlockLabel p = GeneratedBlock p 0

instance Ord w => Ord (BlockLabel w) where
  compare (GeneratedBlock p v) (GeneratedBlock p' v') =
    compare p p' Monoid.<> compare v v'

instance (Integral w, Show w) => Show (BlockLabel w) where
  showsPrec _ (GeneratedBlock a 0) s = "block_" ++ showHex a s
  showsPrec _ (GeneratedBlock a w) s = "subblock_" ++ showHex a ("_" ++ shows w s)
  {-# INLINABLE showsPrec #-}

instance (Integral w, Show w) => Pretty (BlockLabel w) where
  pretty l = text (show l)

-----------------------------------------------------------------------
-- App

-- | App defines builtin operations on values.
data App (f :: Type -> *) (tp :: Type) where

  Mux :: !(NatRepr n)
      -> !(f BoolType)
      -> !(f (BVType n))
      -> !(f (BVType n))
      -> App f (BVType n)

  ----------------------------------------------------------------------
  -- Operations related to concatenating and extending bitvectors.

  -- This returns a 80-bit value where the high 16-bits are all 1s,
  -- and the low 64-bits are the given register.
  MMXExtend :: !(f (BVType 64))
            -> App f (BVType 80)

  -- Concatenate two bitvectors together (low-bits are first)
  ConcatV :: !(NatRepr n)
          -> !(NatRepr m)
          -> !(f (BVType n))
          -> !(f (BVType m))
          -> App f (BVType (n+m))

  -- Get upper half of bitvector
  UpperHalf :: !(NatRepr n)
            -> !(f (BVType (n+n)))
            -> App f (BVType n)

  -- Truncate a bitvector value.
  Trunc :: (1 <= n, n+1 <= m) => !(f (BVType m)) -> !(NatRepr n) -> App f (BVType n)
  -- Signed extension.
  SExt :: (1 <= m, m+1 <= n) => f (BVType m) -> NatRepr n -> App f (BVType n)
  -- Unsigned extension.
  UExt :: (1 <= m, m+1 <= n) => f (BVType m) -> NatRepr n -> App f (BVType n)

  ----------------------------------------------------------------------
  -- Boolean operations

  AndApp :: !(f BoolType) -> !(f BoolType) -> App f BoolType
  OrApp  :: !(f BoolType) -> !(f BoolType) -> App f BoolType
  NotApp :: !(f BoolType) -> App f BoolType

  ----------------------------------------------------------------------
  -- Bitvector operations

  BVAdd :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)
  BVSub :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)

  -- Multiply two numbers
  BVMul :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)

  -- Unsigned division (rounds fractions to zero).
  --
  -- This operation is not defined when the denominator is zero. The
  -- caller should raise a #de exception in this case (see
  -- 'Reopt.Semantics.Implementation.exec_div').
  BVQuot :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)

  -- Unsigned modulo (rounds fractional results to zero)
  --
  -- See 'BVQuot' for usage.
  BVRem :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)

  -- Signed division (rounds fractional results to zero).
  --
  -- See 'BVQuot' for usage.
  BVSignedQuot :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)

  -- Signed modulo (rounds fractional results to zero).
  --
  -- The resulting modulus has the same sign as the quotient and satisfies
  -- the constraint that for all x y where y != 0:
  --   x = (y * BVSignedQuot x y) + BVSignedRem x y
  --
  -- See 'BVQuot' for usage.
  BVSignedRem :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)

  -- Unsigned less than.
  BVUnsignedLt :: !(f (BVType n)) -> !(f (BVType n)) -> App f BoolType

  -- Unsigned less than or equal.
  BVUnsignedLe :: !(f (BVType n)) -> !(f (BVType n)) -> App f BoolType

  -- Signed less than
  BVSignedLt :: !(f (BVType n)) -> !(f (BVType n)) -> App f BoolType

  -- Signed less than or equal.
  BVSignedLe :: !(f (BVType n)) -> !(f (BVType n)) -> App f BoolType

  -- @BVTestBit x i@ returns true iff bit @i@ of @x@ is true.
  -- 0 is the index of the least-significant bit.
  BVTestBit :: !(f (BVType n)) -> !(f (BVType log_n)) -> App f BoolType

  -- Bitwise complement
  BVComplement :: !(NatRepr n) -> !(f (BVType n)) -> App f (BVType n)
  -- Bitwise and
  BVAnd :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)
  -- Bitwise or
  BVOr  :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)
  -- Exclusive or
  BVXor :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)

  -- Logical left shift (x * 2 ^ n)
  BVShl :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)
  -- Logical right shift (x / 2 ^ n)
  BVShr :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)
  -- Arithmetic right shift (x / 2 ^ n)
  BVSar :: !(NatRepr n) -> !(f (BVType n)) -> !(f (BVType n)) -> App f (BVType n)

  -- Compare for equality.
  BVEq :: !(f (BVType n)) -> !(f (BVType n)) -> App f BoolType

  -- Return true if value contains even number of true bits.
  EvenParity :: !(f (BVType 8)) -> App f BoolType

  -- Reverse the bytes in a bitvector expression.
  ReverseBytes :: !(NatRepr n) -> !(f (BVType n)) -> App f (BVType n)

  -- Add two values and a carry bit to determine if they have an unsigned
  -- overflow.
  UadcOverflows :: !(NatRepr n)
                -> !(f (BVType n))
                -> !(f (BVType n))
                -> !(f BoolType)
                -> App f BoolType
  -- Add two values and a carry bit to determine if they have a signed
  -- overflow.
  SadcOverflows :: !(NatRepr n)
                -> !(f (BVType n))
                -> !(f (BVType n))
                -> !(f BoolType)
                -> App f BoolType

  -- Unsigned subtract with borrow overflow
  UsbbOverflows :: !(NatRepr n)
                -> !(f (BVType n))
                -> !(f (BVType n))
                -> !(f BoolType)
                -> App f BoolType

  -- Signed subtract with borrow overflow
  SsbbOverflows :: !(NatRepr n)
                -> !(f (BVType n))
                -> !(f (BVType n))
                -> !(f BoolType)
                -> App f BoolType


  -- bsf "bit scan forward" returns the index of the least-significant
  -- bit that is 1.  Undefined if value is zero.
  -- All bits at indices less than return value must be unset.
  Bsf :: !(NatRepr n) -> !(f (BVType n)) -> App f (BVType n)

  -- bsr "bit scan reverse" returns the index of the most-significant
  -- bit that is 1.  Undefined if value is zero.
  -- All bits at indices greater than return value must be unset.
  Bsr :: !(NatRepr n) -> !(f (BVType n)) -> App f (BVType n)

  ----------------------------------------------------------------------
  -- Floating point operations

  FPIsQNaN :: !(FloatInfoRepr flt)
           -> !(f (FloatType flt))
           -> App f BoolType

  FPIsSNaN :: !(FloatInfoRepr flt)
           -> !(f (FloatType flt))
           -> App f BoolType

  FPAdd :: !(FloatInfoRepr flt)
        -> !(f (FloatType flt))
        -> !(f (FloatType flt))
        -> App f (FloatType flt)

  FPAddRoundedUp :: !(FloatInfoRepr flt)
                 -> !(f (FloatType flt))
                 -> !(f (FloatType flt))
                 -> App f BoolType

  FPSub :: !(FloatInfoRepr flt)
        -> !(f (FloatType flt))
        -> !(f (FloatType flt))
        -> App f (FloatType flt)

  FPSubRoundedUp
    :: !(FloatInfoRepr flt)
    -> !(f (FloatType flt))
    -> !(f (FloatType flt))
    -> App f BoolType

  FPMul :: !(FloatInfoRepr flt)
        -> !(f (FloatType flt))
        -> !(f (FloatType flt))
        -> App f (FloatType flt)

  FPMulRoundedUp :: !(FloatInfoRepr flt)
                 -> !(f (FloatType flt))
                 -> !(f (FloatType flt))
                 -> App f BoolType

  -- Divides two floating point numbers.
  FPDiv :: !(FloatInfoRepr flt)
        -> !(f (FloatType flt))
        -> !(f (FloatType flt))
        -> App f (FloatType flt)

  -- Compare if one floating is strictly less than another.
  FPLt :: !(FloatInfoRepr flt)
       -> !(f (FloatType flt))
       -> !(f (FloatType flt))
       -> App f BoolType

  -- Floating point equality (equates -0 and 0)
  FPEq :: !(FloatInfoRepr flt)
       -> !(f (FloatType flt))
       -> !(f (FloatType flt))
       -> App f BoolType

  FPCvt :: !(FloatInfoRepr flt)
        -> !(f (FloatType flt))
        -> !(FloatInfoRepr flt')
        -> App f (FloatType flt')

  FPCvtRoundsUp :: !(FloatInfoRepr flt)
                -> !(f (FloatType flt))
                -> !(FloatInfoRepr flt')
                -> App f BoolType

  FPFromBV :: !(f (BVType n))
           -> !(FloatInfoRepr flt)
           -> App f (FloatType flt)

  -- Convert a floating point value to a signed integer.
  -- If the conversion is inexact, then the value is truncated to zero.
  -- If the conversion is out of the range of the bitvector, then a floating
  -- point exception should be raised.
  -- If that exception is masked, then this returns -1 (as a signed bitvector).
  TruncFPToSignedBV :: FloatInfoRepr flt
                    -> f (FloatType flt)
                    -> NatRepr n
                    -> App f (BVType n)

------------------------------------------------------------------------
-- App pretty printing

sexpr :: String -> [Doc] -> Doc
sexpr nm d = parens (hsep (text nm : d))

sexprA :: Applicative m => String -> [m Doc] -> m Doc
sexprA nm d = sexpr nm <$> sequenceA d

ppNat :: Applicative m => NatRepr n -> m Doc
ppNat n = pure (text (show n))

prettyPure :: (Applicative m, Pretty v) => v -> m Doc
prettyPure = pure . pretty

ppApp :: (forall u . f u -> Doc)
      -> App f tp
      -> Doc
ppApp pp a0 = runIdentity $ ppAppA (Identity . pp) a0

ppAppA :: Applicative m
      => (forall u . f u -> m Doc)
      -> App f tp
      -> m Doc
ppAppA pp a0 =
  case a0 of
    Mux _ c x y -> sexprA "mux" [ pp c, pp x, pp y ]
    MMXExtend e -> sexprA "mmx_extend" [ pp e ]
    ConcatV _ _ x y -> sexprA "concat" [ pp x, pp y ]
    UpperHalf _ x -> sexprA "upper_half" [ pp x ]
    Trunc x w -> sexprA "trunc" [ pp x, ppNat w ]
    SExt x w -> sexprA "sext" [ pp x, ppNat w ]
    UExt x w -> sexprA "uext" [ pp x, ppNat w ]
    AndApp x y -> sexprA "and" [ pp x, pp y ]
    OrApp  x y -> sexprA "or"  [ pp x, pp y ]
    NotApp x   -> sexprA "not" [ pp x ]
    BVAdd _ x y -> sexprA "bv_add" [ pp x, pp y ]
    BVSub _ x y -> sexprA "bv_sub" [ pp x, pp y ]
    BVMul _ x y -> sexprA "bv_mul" [ pp x, pp y ]
    BVQuot _ x y      -> sexprA "bv_uquot" [ pp x, pp y ]
    BVSignedQuot _ x y -> sexprA "bv_squot" [ pp x, pp y ]
    BVRem _ x y       -> sexprA "bv_urem" [ pp x, pp y ]
    BVSignedRem _ x y -> sexprA "bv_srem" [ pp x, pp y ]
    BVUnsignedLt x y  -> sexprA "bv_ult"  [ pp x, pp y ]
    BVUnsignedLe x y  -> sexprA "bv_ule"  [ pp x, pp y ]
    BVSignedLt x y    -> sexprA "bv_slt"  [ pp x, pp y ]
    BVSignedLe x y    -> sexprA "bv_sle"  [ pp x, pp y ]
    BVTestBit x i -> sexprA "bv_testbit" [ pp x, pp i]
    BVComplement _ x -> sexprA "bv_complement" [ pp x ]
    BVAnd _ x y -> sexprA "bv_and" [ pp x, pp y ]
    BVOr  _ x y -> sexprA "bv_or"  [ pp x, pp y ]
    BVXor _ x y -> sexprA "bv_xor" [ pp x, pp y ]
    BVShl _ x y -> sexprA "bv_shl" [ pp x, pp y ]
    BVShr _ x y -> sexprA "bv_shr" [ pp x, pp y ]
    BVSar _ x y -> sexprA "bv_sar" [ pp x, pp y ]
    BVEq x y    -> sexprA "bv_eq" [ pp x, pp y ]
    EvenParity x -> sexprA "even_parity" [ pp x ]
    ReverseBytes _ x -> sexprA "reverse_bytes" [ pp x ]
    UadcOverflows _ x y c -> sexprA "uadc_overflows" [ pp x, pp y, pp c ]
    SadcOverflows _ x y c -> sexprA "sadc_overflows" [ pp x, pp y, pp c ]
    UsbbOverflows _ x y c -> sexprA "usbb_overflows" [ pp x, pp y, pp c ]
    SsbbOverflows _ x y c -> sexprA "ssbb_overflows" [ pp x, pp y, pp c ]
    Bsf _ x -> sexprA "bsf" [ pp x ]
    Bsr _ x -> sexprA "bsr" [ pp x ]

    -- Floating point
    FPIsQNaN rep x          -> sexprA "fpIsQNaN" [ prettyPure rep, pp x ]
    FPIsSNaN rep x          -> sexprA "fpIsSNaN" [ prettyPure rep, pp x ]
    FPAdd rep x y           -> sexprA "fpAdd" [ prettyPure rep, pp x, pp y ]
    FPAddRoundedUp rep x y  -> sexprA "fpAddRoundedUp" [ prettyPure rep, pp x, pp y ]
    FPSub rep x y           -> sexprA "fpSub" [ prettyPure rep, pp x, pp y ]
    FPSubRoundedUp rep x y  -> sexprA "fpSubRoundedUp" [ prettyPure rep, pp x, pp y ]
    FPMul rep x y           -> sexprA "fpMul" [ prettyPure rep, pp x, pp y ]
    FPMulRoundedUp rep x y  -> sexprA "fpMulRoundedUp" [ prettyPure rep, pp x, pp y ]
    FPDiv rep x y           -> sexprA "fpDiv" [ prettyPure rep, pp x, pp y ]
    FPLt rep x y            -> sexprA "fpLt" [ prettyPure rep, pp x, pp y ]
    FPEq rep x y            -> sexprA "fpEq" [ prettyPure rep, pp x, pp y ]
    FPCvt src x tgt         -> sexprA "fpCvt" [ prettyPure src, pp x, prettyPure tgt ]
    FPCvtRoundsUp src x tgt -> sexprA "fpCvtRoundsUp" [ prettyPure src, pp x, prettyPure tgt ]
    FPFromBV x tgt          -> sexprA "fpFromBV" [ pp x, prettyPure tgt ]
    TruncFPToSignedBV _ x w -> sexprA "truncFP_sbv" [ pp x, ppNat w]

-- Force app to be in template-haskell context.
$(pure [])

------------------------------------------------------------------------
-- appType

appType :: App f tp -> TypeRepr tp
appType a =
  case a of
    Mux w _ _ _ -> BVTypeRepr w
    MMXExtend{} -> knownType
    ConcatV w w' _ _ -> BVTypeRepr (addNat w w')
    UpperHalf w _ -> BVTypeRepr w
    Trunc _ w -> BVTypeRepr w
    SExt _ w -> BVTypeRepr w
    UExt _ w -> BVTypeRepr w

    AndApp{} -> knownType
    OrApp{}  -> knownType
    NotApp{} -> knownType

    BVAdd w _ _ -> BVTypeRepr w
    BVSub w _ _ -> BVTypeRepr w
    BVMul w _ _ -> BVTypeRepr w
    BVQuot w _ _ -> BVTypeRepr w
    BVSignedQuot w _ _ -> BVTypeRepr w
    BVRem w _ _ -> BVTypeRepr w
    BVSignedRem w _ _ -> BVTypeRepr w

    BVUnsignedLt{} -> knownType
    BVUnsignedLe{} -> knownType
    BVSignedLt{} -> knownType
    BVSignedLe{} -> knownType
    BVTestBit{} -> knownType

    BVComplement w _ -> BVTypeRepr w
    BVAnd w _ _ -> BVTypeRepr w
    BVOr  w _ _ -> BVTypeRepr w
    BVXor w _ _ -> BVTypeRepr w
    BVShl w _ _ -> BVTypeRepr w
    BVShr w _ _ -> BVTypeRepr w
    BVSar w _ _ -> BVTypeRepr w
    BVEq _ _ -> knownType
    EvenParity _ -> knownType
    ReverseBytes w _ -> BVTypeRepr w

    UadcOverflows{}  -> knownType
    SadcOverflows{} -> knownType
    UsbbOverflows{} -> knownType
    SsbbOverflows{} -> knownType

    Bsf w _ -> BVTypeRepr w
    Bsr w _ -> BVTypeRepr w

    -- Floating point
    FPIsQNaN _ _ -> knownType
    FPIsSNaN _ _ -> knownType
    FPAdd rep _ _ -> floatTypeRepr rep
    FPAddRoundedUp{} -> knownType
    FPSub rep _ _ -> floatTypeRepr rep
    FPSubRoundedUp{} -> knownType
    FPMul rep _ _ -> floatTypeRepr rep
    FPMulRoundedUp{} -> knownType
    FPDiv rep _ _ -> floatTypeRepr rep
    FPLt{} -> knownType
    FPEq{} -> knownType
    FPCvt _ _ tgt   -> floatTypeRepr tgt
    FPCvtRoundsUp{} -> knownType
    FPFromBV _ tgt  -> floatTypeRepr tgt
    TruncFPToSignedBV _ _ w -> BVTypeRepr w

appWidth :: App f (BVType n) -> NatRepr n
appWidth a =
  case appType a of
    BVTypeRepr n -> n

$(pure [])
------------------------------------------------------------------------
-- Type famiulies for architecture specific components.

-- | A type family for architecture specific functions.
--
-- These function may return a value.  They may depend on the current state of
-- the heap, but should not affect the processor in any way.
type family ArchFn (arch :: Symbol) :: Type -> *

-- | A type family for defining architecture specific registers that are
-- assigned as part of the language.
type family ArchReg (arch :: symbol) :: Type -> *

-- | A type family for defining architecture specici statements that are
-- part of the language.
type family ArchStmt (arch :: Symbol) :: *

-- | Number of bits in addreses for architecture.
type family ArchAddrWidth (arch :: Symbol) :: Nat

------------------------------------------------------------------------
-- AssignId

-- | This should be an identifier that can be used to identify the
-- assignment statement uniquely within the CFG.
type AssignId = Word64

ppAssignId :: AssignId -> Doc
ppAssignId w = text ("r" ++ show w)

------------------------------------------------------------------------
-- Value, Assignment, AssignRhs declarations.

-- | A value at runtime.
data Value arch tp
   = forall n . (tp ~ BVType n) => BVValue !(NatRepr n) !Integer
     -- ^ Bitvector value.
   | AssignedValue !(Assignment arch tp)
     -- ^ Value from an assignment statement.
   | Initial !(ArchReg arch tp)
     -- ^ Denotes the value for an initial register

type BVValue arch w = Value arch (BVType w)

-- | An assignment consists of a unique location identifier and a right-
-- hand side that returns a value.
data Assignment arch tp = Assignment { assignId :: !AssignId
                                     , assignRhs :: !(AssignRhs arch tp)
                                     }

-- | The right hand side of an assignment is an expression that
-- returns a value.
data AssignRhs (arch :: Symbol) tp where
  -- An expression that is computed from evaluating subexpressions.
  EvalApp :: !(App (Value arch) tp)
          -> AssignRhs arch tp

  -- An expression with an undefined value.
  SetUndefined :: (tp ~ BVType n)
               => !(NatRepr n) -- Width of undefined value.
               -> AssignRhs arch tp

  -- Read memory at given location.
  ReadMem :: !(Value arch (BVType (ArchAddrWidth arch)))
          -> !(TypeRepr tp)
          -> AssignRhs arch tp

  -- Call an architecture specific function that returns some result.
  EvalArchFn :: !(ArchFn arch tp)
             -> AssignRhs arch tp

------------------------------------------------------------------------
-- Type operations on assignment AssignRhs, and Value

instance HasRepr (ArchFn arch) TypeRepr
      => HasRepr (Assignment arch) TypeRepr where
  typeRepr = typeRepr . assignRhs

instance HasRepr (ArchFn arch) TypeRepr
      => HasRepr (AssignRhs arch) TypeRepr where
  typeRepr rhs =
    case rhs of
      EvalApp a -> appType a
      SetUndefined w -> BVTypeRepr w
      ReadMem _ tp -> tp
      EvalArchFn f -> typeRepr f

instance ( HasRepr (ArchFn arch) TypeRepr
         , HasRepr (ArchReg arch) TypeRepr
         )
      => HasRepr (Value arch) TypeRepr where

  typeRepr (BVValue n _) = BVTypeRepr n
  typeRepr (AssignedValue a) = typeRepr a
  typeRepr (Initial r) = typeRepr r

valueWidth :: ( HasRepr (ArchFn arch) TypeRepr
              , HasRepr (ArchReg arch) TypeRepr
              )
           => Value arch (BVType n) -> NatRepr n
valueWidth v =
  case typeRepr v of
    BVTypeRepr n -> n

$(pure [])

instance HasRepr (AssignRhs arch) TypeRepr
      => TestEquality (Assignment arch) where
  testEquality x y = orderingF_refl (compareF x y)

instance HasRepr (AssignRhs arch) TypeRepr
      => OrdF (Assignment arch) where
  compareF x y =
    case compare (assignId x) (assignId y) of
      LT -> LTF
      GT -> GTF
      EQ ->
        case testEquality (typeRepr (assignRhs x)) (typeRepr (assignRhs y)) of
          Just Refl -> EQF
          Nothing -> error "mismatched types"

$(pure [])

------------------------------------------------------------------------
-- Pretty print a value

ppLit :: NatRepr n -> Integer -> Doc
ppLit w i =
  text ("0x" ++ showHex i "") <+> text "::" <+> brackets (text (show w))

-- | Pretty print a value.
ppValue :: ShowF (ArchReg arch) => Prec -> Value arch tp -> Doc
ppValue p (BVValue w i) = assert (i >= 0) $ parenIf (p > colonPrec) $ ppLit w i
ppValue _ (AssignedValue a) = ppAssignId (assignId a)
ppValue _ (Initial r)       = text (showF r) PP.<> text "_0"

instance ShowF (ArchReg arch) => PrettyPrec (Value arch tp) where
  prettyPrec = ppValue

instance ShowF (ArchReg arch) => Pretty (Value arch tp) where
  pretty = ppValue 0

instance ShowF (ArchReg arch) => Show (Value arch tp) where
  show = show . pretty

$(pure [])

------------------------------------------------------------------------
-- Pretty print Assign, AssignRhs operations

-- | Pretty print an assignment right-hand side using operations parameterized
-- over an application to allow side effects.
ppAssignRhs :: Applicative m
            => (forall u . Value arch u -> m Doc)
               -- ^ Function for pretty printing value.
            -> (forall u . ArchFn arch u -> m Doc)
               -- ^ Function for pretty printing an architecture-specific function
            -> AssignRhs arch tp
            -> m Doc
ppAssignRhs pp _ (EvalApp a) = ppAppA pp a
ppAssignRhs _  _ (SetUndefined w) = pure $ text "undef ::" <+> brackets (text (show w))
ppAssignRhs pp _ (ReadMem a _) = (\d -> text "*" PP.<> d) <$> pp a
ppAssignRhs _ pp (EvalArchFn f) = pp f

instance ( ShowF (ArchReg arch)
         , PrettyF (ArchFn arch)
         ) =>
         Pretty (AssignRhs arch tp) where
  pretty v = runIdentity $ ppAssignRhs (Identity . ppValue 10) (Identity . prettyF) v

instance ( ShowF (ArchReg arch)
         , PrettyF (ArchFn arch)
         ) =>
         Pretty (Assignment arch tp) where
  pretty (Assignment lhs rhs) = ppAssignId lhs <+> text ":=" <+> pretty rhs

$(pure [])

------------------------------------------------------------------------
-- Stmt

-- | A statement in our control flow graph language.
data Stmt arch
   = forall tp . AssignStmt !(Assignment arch tp)
   | forall tp . WriteMem !(BVValue arch (ArchAddrWidth arch)) !(Value arch tp)
    -- ^ Write to memory at the given location
   | PlaceHolderStmt !([Some (Value arch)]) !String
   | Comment !Text
   | ExecArchStmt (ArchStmt arch)
     -- ^ Execute an architecture specific statement

instance ( ShowF (ArchReg arch)
         , Pretty (ArchStmt arch)
         , PrettyF (ArchFn arch)
         )
         => Pretty (Stmt arch) where
  pretty (AssignStmt a) = pretty a
  pretty (WriteMem a rhs) = text "*" PP.<> prettyPrec 11 a <+> text ":=" <+> ppValue 0 rhs
  pretty (PlaceHolderStmt vals name) = text ("PLACEHOLDER: " ++ name)
                                       <+> parens (hcat $ punctuate comma
                                                   $ map (viewSome (ppValue 0)) vals)
  pretty (Comment s) = text $ "# " ++ Text.unpack s
  pretty (ExecArchStmt s) = pretty s


instance ( ShowF (ArchReg arch)
         , Pretty (ArchStmt arch)
         , PrettyF (ArchFn arch)
         )
         => Show (Stmt arch) where
  show = show . pretty

$(pure [])

------------------------------------------------------------------------
-- X86_64 specific declarations

type X86_64 = "x86_64"
type instance ArchAddrWidth X86_64 = 64
type instance ArchReg  X86_64 = X86Reg
type instance ArchFn   X86_64 = X86PrimFn
type instance ArchStmt X86_64 = X86Stmt

------------------------------------------------------------------------
-- X86Reg

-- | Defines the register type for X86 instructions.
data X86Reg tp
   = forall cl . (N.RegisterType cl ~ tp) => X86Reg (N.RegisterName cl)

instance TestEquality X86Reg where
  testEquality (X86Reg x) (X86Reg y) = (\Refl -> Refl) <$> testEquality x y

instance OrdF X86Reg where
  compareF (X86Reg x) (X86Reg y) = do
    case compareF x y of
      EQF -> EQF
      LTF -> LTF
      GTF -> GTF

instance ShowF X86Reg where
  showF (X86Reg r) = show r

instance HasRepr X86Reg TypeRepr where
  typeRepr (X86Reg r) = N.registerType r

------------------------------------------------------------------------
-- X86PrimLoc

-- | This describes a primitive location that can be read or written to in the
-- X86 architecture model.
data X86PrimLoc tp where
  ControlLoc :: !(N.RegisterName 'N.Control) -> X86PrimLoc (BVType 64)
  DebugLoc   :: !(N.RegisterName 'N.Debug)   -> X86PrimLoc (BVType 64)

  -- | This refers to the selector of the 'FS' register.
  FS :: X86PrimLoc (BVType 16)
  -- | This refers to the selector of the 'GS' register.
  GS :: X86PrimLoc (BVType 16)

  -- X87 precision control field.  Values are:
  -- 00 Single Precision (24 bits)
  -- 01 Reserved
  -- 10 Double Precision (53 bits)
  -- 11 Double Extended Precision (64 bits)
  X87_PC :: X86PrimLoc (BVType 2)

  -- X87 rounding control field.  Values are:
  --
  -- 00 Round to nearest (even)
  -- Rounded result is the closest to the infinitely precise result. If two
  -- values are equally close, the result is the even value (that is, the one
  -- with the least-significant bit of zero). Default
  --
  -- 01 Round down (toward −∞)
  -- Rounded result is closest to but no greater than the infinitely precise result.
  --
  -- 10 Round up (toward +∞)
  -- Rounded result is closest to but no less than the infinitely precise result.
  --
  -- 11 Round toward zero (Truncate)
  -- Rounded result is closest to but no greater in absolute value than the
  -- infinitely precise result.
  X87_RC :: X86PrimLoc (BVType 2)

instance HasRepr X86PrimLoc TypeRepr where
  typeRepr ControlLoc{} = knownType
  typeRepr DebugLoc{}   = knownType
  typeRepr FS = knownType
  typeRepr GS = knownType
  typeRepr X87_PC = knownType
  typeRepr X87_RC = knownType

instance Pretty (X86PrimLoc tp) where
  pretty (ControlLoc r) = text (show r)
  pretty (DebugLoc r) = text (show r)
  pretty FS = text "fs"
  pretty GS = text "gs"
  pretty X87_PC = text "x87_pc"
  pretty X87_RC = text "x87_rc"

------------------------------------------------------------------------
-- X86PrimFn

-- | Defines primitive functions in the X86 format.
data X86PrimFn tp
   = ReadLoc !(X86PrimLoc tp)
     -- ^ Read from a primitive X86 location
   | (tp ~ BVType 64) => ReadFSBase
     -- ^ Read the 'FS' base address
   | (tp ~ BVType 64) => ReadGSBase
     -- ^ Read the 'GS' base address
   | (tp ~ BVType 64)
     => MemCmp !Integer
               -- ^ Number of bytes per value.
               !(BVValue X86_64 64)
               -- ^ Number of values to compare
               !(BVValue X86_64 64)
               -- ^ Pointer to first buffer.
               !(BVValue X86_64 64)
               -- ^ Pointer to second buffer.
               !(BVValue X86_64 1)
               -- ^ Direction flag, False means increasing
     -- ^ Compares to memory regions
   | forall n
     . (tp ~ BVType 64, 1 <= n)
     => FindElement !Integer
                    -- ^ Number of bytes to compare at a time {1, 2, 4, 8}
                    !Bool
                    -- ^ Find first matching (True) or not matching (False)
                    !(BVValue X86_64 64)
                    -- ^ Number of elements to compare
                    !(BVValue X86_64 64)
                    -- ^ Pointer to first buffer
                    !(BVValue X86_64 n)
                    -- ^ Value to compare
                    !(BVValue X86_64 1)
                    -- ^ Flag indicates direction of copy:
                    -- True means we should decrement buffer pointers after each copy.
                    -- False means we should increment the buffer pointers after each copy.

instance HasRepr X86PrimFn TypeRepr where
  typeRepr f =
    case f of
      ReadLoc loc   -> typeRepr loc
      ReadFSBase    -> knownType
      ReadGSBase    -> knownType
      MemCmp{}      -> knownType
      FindElement{} -> knownType

instance PrettyF X86PrimFn where
  prettyF = runIdentity . ppX86PrimFn (Identity . ppValue 10)

ppX86PrimFn :: Applicative m
             => (forall u . Value X86_64 u -> m Doc)
               -- ^ Function for pretty printing vlaue.
            -> X86PrimFn tp
            -> m Doc
ppX86PrimFn pp f =
  case f of
    ReadLoc loc -> pure $ pretty loc
    ReadFSBase  -> pure $ text "fs.base"
    ReadGSBase  -> pure $ text "gs.base"
    MemCmp sz cnt src dest rev -> sexprA "memcmp" args
      where args = [pure (pretty sz), pp cnt, pp dest, pp src, pp rev]
    FindElement sz fndeq cnt buf val rev -> sexprA "find_element" args
      where args = [pure (pretty sz), pure (pretty fndeq), pp cnt, pp buf, pp val, pp rev]

------------------------------------------------------------------------
-- X86Stmt

-- | An X86 specific statement
data X86Stmt
   = forall tp .
     WriteLoc !(X86PrimLoc tp) !(Value X86_64 tp)
   | MemCopy !Integer
             -- ^ Number of bytes to copy at a time (1,2,4,8)
             !(BVValue X86_64 64)
             -- ^ Number of values to move.
             !(BVValue X86_64 64)
             -- ^ Start of source buffer.
             !(BVValue X86_64 64)
             -- ^ Start of destination buffer.
             !(BVValue X86_64 1)
             -- ^ Flag indicates whether direction of move:
             -- True means we should decrement buffer pointers after each copy.
             -- False means we should increment the buffer pointers after each copy.
   | forall n .
     MemSet !(BVValue X86_64 64)
            -- ^ Number of values to assign
            !(BVValue X86_64 n)
            -- ^ Value to assign
            !(BVValue X86_64 64)
            -- ^ Address to start assigning from.
            !(BVValue X86_64 1)
            -- ^ Direction flag

instance Pretty X86Stmt where
  pretty (WriteLoc loc rhs) = pretty loc <+> text ":=" <+> ppValue 0 rhs
  pretty (MemCopy sz cnt src dest rev) =
      text "memcopy" <+> parens (hcat $ punctuate comma args)
    where args = [pretty sz, pretty cnt, pretty src, pretty dest, pretty rev]
  pretty (MemSet cnt val dest df) =
      text "memset" <+> parens (hcat $ punctuate comma args)
    where args = [pretty cnt, pretty val, pretty dest, pretty df]

------------------------------------------------------------------------
-- TermStmt

-- A terminal statement in a block
data TermStmt
     -- | Fetch and execute the next instruction from the given processor state.
  = FetchAndExecute !(X86State (Value X86_64))
    -- | Branch and execute one block or another.
  | Branch !(Value X86_64 BoolType) !(BlockLabel Word64) !(BlockLabel Word64)
    -- | The syscall instruction.
    -- We model system calls as terminal instructions because from the
    -- application perspective, the semantics will depend on the operating
    -- system.
  | Syscall !(X86State (Value X86_64))

instance Pretty TermStmt where
  pretty (FetchAndExecute s) =
    text "fetch_and_execute" <$$>
    indent 2 (pretty s)
  pretty (Branch c x y) =
    text "branch" <+> ppValue 0 c <+> pretty x <+> pretty y
  pretty (Syscall s) =
    text "syscall" <$$>
    indent 2 (pretty s)

------------------------------------------------------------------------
-- Value operations

instance ( OrdF (ArchReg arch)
         , HasRepr (ArchFn arch) TypeRepr
         )
      => Eq  (Value arch tp) where
  x == y = isJust (testEquality x y)

instance ( OrdF (ArchReg arch)
         , HasRepr (ArchFn arch) TypeRepr
         )
      => Ord (Value arch tp) where
  compare x y = toOrdering (compareF x y)

instance ( OrdF (ArchReg arch)
         , HasRepr (ArchFn arch) TypeRepr
         )
      => EqF (Value arch) where
  eqF = (==)

instance ( OrdF (ArchReg arch)
         , HasRepr (ArchFn arch) TypeRepr
         )
      => TestEquality (Value arch) where
  testEquality x y = orderingF_refl (compareF x y)

instance ( OrdF (ArchReg arch)
         , HasRepr (ArchFn arch) TypeRepr
         )
      => OrdF (Value arch) where
  compareF (BVValue wx vx) (BVValue wy vy) =
    case compareF wx wy of
      LTF -> LTF
      EQF -> fromOrdering (compare vx vy)
      GTF -> GTF
  compareF BVValue{} _ = LTF
  compareF _ BVValue{} = GTF

  compareF (AssignedValue a1) (AssignedValue a2) = compareF a1 a2
  compareF AssignedValue{} _ = LTF
  compareF _ AssignedValue{} = GTF

  compareF (Initial r) (Initial r') =
    case compareF r r' of
      LTF -> LTF
      EQF -> EQF
      GTF -> GTF


valueAsApp :: Value arch tp -> Maybe (App (Value arch) tp)
valueAsApp (AssignedValue (Assignment _ (EvalApp a))) = Just a
valueAsApp _ = Nothing

asInt64Constant :: Value arch (BVType 64) -> Maybe Int64
asInt64Constant (BVValue _ o) = Just (fromInteger o)
asInt64Constant _ = Nothing

asStackAddrOffset :: Value X86_64 tp -> Maybe (BVValue X86_64 64)
asStackAddrOffset addr
  | Just (BVAdd _ (Initial base) offset) <- valueAsApp addr
  , Just Refl <- testEquality base (X86Reg N.rsp) = do
    Just offset
  | Initial base <- addr
  , Just Refl <- testEquality base (X86Reg N.rsp) = do
    Just (BVValue knownNat 0)
  | otherwise =
    Nothing

asBaseOffset :: Value arch (BVType w) -> (Value arch (BVType w), Integer)
asBaseOffset x
  | Just (BVAdd _ x_base (BVValue _  x_off)) <- valueAsApp x = (x_base, x_off)
  | otherwise = (x,0)

mkLit :: NatRepr n -> Integer -> Value arch (BVType n)
mkLit n v = BVValue n (v .&. mask)
  where mask = maxUnsigned n

bvValue :: KnownNat n => Integer -> Value arch (BVType n)
bvValue i = mkLit knownNat i

instance PrettyRegValue (Value X86_64) where
  ppValueEq r v
    | Just _ <- testEquality v (Initial (X86Reg r)) = Nothing
    | otherwise   = Just $ text (show r) <+> text "=" <+> pretty v


collectValueRep :: Prec -> Value X86_64 tp -> State (Map AssignId Doc) Doc
collectValueRep _ (AssignedValue a) = do
  let lhs = assignId a
  mr <- gets $ Map.lookup lhs
  when (isNothing mr) $ do
    let ppVal :: forall u . Value X86_64 u -> State (Map AssignId Doc) Doc
        ppVal = collectValueRep 10
    rhs <- ppAssignRhs ppVal (ppX86PrimFn ppVal) (assignRhs a)
    let d = ppAssignId lhs <+> text ":=" <+> rhs
    modify $ Map.insert lhs d
  return $! ppAssignId lhs
collectValueRep p v = return $ ppValue p v

-- | This pretty prints all the history used to create a value.
ppValueAssignments' :: State (Map AssignId Doc) Doc -> Doc
ppValueAssignments' m =
  case Map.elems bindings of
    [] -> rhs
    (h:r) ->
      let first = text "let" PP.<+> h
          f b   = text "    " PP.<> b
       in vcat (first:fmap f r) <$$>
          text " in" PP.<+> rhs
  where (rhs, bindings) = runState m Map.empty

-- | This pretty prints all the history used to create a value.
ppValueAssignments :: Value X86_64 tp -> Doc
ppValueAssignments v = ppValueAssignments' (collectValueRep 0 v)


ppValueAssignmentList :: [Value X86_64 tp] -> Doc
ppValueAssignmentList vals =
  ppValueAssignments' $ do
    docs <- mapM (collectValueRep 0) vals
    return $ brackets $ hcat (punctuate comma docs)

-----------------------------------------------------------------------
-- App utilities

-- Force app to be in template-haskell context.
$(pure [])

instance TestEquality f => Eq (App f tp) where
  (==) = \x y -> isJust (testEquality x y)

instance TestEquality f => TestEquality (App f) where
  testEquality = $(structuralTypeEquality [t|App|]
                   [ (DataArg 0                  `TypeApp` AnyType, [|testEquality|])
                   , (ConType [t|NatRepr|]       `TypeApp` AnyType, [|testEquality|])
                   , (ConType [t|FloatInfoRepr|] `TypeApp` AnyType, [|testEquality|])
                   ]
                  )

instance OrdF f => OrdF (App f) where
  compareF = $(structuralTypeOrd [t|App|]
                   [ (DataArg 0                  `TypeApp` AnyType, [|compareF|])
                   , (ConType [t|NatRepr|]       `TypeApp` AnyType, [|compareF|])
                   , (ConType [t|FloatInfoRepr|] `TypeApp` AnyType, [|compareF|])
                   ]
              )

instance OrdF f => Ord (App f tp) where
  compare a b = case compareF a b of LTF -> LT
                                     EQF -> EQ
                                     GTF -> GT

traverseApp :: Applicative m
            => (forall u . f u -> m (g u))
            -> App f tp
            -> m (App g tp)
traverseApp = $(structuralTraversal [t|App|] [])

mapApp :: (forall u . f u -> g u)
       -> App f tp
       -> App g tp
mapApp f m = runIdentity $ traverseApp (return . f) m

foldApp :: Monoid m => (forall u. f u -> m) -> App f tp -> m
foldApp f m = getConst (traverseApp (\f_u -> Const $ f f_u) m)


------------------------------------------------------------------------
-- Compute set of assignIds in values.

refsInApp :: App (Value arch) tp -> Set AssignId
refsInApp app = foldApp refsInValue app

refsInValue :: Value arch tp -> Set AssignId
refsInValue (AssignedValue (Assignment v _)) = Set.singleton v
refsInValue _                                = Set.empty

refsInAssignRhs :: AssignRhs X86_64 tp -> Set AssignId
refsInAssignRhs rhs =
  case rhs of
    EvalApp v      -> refsInApp v
    SetUndefined _ -> Set.empty
    ReadMem v _    -> refsInValue v
    EvalArchFn f ->
      case f of
        ReadLoc _ -> Set.empty
        ReadFSBase -> Set.empty
        ReadGSBase -> Set.empty
        MemCmp _ cnt src dest dir ->
          Set.unions [ refsInValue cnt
                     , refsInValue src
                     , refsInValue dest
                     , refsInValue dir
                     ]
        FindElement _ _ cnt buf val dir ->
          Set.unions [ refsInValue cnt
                     , refsInValue buf
                     , refsInValue val
                     , refsInValue dir
                     ]

------------------------------------------------------------------------
-- StateMonadMonoid

-- helper type to make a monad a monoid in the obvious way
newtype StateMonadMonoid s m = SMM { getStateMonadMonoid :: State s m }
                               deriving (Functor, Applicative, Monad, MonadState s)

instance Monoid m => Monoid (StateMonadMonoid s m) where
  mempty = return mempty
  mappend m m' = do mv <- m
                    mv' <- m'
                    return (mappend mv mv')

foldValueCached :: forall m tp
                .  (Monoid m)
                => (forall n.  NatRepr n -> Integer -> m)
                -> (forall cl. N.RegisterName cl -> m)
                -> (forall tp' . Assignment X86_64 tp' -> m -> m)
                -> Value X86_64 tp
                -> State (Map (Some (Assignment X86_64)) m) m
foldValueCached litf initf assignf val = getStateMonadMonoid (go val)
  where
    go :: forall tp'
       .  Value X86_64 tp'
       -> StateMonadMonoid (Map (Some (Assignment X86_64)) m) m
    go v =
      case v of
        BVValue sz i -> return $ litf sz i
        Initial (X86Reg r)    -> return $ initf r
        AssignedValue asgn@(Assignment _ rhs) ->
          do m_v <- use (at (Some asgn))
             case m_v of
               Just v' -> return $ assignf asgn v'
               Nothing ->
                  do rhs_v <- goAssignRHS rhs
                     at (Some asgn) .= Just rhs_v
                     return (assignf asgn rhs_v)

    goAssignRHS :: forall tp'
                .  AssignRhs X86_64 tp'
                -> StateMonadMonoid (Map (Some (Assignment X86_64)) m) m
    goAssignRHS v =
      case v of
        EvalApp a -> foldApp go a
        SetUndefined _w -> mempty
        ReadMem addr _ -> go addr
        EvalArchFn f ->
          case f of
            ReadLoc _ -> mempty
            ReadFSBase -> mempty
            ReadGSBase -> mempty
            MemCmp _sz cnt src dest rev ->
              mconcat [ go cnt, go src, go dest, go rev ]
            FindElement _sz _findEq cnt buf val' rev ->
              mconcat [ go cnt, go buf, go val', go rev ]

------------------------------------------------------------------------
-- Block

-- | A basic block in a control flow graph.
-- Consists of:
-- 1. A label that should uniquely identify the block, equence of
data Block = Block { blockLabel :: !(BlockLabel Word64)
                     -- | List of statements in the block.
                   , blockStmts :: !([Stmt X86_64])
                     -- | This maps applications to the associated assignment.
                   , blockCache :: !(MapF (App (Value X86_64)) (Assignment X86_64))
                     -- | The last statement in the block.
                   , blockTerm :: !TermStmt
                   }

instance Pretty Block where
  pretty b = do
    pretty (blockLabel b) PP.<> text ":" <$$>
      indent 2 (vcat (pretty <$> blockStmts b) <$$> pretty (blockTerm b))

-- | Returns true if block has a call comment.
hasCallComment :: Block -> Bool
hasCallComment b = any isCallComment (blockStmts b)
  where isCallComment (Comment s) = "call" `Text.isInfixOf` s
        isCallComment _ = False

-- | Returns true if block has a ret comment.
hasRetComment :: Block -> Bool
hasRetComment b = any isRetComment (blockStmts b)
  where isRetComment (Comment s) = "ret" `Text.isSuffixOf` s
        isRetComment _ = False

------------------------------------------------------------------------
-- CFG

-- | A CFG is a map from all reachable code locations
-- to the block for that code location.
data CFG = CFG { _cfgBlocks :: !(Map (BlockLabel Word64) Block)
                 -- | Maps each address that is the start of a block
                 -- to the address just past the end of that block.
                 -- Blocks are expected to be contiguous.
               , _cfgBlockRanges :: !(Map CodeAddr CodeAddr)
               }

-- | Create empty CFG
emptyCFG :: CFG
emptyCFG = CFG { _cfgBlocks = Map.empty
               , _cfgBlockRanges = Map.empty
               }

cfgBlocks :: Simple Lens CFG (Map (BlockLabel Word64) Block)
cfgBlocks = lens _cfgBlocks (\s v -> s { _cfgBlocks = v })

cfgBlockRanges :: Simple Lens CFG (Map CodeAddr CodeAddr)
cfgBlockRanges = lens _cfgBlockRanges (\s v -> s { _cfgBlockRanges = v })

cfgBlockEnds :: CFG -> Set CodeAddr
cfgBlockEnds g = Set.fromList (Map.elems (g^.cfgBlockRanges))

insertBlock :: Block -> CFG -> CFG
insertBlock b c = do
  let lbl = blockLabel b
  case Map.lookup lbl (c^.cfgBlocks) of
    Just{} -> error $ "Block with label " ++ show (pretty lbl) ++ " already defined."
    Nothing -> c & cfgBlocks %~ Map.insert (blockLabel b) b

-- | Inserts blocks for a contiguous region of code.
insertBlocksForCode :: CodeAddr -> CodeAddr -> [Block] -> CFG -> CFG
insertBlocksForCode start end bs = execState $ do
  modify $ \cfg -> foldl' (flip insertBlock) cfg bs
  cfgBlockRanges %= Map.insert start end

-- | Return block with given label.
findBlock :: CFG -> BlockLabel Word64 -> Maybe Block
findBlock g l = Map.lookup l (g^.cfgBlocks)

instance Pretty CFG where
  pretty g = vcat (pretty <$> Map.elems (g^.cfgBlocks))

-- FIXME: refactor to be more efficient
-- FIXME: not a Traversal, more like a map+fold
traverseBlocks :: CFG
               -> BlockLabel Word64
               -> (Block -> a)
               -> (a -> a -> a -> a)
               -> a
traverseBlocks cfg root f merge = go root
  where
    go l = case cfg ^. cfgBlocks . at l of
            Nothing -> error $ "label not found"
            Just b  -> let v = f b in
                        case blockTerm b of
                         Branch _ lb rb -> merge (go lb) v (go rb)
                         _              -> v

-- | As for traverseBlocks but starting from a block in the cfg, not
-- an address
traverseBlockAndChildren :: CFG
                         -> Block
                         -> (Block -> a)
                            -- Maps a block to a value
                         -> (Block -> a -> a -> a)
                            -- Maps results from to sub-blocks together.
                         -> a
traverseBlockAndChildren cfg b0 f merge = goBlock b0
  where
    goBlock b = case blockTerm b of
                 Branch _ lb rb -> merge b (go lb) (go rb)
                 _              -> f b

    go l = case cfg ^. cfgBlocks . at l of
            Nothing -> error $ "label not found"
            Just b  -> goBlock b
