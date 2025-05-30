{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{- |
   Module      : Text.Pandoc.Writers.Shared
   Copyright   : Copyright (C) 2013-2024 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Shared utility functions for pandoc writers.
-}
module Text.Pandoc.Writers.Shared (
                       metaToContext
                     , metaToContext'
                     , addVariablesToContext
                     , getField
                     , setField
                     , resetField
                     , defField
                     , getLang
                     , tagWithAttrs
                     , htmlAddStyle
                     , htmlAlignmentToString
                     , htmlAttrs
                     , isDisplayMath
                     , fixDisplayMath
                     , unsmartify
                     , gridTable
                     , lookupMetaBool
                     , lookupMetaBlocks
                     , lookupMetaInlines
                     , lookupMetaString
                     , stripLeadingTrailingSpace
                     , toSubscript
                     , toSuperscript
                     , toSubscriptInline
                     , toSuperscriptInline
                     , toTableOfContents
                     , endsWithPlain
                     , toLegacyTable
                     , splitSentences
                     , ensureValidXmlIdentifiers
                     , setupTranslations
                     , isOrderedListMarker
                     , toTaskListItem
                     , delimited
                     )
where
import Safe (lastMay)
import qualified Data.ByteString.Lazy as BL
import Control.Monad (zipWithM, MonadPlus, mzero)
import Data.Either (isRight)
import Data.Aeson (ToJSON (..), encode)
import Data.Char (chr, ord, isSpace, isLetter, isUpper)
import Data.List (groupBy, intersperse, transpose, foldl')
import Data.List.NonEmpty (NonEmpty(..), nonEmpty)
import Data.Text.Conversions (FromText(..))
import qualified Data.Map as M
import qualified Data.Text as T
import Data.Text (Text)
import qualified Text.Pandoc.Builder as Builder
import Text.Pandoc.CSS (cssAttributes)
import Text.Pandoc.Definition
import Text.Pandoc.Options
import Text.Pandoc.Parsing (runParser, eof, defaultParserState,
                            anyOrderedListMarker)
import Text.DocLayout
import Text.Pandoc.Shared (stringify, makeSections, blocksToInlines)
import Text.Pandoc.Walk (Walkable(..))
import qualified Text.Pandoc.UTF8 as UTF8
import Text.Pandoc.XML (escapeStringForXML)
import Text.DocTemplates (Context(..), Val(..), TemplateTarget,
                          ToContext(..), FromContext(..))
import Text.Pandoc.Chunks (tocToList, toTOCTree)
import Text.Collate.Lang (Lang (..))
import Text.Pandoc.Class (PandocMonad, toLang)
import Text.Pandoc.Translations (setTranslations)
import Data.Maybe (fromMaybe)

-- | Create template Context from a 'Meta' and an association list
-- of variables, specified at the command line or in the writer.
-- Variables overwrite metadata fields with the same names.
-- If multiple variables are set with the same name, a list is
-- assigned.  Does nothing if 'writerTemplate' is Nothing.
metaToContext :: (Monad m, TemplateTarget a)
              => WriterOptions
              -> ([Block] -> m (Doc a))
              -> ([Inline] -> m (Doc a))
              -> Meta
              -> m (Context a)
metaToContext opts blockWriter inlineWriter meta =
  case writerTemplate opts of
    Nothing -> return mempty
    Just _  -> addVariablesToContext opts <$>
                metaToContext' blockWriter inlineWriter meta

-- | Like 'metaToContext, but does not include variables and is
-- not sensitive to 'writerTemplate'.
metaToContext' :: (Monad m, TemplateTarget a)
           => ([Block] -> m (Doc a))     -- ^ block writer
           -> ([Inline] -> m (Doc a))    -- ^ inline writer
           -> Meta
           -> m (Context a)
metaToContext' blockWriter inlineWriter (Meta metamap) =
  Context <$> mapM (metaValueToVal blockWriter inlineWriter) metamap

-- | Add variables to a template Context, using monoidal append.
-- Also add `meta-json`.  Note that metadata values are used
-- in template contexts only when like-named variables aren't set.
addVariablesToContext :: TemplateTarget a
                      => WriterOptions -> Context a -> Context a
addVariablesToContext opts c1 =
  c2 <> (fromText <$> writerVariables opts) <> c1
 where
   c2 = Context $
          M.insert "meta-json" (SimpleVal $ literal $ fromText jsonrep)
                               mempty
   jsonrep = UTF8.toText $ BL.toStrict $ encode $ toJSON c1

-- | Converts a 'MetaValue' into a doctemplate 'Val', using the given
-- converter functions.
metaValueToVal :: (Monad m, TemplateTarget a)
               => ([Block] -> m (Doc a))    -- ^ block writer
               -> ([Inline] -> m (Doc a))   -- ^ inline writer
               -> MetaValue
               -> m (Val a)
metaValueToVal blockWriter inlineWriter (MetaMap metamap) =
  MapVal . Context <$> mapM (metaValueToVal blockWriter inlineWriter) metamap
metaValueToVal blockWriter inlineWriter (MetaList xs) = ListVal <$>
  mapM (metaValueToVal blockWriter inlineWriter) xs
metaValueToVal _ _ (MetaBool b) = return $ BoolVal b
metaValueToVal _ inlineWriter (MetaString s) =
   SimpleVal <$> inlineWriter (Builder.toList (Builder.text s))
metaValueToVal blockWriter _ (MetaBlocks bs) = SimpleVal <$> blockWriter bs
metaValueToVal _ inlineWriter (MetaInlines is) = SimpleVal <$> inlineWriter is


-- | Retrieve a field value from a template context.
getField   :: FromContext a b => Text -> Context a -> Maybe b
getField field (Context m) = M.lookup field m >>= fromVal

-- | Set a field of a template context.  If the field already has a value,
-- convert it into a list with the new value appended to the old value(s).
-- This is a utility function to be used in preparing template contexts.
setField   :: ToContext a b => Text -> b -> Context a -> Context a
setField field val (Context m) =
  Context $ M.insertWith combine field (toVal val) m
 where
  combine newval (ListVal xs)   = ListVal (xs ++ [newval])
  combine newval x              = ListVal [x, newval]

-- | Reset a field of a template context.  If the field already has a
-- value, the new value replaces it.
-- This is a utility function to be used in preparing template contexts.
resetField :: ToContext a b => Text -> b -> Context a -> Context a
resetField field val (Context m) =
  Context (M.insert field (toVal val) m)

-- | Set a field of a template context if it currently has no value.
-- If it has a value, do nothing.
-- This is a utility function to be used in preparing template contexts.
defField   :: ToContext a b => Text -> b -> Context a -> Context a
defField field val (Context m) =
  Context (M.insertWith f field (toVal val) m)
  where
    f _newval oldval = oldval

-- | Get the contents of the `lang` metadata field or variable.
getLang :: WriterOptions -> Meta -> Maybe Text
getLang opts meta =
  case lookupContext "lang" (writerVariables opts) of
        Just s -> Just s
        _      ->
          case lookupMeta "lang" meta of
               Just (MetaBlocks [Para [Str s]])  -> Just s
               Just (MetaBlocks [Plain [Str s]]) -> Just s
               Just (MetaInlines [Str s])        -> Just s
               Just (MetaString s)               -> Just s
               _                                 -> Nothing

-- | Produce an HTML tag with the given pandoc attributes.
tagWithAttrs :: HasChars a => a -> Attr -> Doc a
tagWithAttrs tag attr = "<" <> literal tag <> (htmlAttrs attr) <> ">"

-- | Produce HTML for the given pandoc attributes, to be used in HTML tags
htmlAttrs :: HasChars a => Attr -> Doc a
htmlAttrs (ident, classes, kvs) = addSpaceIfNotEmpty (hsep [
  if T.null ident
      then empty
      else "id=" <> doubleQuotes (text $ T.unpack ident)
  ,if null classes
      then empty
      else "class=" <> doubleQuotes (text $ T.unpack (T.unwords classes))
  ,hsep (map (\(k,v) -> text (T.unpack k) <> "=" <>
                doubleQuotes (text $ T.unpack (escapeStringForXML v))) kvs)
  ])

addSpaceIfNotEmpty :: HasChars a => Doc a -> Doc a
addSpaceIfNotEmpty f = if isEmpty f then f else " " <> f

-- | Adds a key-value pair to the @style@ attribute.
htmlAddStyle :: (Text, Text) -> [(Text, Text)] -> [(Text, Text)]
htmlAddStyle (key, value) kvs =
  let cssToStyle = T.intercalate " " . map (\(k, v) -> k <> ": " <> v <> ";")
  in case break ((== "style") . fst) kvs of
    (_, []) ->
      -- no style attribute yet, add new one
      ("style", cssToStyle [(key, value)]) : kvs
    (xs, (_,cssStyles):rest) ->
      -- modify the style attribute
      xs ++ ("style", cssToStyle modifiedCssStyles) : rest
      where
        modifiedCssStyles =
          case break ((== key) . fst) $ cssAttributes cssStyles of
            (cssAttribs, []) -> (key, value) : cssAttribs
            (pre, _:post)    -> pre ++ (key, value) : post

-- | Get the html representation of an alignment key
htmlAlignmentToString :: Alignment -> Maybe Text
htmlAlignmentToString = \case
  AlignLeft    -> Just "left"
  AlignRight   -> Just "right"
  AlignCenter  -> Just "center"
  AlignDefault -> Nothing

-- | Returns 'True' iff the argument is an inline 'Math' element of type
-- 'DisplayMath'.
isDisplayMath :: Inline -> Bool
isDisplayMath (Math DisplayMath _)          = True
isDisplayMath (Span _ [Math DisplayMath _]) = True
isDisplayMath _                             = False

-- | Remove leading and trailing 'Space' and 'SoftBreak' elements.
stripLeadingTrailingSpace :: [Inline] -> [Inline]
stripLeadingTrailingSpace = go . reverse . go . reverse
  where go (Space:xs)     = xs
        go (SoftBreak:xs) = xs
        go xs             = xs

-- | Put display math in its own block (for ODT/DOCX).
fixDisplayMath :: Block -> Block
fixDisplayMath (Plain lst)
  | any isDisplayMath lst && not (all isDisplayMath lst) =
    -- chop into several paragraphs so each displaymath is its own
    Div ("",["math"],[]) $
       map Plain $
       filter (not . null) $
       map stripLeadingTrailingSpace $
       groupBy (\x y -> (isDisplayMath x && isDisplayMath y) ||
                         not (isDisplayMath x || isDisplayMath y)) lst
fixDisplayMath (Para lst)
  | any isDisplayMath lst && not (all isDisplayMath lst) =
    -- chop into several paragraphs so each displaymath is its own
    Div ("",["math"],[]) $
       map Para $
       filter (not . null) $
       map stripLeadingTrailingSpace $
       groupBy (\x y -> (isDisplayMath x && isDisplayMath y) ||
                         not (isDisplayMath x || isDisplayMath y)) lst
fixDisplayMath x = x

-- | Converts a Unicode character into the ASCII sequence used to
-- represent the character in "smart" Markdown.
unsmartify :: WriterOptions -> Text -> Text
unsmartify opts = T.concatMap $ \c -> case c of
  '\8217' -> "'"
  '\8230' -> "..."
  '\8211'
    | isEnabled Ext_old_dashes opts -> "-"
    | otherwise                     -> "--"
  '\8212'
    | isEnabled Ext_old_dashes opts -> "--"
    | otherwise                     -> "---"
  '\8220' -> "\""
  '\8221' -> "\""
  '\8216' -> "'"
  _       -> T.singleton c

-- | Writes a grid table.
gridTable :: (Monad m, HasChars a)
          => WriterOptions
          -> (WriterOptions -> [Block] -> m (Doc a)) -- ^ format Doc writer
          -> Bool             -- ^ headless
          -> [Alignment]      -- ^ column alignments
          -> [Double]         -- ^ column widths
          -> [[Block]]        -- ^ table header row
          -> [[[Block]]]      -- ^ table body rows
          -> m (Doc a)
gridTable opts blocksToDoc headless aligns widths headers rows = do
  -- the number of columns will be used in case of even widths
  let numcols = maximum (length aligns :| length widths :
                           map length (headers:rows))
  let officialWidthsInChars :: [Double] -> [Int]
      officialWidthsInChars widths' = map (
                        (max 1) .
                        (\x -> x - 3) . floor .
                        (fromIntegral (writerColumns opts) *)
                        ) widths'
  -- handleGivenWidths wraps the given blocks in order for them to fit
  -- in cells with given widths. the returned content can be
  -- concatenated with borders and frames
  let handleGivenWidthsInChars widthsInChars' = do
        -- replace page width (in columns) in the options with a
        -- given width if smaller (adjusting by two)
        let useWidth w = opts{writerColumns = min (w - 2) (writerColumns opts)}
        -- prepare options to use with header and row cells
        let columnOptions = map useWidth widthsInChars'
        rawHeaders' <- zipWithM blocksToDoc columnOptions headers
        rawRows' <- mapM
             (\cs -> zipWithM blocksToDoc columnOptions cs)
             rows
        return (widthsInChars', rawHeaders', rawRows')
  let handleGivenWidths widths' = handleGivenWidthsInChars
                                     (officialWidthsInChars widths')
  -- handleFullWidths tries to wrap cells to the page width or even
  -- more in cases where `--wrap=none`. thus the content here is left
  -- as wide as possible
  let handleFullWidths widths' = do
        rawHeaders' <- mapM (blocksToDoc opts) headers
        rawRows' <- mapM (mapM (blocksToDoc opts)) rows
        let numChars = maybe 0 maximum . nonEmpty . map offset
        let minWidthsInChars =
                map numChars $ transpose (rawHeaders' : rawRows')
        let widthsInChars' = zipWith max
                              minWidthsInChars
                              (officialWidthsInChars widths')
        return (widthsInChars', rawHeaders', rawRows')
  -- handleZeroWidths calls handleFullWidths to check whether a wide
  -- table would fit in the page. if the produced table is too wide,
  -- it calculates even widths and passes the content to
  -- handleGivenWidths
  let handleZeroWidths widths' = do
        (widthsInChars', rawHeaders', rawRows') <- handleFullWidths widths'
        if foldl' (+) 0 widthsInChars' > writerColumns opts
           then do -- use even widths except for thin columns
             let evenCols  = max 5
                              (((writerColumns opts - 1) `div` numcols) - 3)
             let (numToExpand, colsToExpand) =
                   foldr (\w (n, tot) -> if w < evenCols
                                            then (n, tot + (evenCols - w))
                                            else (n + 1, tot))
                                   (0,0) widthsInChars'
             let expandAllowance = colsToExpand `div` numToExpand
             let newWidthsInChars = map (\w -> if w < evenCols
                                                  then w
                                                  else min
                                                       (evenCols + expandAllowance)
                                                       w)
                                        widthsInChars'
             handleGivenWidthsInChars newWidthsInChars
           else return (widthsInChars', rawHeaders', rawRows')
  -- render the contents of header and row cells differently depending
  -- on command line options, widths given in this specific table, and
  -- cells' contents
  let handleWidths
        | writerWrapText opts == WrapNone    = handleFullWidths widths
        | all (== 0) widths                  = handleZeroWidths widths
        | otherwise                          = handleGivenWidths widths
  (widthsInChars, rawHeaders, rawRows) <- handleWidths
  let hpipeBlocks blocks = hcat [beg, middle, end]
        where sep'    = vfill " | "
              beg     = vfill "| "
              end     = vfill " |"
              middle  = chomp $ hcat $ intersperse sep' blocks
  let makeRow = hpipeBlocks . zipWith lblock widthsInChars
  let head' = makeRow rawHeaders
  let rows' = map (makeRow . map chomp) rawRows
  let borderpart ch align widthInChars =
           (if align == AlignLeft || align == AlignCenter
               then char ':'
               else char ch) <>
           text (replicate widthInChars ch) <>
           (if align == AlignRight || align == AlignCenter
               then char ':'
               else char ch)
  let border ch aligns' widthsInChars' =
        char '+' <>
        hcat (intersperse (char '+') (zipWith (borderpart ch)
                aligns' widthsInChars')) <> char '+'
  let body = vcat $ intersperse (border '-' (repeat AlignDefault) widthsInChars)
                    rows'
  let head'' = if headless
                  then empty
                  else head' $$ border '=' aligns widthsInChars
  if headless
     then return $
           border '-' aligns widthsInChars $$
           body $$
           border '-' (repeat AlignDefault) widthsInChars
     else return $
           border '-' (repeat AlignDefault) widthsInChars $$
           head'' $$
           body $$
           border '-' (repeat AlignDefault) widthsInChars

-- | Retrieve the metadata value for a given @key@
-- and convert to Bool.
lookupMetaBool :: Text -> Meta -> Bool
lookupMetaBool key meta =
  case lookupMeta key meta of
      Just (MetaBlocks _)  -> True
      Just (MetaInlines _) -> True
      Just (MetaString x)  -> not (T.null x)
      Just (MetaBool True) -> True
      _                    -> False

-- | Retrieve the metadata value for a given @key@
-- and extract blocks.
lookupMetaBlocks :: Text -> Meta -> [Block]
lookupMetaBlocks key meta =
  case lookupMeta key meta of
         Just (MetaBlocks bs)   -> bs
         Just (MetaInlines ils) -> [Plain ils]
         Just (MetaString s)    -> [Plain [Str s]]
         _                      -> []

-- | Retrieve the metadata value for a given @key@
-- and extract inlines.
lookupMetaInlines :: Text -> Meta -> [Inline]
lookupMetaInlines key meta =
  case lookupMeta key meta of
         Just (MetaString s)           -> [Str s]
         Just (MetaInlines ils)        -> ils
         Just (MetaBlocks [Plain ils]) -> ils
         Just (MetaBlocks [Para ils])  -> ils
         _                             -> []

-- | Retrieve the metadata value for a given @key@
-- and convert to String.
lookupMetaString :: Text -> Meta -> Text
lookupMetaString key meta =
  case lookupMeta key meta of
         Just (MetaString s)    -> s
         Just (MetaInlines ils) -> stringify ils
         Just (MetaBlocks bs)   -> stringify bs
         Just (MetaBool b)      -> T.pack (show b)
         _                      -> ""

-- | Tries to convert a character into a unicode superscript version of
-- the character.
toSuperscript :: Char -> Maybe Char
toSuperscript '1' = Just '\x00B9'
toSuperscript '2' = Just '\x00B2'
toSuperscript '3' = Just '\x00B3'
toSuperscript '+' = Just '\x207A'
toSuperscript '-' = Just '\x207B'
toSuperscript '\x2212' = Just '\x207B' -- unicode minus
toSuperscript '=' = Just '\x207C'
toSuperscript '(' = Just '\x207D'
toSuperscript ')' = Just '\x207E'
toSuperscript c
  | c >= '0' && c <= '9' =
                 Just $ chr (0x2070 + (ord c - 48))
  | isSpace c = Just c
  | otherwise = Nothing

-- | Tries to convert a character into a unicode subscript version of
-- the character.
toSubscript :: Char -> Maybe Char
toSubscript '+' = Just '\x208A'
toSubscript '-' = Just '\x208B'
toSubscript '=' = Just '\x208C'
toSubscript '(' = Just '\x208D'
toSubscript ')' = Just '\x208E'
toSubscript c
  | c >= '0' && c <= '9' =
                 Just $ chr (0x2080 + (ord c - 48))
  | isSpace c = Just c
  | otherwise = Nothing

toSubscriptInline :: Inline -> Maybe Inline
toSubscriptInline Space = Just Space
toSubscriptInline (Span attr ils) = Span attr <$> traverse toSubscriptInline ils
toSubscriptInline (Str s) = Str . T.pack <$> traverse toSubscript (T.unpack s)
toSubscriptInline LineBreak = Just LineBreak
toSubscriptInline SoftBreak = Just SoftBreak
toSubscriptInline _ = Nothing

toSuperscriptInline :: Inline -> Maybe Inline
toSuperscriptInline Space = Just Space
toSuperscriptInline (Span attr ils) = Span attr <$> traverse toSuperscriptInline ils
toSuperscriptInline (Str s) = Str . T.pack <$> traverse toSuperscript (T.unpack s)
toSuperscriptInline LineBreak = Just LineBreak
toSuperscriptInline SoftBreak = Just SoftBreak
toSuperscriptInline _ = Nothing

-- | Construct table of contents (as a bullet list) from document body.
toTableOfContents :: WriterOptions
                  -> [Block]
                  -> Block
toTableOfContents opts =
  tocToList (writerNumberSections opts) (writerTOCDepth opts)
  . toTOCTree
  . makeSections (writerNumberSections opts) Nothing

-- | Returns 'True' iff the list of blocks has a @'Plain'@ as its last
-- element.
endsWithPlain :: [Block] -> Bool
endsWithPlain xs =
  case lastMay xs of
    Just Plain{} -> True
    Just (BulletList is) -> maybe False endsWithPlain (lastMay is)
    Just (OrderedList _ is) -> maybe False endsWithPlain (lastMay is)
    _ -> False

-- | Convert the relevant components of a new-style table (with block
-- caption, row headers, row and column spans, and so on) to those of
-- an old-style table (inline caption, table head with one row, no
-- foot, and so on). Cells with a 'RowSpan' and 'ColSpan' of @(h, w)@
-- will be cut up into @h * w@ cells of dimension @(1, 1)@, with the
-- content placed in the upper-left corner.
toLegacyTable :: Caption
              -> [ColSpec]
              -> TableHead
              -> [TableBody]
              -> TableFoot
              -> ([Inline], [Alignment], [Double], [[Block]], [[[Block]]])
toLegacyTable (Caption _ cbody) specs thead tbodies tfoot
  = (cbody', aligns, widths, th', tb')
  where
    numcols = length specs
    (aligns, mwidths) = unzip specs
    fromWidth (ColWidth w) | w > 0 = w
    fromWidth _                    = 0
    widths = map fromWidth mwidths
    unRow (Row _ x) = x
    unBody (TableBody _ _ hd bd) = hd <> bd
    unBodies = concatMap unBody

    TableHead _ th = Builder.normalizeTableHead numcols thead
    tb = map (Builder.normalizeTableBody numcols) tbodies
    TableFoot _ tf = Builder.normalizeTableFoot numcols tfoot

    cbody' = blocksToInlines cbody

    (th', tb') = case th of
      r:rs -> let (pendingPieces, r') = placeCutCells [] $ unRow r
                  rs' = cutRows pendingPieces $ rs <> unBodies tb <> tf
              in (r', rs')
      []    -> ([], cutRows [] $ unBodies tb <> tf)

    -- Adapted from placeRowSection in Builders. There is probably a
    -- more abstract foldRowSection that unifies them both.
    placeCutCells pendingPieces cells
      -- If there are any pending pieces for a column, add
      -- them. Pending pieces have preference over cells due to grid
      -- layout rules.
      | (p:ps):pendingPieces' <- pendingPieces
      = let (pendingPieces'', rowPieces) = placeCutCells pendingPieces' cells
        in (ps : pendingPieces'', p : rowPieces)
      -- Otherwise cut up a cell on the row and deal with its pieces.
      | c:cells' <- cells
      = let (h, w, cBody) = getComponents c
            cRowPieces = cBody : replicate (w - 1) mempty
            cPendingPieces = replicate w $ replicate (h - 1) mempty
            pendingPieces' = drop w pendingPieces
            (pendingPieces'', rowPieces) = placeCutCells pendingPieces' cells'
        in (cPendingPieces <> pendingPieces'', cRowPieces <> rowPieces)
      | otherwise = ([], [])

    cutRows pendingPieces (r:rs)
      = let (pendingPieces', r') = placeCutCells pendingPieces $ unRow r
            rs' = cutRows pendingPieces' rs
        in r' : rs'
    cutRows _ [] = []

    getComponents (Cell _ _ (RowSpan h) (ColSpan w) body)
      = (h, w, body)

splitSentences :: Doc Text -> Doc Text
splitSentences = go . toList
 where
  go [] = mempty
  go (Text len t : AfterBreak _ : BreakingSpace : xs)
    | isSentenceEnding t = Text len t <> NewLine <> go xs
  go (Text len t : BreakingSpace : xs)
    | isSentenceEnding t = Text len t <> NewLine <> go xs
  go (x:xs) = x <> go xs

  toList (Concat (Concat a b) c) = toList (Concat a (Concat b c))
  toList (Concat a b) = a : toList b
  toList x = [x]

  isSentenceEnding t =
    case T.unsnoc t of
      Just (t',c)
        | c == '.' || c == '!' || c == '?'
        , not (isInitial t') -> True
        | c == ')' || c == ']' || c == '"' || c == '\x201D' ->
           case T.unsnoc t' of
             Just (t'',d) -> d == '.' || d == '!' || d == '?' &&
                             not (isInitial t'')
             _ -> False
      _ -> False
   where
    isInitial x = T.length x == 1 && T.all isUpper x

-- | Ensure that all identifiers start with a letter,
-- and modify internal links accordingly. (Yes, XML allows an
-- underscore, but HTML 4 doesn't, so we are more conservative.)
ensureValidXmlIdentifiers :: Pandoc -> Pandoc
ensureValidXmlIdentifiers = walk fixLinks . walkAttr fixIdentifiers
 where
  fixIdentifiers (ident, classes, kvs) =
    (case T.uncons ident of
      Nothing -> ident
      Just (c, _) | isLetter c -> ident
      _ -> "id_" <> ident,
     classes, kvs)
  needsFixing src =
    case T.uncons src of
      Just ('#',t) ->
        case T.uncons t of
          Just (c,_) | not (isLetter c) -> Just ("#id_" <> t)
          _ -> Nothing
      _ -> Nothing
  fixLinks (Link attr ils (src, tit))
    | Just src' <- needsFixing src = Link attr ils (src', tit)
  fixLinks (Image attr ils (src, tit))
    | Just src' <- needsFixing src = Image attr ils (src', tit)
  fixLinks x = x

-- | Walk Pandoc document, modifying attributes.
walkAttr :: (Attr -> Attr) -> Pandoc -> Pandoc
walkAttr f = walk goInline . walk goBlock
 where
  goInline (Span attr ils) = Span (f attr) ils
  goInline (Link attr ils target) = Link (f attr) ils target
  goInline (Image attr ils target) = Image (f attr) ils target
  goInline (Code attr txt) = Code (f attr) txt
  goInline x = x

  goBlock (Header lev attr ils) = Header lev (f attr) ils
  goBlock (CodeBlock attr txt) = CodeBlock (f attr) txt
  goBlock (Table attr cap colspecs thead tbodies tfoot) =
    Table (f attr) cap colspecs thead tbodies tfoot
  goBlock (Div attr bs) = Div (f attr) bs
  goBlock x = x

-- | Set translations based on the `lang` in metadata.
setupTranslations :: PandocMonad m => Meta -> m ()
setupTranslations meta = do
  let defLang = Lang "en" (Just "US") Nothing [] [] []
  lang <- case lookupMetaString "lang" meta of
            "" -> pure defLang
            s  -> fromMaybe defLang <$> toLang (Just s)
  setTranslations lang

-- True if the string would count as a Markdown ordered list marker.
isOrderedListMarker :: Text -> Bool
isOrderedListMarker xs = not (T.null xs) && (T.last xs `elem` ['.',')']) &&
              isRight (runParser (anyOrderedListMarker >> eof)
                       defaultParserState "" xs)

toTaskListItem :: MonadPlus m => [Block] -> m (Bool, [Block])
toTaskListItem (Plain (Str "☐":Space:ils):xs) = pure (False, Plain ils:xs)
toTaskListItem (Plain (Str "☒":Space:ils):xs) = pure (True, Plain ils:xs)
toTaskListItem (Para  (Str "☐":Space:ils):xs) = pure (False, Para ils:xs)
toTaskListItem (Para  (Str "☒":Space:ils):xs) = pure (True, Para ils:xs)
toTaskListItem _                              = mzero

-- | Add an opener and closer to a Doc. If the Doc begins or ends
-- with whitespace, export this outside the opener or closer.
-- This is used for formats, like Markdown, which don't allow spaces
-- after opening or before closing delimiters.
delimited :: Doc Text -> Doc Text -> Doc Text -> Doc Text
delimited opener closer content =
  mconcat initialWS <> opener <> mconcat middle <> closer <> mconcat finalWS
 where
  contents = toList content
  (initialWS, rest) = span isWS contents
  (reverseFinalWS, reverseMiddle) = span isWS (reverse rest)
  finalWS = reverse reverseFinalWS
  middle = reverse reverseMiddle
  isWS NewLine = True
  isWS CarriageReturn = True
  isWS BreakingSpace = True
  isWS BlankLines{} = True
  isWS _ = False
  toList (Concat (Concat a b) c) = toList (Concat a (Concat b c))
  toList (Concat a b) = a : toList b
  toList x = [x]
