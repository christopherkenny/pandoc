{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns      #-}
{- |
   Module      : Text.Pandoc.Writers.RST
   Copyright   : Copyright (C) 2006-2024 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of 'Pandoc' documents to reStructuredText.

reStructuredText:  <http://docutils.sourceforge.net/rst.html>
-}
module Text.Pandoc.Writers.RST ( writeRST, flatten ) where
import Control.Monad.State.Strict ( StateT, gets, modify, evalStateT )
import Control.Monad (zipWithM, liftM)
import Data.Char (isSpace, generalCategory, isAscii, isAlphaNum,
                  GeneralCategory(
                        ClosePunctuation, OpenPunctuation, InitialQuote,
                         FinalQuote, DashPunctuation, OtherPunctuation))
import Data.List (transpose, intersperse, foldl')
import qualified Data.List.NonEmpty as NE
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text (Text)
import qualified Text.Pandoc.Builder as B
import Text.Pandoc.Class.PandocMonad (PandocMonad, report)
import Text.Pandoc.Definition
import Text.Pandoc.ImageSize
import Text.Pandoc.Logging
import Text.Pandoc.Options
import Text.DocLayout
import Text.Pandoc.Shared
import Text.Pandoc.URI
import Text.Pandoc.Templates (renderTemplate)
import Text.Pandoc.Writers.Shared
import Text.Pandoc.Walk
import Safe (lastMay, headMay)

type Refs = [([Inline], Target)]

data WriterState =
  WriterState { stNotes       :: [[Block]]
              , stLinks       :: Refs
              , stImages      :: [([Inline], (Attr, Text, Text, Maybe Text))]
              , stHasMath     :: Bool
              , stHasRawTeX   :: Bool
              , stOptions     :: WriterOptions
              , stTopLevel    :: Bool
              , stImageId     :: Int
              }

type RST = StateT WriterState

-- | Convert Pandoc to RST.
writeRST :: PandocMonad m => WriterOptions -> Pandoc -> m Text
writeRST opts document = do
  let st = WriterState { stNotes = [], stLinks = [],
                         stImages = [], stHasMath = False,
                         stHasRawTeX = False, stOptions = opts,
                         stTopLevel = True, stImageId = 1 }
  evalStateT (pandocToRST document) st

-- | Return RST representation of document.
pandocToRST :: PandocMonad m => Pandoc -> RST m Text
pandocToRST (Pandoc meta blocks) = do
  opts <- gets stOptions
  let colwidth = if writerWrapText opts == WrapAuto
                    then Just $ writerColumns opts
                    else Nothing
  let subtit = lookupMetaInlines "subtitle" meta
  title <- titleToRST (docTitle meta) subtit
  metadata <- metaToContext opts
                blockListToRST
                (fmap chomp . inlineListToRST)
                meta
  body <- blockListToRST' True $ case writerTemplate opts of
                                      Just _  -> normalizeHeadings 1 blocks
                                      Nothing -> blocks
  notes <- gets (reverse . stNotes) >>= notesToRST
  -- note that the notes may contain refs, so we do them first
  refs <- gets (reverse . stLinks) >>= refsToRST
  pics <- gets (reverse . stImages) >>= pictRefsToRST
  hasMath <- gets stHasMath
  rawTeX <- gets stHasRawTeX
  let main = vsep [body, notes, refs, pics]
  let context = defField "body" main
              $ defField "toc" (writerTableOfContents opts)
              $ defField "toc-depth" (tshow $ writerTOCDepth opts)
              $ defField "number-sections" (writerNumberSections opts)
              $ defField "math" hasMath
              $ defField "titleblock" (render Nothing title :: Text)
              $ defField "math" hasMath
              $ defField "rawtex" rawTeX metadata
  return $ render colwidth $
    case writerTemplate opts of
       Nothing  -> main
       Just tpl -> renderTemplate tpl context
  where
    normalizeHeadings lev (Header l a i:bs) =
      Header lev a i:normalizeHeadings (lev+1) cont ++ normalizeHeadings lev bs'
      where (cont,bs') = break (headerLtEq l) bs
            headerLtEq level (Header l' _ _) = l' <= level
            headerLtEq _ _                   = False
    normalizeHeadings lev (b:bs) = b:normalizeHeadings lev bs
    normalizeHeadings _   []     = []

-- | Return RST representation of reference key table.
refsToRST :: PandocMonad m => Refs -> RST m (Doc Text)
refsToRST refs =
   vcat <$> mapM keyToRST refs

-- | Return RST representation of a reference key.
keyToRST :: PandocMonad m => ([Inline], (Text, Text)) -> RST m (Doc Text)
keyToRST (label, (src, _)) = do
  label' <- inlineListToRST label
  let label'' = if (==':') `T.any` (render Nothing label' :: Text)
                   then char '`' <> label' <> char '`'
                   else label'
  return $ nowrap $ ".. _" <> label'' <> ": " <> literal src

-- | Return RST representation of notes.
notesToRST :: PandocMonad m => [[Block]] -> RST m (Doc Text)
notesToRST notes =
   vsep <$> zipWithM noteToRST [1..] notes

-- | Return RST representation of a note.
noteToRST :: PandocMonad m => Int -> [Block] -> RST m (Doc Text)
noteToRST num note = do
  contents <- blockListToRST note
  let marker = ".. [" <> text (show num) <> "]"
  return $ nowrap $ marker $$ nest 3 contents

-- | Return RST representation of picture reference table.
pictRefsToRST :: PandocMonad m
              => [([Inline], (Attr, Text, Text, Maybe Text))]
              -> RST m (Doc Text)
pictRefsToRST refs =
   vcat <$> mapM pictToRST refs

-- | Return RST representation of a picture substitution reference.
pictToRST :: PandocMonad m
          => ([Inline], (Attr, Text, Text, Maybe Text))
          -> RST m (Doc Text)
pictToRST (label, (attr, src, _, mbtarget)) = do
  label' <- inlineListToRST label
  dims   <- imageDimsToRST attr
  let (_, cls, _) = attr
      classes = case cls of
                   []               -> empty
                   ["align-top"]    -> ":align: top"
                   ["align-middle"] -> ":align: middle"
                   ["align-bottom"] -> ":align: bottom"
                   ["align-center"] -> empty
                   ["align-right"]  -> empty
                   ["align-left"]   -> empty
                   _                -> ":class: " <> literal (T.unwords cls)
  return $ nowrap
         $ ".. |" <> label' <> "| image:: " <> literal src $$ hang 3 empty (classes $$ dims)
         $$ case mbtarget of
                 Nothing -> empty
                 Just t  -> "   :target: " <> literal t

-- | Escape special characters for RST.
escapeText :: WriterOptions -> Text -> Text
escapeText opts t =
  if T.any isSpecial t
     then T.pack . escapeString' True . T.unpack $ t
     else t -- optimization
 where
  isSmart = isEnabled Ext_smart opts
  isSpecial c = c == '\\' || c == '_' || c == '`' || c == '*' || c == '|'
                || (isSmart && (c == '-' || c == '.' || c == '"' || c == '\''))
  canFollowInlineMarkup c = c == '-' || c == '.' || c == ',' || c == ':'
                    || c == ';' || c == '!' || c == '?' || c == '\''
                    || c == '"' || c == ')' || c == ']' || c == '}'
                    || c == '>' || isSpace c
                    || (not (isAscii c) &&
                        generalCategory c `elem`
                        [OpenPunctuation, InitialQuote, FinalQuote,
                         DashPunctuation, OtherPunctuation])
  canPrecedeInlineMarkup c = c == '-' || c == ':' || c == '/' || c == '\''
                     || c == '"' || c == '<' || c == '(' || c == '['
                     || c == '{' || isSpace c
                     || (not (isAscii c) &&
                          generalCategory c `elem`
                          [ClosePunctuation, InitialQuote, FinalQuote,
                          DashPunctuation, OtherPunctuation])
  escapeString' canStart cs =
    case cs of
      [] -> []
      d:ds
        | d == '\\'
        -> '\\' : d : escapeString' False ds
      '\'':ds
        | isSmart
        -> '\\' : '\'' : escapeString' True ds
      '"':ds
        | isSmart
        -> '\\' : '"' : escapeString' True ds
      '-':'-':ds
        | isSmart
        -> '\\' : '-' : escapeString' False ('-':ds)
      '.':'.':'.':ds
        | isSmart
        -> '\\' : '.' : escapeString' False ('.':'.':ds)
      [e]
        | e == '*' || e == '_' || e == '|' || e == '`'
        -> ['\\',e]
      d:ds
        | canPrecedeInlineMarkup d
        -> d : escapeString' True ds
      e:d:ds
        | e == '*' || e == '_' || e == '|' || e == '`'
        , (not canStart && canFollowInlineMarkup d)
          || (canStart && not (isSpace d))
        -> '\\' : e : escapeString' False (d:ds)
      '_':d:ds
        | not (isAlphaNum d)
        -> '\\' : '_' : escapeString' False (d:ds)
      d:ds -> d : escapeString' False ds

titleToRST :: PandocMonad m => [Inline] -> [Inline] -> RST m (Doc Text)
titleToRST [] _ = return empty
titleToRST tit subtit = do
  title <- inlineListToRST tit
  subtitle <- inlineListToRST subtit
  return $ bordered title '=' $$ bordered subtitle '-'

bordered :: Doc Text -> Char -> Doc Text
bordered contents c =
  if len > 0
     then border $$ contents $$ border
     else empty
   where len = offset contents
         border = literal (T.replicate len $ T.singleton c)

-- | Convert Pandoc block element to RST.
blockToRST :: PandocMonad m
           => Block         -- ^ Block element
           -> RST m (Doc Text)
blockToRST (Div ("",["title"],[]) _) = return empty
  -- this is generated by the rst reader and can safely be
  -- omitted when we're generating rst
blockToRST (Div (ident,classes,_kvs) bs) = do
  contents <- blockListToRST bs
  let admonitions = ["attention","caution","danger","error","hint",
                     "important","note","tip","warning","admonition"]
  let admonition = case classes of
                        (cl:_)
                          | cl `elem` admonitions
                          -> ".. " <> literal cl <> "::"
                        cls -> ".. container::" <> space <>
                                   literal (T.unwords (filter (/= "container") cls))
  -- if contents start with block quote, we need to insert
  -- an empty comment to fix the indentation point (#10236)
  let contents' = case bs of
                    BlockQuote{}:_-> ".." $+$ contents
                    _ -> contents
  return $ blankline $$
           admonition $$
           (if T.null ident
               then blankline
               else "   :name: " <> literal ident $$ blankline) $$
           nest 3 contents' $$
           blankline
blockToRST (Plain inlines) = inlineListToRST inlines
blockToRST (Para inlines)
  | LineBreak `elem` inlines =
      linesToLineBlock $ splitBy (==LineBreak) inlines
  | otherwise = do
      contents <- inlineListToRST inlines
      return $ contents <> blankline
blockToRST (LineBlock lns) =
  linesToLineBlock lns
blockToRST (RawBlock f@(Format f') str)
  | f == "rst" = return $ literal str
  | f == "tex" = blockToRST (RawBlock (Format "latex") str)
  | otherwise  = return $ blankline <> ".. raw:: " <>
                    literal (T.toLower f') $+$
                    nest 3 (literal str) $$ blankline
blockToRST HorizontalRule =
  return $ blankline $$ "--------------" $$ blankline
blockToRST (Header level (name,classes,_) inlines) = do
  contents <- inlineListToRST inlines
  -- we calculate the id that would be used by auto_identifiers
  -- so we know whether to print an explicit identifier
  opts <- gets stOptions
  let autoId = uniqueIdent (writerExtensions opts) inlines mempty
  isTopLevel <- gets stTopLevel
  if isTopLevel
    then do
          let headerChar = if level > 5 then ' ' else "=-~^'" !! (level - 1)
          let border = literal $ T.replicate (offset contents) $ T.singleton headerChar
          let anchor | T.null name || name == autoId = empty
                     | otherwise = ".. _" <>
                                   (if T.any (==':') name ||
                                        T.take 1 name == "_"
                                       then "`" <> literal name <> "`"
                                       else literal name) <>
                                   ":" $$ blankline
          return $ nowrap $ anchor $$ contents $$ border $$ blankline
    else do
          let rub     = "rubric:: " <> contents
          let name' | T.null name    = empty
                    | otherwise      = ":name: " <> literal name
          let cls   | null classes   = empty
                    | otherwise      = ":class: " <> literal (T.unwords classes)
          return $ nowrap $ hang 3 ".. " (rub $$ name' $$ cls) $$ blankline
blockToRST (CodeBlock (_,classes,kvs) str) = do
  opts <- gets stOptions
  let startnum = maybe "" (\x -> " " <> literal x) $ lookup "startFrom" kvs
  let numberlines = if "numberLines" `elem` classes
                       then "   :number-lines:" <> startnum
                       else empty
  if "haskell" `elem` classes && "literate" `elem` classes &&
                  isEnabled Ext_literate_haskell opts
     then return $ prefixed "> " (literal str) $$ blankline
     else return $
          (case [c | c <- classes,
                     c `notElem` ["sourceCode","literate","numberLines",
                                  "number-lines","example"]] of
             []       -> "::"
             (lang:_) -> (".. code:: " <> literal lang) $$ numberlines)
          $+$ nest 3 (literal str) $$ blankline
blockToRST (BlockQuote blocks) = do
  contents <- blockListToRST blocks
  return $ nest 3 contents <> blankline
blockToRST (Table _attrs blkCapt specs thead tbody tfoot) = do
  let (caption, aligns, widths, headers, rows) =
        toLegacyTable blkCapt specs thead tbody tfoot
  caption' <- inlineListToRST caption
  let blocksToDoc opts bs = do
         oldOpts <- gets stOptions
         modify $ \st -> st{ stOptions = opts }
         result <- blockListToRST bs
         modify $ \st -> st{ stOptions = oldOpts }
         return result
  opts <- gets stOptions
  let specs' = map (\(_,width) -> (AlignDefault, width)) specs
      renderGrid = gridTable opts blocksToDoc specs' thead tbody tfoot
      isSimple = all (== 0) widths && length widths > 1
      renderSimple = do
        tbl' <- simpleTable opts blocksToDoc headers rows
        if offset tbl' > writerColumns opts
          then renderGrid
          else return tbl'
      isList = writerListTables opts
      renderList = tableToRSTList caption (map (const AlignDefault) aligns)
                    widths headers rows
      rendered
        | isList    = renderList
        | isSimple  = renderSimple
        | otherwise = renderGrid
  tbl <- rendered
  return $ blankline $$
           (if null caption || isList
               then tbl
               else (".. table:: " <> caption') $$ blankline $$ nest 3 tbl) $$
           blankline
blockToRST (BulletList items) = do
  contents <- mapM bulletListItemToRST items
  -- ensure that sublists have preceding blank line
  return $ blankline $$
           (if isTightList items then vcat else vsep) contents $$
           blankline
blockToRST (OrderedList (start, style', delim) items) = do
  let markers = if start == 1 && style' == DefaultStyle && delim == DefaultDelim
                   then replicate (length items) "#."
                   else take (length items) $ orderedListMarkers
                                              (start, style', delim)
  let maxMarkerLength = maybe 0 maximum $ NE.nonEmpty $ map T.length markers
  let markers' = map (\m -> let s = maxMarkerLength - T.length m
                            in  m <> T.replicate s " ") markers
  contents <- zipWithM orderedListItemToRST markers' items
  -- ensure that sublists have preceding blank line
  return $ blankline $$
           (if isTightList items then vcat else vsep) contents $$
           blankline
blockToRST (DefinitionList items) = do
  contents <- mapM definitionListItemToRST items
  -- ensure that sublists have preceding blank line
  return $ blankline $$ vcat contents $$ blankline

blockToRST (Figure (ident, classes, _kvs)
             (Caption _ longCapt) body) = do
  let figure attr txt (src, tit) = do
        description <- inlineListToRST txt
        capt <- blockListToRST longCapt
        dims <- imageDimsToRST attr
        let fig = "figure::" <+> literal src
            alt = if null txt
                     then if T.null tit
                              then empty
                              else ":alt:" <+> literal tit
                     else ":alt:" <+> description
            name = if T.null ident
                      then empty
                      else "name:" <+> literal ident
            (_,cls,_) = attr
            align = case cls of
                      []               -> empty
                      ["align-right"]  -> ":align: right"
                      ["align-left"]   -> ":align: left"
                      ["align-center"] -> ":align: center"
                      _ -> ":figclass: " <> literal (T.unwords cls)
        return $ hang 3 ".. " (fig $$ name $$ alt $$ align $$ dims $+$ capt)
              $$ blankline
  case body of
    [Para  [Image attr txt tgt]] -> figure attr txt tgt
    [Plain [Image attr txt tgt]] -> figure attr txt tgt
    _ -> do
      content <- blockListToRST body
      return $ blankline $$ (
        ".. container:: float" <> space <>
        literal (T.unwords (filter (/= "container") classes))) $$
        (if T.null ident
         then blankline
         else "   :name: " <> literal ident $$ blankline) $$
        nest 3 content $$
        blankline

-- | Convert bullet list item (list of blocks) to RST.
bulletListItemToRST :: PandocMonad m => [Block] -> RST m (Doc Text)
bulletListItemToRST items = do
  contents <- blockListToRST items
  -- if a list item starts with block quote, we need to insert
  -- an empty comment to fix the indentation point (#10236)
  let contents' = case items of
                    BlockQuote{}:_-> ".." $+$ contents
                    _ -> contents
  return $ hang 2 "- " contents' $$
      if null items || (endsWithPlain items && not (endsWithList items))
         then cr
         else blankline

-- | Convert ordered list item (a list of blocks) to RST.
orderedListItemToRST :: PandocMonad m
                     => Text   -- ^ marker for list item
                     -> [Block]  -- ^ list item (list of blocks)
                     -> RST m (Doc Text)
orderedListItemToRST marker items = do
  contents <- blockListToRST items
  let marker' = marker <> " "
  -- if a list item starts with block quote, we need to insert
  -- an empty comment to fix the indentation point (#10236)
  let contents' = case items of
                    BlockQuote{}:_-> ".." $+$ contents
                    _ -> contents
  return $ hang (T.length marker') (literal marker') contents' $$
      if null items || (endsWithPlain items && not (endsWithList items))
         then cr
         else blankline

endsWithList :: [Block] -> Bool
endsWithList bs = case lastMay bs of
                    Just (BulletList{}) -> True
                    Just (OrderedList{}) -> True
                    _ -> False

-- | Convert definition list item (label, list of blocks) to RST.
definitionListItemToRST :: PandocMonad m => ([Inline], [[Block]]) -> RST m (Doc Text)
definitionListItemToRST (label, defs) = do
  label' <- inlineListToRST label
  contents <- liftM vcat $ mapM blockListToRST defs
  -- if definition list starts with block quote, we need to insert
  -- an empty comment to fix the indentation point (#10236)
  let contents' = case defs of
                    (BlockQuote{}:_):_ -> ".." $+$ contents
                    _ -> contents
  return $ nowrap label' $$ nest 3 (nestle contents') $$
      if isTightList defs
         then cr
         else blankline

-- | Format a list of lines as line block.
linesToLineBlock :: PandocMonad m => [[Inline]] -> RST m (Doc Text)
linesToLineBlock inlineLines = do
  lns <- mapM inlineListToRST inlineLines
  return $
                      vcat (map (hang 2 (literal "| ")) lns) <> blankline

-- | Convert list of Pandoc block elements to RST.
blockListToRST' :: PandocMonad m
                => Bool
                -> [Block]       -- ^ List of block elements
                -> RST m (Doc Text)
blockListToRST' topLevel blocks = do
  -- insert comment between list and quoted blocks, see #4248 and #3675
  let fixBlocks (b1:b2@(BlockQuote _):bs)
        | toClose b1 = b1 : commentSep : b2 : fixBlocks bs
        where
          toClose Plain{}                  = False
          toClose Header{}                 = False
          toClose LineBlock{}              = False
          toClose HorizontalRule           = False
          toClose SimpleFigure{}           = True
          toClose Para{}                   = False
          toClose _                        = True
          commentSep  = RawBlock "rst" "..\n\n"
      fixBlocks (b:bs) = b : fixBlocks bs
      fixBlocks [] = []
  tl <- gets stTopLevel
  modify (\s->s{stTopLevel=topLevel})
  res <- vcat `fmap` mapM blockToRST (fixBlocks blocks)
  modify (\s->s{stTopLevel=tl})
  return res

blockListToRST :: PandocMonad m
               => [Block]       -- ^ List of block elements
               -> RST m (Doc Text)
blockListToRST = blockListToRST' False

{-

http://docutils.sourceforge.net/docs/ref/rst/restructuredtext.html#directives

According to the terminology used in the spec, a marker includes a
final whitespace and a block includes the directive arguments. Here
the variable names have slightly different meanings because we don't
want to finish the line with a space if there are no arguments, it
would produce rST that differs from what users expect in a way that's
not easy to detect

-}
toRSTDirective :: Doc Text -> Doc Text -> [(Doc Text, Doc Text)] -> Doc Text -> Doc Text
toRSTDirective typ args options content = marker <> spaceArgs <> cr <> block
  where marker = ".. " <> typ <> "::"
        block = nest 3 (fieldList $$
                        blankline $$
                        content $$
                        blankline)
        spaceArgs = if isEmpty args then "" else " " <> args
        -- a field list could end up being an empty doc thus being
        -- omitted by $$
        fieldList = foldl ($$) "" $ map joinField options
        -- a field body can contain multiple lines
        joinField (name, body) = ":" <> name <> ": " <> body

tableToRSTList :: PandocMonad m
             => [Inline]
             -> [Alignment]
             -> [Double]
             -> [[Block]]
             -> [[[Block]]]
             -> RST m (Doc Text)
tableToRSTList caption _ propWidths headers rows = do
  captionRST <- inlineListToRST caption
  opts       <- gets stOptions
  content    <- listTableContent toWrite
  pure $ toRSTDirective "list-table" captionRST (directiveOptions opts) content
  where directiveOptions opts = widths (writerColumns opts) propWidths <>
                                headerRows
        toWrite = if noHeaders then rows else headers:rows
        headerRows = [("header-rows", text $ show (1 :: Int)) | not noHeaders]
        widths tot pro = [("widths", showWidths tot pro) |
                          not (null propWidths || all (==0.0) propWidths)]
        noHeaders = all null headers
        -- >>> showWidths 70 [0.5, 0.5]
        -- "35 35"
        showWidths :: Int -> [Double] -> Doc Text
        showWidths tot = text . unwords . map (show . toColumns tot)
        -- toColumns converts a width expressed as a proportion of the
        -- total into a width expressed as a number of columns
        toColumns :: Int -> Double -> Int
        toColumns t p = round (p * fromIntegral t)
        listTableContent :: PandocMonad m => [[[Block]]] -> RST m (Doc Text)
        listTableContent = fmap vcat .
          mapM (fmap (hang 2 (text "* ") . vcat) . mapM bulletListItemToRST)

transformInlines :: [Inline] -> [Inline]
transformInlines =  insertBS .
                    filter hasContents .
                    removeSpaceAfterDisplayMath .
                    concatMap (transformNested . flatten)
  where -- empty inlines are not valid RST syntax
        hasContents :: Inline -> Bool
        hasContents (Str "")              = False
        hasContents (Emph [])             = False
        hasContents (Underline [])        = False
        hasContents (Strong [])           = False
        hasContents (Strikeout [])        = False
        hasContents (Superscript [])      = False
        hasContents (Subscript [])        = False
        hasContents (SmallCaps [])        = False
        hasContents (Quoted _ [])         = False
        hasContents (Cite _ [])           = False
        hasContents (Span _ [])           = False
        hasContents (Link _ [] ("", ""))  = False
        hasContents (Image _ [] ("", "")) = False
        hasContents _                     = True
        -- remove spaces after displaymath, as they screw up indentation:
        removeSpaceAfterDisplayMath (Math DisplayMath x : zs) =
              Math DisplayMath x : dropWhile (==Space) zs
        removeSpaceAfterDisplayMath (x:xs) = x : removeSpaceAfterDisplayMath xs
        removeSpaceAfterDisplayMath [] = []
        insertBS :: [Inline] -> [Inline] -- insert '\ ' where needed
        insertBS (x:y:z:zs)
          | isComplex y && surroundComplex x z =
              x : y : insertBS (z : zs)
        insertBS (x:y:zs)
          | isComplex x && not (okAfterComplex y) =
              x : RawInline "rst" "\\ " : insertBS (y : zs)
          | isComplex y && not (okBeforeComplex x) =
              x : RawInline "rst" "\\ " : insertBS (y : zs)
          | otherwise =
              x : insertBS (y : zs)
        insertBS (x:ys) = x : insertBS ys
        insertBS [] = []
        transformNested :: [Inline] -> [Inline]
        transformNested = concatMap exportLeadingTrailingSpace
        exportLeadingTrailingSpace :: Inline -> [Inline]
        exportLeadingTrailingSpace il
          | isComplex il =
             let contents = dropInlineParent il
                 headSpace = headMay contents == Just Space
                 lastSpace = lastMay contents == Just Space
              in (if headSpace then (Space:) else id) .
                 (if lastSpace then (++ [Space]) else id) $
                 [setInlineChildren il (stripLeadingTrailingSpace contents)]
          | otherwise = [il]

        surroundComplex :: Inline -> Inline -> Bool
        surroundComplex (Str s) (Str s')
          | Just (_, c)  <- T.unsnoc s
          , Just (c', _) <- T.uncons s'
          = case (c, c') of
              ('\'','\'') -> True
              ('"','"')   -> True
              ('<','>')   -> True
              ('[',']')   -> True
              ('{','}')   -> True
              _           -> False
        surroundComplex _ _ = False
        okAfterComplex :: Inline -> Bool
        okAfterComplex Space = True
        okAfterComplex SoftBreak = True
        okAfterComplex LineBreak = True
        okAfterComplex (Str (T.uncons -> Just (c,_)))
          = isSpace c || T.any (== c) "-.,:;!?\\/'\")]}>–—"
        okAfterComplex _ = False
        okBeforeComplex :: Inline -> Bool
        okBeforeComplex Space = True
        okBeforeComplex SoftBreak = True
        okBeforeComplex LineBreak = True
        okBeforeComplex (Str (T.unsnoc -> Just (_,c)))
          = isSpace c || T.any (== c) "-:/'\"<([{–—"
        okBeforeComplex _ = False
        isComplex :: Inline -> Bool
        isComplex (Emph _)        = True
        isComplex (Underline _)   = True
        isComplex (Strong _)      = True
        isComplex (SmallCaps _)   = True
        isComplex (Strikeout _)   = True
        isComplex (Superscript _) = True
        isComplex (Subscript _)   = True
        isComplex Link{}          = True
        isComplex Image{}         = True
        isComplex (Code _ _)      = True
        isComplex (Math _ _)      = True
        isComplex (Cite _ (x:_))  = isComplex x
        isComplex (Span _ (x:_))  = isComplex x
        isComplex _               = False

-- | Flattens nested inlines. Extracts nested inlines and goes through
-- them either collapsing them in the outer inline container or
-- pulling them out of it
flatten :: Inline -> [Inline]
flatten outer
  | null contents = [outer]
  | otherwise     = combineAll contents
  where contents = dropInlineParent outer
        combineAll = foldl' combine []

        combine :: [Inline] -> Inline -> [Inline]
        combine f i =
          case (outer, i) of
          -- quotes are not rendered using RST inlines, so we can keep
          -- them and they will be readable and parsable
          (Quoted _ _, _)          -> keep f i
          (_, Quoted _ _)          -> keep f i
          -- spans are not rendered using RST inlines, so we can keep them
          (Span (_,_,[]) _, _)   -> keep f i
          (_, Span (_,_,[]) _)   -> keep f i
          -- inlineToRST handles this case properly so it's safe to keep
          ( Link{}, Image{})       -> keep f i
          -- parent inlines would prevent links from being correctly
          -- parsed, in this case we prioritise the content over the
          -- style
          (_, Link{})              -> emerge f i
          -- always give priority to strong text over emphasis
          (Emph _, Strong _)       -> emerge f i
          -- drop all other nested styles
          (_, _)                   -> collapse f i

        emerge f i = f <> [i]
        keep f i = appendToLast f [i]
        collapse f i = appendToLast f $ dropInlineParent i

        appendToLast :: [Inline] -> [Inline] -> [Inline]
        appendToLast flattened toAppend =
          case NE.nonEmpty flattened of
            Nothing -> [setInlineChildren outer toAppend]
            Just xs ->
              if isOuter lastFlat
                 then NE.init xs <> [appendTo lastFlat toAppend]
                 else flattened <> [setInlineChildren outer toAppend]
               where
                lastFlat = NE.last xs
                appendTo o i = mapNested (<> i) o
                isOuter i = emptyParent i == emptyParent outer
                emptyParent i = setInlineChildren i []

mapNested :: ([Inline] -> [Inline]) -> Inline -> Inline
mapNested f i = setInlineChildren i (f (dropInlineParent i))

dropInlineParent :: Inline -> [Inline]
dropInlineParent (Link _ i _)    = i
dropInlineParent (Emph i)        = i
dropInlineParent (Underline i)   = i
dropInlineParent (Strong i)      = i
dropInlineParent (Strikeout i)   = i
dropInlineParent (Superscript i) = i
dropInlineParent (Subscript i)   = i
dropInlineParent (SmallCaps i)   = i
dropInlineParent (Cite _ i)      = i
dropInlineParent (Image _ i _)   = i
dropInlineParent (Span _ i)      = i
dropInlineParent (Quoted _ i)    = i
dropInlineParent i               = [i] -- not a parent, like Str or Space

setInlineChildren :: Inline -> [Inline] -> Inline
setInlineChildren (Link a _ t) i    = Link a i t
setInlineChildren (Emph _) i        = Emph i
setInlineChildren (Underline _) i   = Underline i
setInlineChildren (Strong _) i      = Strong i
setInlineChildren (Strikeout _) i   = Strikeout i
setInlineChildren (Superscript _) i = Superscript i
setInlineChildren (Subscript _) i   = Subscript i
setInlineChildren (SmallCaps _) i   = SmallCaps i
setInlineChildren (Quoted q _) i    = Quoted q i
setInlineChildren (Cite c _) i      = Cite c i
setInlineChildren (Image a _ t) i   = Image a i t
setInlineChildren (Span a _) i      = Span a i
setInlineChildren leaf _            = leaf

inlineListToRST :: PandocMonad m => [Inline] -> RST m (Doc Text)
inlineListToRST = writeInlines . walk transformInlines

-- | Convert list of Pandoc inline elements to RST.
writeInlines :: PandocMonad m => [Inline] -> RST m (Doc Text)
writeInlines lst =
   hcat <$> mapM inlineToRST lst

-- | Convert Pandoc inline element to RST.
inlineToRST :: PandocMonad m => Inline -> RST m (Doc Text)
inlineToRST (Span ("",["mark"],[]) ils) = do
  contents <- writeInlines ils
  return $ ":mark:`" <> contents <> "`"
inlineToRST (Span (_,_,kvs) ils) = do
  contents <- writeInlines ils
  return $
    case lookup "role" kvs of
          Just role -> ":" <> literal role <> ":`" <> contents <> "`"
          Nothing   -> contents
inlineToRST (Emph lst) = do
  contents <- writeInlines lst
  return $ "*" <> contents <> "*"
-- Underline is not supported, fall back to Emph
inlineToRST (Underline lst) =
  inlineToRST (Emph lst)
inlineToRST (Strong lst) = do
  contents <- writeInlines lst
  return $ "**" <> contents <> "**"
inlineToRST (Strikeout lst) = do
  contents <- writeInlines lst
  return $ "[STRIKEOUT:" <> contents <> "]"
inlineToRST (Superscript lst) = do
  contents <- writeInlines lst
  return $ ":sup:`" <> contents <> "`"
inlineToRST (Subscript lst) = do
  contents <- writeInlines lst
  return $ ":sub:`" <> contents <> "`"
inlineToRST (SmallCaps lst) = writeInlines lst
inlineToRST (Quoted SingleQuote lst) = do
  contents <- writeInlines lst
  opts <- gets stOptions
  if isEnabled Ext_smart opts
     then return $ "'" <> contents <> "'"
     else return $ "‘" <> contents <> "’"
inlineToRST (Quoted DoubleQuote lst) = do
  contents <- writeInlines lst
  opts <- gets stOptions
  if isEnabled Ext_smart opts
     then return $ "\"" <> contents <> "\""
     else return $ "“" <> contents <> "”"
inlineToRST (Cite _  lst) =
  writeInlines lst
inlineToRST (Code (_,["interpreted-text"],[("role",role)]) str) =
  return $ ":" <> literal role <> ":`" <> literal str <> "`"
inlineToRST (Code _ str) = do
  opts <- gets stOptions
  -- we trim the string because the delimiters must adjoin a
  -- non-space character; see #3496
  -- we use :literal: when the code contains backticks, since
  -- :literal: allows backslash-escapes; see #3974
  return $
    if T.any (== '`') str
       then ":literal:`" <> literal (escapeText opts (trim str)) <> "`"
       else "``" <> literal (trim str) <> "``"
inlineToRST (Str str) = do
  opts <- gets stOptions
  return $ literal $
    (if isEnabled Ext_smart opts
        then unsmartify opts
        else id) $ escapeText opts str
inlineToRST (Math t str) = do
  modify $ \st -> st{ stHasMath = True }
  return $ if t == InlineMath
              then ":math:`" <> literal str <> "`"
              else if T.any (== '\n') str
                   then blankline $$ ".. math::" $$
                        blankline $$ nest 3 (literal str) $$ blankline
                   else blankline $$ (".. math:: " <> literal str) $$ blankline
inlineToRST il@(RawInline f x)
  | f == "rst" = return $ literal x
  | f == "latex" || f == "tex" = do
      modify $ \st -> st{ stHasRawTeX = True }
      return $ ":raw-latex:`" <> literal x <> "`"
  | otherwise  = empty <$ report (InlineNotRendered il)
inlineToRST LineBreak = return cr -- there's no line break in RST (see Para)
inlineToRST Space = return space
inlineToRST SoftBreak = do
  wrapText <- gets $ writerWrapText . stOptions
  case wrapText of
        WrapPreserve -> return cr
        WrapAuto     -> return space
        WrapNone     -> return space
-- autolink
inlineToRST (Link _ [Str str] (src, _))
  | isURI src &&
    if "mailto:" `T.isPrefixOf` src
       then src == escapeURI ("mailto:" <> str)
       else src == escapeURI str = do
  let srcSuffix = fromMaybe src (T.stripPrefix "mailto:" src)
  return $ literal srcSuffix
inlineToRST (Link _ [Image attr alt (imgsrc,imgtit)] (src, _tit)) = do
  label <- registerImage attr alt (imgsrc,imgtit) (Just src)
  return $ "|" <> label <> "|"
inlineToRST (Link _ txt (src, tit)) = do
  useReferenceLinks <- gets $ writerReferenceLinks . stOptions
  linktext <- writeInlines $ B.toList . B.trimInlines . B.fromList $ txt
  if useReferenceLinks
    then do refs <- gets stLinks
            case lookup txt refs of
                 Just (src',tit') ->
                   if src == src' && tit == tit'
                      then return $ "`" <> linktext <> "`_"
                      else
                        return $ "`" <> linktext <> " <" <> literal src <> ">`__"
                 Nothing -> do
                   modify $ \st -> st { stLinks = (txt,(src,tit)):refs }
                   return $ "`" <> linktext <> "`_"
    else return $ "`" <> linktext <> " <" <> literal src <> ">`__"
inlineToRST (Image attr alternate (source, tit)) = do
  label <- registerImage attr alternate (source,tit) Nothing
  return $ "|" <> label <> "|"
inlineToRST (Note contents) = do
  -- add to notes in state
  notes <- gets stNotes
  modify $ \st -> st { stNotes = contents:notes }
  let ref = show $ length notes + 1
  return $ " [" <> text ref <> "]_"

registerImage :: PandocMonad m => Attr -> [Inline] -> Target -> Maybe Text -> RST m (Doc Text)
registerImage attr alt (src,tit) mbtarget = do
  pics <- gets stImages
  imgId <- gets stImageId
  let getImageName = do
        modify $ \st -> st{ stImageId = imgId + 1 }
        return [Str ("image" <> tshow imgId)]
  txt <- case lookup alt pics of
               Just (a,s,t,mbt) ->
                 if (a,s,t,mbt) == (attr,src,tit,mbtarget)
                    then return alt
                    else do
                        alt' <- getImageName
                        modify $ \st -> st { stImages =
                           (alt', (attr,src,tit, mbtarget)):stImages st }
                        return alt'
               Nothing -> do
                 alt' <- if null alt || alt == [Str ""]
                            then getImageName
                            else return alt
                 modify $ \st -> st { stImages =
                        (alt', (attr,src,tit, mbtarget)):stImages st }
                 return alt'
  inlineListToRST txt

imageDimsToRST :: PandocMonad m => Attr -> RST m (Doc Text)
imageDimsToRST attr = do
  let (ident, _, _) = attr
      name = if T.null ident
                then empty
                else ":name: " <> literal ident
      showDim dir = let cols d = ":" <> text (show dir) <> ": " <> text (show d)
                    in  case dimension dir attr of
                          Just (Percent a) ->
                            case dir of
                              Height -> empty
                              Width  -> cols (Percent a)
                          Just dim -> cols dim
                          Nothing  -> empty
  return $ cr <> name $$ showDim Width $$ showDim Height

simpleTable :: PandocMonad m
            => WriterOptions
            -> (WriterOptions -> [Block] -> m (Doc Text))
            -> [[Block]]
            -> [[[Block]]]
            -> m (Doc Text)
simpleTable opts blocksToDoc headers rows = do
  -- can't have empty cells in first column:
  let fixEmpties (d:ds) = if isEmpty d
                             then literal "\\ " : ds
                             else d : ds
      fixEmpties [] = []
  headerDocs <- if all null headers
                   then return []
                   else fixEmpties <$> mapM (blocksToDoc opts) headers
  rowDocs <- mapM (fmap fixEmpties . mapM (blocksToDoc opts)) rows
  let numChars = maybe 0 maximum . NE.nonEmpty . map offset
  let colWidths = map numChars $ transpose (headerDocs : rowDocs)
  let toRow = mconcat . intersperse (lblock 1 " ") . zipWith lblock colWidths
  let hline = nowrap $ hsep (map (\n -> literal (T.replicate n "=")) colWidths)
  let hdr = if all null headers
               then mempty
               else hline $$ toRow headerDocs
  let bdy = vcat $ map toRow rowDocs
  return $ hdr $$ hline $$ bdy $$ hline
