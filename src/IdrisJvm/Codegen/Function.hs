{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}

module IdrisJvm.Codegen.Function where

import           Control.Applicative          ((<|>))
import           Control.Arrow                (first)
import           Control.Monad.RWS
import qualified Data.DList                   as DL
import qualified Data.IntSet                  as IntSet
import           Data.List                    (find)
import           Data.Maybe
import           Idris.Core.TT
import           IdrisJvm.Codegen.Assembler
import           IdrisJvm.Codegen.Common
import           IdrisJvm.Codegen.Constant
import           IdrisJvm.Codegen.ControlFlow
import           IdrisJvm.Codegen.Foreign
import           IdrisJvm.Codegen.Operator
import           IdrisJvm.Codegen.Types
import           IRTS.Lang
import           IRTS.Simplified

type Locals = IntSet.IntSet

localVariables :: Int -> SExp -> Int
localVariables n (SLet (Loc i) v sc)
   = let nAssignmentExp = localVariables 0 v
         nLetBodyExp = localVariables 0 sc in
       maximum ([n, i, nAssignmentExp, nLetBodyExp] :: [Int])
localVariables n (SUpdate _ e) = localVariables n e
localVariables n (SCase _ e alts) = localVariablesSwitch n e alts
localVariables n (SChkCase e alts) = localVariablesSwitch n e alts
localVariables locals _ = locals

localVariablesSwitch :: Int -> LVar -> [SAlt] -> Int
localVariablesSwitch locals _ alts
   = let newLocals = localVariablesAlt <$> alts
         nonDefaultCases = filter (not . defaultCase) alts
     in if all isIntCase alts
          then maximum (locals: newLocals)
          else maximum (locals: newLocals) + length nonDefaultCases

localVariablesAlt :: SAlt -> Int
localVariablesAlt (SConstCase _ e) = localVariables 0 e
localVariablesAlt (SDefaultCase e) = localVariables 0 e
localVariablesAlt (SConCase lv _ _ args e) = max assignmentLocals bodyLocals
   where assignmentLocals = if null args then 0 else lv + length args - 1
         bodyLocals = localVariables 0 e

cgFun :: Name -> [Name] -> SExp -> Cg ()
cgFun n args def = do
    modify . updateFunctionArgs $ const args
    modify . updateFunctionName $ const functionName
    modify . updateShouldDescribeFrame $ const True
    let clsName = jmethClsName functionName
        fname = jmethName functionName
    writeIns [ CreateMethod [Public, Static] clsName fname (sig nArgs) Nothing Nothing
             , MethodCodeStart
             ]
    modify . updateLocalVarCount $ const nLocalVars
    modify . updateSwitchIndex $ const 0 -- reset
    modify . updateIfIndex $ const 0 -- reset
    writeIns . join . fmap assignNull . DL.fromList $ resultVarIndex: [nArgs .. (nLocalVars - 1)]
    methBody
    writeIns [ Aload resultVarIndex
             , Areturn
             , MaxStackAndLocal (-1) (-1)
             , MethodCodeEnd
             ]

  where
    nArgs = length args
    nLocalVars = localVariables nArgs def
    resultVarIndex = nLocalVars
    tailRecVarIndex = succ resultVarIndex
    totalVars = nLocalVars + 2
    functionName = jname n
    shouldEliminateTco = maybe False ((==) functionName . jname) $ isTailCall def
    ret = if shouldEliminateTco
            then
              writeIns [ Astore resultVarIndex -- Store the result
                       , Iconst 0
                       , Istore tailRecVarIndex ] -- Base case for tailrec. Set the tailrec flag to false.
            else writeIns [ Astore resultVarIndex]
    tcoLocalVarTypes = replicate (nLocalVars + 1) "java/lang/Object"
                     ++ [ "Opcodes.INTEGER" ]
    tcoFrame = Frame FFull totalVars tcoLocalVarTypes 0 []
    methBody =
      if shouldEliminateTco
        then do
          writeIns [ Iconst 1
                   , Istore tailRecVarIndex
                   , CreateLabel tailRecStartLabelName
                   , LabelStart tailRecStartLabelName
                   , tcoFrame
                   , Iload tailRecVarIndex
                   , CreateLabel tailRecEndLabelName
                   , Ifeq tailRecEndLabelName
                   ]
          modify . updateShouldDescribeFrame $ const False
          cgBody ret def
          writeIns [ Goto tailRecStartLabelName
                   , LabelStart tailRecEndLabelName
                   , Frame FSame 0 [] 0 []
                   ]
        else cgBody ret def

tailRecStartLabelName :: String
tailRecStartLabelName = "$tailRecStartLabel"

tailRecEndLabelName :: String
tailRecEndLabelName = "$tailRecEndLabel"

assignNull :: Int -> DL.DList Asm
assignNull varIndex = [Aconstnull, Astore varIndex]

isTailCall :: SExp -> Maybe Name
isTailCall (SApp tailCall f _) = if tailCall then Just f else Nothing
isTailCall (SLet _ v sc) =  isTailCall v <|> isTailCall sc
isTailCall (SUpdate _ e) = isTailCall e
isTailCall (SCase _ _ alts) = join . find isJust . map isTailCallSwitch $ alts
isTailCall (SChkCase _ alts) = join . find isJust . map isTailCallSwitch $ alts
isTailCall _ = Nothing

isTailCallSwitch :: SAlt -> Maybe Name
isTailCallSwitch (SConstCase _ e)     = isTailCall e
isTailCallSwitch (SDefaultCase e)     = isTailCall e
isTailCallSwitch (SConCase _ _ _ _ e) = isTailCall e

cgBody :: Cg () -> SExp -> Cg ()
cgBody ret (SV (Glob n)) = do
  let JMethodName cname mname = jname n
  writeIns [ InvokeMethod InvokeStatic cname mname (sig 0) False]
  ret

cgBody ret (SV (Loc i)) = writeIns [Aload i] >> ret

cgBody ret (SApp True f args) = do
  caller <- cgStFunctionName <$> get
  if jname f == caller -- self tail call, use goto
       then do
              let g toIndex (Loc fromIndex) = assign fromIndex toIndex
                  g _ _ = error "Unexpected global variable"
              writeIns . join . DL.fromList $ zipWith g [0..] args
        else -- non-self tail call
          createThunk caller (jname f) args >> ret

cgBody ret (SApp False f args) = do
  writeIns $ (Aload . locIndex) <$> DL.fromList args
  let JMethodName cname mname = jname f
  writeIns [ InvokeMethod InvokeStatic cname mname (sig $ length  args) False
           , InvokeMethod InvokeStatic (rtClassSig "Runtime") "unwrap" "(Ljava/lang/Object;)Ljava/lang/Object;" False
           ]
  ret

cgBody ret (SLet (Loc i) v sc) = cgBody (writeIns [Astore i]) v >> cgBody ret sc

cgBody ret (SUpdate _ e) = cgBody ret e

cgBody ret (SProj (Loc v) i)
  = writeIns [ Aload v
             , Checkcast "[Ljava/lang/Object;"
             , Iconst $ succ i
             , Aaload
             ] >> ret


cgBody ret (SCon _ t _ args) = do
    writeIns [ Iconst $ length args + 1
             , Anewarray "java/lang/Object"
             , Dup
             , Iconst 0
             , Iconst t
             , boxInt
             , Aastore
             ]
    writeIns $ join . DL.fromList $ zipWith ins [1..] args
    ret
  where
    ins :: Int -> LVar -> DL.DList Asm
    ins index (Loc varIndex)
      = [ Dup
        , Iconst index
        , Aload varIndex
        , Aastore
        ]
    ins _ _ = error "Unexpected global variable"

cgBody ret (SCase _ e alts) = cgSwitch ret cgBody e alts

cgBody ret (SChkCase e alts) = cgSwitch ret cgBody e alts

cgBody ret (SConst c) = cgConst c >> ret

cgBody ret (SOp op args) = cgOp op args >> ret

cgBody ret SNothing = writeIns [Iconst 0, boxInt] >> ret

cgBody ret (SError x) = invokeError (show x) >> ret

cgBody ret (SForeign returns fdesc args) = cgForeign (parseDescriptor returns fdesc args) where
  argsWithTypes = first fdescFieldDescriptor <$> args

  cgForeign (JStatic clazz fn) = do
    let returnDesc = fdescTypeDescriptor returns
        descriptor r = asm $ MethodDescriptor (fdescFieldDescriptor . fst <$> args) r
    idrisToJava argsWithTypes
    writeIns [ InvokeMethod InvokeStatic clazz fn (descriptor returnDesc) False ]
    javaToIdris returnDesc
    ret
  cgForeign (JVirtual clazz fn) = do
    let returnDesc = fdescTypeDescriptor returns
        descriptor = asm $ MethodDescriptor (fdescFieldDescriptor . fst <$> drop 1 args) returnDesc
    idrisToJava argsWithTypes -- drop first arg type as it is an implicit 'this'
    writeIns [ InvokeMethod InvokeVirtual clazz fn descriptor False ]
    javaToIdris returnDesc
    ret
  cgForeign (JInterface clazz fn) = do
    let returnDesc = fdescTypeDescriptor returns
        descriptor = asm $ MethodDescriptor (fdescFieldDescriptor . fst <$> drop 1 args) returnDesc
    idrisToJava argsWithTypes
    writeIns [ InvokeMethod InvokeInterface clazz fn descriptor True ]
    javaToIdris returnDesc
    ret
  cgForeign (JConstructor clazz) = do
    let returnDesc = VoidDescriptor -- Constructors always return void.
        descriptor r = asm $ MethodDescriptor (fdescFieldDescriptor . fst <$> args) r
    writeIns [ New clazz, Dup ]
    idrisToJava argsWithTypes
    writeIns [ InvokeMethod InvokeSpecial clazz "<init>" (descriptor returnDesc) False ]
    ret

cgBody _ _ = error "NOT IMPLEMENTED!!!!"

defaultConstructor :: ClassName -> Cg ()
defaultConstructor cname
  = writeIns [ CreateMethod [Public] cname "<init>" "()V" Nothing Nothing
             , MethodCodeStart
             , Aload 0
             , InvokeMethod InvokeSpecial "java/lang/Object" "<init>" "()V" False
             , Return
             , MaxStackAndLocal (-1) (-1) -- Let the asm calculate
             , MethodCodeEnd
             ]

mainMethod :: Cg ()
mainMethod = do
  let JMethodName cname mname = jname $ MN 0 "runMain"
  writeIns [ CreateMethod [Public, Static] cname "main" "([Ljava/lang/String;)V" Nothing Nothing
           , MethodCodeStart
           , InvokeMethod InvokeStatic cname mname "()Ljava/lang/Object;" False
           , Pop
           , Return
           , MaxStackAndLocal (-1) (-1)
           , MethodCodeEnd
           ]