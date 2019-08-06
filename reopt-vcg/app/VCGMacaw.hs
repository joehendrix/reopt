{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
module VCGMacaw
  ( blockEvents
  , Event(..)
  , ppEvent
  , evenParityDecl
  , evalMemAddr
  , toSMTType
    -- * EvalContext
  , EvalContext
  , primEval
  ) where

import           Control.Lens
import           Control.Monad.Cont
import           Control.Monad.Except
import           Control.Monad.ST
import           Control.Monad.State
import           Data.Macaw.CFG as M
import           Data.Macaw.CFG.Block
import qualified Data.Macaw.Types as M
import           Data.Macaw.X86
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Parameterized.NatRepr
import           Data.Parameterized.Nonce
import           Data.Parameterized.Some
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Word
import           GHC.Natural
import           GHC.Stack
import           Text.PrettyPrint.ANSI.Leijen as PP hiding ((<$>))
import qualified What4.Protocol.SMTLib2.Syntax as SMT

import qualified Reopt.VCG.Annotations as Ann
import           VCGCommon

macawError :: HasCallStack => String -> a
macawError msg = error $ "[Macaw Error] " ++ msg

evalMemAddr :: MemAddr 64
            -> SMT.Term
evalMemAddr a =
  if addrBase a == 0 then
    SMT.bvhexadecimal (toInteger (addrOffset a)) 64
   else
    error "evalMemAddr only supports static binaries."

------------------------------------------------------------------------
-- Event

-- | One of the events generated by running a Macaw block.
data Event
  = CmdEvent !SMT.Command
  | WarningEvent !String
    -- ^ We added a warning about an issue in the VCG
  | InstructionEvent !(MemSegmentOff 64)
    -- ^ Marker to indicate the instruction at the given address will be executed.
  | forall tp . MCOnlyStackReadEvent !SMT.Term !(MemRepr tp) !Var
    -- ^ `MCOnlyReadEvent a w v` indicates that we read `w` bytes
    -- from `a`, and assign the value returned to `v`.  This only
    -- appears in the binary code.
  | forall tp . JointStackReadEvent !SMT.Term !(MemRepr tp) !Var !Ann.AllocaName
    -- ^ `JointReadEvent a w v llvmAlloca` indicates that we read `w` bytes from `a`,
    -- and assign the value returned to `v`.  This appears in the both the binary
    -- and LLVM.  The alloca name refers to the LLVM allocation this is part of,
    -- and otherwise this is a binary only read.
  | forall tp . HeapReadEvent !SMT.Term !(MemRepr tp) !Var
    -- ^ `HeapReadEvent a w v` indicates that we read `w` bytes
    -- from `a`, and assign the value returned to `v`.  The address `a` should be
    -- in the heap.
  | forall tp . MCOnlyStackWriteEvent !SMT.Term !(MemRepr tp) !SMT.Term
    -- ^ `MCOnlyStackWriteEvent a tp v` indicates that we write the `w` byte value `v`  to `a`.
    --
    -- This has side effects, so we record the event.
  | forall tp . JointStackWriteEvent !SMT.Term !(MemRepr tp) !SMT.Term !Ann.AllocaName
    -- ^ `JointStackWriteEvent a w v` indicates that we write the `w` byte value `v`  to `a`.
    -- The write affects the alloca pointed to by Allocaname.
    --
    -- This has side effects, so we record the event.
  | forall tp . HeapWriteEvent !SMT.Term !(MemRepr tp) !SMT.Term
    -- ^ `HeapWriteEvent a w v` indicates that we write the `w` byte value `v`  to `a`.  The
    -- address `a` may be assumed to be in the heap.
    --
    -- This has side effects, so we record the event.
  | forall ids . FetchAndExecuteEvent !EvalContext !(RegState (ArchReg X86_64) (Value X86_64 ids))
    -- ^ A fetch and execute

ppEvent :: Event
        -> String
ppEvent (InstructionEvent _) = "instruction"
ppEvent (WarningEvent _) = "warning"
ppEvent CmdEvent{} = "cmd"
ppEvent MCOnlyStackReadEvent{} = "mconly_read"
ppEvent JointStackReadEvent{} = "joint_stack_read"
ppEvent HeapReadEvent{} = "heap_read"
--ppEvent CondReadEvent{} = "condRead"
ppEvent MCOnlyStackWriteEvent{} = "mconly_write"
ppEvent JointStackWriteEvent{} = "joint_stack_write"
ppEvent HeapWriteEvent{} = "heap_write"
ppEvent (FetchAndExecuteEvent _ _) = "fetchAndExecute"

instance Show Event where
  show = ppEvent


------------------------------------------------------------------------
-- MStateM

-- | State for machine code.
data MState = MState
  { addrEventAnnMap :: !(Map (MemSegmentOff 64) Ann.MemoryAccessType)
    -- ^ Map from addresses to annotations of events on that address.
  , blockStartAddr :: !(MemSegmentOff 64)
    -- ^ Initial address of block.
  , mcCurAddr :: !(MemSegmentOff 64)
    -- ^ Current address of instruction.
  , initRegs :: !(RegState X86Reg (Const SMT.Term))
  , locals   :: !(Map Word64 Text)
    -- ^ Maps assignment indices to the variable name.
  , nextLocalIndex :: !Integer
    -- ^ Index for next local.
  , revEvents :: ![Event]
    -- ^ Events in reverse order.
  }

newtype MStateM a = MStateM (ExceptT String (State MState) a)
  deriving (Functor, Applicative, Monad, MonadState MState)

runMStateM :: MState -> MStateM () -> Either String MState
runMStateM s (MStateM f) = do
  case runState (runExceptT f) s of
    (Left e,   _) -> Left e
    (Right (), t) -> Right t

addEvent :: Event -> MStateM ()
addEvent e = do
  modify $ \s -> s { revEvents = e : revEvents s }

addCommand :: SMT.Command -> MStateM ()
addCommand cmd = addEvent $ CmdEvent cmd

addWarning :: String -> MStateM ()
addWarning msg = addEvent $ WarningEvent msg

getCurrentEventInfo :: MStateM Ann.MemoryAccessType
getCurrentEventInfo = do
  m <- gets addrEventAnnMap
  a <- gets mcCurAddr
  case Map.lookup a m of
    Just info -> pure info
    Nothing -> MStateM $ throwError $ "Unannotated memory event at " ++ show a

------------------------------------------------------------------------
-- Translation

data EvalContext = EvalContext { evalLocals :: !(Map Word64 Text)
                                 -- ^ Maps locals to the variable name.
                               , evalRegs :: !(RegState X86Reg (Const SMT.Term))
                                 -- ^ Map from initial register value to SMT term for its value.
                               }

getEvalContext :: MStateM EvalContext
getEvalContext = do
  s <- get
  pure $! EvalContext { evalLocals = locals s, evalRegs = initRegs s }

primEval :: EvalContext
         -> Value X86_64 ids tp
         -> SMT.Term
primEval _ (BVValue w i) = do
  SMT.bvdecimal i (natValue w)
primEval _ (BoolValue b) = do
  if b then SMT.true else SMT.false
primEval s (AssignedValue (Assignment (AssignId ident) _rhs)) = do
  case Map.lookup (indexValue ident) (evalLocals s) of
    Just t -> varTerm t
    Nothing -> macawError $ "Not contained in the locals: " ++ show ident
primEval s (Initial reg) = do
  case (evalRegs s)^.boundValue reg of
    Const e -> e
primEval _ (RelocatableValue _w addr) = do
  evalMemAddr addr
primEval _ (SymbolValue _w _id) = do
  macawError "SymbolValue: Not implemented yet"

doPrimEval :: Value X86_64 ids tp -> MStateM SMT.Term
doPrimEval v = (`primEval` v) <$> getEvalContext

toSMTType :: M.TypeRepr tp -> SMT.Sort
toSMTType (M.BVTypeRepr w) = SMT.bvSort (natValue w)
toSMTType M.BoolTypeRepr = SMT.boolSort
toSMTType tp = error $ "toSMTType: unsupported type " ++ show tp

{-
readMem :: SMT.Term
        -> M.MemRepr tp
        -> MStateM SMT.Term
readMem ptr (BVMemRepr w end) = do
  when (end /= LittleEndian) $ do
    error "reopt-vcg only encountered big endian read."
  -- TODO: Add assertion that memory is valid.
  mem <- gets curMem
  pure $ readBVLE mem ptr (natValue w)

writeMem :: SMT.Term
         -> M.MemRepr tp
         -> SMT.Term
         -> MStateM ()
writeMem ptr (BVMemRepr w LittleEndian) val = do
  modify' $ \s ->
    let SMem newMem = writeBVLE (curMem s) ptr val (natValue w)
        cmd = SMT.defineFun (memVar (memIndex s)) [] memSort newMem
     in s { curMem = SMem (varTerm (memVar (memIndex s)))
          , memIndex = memIndex s + 1
          , events = CmdEvent cmd : events s
          }
-}

-- | Record that the given assign id has been set.
recordLocal :: AssignId ids tp
            -> MStateM Text
recordLocal (AssignId n) = do
  idx <- gets nextLocalIndex
  modify $ \s -> s { nextLocalIndex = idx + 1 }
  let t = "x86local_" <> Text.pack (show idx)
  alreadyDefined <- Map.member (indexValue n) <$> gets locals
  when alreadyDefined $ error "Duplicate assign id"
  modify $ \s -> s { locals = Map.insert (indexValue n) t (locals s) }
  pure t

-- | Add a command to declare the SMT var with the given local name and Macaw type.
setUndefined :: AssignId ids tp
             -> M.TypeRepr tp
             -> MStateM ()
setUndefined aid tp = do
  v <- recordLocal aid
  addCommand $ SMT.declareFun v [] (toSMTType tp)

-- | Unsigned overflow occurs when the most significant bit is 1.
-- In @unsignedOverflow r w@, the argument @w@ must be one less than the width of @r@.
unsignedOverflow :: SMT.Term -> Natural -> SMT.Term
unsignedOverflow r w = SMT.eq [SMT.extract w w r, SMT.bit1]

-- | Signed overflow occurs when the most significant bit and second most significant bit are distinct.
-- In @unsignedOverflow r w@ the argument @w@ must be one less than the width of @r@.
signedOverflow :: SMT.Term -> Natural -> SMT.Term
signedOverflow r w = SMT.distinct [rmsb, r2msb]
  where rmsb  = SMT.extract w w r
        r2msb = SMT.extract (w-1) (w-1) r


-- | Evaluate a Macaw app associated with the given assignment identifier.
evalApp2SMT :: AssignId ids tp
            -> App (Value X86_64 ids) tp
            -> MStateM ()
evalApp2SMT aid a = do
  let doSet v = do
        let tp = toSMTType (M.typeRepr a)
        t <- recordLocal aid
        addCommand $ SMT.defineFun t [] tp v
  case a of
    Eq x y -> do
      xv <- doPrimEval x
      yv <- doPrimEval y
      doSet $ SMT.eq [xv,yv]
    Mux _ c t f -> do
      cv <- doPrimEval c
      tv <- doPrimEval t
      fv <- doPrimEval f
      doSet $ SMT.ite cv tv fv
    TupleField _ _ _ -> do
      addWarning $ "TODO: Implement " ++ show (ppApp (\_ -> text "*") a) ++ "."
      setUndefined aid (M.typeRepr a)

    AndApp x y -> do
      xv <- doPrimEval x
      yv <- doPrimEval y
      doSet $ SMT.and [xv,yv]
    OrApp x y -> do
      xv <- doPrimEval x
      yv <- doPrimEval y
      doSet $ SMT.or [xv,yv]
    NotApp x -> do
      xv <- doPrimEval x
      doSet $ SMT.not xv
    XorApp x y -> do
      xv <- doPrimEval x
      yv <- doPrimEval y
      doSet $ SMT.xor [xv,yv]

    Trunc x w -> do
      xv <- doPrimEval x
      -- Given the assumption that all data are 64bv, treat it as no ops for the moment.
      doSet $ SMT.extract (natValue w-1) 0 xv
    SExt x w -> do
      xv <- doPrimEval x
      -- This sign extends x
      doSet $ SMT.bvsignExtend (intValue w-intValue (M.typeWidth x)) xv
    UExt x w -> do
      xv <- doPrimEval x
      -- This sign extends x
      doSet $ SMT.bvzeroExtend (intValue w - intValue (M.typeWidth x)) xv
    Bitcast _ _ -> do
      addWarning $ "TODO: Implement " ++ show (ppApp (\_ -> text "*") a) ++ "."
      setUndefined aid (M.typeRepr a)

    BVAdd _w x y -> do
      xv  <- doPrimEval x
      yv  <- doPrimEval y
      doSet $ SMT.bvadd xv [yv]
    BVAdc _ _ _ _ -> do
      addWarning $ "TODO: Implement " ++ show (ppApp (\_ -> text "*") a) ++ "."
      setUndefined aid (M.typeRepr a)
    BVSub _w x y -> do
      xv  <- doPrimEval x
      yv  <- doPrimEval y
      doSet $ SMT.bvsub xv yv
    BVSbb _ _ _ _ -> do
      addWarning $
        "TODO: Implement " ++ show (ppApp (\_ -> text "*") a) ++ "."
      setUndefined aid (M.typeRepr a)
    BVMul _w x y -> do
      xv  <- doPrimEval x
      yv  <- doPrimEval y
      doSet $ SMT.bvmul xv [yv]
    BVUnsignedLe x y -> do
      xv <- doPrimEval x
      yv <- doPrimEval y
      doSet $ SMT.bvule xv yv
    BVUnsignedLt x y -> do
      xv <- doPrimEval x
      yv <- doPrimEval y
      doSet $ SMT.bvult xv yv
    BVSignedLe x y -> do
      xv <- doPrimEval x
      yv <- doPrimEval y
      doSet $ SMT.bvsle xv yv
    BVSignedLt x y -> do
      xv <- doPrimEval x
      yv <- doPrimEval y
      doSet $ SMT.bvslt xv yv

    UadcOverflows x y c -> do
      let w :: Natural
          w = natValue (M.typeWidth x)
      -- We check for unsigned overflow by zero-extending x, y, and c, performing the
      -- addition, and seeing if the most signicant bit is non-zero.
      xExpr <- SMT.bvzeroExtend 1 <$> doPrimEval x
      yExpr <- SMT.bvzeroExtend 1 <$> doPrimEval y
      cv <- doPrimEval c
      let cExpr = SMT.ite cv (SMT.bvdecimal 1 (w+1)) (SMT.bvdecimal 0 (w+1))
      -- Perform addition
      let rExpr = SMT.bvadd xExpr [yExpr, cExpr]
      -- Unsigned overflow occurs if most-significant bit is set.
      doSet $ unsignedOverflow rExpr w

    SadcOverflows x y c -> do
      -- addition, and seeing if the most signicant bit is non-zero.
      let w :: Natural
          w = natValue (M.typeWidth x)
      xExpr <- SMT.bvsignExtend 1 <$> doPrimEval x
      yExpr <- SMT.bvsignExtend 1 <$> doPrimEval y
      -- Compute carry
      cBit <- doPrimEval c
      let cExpr = SMT.ite cBit (SMT.bvdecimal 1 (w+1)) (SMT.bvdecimal 0 (w+1))
      -- Perform addition with w+1 bits.
      let rExpr = SMT.bvadd xExpr [yExpr, cExpr]
      -- Signed overflow occurs if the most significant and second most significant bit are distinct.
      doSet $ signedOverflow rExpr w

    UsbbOverflows x y b -> do
      -- We check for unsigned overflow by zero-extending x, y, and c, performing the
      -- addition, and seeing if the most signicant bit is non-zero.
      let w :: Natural
          w = natValue (M.typeWidth x)
      xExpr <- SMT.bvzeroExtend 1 <$> doPrimEval x
      yExpr <- SMT.bvneg . SMT.bvzeroExtend 1 <$> doPrimEval y
      -- Compute borrow
      bv <- doPrimEval b
      let bExpr = SMT.ite bv (SMT.bvdecimal 1 (w+1)) (SMT.bvdecimal 0 (w+1))
      -- Perform addition
      let rExpr = SMT.bvsub (SMT.bvsub xExpr yExpr) bExpr
      -- Unsigned overflow occurs if most-significant bit is set.
      doSet $ unsignedOverflow rExpr w

    SsbbOverflows x y b -> do
      -- addition, and seeing if the most signicant bit is non-zero.
      let w :: Natural
          w = natValue (M.typeWidth x)
      xExpr <- SMT.bvsignExtend 1 <$> doPrimEval x
      yExpr <- SMT.bvneg . SMT.bvsignExtend 1 <$> doPrimEval y
      -- Compute carry
      bBit <- doPrimEval b
      let bExpr = SMT.ite bBit (SMT.bvdecimal 1 (w+1)) (SMT.bvdecimal 0 (w+1))
      -- Perform addition with w+1 bits.
      let rExpr = SMT.bvsub (SMT.bvsub xExpr yExpr) bExpr
      -- Signed overflow occurs if the most significant and second most significant bit are distinct.
      doSet $ signedOverflow rExpr w

    _app -> do
      addWarning $ "TODO: Implement " ++ show (ppApp (\_ -> text "*") a) ++ "."
      setUndefined aid (M.typeRepr a)

-- | Declaration of even-parity function.
evenParityDecl :: SMT.Command
evenParityDecl =
  let v = varTerm "v"
      bitTerm = SMT.bvxor (SMT.extract 0 0 v) [ SMT.extract i i v | i <- [1..7] ]
      r = SMT.eq [bitTerm, SMT.bvbinary 0 1]
   in SMT.defineFun "even_parity" [("v", SMT.bvSort 8)] SMT.boolSort r

x86PrimFnToSMT :: AssignId ids tp
               -> X86PrimFn (Value X86_64 ids) tp
               -> MStateM ()
x86PrimFnToSMT aid (EvenParity a) = do
  xv <- doPrimEval a
  t <- recordLocal aid
  addCommand $ SMT.defineFun t [] SMT.boolSort (SMT.term_app "even_parity" [xv])
x86PrimFnToSMT aid prim = do
  addWarning $ "TODO: Implement " ++ show (runIdentity (ppArchFn (Identity . ppValue 10) prim))
  setUndefined aid (M.typeRepr prim)

assignRhs2SMT :: AssignId ids tp
              -> AssignRhs X86_64 (Value X86_64 ids) tp
              -> MStateM ()
assignRhs2SMT aid rhs = do
  case rhs of
    EvalApp a -> do
      evalApp2SMT aid a

    ReadMem addr tp -> do
      addrTerm <- doPrimEval addr
      -- Add conditional read event.
      memEventInfo <- getCurrentEventInfo
      t <- recordLocal aid
      case memEventInfo of
        Ann.BinaryOnlyAccess -> do
          addEvent $ MCOnlyStackReadEvent addrTerm tp t
        Ann.JointStackAccess aname -> do
          addEvent $ JointStackReadEvent addrTerm tp t aname
        Ann.HeapAccess -> do
          addEvent $ HeapReadEvent addrTerm tp t

    CondReadMem _ _cond _addr _def -> do
--      when (end /= LittleEndian) $ do
--        error "reopt-vcg only encountered big endian read."
--      condTerm <- doPrimEval cond
--      addrTerm <- doPrimEval addr
--      defTerm <- doPrimEval def

      -- Assert that value = default when cond is false
      -- Add conditional read event.
      error "reopt-vcg does not yet support conditional read memory."
--      addEvent $ CondReadEvent condTerm addrTerm w defTerm (smtLocalVar aid)

    SetUndefined tp -> do
      setUndefined aid tp

    EvalArchFn f _tp -> do
      x86PrimFnToSMT aid f

stmt2SMT :: Stmt X86_64 ids -> MStateM ()
stmt2SMT stmt =
  case stmt of
    AssignStmt (Assignment aid rhs) -> do
      assignRhs2SMT aid rhs
    WriteMem addr tp val -> do
      addrTerm <- doPrimEval addr
      valTerm  <- doPrimEval val
      memEventInfo <- getCurrentEventInfo
      case memEventInfo of
        Ann.BinaryOnlyAccess ->
          addEvent $ MCOnlyStackWriteEvent addrTerm tp valTerm
        Ann.JointStackAccess aname -> do
          addEvent $ JointStackWriteEvent addrTerm tp valTerm aname
        Ann.HeapAccess -> do
          addEvent $ HeapWriteEvent addrTerm tp valTerm
    CondWriteMem{} ->  error "stmt2SMT does not yet support conditional writes."

    InstructionStart off _mnem -> do
      blockAddr <- gets blockStartAddr
      let Just addr = incSegmentOff blockAddr (toInteger off)
      modify $ \s -> s { mcCurAddr = addr }
      addEvent $ InstructionEvent addr
    Comment _s -> return ()                 -- NoOps
    ArchState _a _m -> return ()             -- NoOps
    ExecArchStmt{} -> error "stmt2SMT unsupported statement."

termStmt2SMT :: TermStmt X86_64 ids
             -> MStateM ()
termStmt2SMT tstmt =
  case tstmt of
    FetchAndExecute st -> do
      ctx <- getEvalContext
      addEvent $ FetchAndExecuteEvent ctx st
    TranslateError _regs msg ->
      error $ "TranslateError : " ++ Text.unpack msg
    ArchTermStmt stmt _regs ->
      error $ "Unsupported : " ++ show (prettyF stmt)

block2SMT :: Block X86_64 ids
          -> MStateM ()
block2SMT b = do
  mapM_ stmt2SMT (blockStmts b)
  termStmt2SMT (blockTerm b)

blockEvents :: Map (MemSegmentOff 64) Ann.MemoryAccessType
               -- ^ Map from addresses to annotations of events on that address.
            -> RegState X86Reg (Const SMT.Term)
               -- ^ Initial values for registers
            -> Integer
               -- ^ Next Local variable index
            -> ExploreLoc
               -- ^ Location to explore
            -> Either String ([Event], Integer, MemWord 64)
blockEvents evtMap regs nextLocal loc = runST $ do
  Some stGen <- newSTNonceGenerator
  let addr = loc_ip loc
  mBlock <- runExceptT $ translateInstruction stGen (initX86State loc) addr
  case mBlock of
    Left err ->
      error $ "Translation error: " ++ show err
    Right (b, sz) -> do
      let ms0 = MState { addrEventAnnMap = evtMap
                       , blockStartAddr = addr
                       , mcCurAddr = addr
                       , initRegs = regs
                       , locals = Map.empty
                       , nextLocalIndex = nextLocal
                       , revEvents = []
                       }
      case runMStateM ms0 (block2SMT b) of
        Left e -> do
          pure $! Left e
        Right ms1 ->
          pure $! Right (reverse (revEvents ms1), nextLocalIndex ms1, sz)
