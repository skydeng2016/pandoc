{-# LANGUAGE PatternGuards #-}

{-
Copyright (C) 2017-2018 Jesse Rosenthal <jrosenthal@jhu.edu>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Writers.Powerpoint.Presentation
   Copyright   : Copyright (C) 2017-2018 Jesse Rosenthal
   License     : GNU GPL, version 2 or above

   Maintainer  : Jesse Rosenthal <jrosenthal@jhu.edu>
   Stability   : alpha
   Portability : portable

Definition of Presentation datatype, modeling a MS Powerpoint (pptx)
document, and functions for converting a Pandoc document to
Presentation.
-}

module Text.Pandoc.Writers.Powerpoint.Presentation ( documentToPresentation
                                                   , Presentation(..)
                                                   , Slide(..)
                                                   , SlideElement(..)
                                                   , Shape(..)
                                                   , Graphic(..)
                                                   , BulletType(..)
                                                   , Algnment(..)
                                                   , Paragraph(..)
                                                   , ParaElem(..)
                                                   , ParaProps(..)
                                                   , RunProps(..)
                                                   , TableProps(..)
                                                   , Strikethrough(..)
                                                   , Capitals(..)
                                                   , PicProps(..)
                                                   , URL
                                                   , TeXString(..)
                                                   ) where


import Control.Monad.Reader
import Control.Monad.State
import Data.List (intercalate)
import Data.Default
import Text.Pandoc.Definition
import Text.Pandoc.Class (PandocMonad)
import Text.Pandoc.Slides (getSlideLevel)
import qualified Text.Pandoc.Class as P
import Text.Pandoc.Options
import Text.Pandoc.Logging
import Text.Pandoc.Walk
import qualified Text.Pandoc.Shared as Shared -- so we don't overlap "Element"
import Text.Pandoc.Writers.Shared (metaValueToInlines)
import qualified Data.Map as M
import Data.Maybe (maybeToList)

data WriterEnv = WriterEnv { envMetadata :: Meta
                           , envRunProps :: RunProps
                           , envParaProps :: ParaProps
                           , envSlideLevel :: Int
                           , envOpts :: WriterOptions
                           , envSlideHasHeader :: Bool
                           , envInList :: Bool
                           , envInNoteSlide :: Bool
                           , envCurSlideId :: Int
                           -- the difference between the number at
                           -- the end of the slide file name and
                           -- the rId number
                           , envSlideIdOffset :: Int
                           }
                 deriving (Show)

instance Default WriterEnv where
  def = WriterEnv { envMetadata = mempty
                  , envRunProps = def
                  , envParaProps = def
                  , envSlideLevel = 2
                  , envOpts = def
                  , envSlideHasHeader = False
                  , envInList = False
                  , envInNoteSlide = False
                  , envCurSlideId = 1
                  , envSlideIdOffset = 1
                  }


data WriterState = WriterState { stNoteIds :: M.Map Int [Block]
                               -- associate anchors with slide id
                               , stAnchorMap :: M.Map String Int
                               } deriving (Show, Eq)

instance Default WriterState where
  def = WriterState { stNoteIds = mempty
                    , stAnchorMap= mempty
                    }

type Pres m = ReaderT WriterEnv (StateT WriterState m)

runPres :: Monad m => WriterEnv -> WriterState -> Pres m a -> m a
runPres env st p = evalStateT (runReaderT p env) st

-- GHC 7.8 will still complain about concat <$> mapM unless we specify
-- Functor. We can get rid of this when we stop supporting GHC 7.8.
concatMapM        :: (Monad m) => (a -> m [b]) -> [a] -> m [b]
concatMapM f xs   =  liftM concat (mapM f xs)

type Pixels = Integer

data Presentation = Presentation [Slide]
  deriving (Show)

data Slide = MetadataSlide { metadataSlideTitle :: [ParaElem]
                            , metadataSlideSubtitle :: [ParaElem]
                            , metadataSlideAuthors :: [[ParaElem]]
                            , metadataSlideDate :: [ParaElem]
                            }
           | TitleSlide { titleSlideHeader :: [ParaElem]}
           | ContentSlide { contentSlideHeader :: [ParaElem]
                          , contentSlideContent :: [Shape]
                          }
           | TwoColumnSlide { twoColumnSlideHeader :: [ParaElem]
                            , twoColumnSlideLeft   :: [Shape]
                            , twoColumnSlideRight  :: [Shape]
                            }
           deriving (Show, Eq)

data SlideElement = SlideElement Pixels Pixels Pixels Pixels Shape
  deriving (Show, Eq)

data Shape = Pic PicProps FilePath Text.Pandoc.Definition.Attr [ParaElem]
           | GraphicFrame [Graphic] [ParaElem]
           | TextBox [Paragraph]
  deriving (Show, Eq)

type Cell = [Paragraph]

data TableProps = TableProps { tblPrFirstRow :: Bool
                             , tblPrBandRow :: Bool
                             } deriving (Show, Eq)

data Graphic = Tbl TableProps [Cell] [[Cell]]
  deriving (Show, Eq)


data Paragraph = Paragraph { paraProps :: ParaProps
                           , paraElems  :: [ParaElem]
                           } deriving (Show, Eq)


data BulletType = Bullet
                | AutoNumbering ListAttributes
  deriving (Show, Eq)

data Algnment = AlgnLeft | AlgnRight | AlgnCenter
  deriving (Show, Eq)

data ParaProps = ParaProps { pPropMarginLeft :: Maybe Pixels
                           , pPropMarginRight :: Maybe Pixels
                           , pPropLevel :: Int
                           , pPropBullet :: Maybe BulletType
                           , pPropAlign :: Maybe Algnment
                           , pPropSpaceBefore :: Maybe Pixels
                           } deriving (Show, Eq)

instance Default ParaProps where
  def = ParaProps { pPropMarginLeft = Just 0
                  , pPropMarginRight = Just 0
                  , pPropLevel = 0
                  , pPropBullet = Nothing
                  , pPropAlign = Nothing
                  , pPropSpaceBefore = Nothing
                  }

newtype TeXString = TeXString {unTeXString :: String}
  deriving (Eq, Show)

data ParaElem = Break
              | Run RunProps String
              -- It would be more elegant to have native TeXMath
              -- Expressions here, but this allows us to use
              -- `convertmath` from T.P.Writers.Math. Will perhaps
              -- revisit in the future.
              | MathElem MathType TeXString
              deriving (Show, Eq)

data Strikethrough = NoStrike | SingleStrike | DoubleStrike
  deriving (Show, Eq)

data Capitals = NoCapitals | SmallCapitals | AllCapitals
  deriving (Show, Eq)

type URL = String

data RunProps = RunProps { rPropBold :: Bool
                         , rPropItalics :: Bool
                         , rStrikethrough :: Maybe Strikethrough
                         , rBaseline :: Maybe Int
                         , rCap :: Maybe Capitals
                         , rLink :: Maybe (URL, String)
                         , rPropCode :: Bool
                         , rPropBlockQuote :: Bool
                         , rPropForceSize :: Maybe Pixels
                         } deriving (Show, Eq)

instance Default RunProps where
  def = RunProps { rPropBold = False
                 , rPropItalics = False
                 , rStrikethrough = Nothing
                 , rBaseline = Nothing
                 , rCap = Nothing
                 , rLink = Nothing
                 , rPropCode = False
                 , rPropBlockQuote = False
                 , rPropForceSize = Nothing
                 }

data PicProps = PicProps { picPropLink :: Maybe (URL, String)
                         } deriving (Show, Eq)

instance Default PicProps where
  def = PicProps { picPropLink = Nothing
                 }

--------------------------------------------------

inlinesToParElems :: Monad m => [Inline] -> Pres m [ParaElem]
inlinesToParElems ils = concatMapM inlineToParElems ils

inlineToParElems :: Monad m => Inline -> Pres m [ParaElem]
inlineToParElems (Str s) = do
  pr <- asks envRunProps
  return [Run pr s]
inlineToParElems (Emph ils) =
  local (\r -> r{envRunProps = (envRunProps r){rPropItalics=True}}) $
  inlinesToParElems ils
inlineToParElems (Strong ils) =
  local (\r -> r{envRunProps = (envRunProps r){rPropBold=True}}) $
  inlinesToParElems ils
inlineToParElems (Strikeout ils) =
  local (\r -> r{envRunProps = (envRunProps r){rStrikethrough=Just SingleStrike}}) $
  inlinesToParElems ils
inlineToParElems (Superscript ils) =
  local (\r -> r{envRunProps = (envRunProps r){rBaseline=Just 30000}}) $
  inlinesToParElems ils
inlineToParElems (Subscript ils) =
  local (\r -> r{envRunProps = (envRunProps r){rBaseline=Just (-25000)}}) $
  inlinesToParElems ils
inlineToParElems (SmallCaps ils) =
  local (\r -> r{envRunProps = (envRunProps r){rCap = Just SmallCapitals}}) $
  inlinesToParElems ils
inlineToParElems Space = inlineToParElems (Str " ")
inlineToParElems SoftBreak = inlineToParElems (Str " ")
inlineToParElems LineBreak = return [Break]
inlineToParElems (Link _ ils (url, title)) = do
  local (\r ->r{envRunProps = (envRunProps r){rLink = Just (url, title)}}) $
    inlinesToParElems ils
inlineToParElems (Code _ str) = do
  local (\r ->r{envRunProps = (envRunProps r){rPropCode = True}}) $
    inlineToParElems $ Str str
inlineToParElems (Math mathtype str) =
  return [MathElem mathtype (TeXString str)]
inlineToParElems (Note blks) = do
  notes <- gets stNoteIds
  let maxNoteId = case M.keys notes of
        [] -> 0
        lst -> maximum lst
      curNoteId = maxNoteId + 1
  modify $ \st -> st { stNoteIds = M.insert curNoteId blks notes }
  inlineToParElems $ Superscript [Str $ show curNoteId]
inlineToParElems (Span _ ils) = concatMapM inlineToParElems ils
inlineToParElems (RawInline _ _) = return []
inlineToParElems _ = return []

isListType :: Block -> Bool
isListType (OrderedList _ _) = True
isListType (BulletList _) = True
isListType (DefinitionList _) = True
isListType _ = False

registerAnchorId :: PandocMonad m => String -> Pres m ()
registerAnchorId anchor = do
  anchorMap <- gets stAnchorMap
  slideId <- asks envCurSlideId
  unless (null anchor) $
    modify $ \st -> st {stAnchorMap = M.insert anchor slideId anchorMap}

-- Currently hardcoded, until I figure out how to make it dynamic.
blockQuoteSize :: Pixels
blockQuoteSize = 20

noteSize :: Pixels
noteSize = 18

blockToParagraphs :: PandocMonad m => Block -> Pres m [Paragraph]
blockToParagraphs (Plain ils) = do
  parElems <- inlinesToParElems ils
  pProps <- asks envParaProps
  return [Paragraph pProps parElems]
blockToParagraphs (Para ils) = do
  parElems <- inlinesToParElems ils
  pProps <- asks envParaProps
  return [Paragraph pProps parElems]
blockToParagraphs (LineBlock ilsList) = do
  parElems <- inlinesToParElems $ intercalate [LineBreak] ilsList
  pProps <- asks envParaProps
  return [Paragraph pProps parElems]
-- TODO: work out the attributes
blockToParagraphs (CodeBlock attr str) =
  local (\r -> r{envParaProps = def{pPropMarginLeft = Just 100}}) $
  blockToParagraphs $ Para [Code attr str]
-- We can't yet do incremental lists, but we should render a
-- (BlockQuote List) as a list to maintain compatibility with other
-- formats.
blockToParagraphs (BlockQuote (blk : blks)) | isListType blk = do
  ps  <- blockToParagraphs blk
  ps' <- blockToParagraphs $ BlockQuote blks
  return $ ps ++ ps'
blockToParagraphs (BlockQuote blks) =
  local (\r -> r{ envParaProps = (envParaProps r){pPropMarginLeft = Just 100}
                , envRunProps = (envRunProps r){rPropForceSize = Just blockQuoteSize}})$
  concatMapM blockToParagraphs blks
-- TODO: work out the format
blockToParagraphs (RawBlock _ _) = return []
blockToParagraphs (Header _ (ident, _, _) ils) = do
  -- Note that this function only deals with content blocks, so it
  -- will only touch headers that are above the current slide level --
  -- slides at or below the slidelevel will be taken care of by
  -- `blocksToSlide'`. We have the register anchors in both of them.
  registerAnchorId ident
  -- we set the subeader to bold
  parElems <- local (\e->e{envRunProps = (envRunProps e){rPropBold=True}}) $
              inlinesToParElems ils
  -- and give it a bit of space before it.
  return [Paragraph def{pPropSpaceBefore = Just 30} parElems]
blockToParagraphs (BulletList blksLst) = do
  pProps <- asks envParaProps
  let lvl = pPropLevel pProps
  local (\env -> env{ envInList = True
                    , envParaProps = pProps{ pPropLevel = lvl + 1
                                           , pPropBullet = Just Bullet
                                           , pPropMarginLeft = Nothing
                                           }}) $
    concatMapM multiParBullet blksLst
blockToParagraphs (OrderedList listAttr blksLst) = do
  pProps <- asks envParaProps
  let lvl = pPropLevel pProps
  local (\env -> env{ envInList = True
                    , envParaProps = pProps{ pPropLevel = lvl + 1
                                           , pPropBullet = Just (AutoNumbering listAttr)
                                           , pPropMarginLeft = Nothing
                                           }}) $
    concatMapM multiParBullet blksLst
blockToParagraphs (DefinitionList entries) = do
  let go :: PandocMonad m => ([Inline], [[Block]]) -> Pres m [Paragraph]
      go (ils, blksLst) = do
        term <-blockToParagraphs $ Para [Strong ils]
        -- For now, we'll treat each definition term as a
        -- blockquote. We can extend this further later.
        definition <- concatMapM (blockToParagraphs . BlockQuote) blksLst
        return $ term ++ definition
  concatMapM go entries
blockToParagraphs (Div (_, ("notes" : []), _) _) = return []
blockToParagraphs (Div _ blks)  = concatMapM blockToParagraphs blks
blockToParagraphs blk = do
  P.report $ BlockNotRendered blk
  return []

-- Make sure the bullet env gets turned off after the first para.
multiParBullet :: PandocMonad m => [Block] -> Pres m [Paragraph]
multiParBullet [] = return []
multiParBullet (b:bs) = do
  pProps <- asks envParaProps
  p <- blockToParagraphs b
  ps <- local (\env -> env{envParaProps = pProps{pPropBullet = Nothing}}) $
    concatMapM blockToParagraphs bs
  return $ p ++ ps

cellToParagraphs :: PandocMonad m => Alignment -> TableCell -> Pres m [Paragraph]
cellToParagraphs algn tblCell = do
  paras <- mapM (blockToParagraphs) tblCell
  let alignment = case algn of
        AlignLeft -> Just AlgnLeft
        AlignRight -> Just AlgnRight
        AlignCenter -> Just AlgnCenter
        AlignDefault -> Nothing
      paras' = map (map (\p -> p{paraProps = (paraProps p){pPropAlign = alignment}})) paras
  return $ concat paras'

rowToParagraphs :: PandocMonad m => [Alignment] -> [TableCell] -> Pres m [[Paragraph]]
rowToParagraphs algns tblCells = do
  -- We have to make sure we have the right number of alignments
  let pairs = zip (algns ++ repeat AlignDefault) tblCells
  mapM (\(a, tc) -> cellToParagraphs a tc) pairs

blockToShape :: PandocMonad m => Block -> Pres m Shape
blockToShape (Plain (il:_)) | Image attr ils (url, _) <- il =
      Pic def url attr <$> (inlinesToParElems ils)
blockToShape (Para (il:_))  | Image attr ils (url, _) <- il =
      Pic def url attr <$> (inlinesToParElems ils)
blockToShape (Plain (il:_)) | Link _ (il':_) target <- il
                            , Image attr ils (url, _) <- il' =
      Pic def{picPropLink = Just target} url attr <$> (inlinesToParElems ils)
blockToShape (Para (il:_))  | Link _ (il':_) target <- il
                            , Image attr ils (url, _) <- il' =
      Pic def{picPropLink = Just target} url attr <$> (inlinesToParElems ils)
blockToShape (Table caption algn _ hdrCells rows) = do
  caption' <- inlinesToParElems caption
  hdrCells' <- rowToParagraphs algn hdrCells
  rows' <- mapM (rowToParagraphs algn) rows
  let tblPr = if null hdrCells
              then TableProps { tblPrFirstRow = False
                              , tblPrBandRow = True
                              }
              else TableProps { tblPrFirstRow = True
                              , tblPrBandRow = True
                              }

  return $ GraphicFrame [Tbl tblPr hdrCells' rows'] caption'
blockToShape blk = do paras <- blockToParagraphs blk
                      let paras' = map (\par -> par{paraElems = combineParaElems $ paraElems par}) paras
                      return $ TextBox paras'

combineShapes :: [Shape] -> [Shape]
combineShapes [] = []
combineShapes (s : []) = [s]
combineShapes (pic@(Pic _ _ _ _) : ss) = pic : combineShapes ss
combineShapes ((TextBox []) : ss) = combineShapes ss
combineShapes (s : TextBox [] : ss) = combineShapes (s : ss)
combineShapes ((TextBox (p:ps)) : (TextBox (p':ps')) : ss) =
  combineShapes $ TextBox ((p:ps) ++ (p':ps')) : ss
combineShapes (s:ss) = s : combineShapes ss

blocksToShapes :: PandocMonad m => [Block] -> Pres m [Shape]
blocksToShapes blks = combineShapes <$> mapM blockToShape blks

isImage :: Inline -> Bool
isImage (Image _ _ _) = True
isImage (Link _ ((Image _ _ _) : _) _) = True
isImage _ = False

splitBlocks' :: Monad m => [Block] -> [[Block]] -> [Block] -> Pres m [[Block]]
splitBlocks' cur acc [] = return $ acc ++ (if null cur then [] else [cur])
splitBlocks' cur acc (HorizontalRule : blks) =
  splitBlocks' [] (acc ++ (if null cur then [] else [cur])) blks
splitBlocks' cur acc (h@(Header n _ _) : blks) = do
  slideLevel <- asks envSlideLevel
  case compare n slideLevel of
    LT -> splitBlocks' [] (acc ++ (if null cur then [] else [cur]) ++ [[h]]) blks
    EQ -> splitBlocks' [h] (acc ++ (if null cur then [] else [cur])) blks
    GT -> splitBlocks' (cur ++ [h]) acc blks
-- `blockToParagraphs` treats Plain and Para the same, so we can save
-- some code duplication by treating them the same here.
splitBlocks' cur acc ((Plain ils) : blks) = splitBlocks' cur acc ((Para ils) : blks)
splitBlocks' cur acc ((Para (il:ils)) : blks) | isImage il = do
  slideLevel <- asks envSlideLevel
  case cur of
    (Header n _ _) : [] | n == slideLevel ->
                            splitBlocks' []
                            (acc ++ [cur ++ [Para [il]]])
                            (if null ils then blks else (Para ils) : blks)
    _ -> splitBlocks' []
         (acc ++ (if null cur then [] else [cur]) ++ [[Para [il]]])
         (if null ils then blks else (Para ils) : blks)
splitBlocks' cur acc (tbl@(Table _ _ _ _ _) : blks) = do
  slideLevel <- asks envSlideLevel
  case cur of
    (Header n _ _) : [] | n == slideLevel ->
                            splitBlocks' [] (acc ++ [cur ++ [tbl]]) blks
    _ ->  splitBlocks' [] (acc ++ (if null cur then [] else [cur]) ++ [[tbl]]) blks
splitBlocks' cur acc (d@(Div (_, classes, _) _): blks) | "columns" `elem` classes =  do
  slideLevel <- asks envSlideLevel
  case cur of
    (Header n _ _) : [] | n == slideLevel ->
                            splitBlocks' [] (acc ++ [cur ++ [d]]) blks
    _ ->  splitBlocks' [] (acc ++ (if null cur then [] else [cur]) ++ [[d]]) blks
splitBlocks' cur acc (blk : blks) = splitBlocks' (cur ++ [blk]) acc blks

splitBlocks :: Monad m => [Block] -> Pres m [[Block]]
splitBlocks = splitBlocks' [] []

blocksToSlide' :: PandocMonad m => Int -> [Block] -> Pres m Slide
blocksToSlide' lvl ((Header n (ident, _, _) ils) : blks)
  | n < lvl = do
      registerAnchorId ident
      hdr <- inlinesToParElems ils
      return $ TitleSlide {titleSlideHeader = hdr}
  | n == lvl = do
      registerAnchorId ident
      hdr <- inlinesToParElems ils
      -- Now get the slide without the header, and then add the header
      -- in.
      slide <- blocksToSlide' lvl blks
      return $ case slide of
        ContentSlide _ cont          -> ContentSlide hdr cont
        TwoColumnSlide _ contL contR -> TwoColumnSlide hdr contL contR
        slide'                       -> slide'
blocksToSlide' _ (blk : blks)
  | Div (_, classes, _) divBlks <- blk
  , "columns" `elem` classes
  , (Div (_, clsL, _) blksL) : (Div (_, clsR, _) blksR) : remaining <- divBlks
  , "column" `elem` clsL, "column" `elem` clsR = do
      unless (null blks)
        (mapM (P.report . BlockNotRendered) blks >> return ())
      unless (null remaining)
        (mapM (P.report . BlockNotRendered) remaining >> return ())
      mbSplitBlksL <- splitBlocks blksL
      mbSplitBlksR <- splitBlocks blksR
      let blksL' = case mbSplitBlksL of
            bs : _ -> bs
            []     -> []
      let blksR' = case mbSplitBlksR of
            bs : _ -> bs
            []     -> []
      shapesL <- blocksToShapes blksL'
      shapesR <- blocksToShapes blksR'
      return $ TwoColumnSlide { twoColumnSlideHeader = []
                              , twoColumnSlideLeft = shapesL
                              , twoColumnSlideRight = shapesR
                              }
blocksToSlide' _ (blk : blks) = do
      inNoteSlide <- asks envInNoteSlide
      shapes <- if inNoteSlide
                then forceFontSize noteSize $ blocksToShapes (blk : blks)
                else blocksToShapes (blk : blks)
      return $ ContentSlide { contentSlideHeader = []
                            , contentSlideContent = shapes
                            }
blocksToSlide' _ [] = return $ ContentSlide { contentSlideHeader = []
                                            , contentSlideContent = []
                                            }

blocksToSlide :: PandocMonad m => [Block] -> Pres m Slide
blocksToSlide blks = do
  slideLevel <- asks envSlideLevel
  blocksToSlide' slideLevel blks

makeNoteEntry :: Int -> [Block] -> [Block]
makeNoteEntry n blks =
  let enum = Str (show n ++ ".")
  in
    case blks of
      (Para ils : blks') -> (Para $ enum : Space : ils) : blks'
      _ -> (Para [enum]) : blks

forceFontSize :: PandocMonad m => Pixels -> Pres m a -> Pres m a
forceFontSize px x = do
  rpr <- asks envRunProps
  local (\r -> r {envRunProps = rpr{rPropForceSize = Just px}}) x

-- We leave these as blocks because we will want to include them in
-- the TOC.
makeNotesSlideBlocks :: PandocMonad m => Pres m [Block]
makeNotesSlideBlocks = do
  noteIds <- gets stNoteIds
  slideLevel <- asks envSlideLevel
  meta <- asks envMetadata
  -- Get identifiers so we can give the notes section a unique ident.
  anchorSet <- M.keysSet <$> gets stAnchorMap
  if M.null noteIds
    then return []
    else do let title = case lookupMeta "notes-title" meta of
                  Just val -> metaValueToInlines val
                  Nothing  -> [Str "Notes"]
                ident = Shared.uniqueIdent title anchorSet
                hdr = Header slideLevel (ident, [], []) title
            blks <- return $
                    concatMap (\(n, bs) -> makeNoteEntry n bs) $
                    M.toList noteIds
            return $ hdr : blks

getMetaSlide :: PandocMonad m => Pres m (Maybe Slide)
getMetaSlide  = do
  meta <- asks envMetadata
  title <- inlinesToParElems $ docTitle meta
  subtitle <- inlinesToParElems $
    case lookupMeta "subtitle" meta of
      Just (MetaString s)           -> [Str s]
      Just (MetaInlines ils)        -> ils
      Just (MetaBlocks [Plain ils]) -> ils
      Just (MetaBlocks [Para ils])  -> ils
      _                             -> []
  authors <- mapM inlinesToParElems $ docAuthors meta
  date <- inlinesToParElems $ docDate meta
  if null title && null subtitle && null authors && null date
    then return Nothing
    else return $ Just $ MetadataSlide { metadataSlideTitle = title
                                       , metadataSlideSubtitle = subtitle
                                       , metadataSlideAuthors = authors
                                       , metadataSlideDate = date
                                       }
-- adapted from the markdown writer
elementToListItem :: PandocMonad m => Shared.Element -> Pres m [Block]
elementToListItem (Shared.Sec lev _nums (ident,_,_) headerText subsecs) = do
  opts <- asks envOpts
  let headerLink = if null ident
                   then walk Shared.deNote headerText
                   else [Link nullAttr (walk Shared.deNote headerText)
                          ('#':ident, "")]
  listContents <- if null subsecs || lev >= writerTOCDepth opts
                  then return []
                  else mapM elementToListItem subsecs
  return [Plain headerLink, BulletList listContents]
elementToListItem (Shared.Blk _) = return []

makeTOCSlide :: PandocMonad m => [Block] -> Pres m Slide
makeTOCSlide blks = do
  contents <- BulletList <$> mapM elementToListItem (Shared.hierarchicalize blks)
  meta <- asks envMetadata
  slideLevel <- asks envSlideLevel
  let tocTitle = case lookupMeta "toc-title" meta of
                   Just val -> metaValueToInlines val
                   Nothing  -> [Str "Table of Contents"]
      hdr = Header slideLevel nullAttr tocTitle
  sld <- blocksToSlide [hdr, contents]
  return sld

combineParaElems' :: Maybe ParaElem -> [ParaElem] -> [ParaElem]
combineParaElems' mbPElem [] = maybeToList mbPElem
combineParaElems' Nothing (pElem : pElems) =
  combineParaElems' (Just pElem) pElems
combineParaElems' (Just pElem') (pElem : pElems)
  | Run rPr' s' <- pElem'
  , Run rPr s <- pElem
  , rPr == rPr' =
    combineParaElems' (Just $ Run rPr' $ s' ++ s) pElems
  | otherwise =
    pElem' : combineParaElems' (Just pElem) pElems

combineParaElems :: [ParaElem] -> [ParaElem]
combineParaElems = combineParaElems' Nothing

blocksToPresentation :: PandocMonad m => [Block] -> Pres m Presentation
blocksToPresentation blks = do
  opts <- asks envOpts
  let metadataStartNum = 1
  metadataslides <- maybeToList <$> getMetaSlide
  let tocStartNum = metadataStartNum + length metadataslides
  -- As far as I can tell, if we want to have a variable-length toc in
  -- the future, we'll have to make it twice. Once to get the length,
  -- and a second time to include the notes slide. We can't make the
  -- notes slide before the body slides because we need to know if
  -- there are notes, and we can't make either before the toc slide,
  -- because we need to know its length to get slide numbers right.
  --
  -- For now, though, since the TOC slide is only length 1, if it
  -- exists, we'll just get the length, and then come back to make the
  -- slide later
  let tocSlidesLength = if writerTableOfContents opts then 1 else 0
  let bodyStartNum = tocStartNum + tocSlidesLength
  blksLst <- splitBlocks blks
  bodyslides <- mapM
                (\(bs, n) -> local (\st -> st{envCurSlideId = n}) (blocksToSlide bs))
                (zip blksLst [bodyStartNum..])
  let noteStartNum = bodyStartNum + length bodyslides
  notesSlideBlocks <- makeNotesSlideBlocks
  -- now we come back and make the real toc...
  tocSlides <- if writerTableOfContents opts
               then do toc <- makeTOCSlide $ blks ++ notesSlideBlocks
                       return [toc]
               else return []
  -- ... and the notes slide. We test to see if the blocks are empty,
  -- because we don't want to make an empty slide.
  notesSlides <- if null notesSlideBlocks
                 then return []
                 else do notesSlide <- local
                           (\env -> env { envCurSlideId = noteStartNum
                                        , envInNoteSlide = True
                                        })
                           (blocksToSlide $ notesSlideBlocks)
                         return [notesSlide]
  return $
    Presentation $
    metadataslides ++ tocSlides ++ bodyslides ++ notesSlides

documentToPresentation :: PandocMonad m
                       => WriterOptions
                       -> Pandoc
                       -> m Presentation
documentToPresentation opts (Pandoc meta blks) = do
  let env = def { envOpts = opts
                , envMetadata = meta
                , envSlideLevel = case writerSlideLevel opts of
                                    Just lvl -> lvl
                                    Nothing  -> getSlideLevel blks
                }
  runPres env def $ blocksToPresentation blks
