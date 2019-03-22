{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
module CryptolServer.Data.Expression where

import Control.Applicative
import Control.Exception (throwIO)
import Control.Monad.IO.Class
import Data.Aeson as JSON hiding (Encoding, Value, decode)
import qualified Data.Aeson as JSON
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as Base64
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.Scientific as Sc
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as T
import Data.Traversable
import qualified Data.Vector as V
import Data.Text.Encoding (encodeUtf8)
import Numeric (showHex)

import Cryptol.Eval (evalSel)
import Cryptol.Eval.Monad
import Cryptol.Eval.Value
import Cryptol.IR.FreeVars (freeVars, FreeVars, tyDeps, valDeps)
import Cryptol.ModuleSystem (ModuleCmd, ModuleEnv, checkExpr, evalExpr, getPrimMap, loadModuleByPath, loadModuleByName, meLoadedModules)
import Cryptol.ModuleSystem.Env (initialModuleEnv, isLoadedParamMod, meSolverConfig)
import Cryptol.ModuleSystem.Name (NameInfo(Declared), Name, nameInfo)
import Cryptol.Parser
import Cryptol.Parser.AST (Bind(..), BindDef(..), Decl(..), Expr(..), Type(..), PName(..), Ident(..), Literal(..), Named(..), NumInfo(..))
import Cryptol.Parser.Position (Located(..), emptyRange)
import Cryptol.Parser.Selector
import Cryptol.Prims.Syntax
import Cryptol.TypeCheck.AST (PrimMap, sType)
import Cryptol.TypeCheck.Solve (defaultReplExpr)
import Cryptol.TypeCheck.Subst (apSubst, listParamSubst)
import qualified Cryptol.TypeCheck.Type as TC
import Cryptol.Utils.Ident
import Cryptol.Utils.PP (pretty)
import qualified Cryptol.TypeCheck.Solver.SMT as SMT


import Argo
import CryptolServer
import CryptolServer.Exceptions

data Encoding = Base64 | Hex
  deriving (Eq, Show, Ord)

instance JSON.FromJSON Encoding where
  parseJSON =
    withText "encoding" $
    \case
      "hex"    -> pure Hex
      "base64" -> pure Base64
      _        -> empty

data LetBinding =
  LetBinding
  { argDefName :: !Text
  , argDefVal  :: !Expression
  }
  deriving (Eq, Ord, Show)

instance JSON.FromJSON LetBinding where
  parseJSON =
    withObject "let binding" $ \o ->
      LetBinding <$> o .: "name" <*> o .: "definition"

instance JSON.ToJSON LetBinding where
  toJSON (LetBinding x def) =
    object [ "name" .= x
           , "definition" .= def
           ]

data Expression =
    Bit !Bool
  | Unit
  | Num !Encoding !Text !Integer -- ^ data and bitwidth
  | Record !(HashMap Text Expression)
  | Sequence ![Expression]
  | Tuple ![Expression]
  | Integer !Integer
  | Concrete !Text
  | Let ![LetBinding] !Expression
  | Application !Expression !(NonEmpty Expression)
  deriving (Eq, Ord, Show)

data ExpressionTag = TagNum | TagRecord | TagSequence | TagTuple | TagUnit | TagLet | TagApp

instance JSON.FromJSON ExpressionTag where
  parseJSON =
    withText "tag" $
    \case
      "bits"     -> pure TagNum
      "unit"     -> pure TagUnit
      "record"   -> pure TagRecord
      "sequence" -> pure TagSequence
      "tuple"    -> pure TagTuple
      "let"      -> pure TagLet
      "call"     -> pure TagApp
      _          -> empty

instance JSON.ToJSON ExpressionTag where
  toJSON TagNum      = "bits"
  toJSON TagRecord   = "record"
  toJSON TagSequence = "sequence"
  toJSON TagTuple    = "tuple"
  toJSON TagUnit     = "unit"
  toJSON TagLet      = "let"
  toJSON TagApp      = "call"

instance JSON.FromJSON Expression where
  parseJSON v = bool v <|> integer v <|> concrete v <|> obj v
    where
      bool =
        withBool "boolean" $ pure . Bit
      integer =
        -- Note: this means that we should not expose this API to the
        -- public, but only to systems that will validate input
        -- integers. Otherwise, they can use this to allocate a
        -- gigantic integer that fills up all memory.
        withScientific "integer" $ \s ->
          case Sc.floatingOrInteger s of
            Left fl -> empty
            Right i -> pure (Integer i)
      concrete =
        withText "concrete syntax" $ pure . Concrete

      obj =
        withObject "argument" $
        \o -> o .: "expression" >>=
              \case
                TagUnit -> pure Unit
                TagNum ->
                  do enc <- o .: "encoding"
                     Num enc <$> o .: "data" <*> o .: "width"
                TagRecord ->
                  do fields <- o .: "data"
                     flip (withObject "record data") fields $
                       \fs -> Record <$> traverse parseJSON fs
                TagSequence ->
                  do contents <- o .: "data"
                     flip (withArray "sequence") contents $
                       \s -> Sequence . V.toList <$> traverse parseJSON s
                TagTuple ->
                  do contents <- o .: "data"
                     flip (withArray "tuple") contents $
                       \s -> Tuple . V.toList <$> traverse parseJSON s
                TagLet ->
                  Let <$> o .: "binders" <*> o .: "body"
                TagApp ->
                  Application <$> o .: "function" <*> o .: "arguments"

instance ToJSON Encoding where
  toJSON Hex = String "hex"
  toJSON Base64 = String "base64"

instance JSON.ToJSON Expression where
  toJSON Unit = object [ "expression" .= TagUnit ]
  toJSON (Bit b) = JSON.Bool b
  toJSON (Integer i) = JSON.Number (fromInteger i)
  toJSON (Concrete expr) = toJSON expr
  toJSON (Num enc dat w) =
    object [ "expression" .= TagNum
           , "data" .= String dat
           , "encoding" .= enc
           , "width" .= w
           ]
  toJSON (Record fields) =
    object [ "expression" .= TagRecord
           , "data" .= object [ name .= toJSON val
                              | (name, val) <- HM.toList fields
                              ]
           ]
  toJSON (Sequence elts) =
    object [ "expression" .= TagSequence
           , "data" .= Array (V.fromList (map toJSON elts))
           ]
  toJSON (Tuple projs) =
    object [ "expression" .= TagTuple
           , "data" .= Array (V.fromList (map toJSON projs))
           ]
  toJSON (Let binds body) =
    object [ "expression" .= TagLet
           , "binders" .= Array (V.fromList (map toJSON binds))
           , "body" .= toJSON body
           ]
  toJSON (Application fun args) =
    object [ "expression" .= TagApp
           , "function" .= fun
           , "arguments" .= args
           ]


decode :: Encoding -> Text -> Method s Integer
decode Base64 txt =
  let bytes = encodeUtf8 txt
  in
    case Base64.decode bytes of
      Left err ->
        raise (invalidBase64 bytes err)
      Right decoded -> return $ bytesToInt decoded
decode Hex txt =
  squish <$> traverse hexDigit (T.unpack txt)
  where
    squish = foldl (\acc i -> (acc * 16) + i) 0

hexDigit :: Num a => Char -> Method s a
hexDigit '0' = pure 0
hexDigit '1' = pure 1
hexDigit '2' = pure 2
hexDigit '3' = pure 3
hexDigit '4' = pure 4
hexDigit '5' = pure 5
hexDigit '6' = pure 6
hexDigit '7' = pure 7
hexDigit '8' = pure 8
hexDigit '9' = pure 9
hexDigit 'a' = pure 10
hexDigit 'A' = pure 10
hexDigit 'b' = pure 11
hexDigit 'B' = pure 11
hexDigit 'c' = pure 12
hexDigit 'C' = pure 12
hexDigit 'd' = pure 13
hexDigit 'D' = pure 13
hexDigit 'e' = pure 14
hexDigit 'E' = pure 14
hexDigit 'f' = pure 15
hexDigit 'F' = pure 15
hexDigit c   = raise (invalidHex c)


getExpr :: Expression -> Method s (Expr PName)
getExpr Unit =
  return $
    ETyped
      (ETuple [])
      (TTuple [])
getExpr (Bit b) =
  return $
    ETyped
      (EVar (UnQual (mkIdent $ if b then "True" else "False")))
      TBit
getExpr (Integer i) =
  return $
    ETyped
      (ELit (ECNum i DecLit))
      (TUser (UnQual (mkIdent "Integer")) [])
getExpr (Num enc txt w) =
  do d <- decode enc txt
     return $ ETyped
       (ELit (ECNum d DecLit))
       (TSeq (TNum w) TBit)
getExpr (Record fields) =
  fmap ERecord $ for (HM.toList fields) $
  \(name, spec) ->
    Named (Located emptyRange (mkIdent name)) <$> getExpr spec
getExpr (Sequence elts) =
  EList <$> traverse getExpr elts
getExpr (Tuple projs) =
  ETuple <$> traverse getExpr projs
getExpr (Concrete syntax) =
  case parseExpr syntax of
    Left err ->
      raise (cryptolParseErr syntax err)
    Right e -> pure e
getExpr (Let binds body) =
  EWhere <$> getExpr body <*> traverse mkBind binds
  where
    mkBind (LetBinding x rhs) =
      DBind .
      (\body -> (Bind (fakeLoc (UnQual (mkIdent x))) [] body Nothing False Nothing [] True Nothing)) .
      fakeLoc .
      DExpr <$>
        getExpr rhs

    fakeLoc = Located emptyRange
getExpr (Application fun (arg :| [])) =
  EApp <$> getExpr fun <*> getExpr arg
getExpr (Application fun (arg1 :| (arg : args))) =
  getExpr (Application (Application fun (arg1 :| [])) (arg :| args))

invalidBase64 :: ByteString -> String -> JSONRPCException
invalidBase64 invalidData msg =
  makeJSONRPCException
    32 (T.pack msg) (Just (JSON.toJSON (T.pack (show invalidData))))

invalidHex :: Char -> JSONRPCException
invalidHex invalidData =
  makeJSONRPCException
    33 "Not a hex digit"
    (Just (JSON.toJSON (T.pack (show invalidData))))

invalidType :: TC.Type -> JSONRPCException
invalidType ty =
  makeJSONRPCException
    34 "Can't convert Cryptol data from this type to JSON"
    (Just (JSON.toJSON (T.pack (show ty))))

unwantedDefaults :: [(TC.TParam, TC.Type)] -> JSONRPCException
unwantedDefaults defs =
  makeJSONRPCException
    35 "Execution would have required these defaults"
    (Just (JSON.toJSON (T.pack (show defs))))

evalInParamMod :: [Cryptol.ModuleSystem.Name.Name] -> JSONRPCException -- FIXME: this is deliberately wrong to find correct type later
evalInParamMod mods =
  makeJSONRPCException
    36 "Can't evaluate Cryptol in a parameterized module."
    (Just (toJSON (map pretty mods)))

-- TODO add tests that this is big-endian
-- | Interpret a ByteString as an Integer
bytesToInt bs =
  BS.foldl' (\acc w -> (acc * 256) + toInteger w) 0 bs

readBack :: PrimMap -> TC.Type -> Value -> Eval Expression
readBack prims ty val =
  case TC.tNoUser ty of
    TC.TRec tfs ->
      Record . HM.fromList <$>
        sequence [ do fv <- evalSel val (RecordSel f Nothing)
                      fa <- readBack prims t fv
                      return (identText f, fa)
                 | (f, t) <- tfs
                 ]
    TC.TCon (TC (TCTuple _)) [] ->
      pure Unit
    TC.TCon (TC (TCTuple _)) ts ->
      Tuple <$> sequence [ do v <- evalSel val (TupleSel n Nothing)
                              a <- readBack prims t v
                              return a
                         | (n, t) <- zip [0..] ts
                         ]
    TC.TCon (TC TCBit) [] ->
      case val of
        VBit b -> pure (Bit b)
    TC.TCon (TC TCInteger) [] ->
      case val of
        VInteger i -> pure (Integer i)
    TC.TCon (TC TCSeq) [TC.tNoUser -> len, TC.tNoUser -> contents]
      | len == TC.tZero ->
        return Unit
      | contents == TC.TCon (TC TCBit) []
      , VWord _ wv <- val ->
        do BV w v <- wv >>= asWordVal
           return $ Num Hex (T.pack $ showHex v "") w
      | TC.TCon (TC (TCNum k)) [] <- len ->
        Sequence <$> sequence [ do v <- evalSel val (ListSel n Nothing)
                                   readBack prims contents v
                              | n <- [0 .. fromIntegral k]
                              ]
    other -> liftIO $ throwIO (invalidType other)


observe :: Eval a -> Method ServerState a
observe (Ready x) = pure x
observe (Thunk f) = liftIO $ f theEvalOpts

mkEApp :: Expr PName -> [Expr PName] -> Expr PName
mkEApp f args = foldl EApp f args