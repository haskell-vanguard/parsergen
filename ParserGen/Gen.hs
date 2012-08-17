{-# OPTIONS -Wall #-}
{-# LANGUAGE TemplateHaskell, QuasiQuotes, RecordWildCards, OverloadedStrings #-}

module ParserGen.Gen
    ( genDataTypeFromFile
    , genParserFromFile
    )
where

import ParserGen.ParseQuote
import ParserGen.Wrap as W
import qualified ParserGen.Parser as P

import Language.Haskell.TH as TH
import Control.Applicative
import Control.Monad
import Data.Char (isUpper, toLower)
import Data.Maybe (catMaybes, isNothing)
import qualified Data.ByteString.Char8 as C8

genDataTypeFromFile :: FilePath -> Q [Dec]
genDataTypeFromFile templateName = getDatatype templateName >>= mkDataDecl >>= return . (:[])

genParserFromFile :: FilePath -> Q [Dec]
genParserFromFile templateName = do
    dt <- getDatatype templateName
    (++) <$> mkParsersDecls dt <*> mkWidthDecls dt

mkDataDecl :: Datatype -> Q Dec
mkDataDecl (Datatype {..}) = do
        constrs <- mapM mkConstDef typeConstrs
        return $ DataD [] (mkName typeName) [] constrs [''Eq, ''Show]
    where
        mkConstDef :: DataConstructor -> Q Con
        mkConstDef dc@(DataConstructor {..}) = do
            fields <- catMaybes <$> mapM (mkFieldDef dc) constrFields
            return $ RecC (mkName constrName) fields


mkFieldDef :: DataConstructor -> DataField -> Q (Maybe (Name, Strict, Type))
mkFieldDef dc@(DataConstructor {..}) df@(DataField {..}) = return $ do
        name <- getFieldName dc df
        case fieldRepeat of
            Nothing -> return (name, strict, fieldType)
            _       -> return (name, strict, AppT ListT fieldType)
    where
        strict :: Strict
        strict = if fieldStrict then IsStrict else NotStrict

getFieldName :: DataConstructor -> DataField -> Maybe Name
getFieldName (DataConstructor {..}) (DataField {..}) =
            mkName <$> ((++) <$> (constrPrefix <|> defaultPrefix) <*> fieldName)
    where
        defaultPrefix = Just (map toLower . filter isUpper $ constrName)


-- to create separate parsers for each constructor
mkParsersDecls :: Datatype -> Q [Dec]
mkParsersDecls (Datatype {..}) = concat <$> mapM (mkConstrParser typeName) typeConstrs
    where
        mkConstrParser :: String -> DataConstructor -> Q [Dec]
        mkConstrParser name dc@(DataConstructor {..}) = do
                fields <- mapM mkField (fuseIgnores constrFields)
                ensure <- ensureBytes $ getConstructorWidth dc
                t <- [t| P.Parser |]

                return $ [ SigD funName (AppT t (ConT . mkName $ name ))
                         , FunD funName [Clause [] (NormalB . DoE $ ensure : fields ++ [result] ) []]
                         ]
            where

                ensureBytes :: Int -> Q Stmt
                ensureBytes t = [| P.ensureBytesLeft t |] >>= return . BindS WildP

                funName :: Name
                funName = mkName $ "parserFor" ++ constrName

                mkField :: DataField -> Q Stmt
                mkField df@(DataField {..}) = parser >>= adjustRepeat >>= return . BindS pat
                    where

                        adjustRepeat :: Exp -> Q Exp
                        adjustRepeat p = case fieldRepeat of
                            Nothing -> return p
                            Just q  -> [| count q $(return p) |]

                        pat :: Pat
                        pat = case getFieldName dc df of
                            Just n  -> VarP n
                            Nothing -> WildP

                        parser :: Q Exp
                        parser = case fieldParser of
                            CustomParser p    -> return p
                            UnsignedParser    -> case getTypeName fieldType of
                                "()"              -> [| P.skip     fieldWidth |]
                                "ByteString"      -> [| P.take     fieldWidth |]
                                "Int"             -> [| P.decimalX fieldWidth |]
                                x                 -> deriveSizeParserFor x fieldWidth
                            SignedParser      -> case getTypeName fieldType of
                                "Int"             -> [| P.decimalXS fieldWidth |]
                                x                 -> deriveSignSizeParserFor x fieldWidth

                            HardcodedString s -> case pat of
                                _ | length s /= fieldWidth -> fail $ "Width of " ++ show s ++ " is not " ++ show fieldWidth ++ "!"
                                -- if string value is ignored - no need to return it
                                WildP -> [| P.string (C8.pack s) |]
                                _     -> [| P.string (C8.pack s) >> return (C8.pack s) |]


                atEndQ :: Q Stmt
                atEndQ = [| P.atEnd >>= guard |] >>= return . BindS WildP

                result :: Stmt
                result = NoBindS (AppE (VarE . mkName $ "return")
                                         (RecConE (mkName constrName)
                                                  (concatMap mkFieldAssignment constrFields)))

                mkFieldAssignment :: DataField -> [FieldExp]
                mkFieldAssignment df@(DataField {..}) = case getFieldName dc df of
                        Just n  -> [(n, VarE n)]
                        Nothing -> []

                -- some optimization helpers {{{
                -- will transform sequence of sizebased parsers with ignored values into one larger parser -- {{{
                fuseIgnores :: [DataField] -> [DataField]

                -- join two sequential skips into one
                fuseIgnores (a:b:rest) | ignored a && ignored b = fuseIgnores $ fused : rest
                    where
                        fused = DataField { fieldName   = Nothing
                                          , fieldStrict = False
                                          , fieldRepeat = Nothing
                                          , fieldType   = (ConT . mkName $ "()")
                                          , fieldParser = UnsignedParser
                                          , fieldWidth  = getFieldWidth a + getFieldWidth b
                                          }
                -- transform skips to cheapest possible version
                fuseIgnores (x:xs) | ignored x = transformed : fuseIgnores xs
                    where
                        transformed = x { fieldType = (ConT . mkName $ "()" ) }

                -- transform rest of the stream
                fuseIgnores (x:xs) = x : fuseIgnores xs
                fuseIgnores [] = []

                -- size based and ignored
                ignored :: DataField -> Bool
                ignored (DataField {..}) = isNothing fieldName && fieldParser `elem` [SignedParser, UnsignedParser]

                -- }}}
                -- }}}


        getTypeName :: Type -> String
        getTypeName (ConT n) = nameBase n
        getTypeName t = error $ "Invalid type in size based parser: " ++ show t

mkWidthDecls :: Datatype -> Q [Dec]
mkWidthDecls (Datatype {..}) = concat <$> mapM mkConstrWidthDecl typeConstrs
    where
        mkConstrWidthDecl :: DataConstructor -> Q [Dec]
        mkConstrWidthDecl dc@(DataConstructor {..}) = return
                [ SigD name (ConT $ mkName "Int")
                , FunD name [Clause [] (NormalB $ LitE $ IntegerL width) []]
                ]
            where
                width = fromIntegral $ getConstructorWidth dc
                name  = mkName $ "widthFor" ++ constrName

-- try to derive size based parser for given type
deriveSizeParserFor :: String -> Int -> Q Exp
deriveSizeParserFor fieldTypeName s = do
        TyConI info <- recover (fail unknownType) (reify (mkName fieldTypeName))

        case info of
            TySynD _ _ (ConT synTo)
                | synTo == ''Int         -> [| P.decimalX s |]
                | otherwise -> fail $ "Only Int synonyms supported, not " ++ show synTo


            NewtypeD _ _ _ (RecC constr [(unconstr, _, ConT typeFor)]) _
                | typeFor == ''Int       -> [| $( return $ ConE constr) `fmap` P.decimalX s |]
                | typeFor == ''AlphaNum  -> [| $( return $ ConE constr) `fmap` W.alphaNumParser s |]
                | otherwise -> fail $ "Not supported type inside newtype: " ++ show typeFor ++ show info

            NewtypeD _ _ _ (NormalC constr [(_, ConT typeFor)]) _
                | typeFor == ''Int       -> [| $( return $ ConE constr) `fmap` P.decimalX s |]
                | typeFor == ''AlphaNum  -> [| $( return $ ConE constr) `fmap` W.alphaNumParser s |]
                | otherwise -> fail $ "Not supported type inside newtype: " ++ show typeFor

            _ -> fail $ "Size based parser only supported for type and newtype declarations: " ++ show info
    where
        unknownType = "Type `" ++ fieldTypeName ++ "' is undefined. " ++ cantDerive
        cantDerive  = "Can't derive size based parser."




-- try to derive size based parser for given type
deriveSignSizeParserFor:: String -> Int -> Q Exp
deriveSignSizeParserFor fieldTypeName s = do
        TyConI info <- recover (fail unknownType) (reify (mkName fieldTypeName))

        case info of
            TySynD _ _ (ConT synTo)
                | synTo == ''Int         -> [| P.decimalXS s |]
                | otherwise -> fail $ "Only Int synonyms supported, not " ++ show synTo

            NewtypeD _ _ _ (NormalC constr [(_, ConT typeFor)]) _
                | typeFor == ''Int       -> [| $( return $ ConE constr) `fmap` P.decimalXS s |]
                | otherwise -> fail $ "Not supported type inside newtype: " ++ show typeFor

            _ -> fail $ "Size based parser only supported for type and newtype declarations: " ++ show info
    where
        unknownType = "Type `" ++ fieldTypeName ++ "' is undefined. " ++ cantDerive
        cantDerive  = "Can't derive size based parser."

-- | Apply the given action repeatedly, returning every result.
count :: Monad m => Int -> m a -> m [a]
count n p = sequence (replicate n p)
{-# INLINE count #-}
