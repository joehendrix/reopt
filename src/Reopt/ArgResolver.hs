{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Reopt.ArgResolver
  ( ArgResolver
  , runArgResolver
  , ArgResolverError(..)
  , showArgResolverError
  , addGPReg64
  , addDoubleArg
  ) where

import           Control.Monad.Except
import           Control.Monad.State
import           Data.Word
import qualified Flexdis86 as F
import           Text.Printf (printf)

import           Reopt.CFG.Recovery (X86ArgInfo(..), ZMMType(..))

-- | An error from parsing the external header for arguments
data ArgResolverError
   = OutOfGPRegs !String
     -- ^ @OutOfGPRegs nm@ The argument @nm@ could not be added due to limit on general-purpose registers.
   | OutOfSSERegs !String
     -- ^ @OutOfSSERegs nm@ The argument @nm@ could not be added due to limit on SSE/AVX registers.
   | MissingArgType !String
     -- ^ Return type for argument is missing
   | UnsupportedArgType !String !String
     -- ^ @UnsupportedArgType nm tp@ Argument @nm@ does not support type.
   | UnsupportedReturnType !String
   | DebugResolveError !String
   | VarArgsUnsupported

-- | Pretty print for header errors.
showArgResolverError :: ArgResolverError -> String
showArgResolverError (OutOfGPRegs _) =
  "Stack arguments are not supported and no more general-purpose registers available."
showArgResolverError (OutOfSSERegs _) =
  "Stack arguments are not supported and no more SSE available."
showArgResolverError (MissingArgType vnm) =
  printf "Argument %s missing type." vnm
showArgResolverError (UnsupportedArgType vnm tp) =
  printf "Argument %s does not support type %s." vnm tp
showArgResolverError (UnsupportedReturnType tp) =
  printf "Do not support return argument type %s." tp
showArgResolverError (DebugResolveError msg) =
  msg
showArgResolverError VarArgsUnsupported =
  "Do not support vararg functions."

-- |  State monad for resolving arguments.
data ArgResolverState = ARS { arsPrev :: [X86ArgInfo]
                              -- ^ Arguments identified in reverse order.
                            , arsNextGPP :: [F.Reg64]
                              -- ^ General purpose registers still
                              -- available for arguments.
                            , arsXMMCount :: !Word8
                              -- ^ Number of xmm registers used so far.
                            }

-- | Monad used for recording arguments to resolve.
newtype ArgResolver m a =
    ArgResolver (StateT ArgResolverState (ExceptT ArgResolverError m) a)
  deriving (Functor, Applicative, Monad, MonadError ArgResolverError, MonadIO)

-- | Run the aergument resolver and get the next state.
runArgResolver :: Monad m => ArgResolver m () -> ExceptT ArgResolverError m [X86ArgInfo]
runArgResolver (ArgResolver m) =
  let s0 = ARS { arsPrev = []
               , arsNextGPP = [ F.RDI, F.RSI, F.RDX, F.RCX, F.R8, F.R9 ]
               , arsXMMCount = 0
               }
   in reverse . arsPrev <$> execStateT m s0


-- | Reserve a 64-bit register for an argument
addGPReg64 :: Monad m => String -> ArgResolver m ()
addGPReg64 nm = ArgResolver $ do
  regs <- gets arsNextGPP
  case regs of
    [] ->
      throwError $ OutOfGPRegs nm
    (r:rest) -> do
      modify $ \s -> s { arsPrev = ArgBV64 r : arsPrev s
                       , arsNextGPP = rest
                       }

addDoubleArg :: Monad m => String -> ArgResolver m ()
addDoubleArg nm = ArgResolver $ do
  cnt <- gets arsXMMCount
  if cnt >= 8 then
    throwError $ OutOfSSERegs nm
  else
    modify $ \s -> s { arsPrev = ArgZMM ZMMDouble cnt : arsPrev s, arsXMMCount = cnt+1 }