{-#LANGUAGE TupleSections #-}
{-#LANGUAGE OverloadedStrings #-}
{-#LANGUAGE ScopedTypeVariables #-}
-- | Ginger parser.
module Text.Ginger.Parse
( parseGinger
, parseGingerFile
, ParserError (..)
, IncludeResolver
, Source, SourceName
)
where

import Text.Parsec ( ParseError
                   , sourceLine
                   , sourceColumn
                   , sourceName
                   , ParsecT
                   , runParserT
                   , try, lookAhead
                   , manyTill, oneOf, string, notFollowedBy, between, sepBy
                   , eof, spaces, anyChar, char
                   , option
                   , unexpected
                   , digit
                   , getState, modifyState
                   , (<?>)
                   )
import Text.Parsec.Error ( errorMessages
                         , errorPos
                         , showErrorMessages
                         )
import Text.Ginger.AST
import Text.Ginger.Html ( unsafeRawHtml )

import Control.Monad.Reader ( ReaderT
                            , runReaderT
                            , ask, asks
                            )
import Control.Monad.Trans.Class ( lift )
import Control.Applicative
import Safe ( readMay )

import Data.Text (Text)
import Data.Maybe ( fromMaybe )
import Data.Scientific ( Scientific )
import qualified Data.Text as Text
import Data.List ( foldr, nub, sort )
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap

import System.FilePath ( takeDirectory, (</>) )

-- | Input type for the parser (source code).
type Source = String

-- | A source identifier (typically a filename).
type SourceName = String

-- | Used to resolve includes. Ginger will call this function whenever it
-- encounters an {% include %}, {% import %}, or {% extends %} directive.
-- If the required source code is not available, the resolver should return
-- @Nothing@, else @Just@ the source.
type IncludeResolver m = SourceName -> m (Maybe Source)


-- | Error information for Ginger parser errors.
data ParserError =
    ParserError
        { peErrorMessage :: String -- ^ Human-readable error message
        , peSourceName :: Maybe SourceName -- ^ Source name, if any
        , peSourceLine :: Maybe Int -- ^ Line number, if available
        , peSourceColumn :: Maybe Int -- ^ Column number, if available
        }
        deriving (Show)

-- | Helper function to create a Ginger parser error from a Parsec error.
fromParsecError :: ParseError -> ParserError
fromParsecError e =
    let pos = errorPos e
        sourceFilename =
            let sn = sourceName pos
            in if null sn then Nothing else Just sn
    in ParserError
        (dropWhile (== '\n') .
            showErrorMessages
            "or"
            "unknown parse error"
            "expecting"
            "unexpected"
            "end of input"
            $ errorMessages e)
        sourceFilename
        (Just $ sourceLine pos)
        (Just $ sourceColumn pos)
-- | Parse Ginger source from a file.
parseGingerFile :: Monad m => IncludeResolver m -> SourceName -> m (Either ParserError Template)
parseGingerFile resolve fn = do
    srcMay <- resolve fn
    case srcMay of
        Nothing -> return . Left $
            ParserError
                { peErrorMessage = "Template source not found: " ++ fn
                , peSourceName = Nothing
                , peSourceLine = Nothing
                , peSourceColumn = Nothing
                }
        Just src -> parseGinger resolve (Just fn) src


data ParseContext m
    = ParseContext
        { pcResolve :: IncludeResolver m
        , pcCurrentSource :: Maybe SourceName
        }

data ParseState
    = ParseState
        { psBlocks :: HashMap VarName Block
        }

defParseState :: ParseState
defParseState =
    ParseState
        { psBlocks = HashMap.empty
        }

-- | Parse Ginger source from memory.
parseGinger :: Monad m => IncludeResolver m -> Maybe SourceName -> Source -> m (Either ParserError Template)
parseGinger resolve sn src = do
    result <- runReaderT (runParserT (templateP `before` eof) defParseState (fromMaybe "<<unknown>>" sn) src) (ParseContext resolve sn)
    case result of
        Right t -> return . Right $ t
        Left e -> return . Left $ fromParsecError e

type Parser m a = ParsecT String ParseState (ReaderT (ParseContext m) m) a

ignore :: Monad m => m a -> m ()
ignore = (>> return ())

getResolver :: Monad m => Parser m (IncludeResolver m)
getResolver = asks pcResolve

include :: Monad m => SourceName -> Parser m Statement
include sourceName = PreprocessedIncludeS <$> includeTemplate sourceName

-- include sourceName = templateBody <$> includeTemplate sourceName

includeTemplate :: Monad m => SourceName -> Parser m Template
includeTemplate sourceName = do
    resolver <- getResolver
    currentSource <- fromMaybe "" <$> asks pcCurrentSource
    let includeSourceName = takeDirectory currentSource </> sourceName
    pres <- lift . lift $ parseGingerFile resolver includeSourceName
    case pres of
        Right t -> return t
        Left err -> fail (show err)

reduceStatements :: [Statement] -> Statement
reduceStatements [] = NullS
reduceStatements (x:[]) = x
reduceStatements xs = MultiS xs

templateP :: Monad m => Parser m Template
templateP = derivedTemplateP <|> baseTemplateP

derivedTemplateP :: Monad m => Parser m Template
derivedTemplateP = do
    parentName <- try (spaces >> fancyTagP "extends" stringLiteralP)
    parentTemplate <- includeTemplate parentName
    blocks <- HashMap.fromList <$> many blockP
    return $ Template { templateBody = NullS, templateParent = Just parentTemplate, templateBlocks = blocks }

baseTemplateP :: Monad m => Parser m Template
baseTemplateP = do
    body <- statementsP
    blocks <- psBlocks <$> getState
    return $ Template { templateBody = body, templateParent = Nothing, templateBlocks = blocks }

statementsP :: Monad m => Parser m Statement
statementsP = do
    reduceStatements . filter (not . isNullS) <$> many (try statementP)
    where
        isNullS NullS = True
        isNullS _ = False

statementP :: Monad m => Parser m Statement
statementP = interpolationStmtP
           <|> commentStmtP
           <|> ifStmtP
           <|> setStmtP
           <|> forStmtP
           <|> includeP
           <|> macroStmtP
           <|> blockStmtP
           <|> callStmtP
           <|> scopeStmtP
           <|> literalStmtP

interpolationStmtP :: Monad m => Parser m Statement
interpolationStmtP = do
    try $ string "{{"
    spaces
    expr <- expressionP
    spaces
    string "}}"
    return $ InterpolationS expr

literalStmtP :: Monad m => Parser m Statement
literalStmtP = do
    txt <- manyTill anyChar endOfLiteralP

    case txt of
        [] -> unexpected "{{"
        _ -> return . LiteralS . unsafeRawHtml . Text.pack $ txt

endOfLiteralP :: Monad m => Parser m ()
endOfLiteralP =
    (ignore . lookAhead . try . string $ "{{") <|>
    (ignore . lookAhead $ openTagP) <|>
    (ignore . lookAhead $ openCommentP) <|>
    eof

commentStmtP :: Monad m => Parser m Statement
commentStmtP = do
    try $ openCommentP
    manyTill anyChar (try $ closeCommentP)
    return NullS

ifStmtP :: Monad m => Parser m Statement
ifStmtP = do
    condExpr <- fancyTagP "if" expressionP
    trueStmt <- statementsP
    falseStmt <- elifBranchP <|> elseBranchP <|> return NullS
    simpleTagP "endif"
    return $ IfS condExpr trueStmt falseStmt

elseBranchP :: Monad m => Parser m Statement
elseBranchP = do
    try $ simpleTagP "else"
    statementsP

elifBranchP :: Monad m => Parser m Statement
elifBranchP = do
    condExpr <- try $ fancyTagP "elif" expressionP
    trueStmt <- statementsP
    falseStmt <- elifBranchP <|> elseBranchP <|> return NullS
    -- No endif here: the parent {% if %} owns that one.
    return $ IfS condExpr trueStmt falseStmt

setStmtP :: Monad m => Parser m Statement
setStmtP = fancyTagP "set" setStmtInnerP

setStmtInnerP :: Monad m => Parser m Statement
setStmtInnerP = do
    name <- identifierP
    spaces
    char '='
    spaces
    val <- expressionP
    spaces
    return $ SetVarS name val

defineBlock :: VarName -> Block -> ParseState -> ParseState
defineBlock name block s =
    s { psBlocks = HashMap.insert name block (psBlocks s) }

blockStmtP :: Monad m => Parser m Statement
blockStmtP = do
    (name, block) <- blockP
    modifyState (defineBlock name block)
    return $ BlockRefS name

blockP :: Monad m => Parser m (VarName, Block)
blockP = do
    name <- fancyTagP "block" identifierP
    body <- statementsP
    fancyTagP "endblock" (optional $ string (Text.unpack name) >> spaces)
    return (name, Block body)

macroStmtP :: Monad m => Parser m Statement
macroStmtP = do
    (name, args) <- try $ fancyTagP "macro" macroHeadP
    body <- statementsP
    fancyTagP "endmacro" (optional $ string (Text.unpack name) >> spaces)
    return $ DefMacroS name (Macro args body)

macroHeadP :: Monad m => Parser m (VarName, [VarName])
macroHeadP = do
    name <- identifierP
    spaces
    args <- option [] $ groupP "(" ")" identifierP
    spaces
    return (name, args)

-- {% call (foo) bar(baz) %}quux{% endcall %}
--
-- is the same as:
--
-- {% scope %}
-- {% macro __lambda(foo) %}quux{% endmacro %}
-- {% set caller = __lambda %}
-- {{ bar(baz) }}
-- {% endscope %]
callStmtP :: Monad m => Parser m Statement
callStmtP = do
    (callerArgs, call) <- try $ fancyTagP "call" callHeadP
    body <- statementsP
    simpleTagP "endcall"
    return (
        ScopedS (
            MultiS [ DefMacroS "caller" (Macro callerArgs body)
                   , InterpolationS call
                   ]))

callHeadP :: Monad m => Parser m ([Text], Expression)
callHeadP = do
    callerArgs <- option [] $ groupP "(" ")" identifierP
    spaces
    call <- expressionP
    spaces
    return (callerArgs, call)

scopeStmtP :: Monad m => Parser m Statement
scopeStmtP =
    ScopedS <$>
        between
            (simpleTagP "scope")
            (simpleTagP "endscope")
            statementsP

forStmtP :: Monad m => Parser m Statement
forStmtP = do
    (iteree, varNameVal, varNameIndex) <- fancyTagP "for" forHeadP
    body <- statementsP
    simpleTagP "endfor"
    return $ ForS varNameIndex varNameVal iteree body

includeP :: Monad m => Parser m Statement
includeP = do
    sourceName <- fancyTagP "include" stringLiteralP
    include sourceName

forHeadP :: Monad m => Parser m (Expression, VarName, Maybe VarName)
forHeadP = try forHeadInP <|> forHeadAsP

forIteratorP :: Monad m => Parser m (VarName, Maybe VarName)
forIteratorP = try forIndexedIteratorP <|> try forSimpleIteratorP <?> "iteration variables"

forIndexedIteratorP :: Monad m => Parser m (VarName, Maybe VarName)
forIndexedIteratorP = do
    indexIdent <- identifierP
    spaces
    char ','
    spaces
    varIdent <- identifierP
    spaces
    return (varIdent, Just indexIdent)

forSimpleIteratorP :: Monad m => Parser m (VarName, Maybe VarName)
forSimpleIteratorP = do
    varIdent <- identifierP
    spaces
    return (varIdent, Nothing)

forHeadInP :: Monad m => Parser m (Expression, VarName, Maybe VarName)
forHeadInP = do
    (varIdent, indexIdent) <- forIteratorP
    spaces
    string "in"
    notFollowedBy identCharP
    spaces
    iteree <- expressionP
    return (iteree, varIdent, indexIdent)

forHeadAsP :: Monad m => Parser m (Expression, VarName, Maybe VarName)
forHeadAsP = do
    iteree <- expressionP
    spaces
    string "as"
    notFollowedBy identCharP
    spaces
    (varIdent, indexIdent) <- forIteratorP
    return (iteree, varIdent, indexIdent)

fancyTagP :: Monad m => String -> Parser m a -> Parser m a
fancyTagP tagName inner =
    between
        (try $ do
            openTagP
            string tagName
            spaces)
        closeTagP
        inner

simpleTagP :: Monad m => String -> Parser m ()
simpleTagP tagName = openTagP >> string tagName >> closeTagP

openCommentP :: Monad m => Parser m ()
openCommentP = openP '#'

closeCommentP :: Monad m => Parser m ()
closeCommentP = closeP '#'

openTagP :: Monad m => Parser m ()
openTagP = openP '%'

closeTagP :: Monad m => Parser m ()
closeTagP = closeP '%'

openP :: Monad m => Char -> Parser m ()
openP c = try (openWP c) <|> try (openNWP c)

openWP :: Monad m => Char -> Parser m ()
openWP c = ignore $ do
    spaces
    string [ '{', c, '-' ]
    spaces

openNWP :: Monad m => Char -> Parser m ()
openNWP c = ignore $ do
    string [ '{', c ]
    spaces

closeP :: Monad m => Char -> Parser m ()
closeP c = try (closeWP c) <|> try (closeNWP c)

closeWP :: Monad m => Char -> Parser m ()
closeWP c = ignore $ do
    spaces
    string [ '-', c, '}' ]
    spaces

closeNWP :: Monad m => Char -> Parser m ()
closeNWP c = ignore $ do
    spaces
    string [ c, '}' ]
    optional . ignore . char $ '\n'

expressionP :: Monad m => Parser m Expression
expressionP = lambdaExprP <|> booleanExprP

lambdaExprP :: Monad m => Parser m Expression
lambdaExprP = do
    argNames <- try $ do
        char '('
        spaces
        argNames <- sepBy (spaces >> identifierP) (try $ spaces >> char ',')
        char ')'
        spaces
        string "->"
        spaces
        return argNames
    body <- expressionP
    return $ LambdaE argNames body

operativeExprP :: forall m. Monad m => Parser m Expression -> [ (String, Text) ] -> Parser m Expression
operativeExprP operandP operators = do
    lhs <- operandP
    spaces
    tails <- many . try $ operativeTail
    return $ foldl (flip ($)) lhs tails
    where
        opChars :: [Char]
        opChars = nub . sort . concat . map fst $ operators
        operativeTail :: Parser m (Expression -> Expression)
        operativeTail = do
            funcName <-
                foldl (<|>) (fail "operator") $
                [ try (string op >> notFollowedBy (oneOf opChars)) >> return fn | (op, fn) <- operators ]
            spaces
            rhs <- operandP
            spaces
            return (\lhs -> CallE (VarE funcName) [(Nothing, lhs), (Nothing, rhs)])

booleanExprP :: Monad m => Parser m Expression
booleanExprP =
    operativeExprP
        comparativeExprP
        [ ("||", "any")
        , ("&&", "all")
        ]

comparativeExprP :: Monad m => Parser m Expression
comparativeExprP =
    operativeExprP
        additiveExprP
        [ ("==", "equals")
        , ("!=", "nequals")
        , (">=", "greaterEquals")
        , ("<=", "lessEquals")
        , (">", "greater")
        , ("<", "less")
        ]

additiveExprP :: Monad m => Parser m Expression
additiveExprP =
    operativeExprP
        multiplicativeExprP
        [ ("+", "sum")
        , ("-", "difference")
        , ("~", "concat")
        ]

multiplicativeExprP :: Monad m => Parser m Expression
multiplicativeExprP =
    operativeExprP
        postfixExprP
        [ ("*", "product")
        , ("//", "int_ratio")
        , ("/", "ratio")
        , ("%", "modulo")
        ]

postfixExprP :: Monad m => Parser m Expression
postfixExprP = do
    base <- atomicExprP
    spaces
    postfixes <- many . try $ postfixP `before` spaces
    return $ foldl (flip ($)) base postfixes

postfixP :: Monad m => Parser m (Expression -> Expression)
postfixP = dotPostfixP
         <|> arrayAccessP
         <|> funcCallP
         <|> filterP

dotPostfixP :: Monad m => Parser m (Expression -> Expression)
dotPostfixP = do
    char '.'
    spaces
    i <- StringLiteralE <$> identifierP
    return $ \e -> MemberLookupE e i

arrayAccessP :: Monad m => Parser m (Expression -> Expression)
arrayAccessP = do
    i <- bracedP "[" "]" expressionP
    return $ \e -> MemberLookupE e i

funcCallP :: Monad m => Parser m (Expression -> Expression)
funcCallP = do
    args <- groupP "(" ")" funcArgP
    return $ \e -> CallE e args

funcArgP :: Monad m => Parser m (Maybe Text, Expression)
funcArgP = namedFuncArgP <|> positionalFuncArgP

namedFuncArgP :: Monad m => Parser m (Maybe Text, Expression)
namedFuncArgP = do
    name <- try $ identifierP `before` (between spaces spaces $ string "=")
    expr <- expressionP
    return (Just name, expr)

positionalFuncArgP :: Monad m => Parser m (Maybe Text, Expression)
positionalFuncArgP = try $ (Nothing,) <$> expressionP

filterP :: Monad m => Parser m (Expression -> Expression)
filterP = do
    char '|'
    spaces
    func <- atomicExprP
    args <- option [] $ groupP "(" ")" funcArgP
    return $ \e -> CallE func ((Nothing, e):args)

atomicExprP :: Monad m => Parser m Expression
atomicExprP = parenthesizedExprP
            <|> objectExprP
            <|> listExprP
            <|> stringLiteralExprP
            <|> numberLiteralExprP
            <|> varExprP

parenthesizedExprP :: Monad m => Parser m Expression
parenthesizedExprP =
    between
        (try . ignore $ char '(' >> spaces)
        (ignore $ char ')' >> spaces)
        expressionP

listExprP :: Monad m => Parser m Expression
listExprP = ListE <$> groupP "[" "]" expressionP

objectExprP :: Monad m => Parser m Expression
objectExprP = ObjectE <$> groupP "{" "}" expressionPairP

expressionPairP :: Monad m => Parser m (Expression, Expression)
expressionPairP = do
    a <- expressionP
    spaces
    char ':'
    spaces
    b <- expressionP
    spaces
    return (a, b)

groupP :: Monad m => String -> String -> Parser m a -> Parser m [a]
groupP obr cbr inner =
    bracedP obr cbr
        (sepBy (inner `before` spaces) (try $ string "," `before` spaces))

bracedP :: Monad m => String -> String -> Parser m a -> Parser m a
bracedP obr cbr =
    between
        (try . ignore $ string obr >> spaces)
        (ignore $ string cbr >> spaces)

varExprP :: Monad m => Parser m Expression
varExprP = do
    litName <- identifierP
    spaces
    return $ case litName of
        "true" -> BoolLiteralE True
        "false" -> BoolLiteralE False
        "null" -> NullLiteralE
        _ -> VarE litName

identifierP :: Monad m => Parser m Text
identifierP =
    Text.pack <$> (
    (:)
        <$> oneOf (['a'..'z'] ++ ['A'..'Z'] ++ ['_'])
        <*> many identCharP)

identCharP :: Monad m => Parser m Char
identCharP = oneOf (['a'..'z'] ++ ['A'..'Z'] ++ ['_'] ++ ['0'..'9'])

stringLiteralExprP :: Monad m => Parser m Expression
stringLiteralExprP = do
    StringLiteralE . Text.pack <$> stringLiteralP

stringLiteralP :: Monad m => Parser m String
stringLiteralP = do
    d <- oneOf [ '\'', '\"' ]
    manyTill stringCharP (char d)

stringCharP :: Monad m => Parser m Char
stringCharP = do
    c1 <- anyChar
    case c1 of
        '\\' -> do
            c2 <- anyChar
            case c2 of
                'n' -> return '\n'
                'b' -> return '\b'
                'v' -> return '\v'
                '0' -> return '\0'
                't' -> return '\t'
                _ -> return c2
        _ -> return c1

numberLiteralExprP :: Monad m => Parser m Expression
numberLiteralExprP = do
    str <- numberLiteralP
    let nMay :: Maybe Scientific
        nMay = readMay str
    case nMay of
        Just n -> return . NumberLiteralE $ n
        Nothing -> fail $ "Failed to parse " ++ str ++ " as a number"

numberLiteralP :: Monad m => Parser m String
numberLiteralP = do
    sign <- option "" $ string "-"
    integral <- string "0" <|> ((:) <$> oneOf ['1'..'9'] <*> many digit)
    fractional <- option "" $ (:) <$> char '.' <*> many digit
    return $ sign ++ integral ++ fractional

followedBy :: Monad m => m b -> m a -> m a
followedBy b a = a >>= \x -> (b >> return x)

before :: Monad m => m a -> m b -> m a
before = flip followedBy
