{-# LANGUAGE RecordWildCards #-}

module Heist.Extra.Splices.Pandoc.Render
  ( renderPandocWith,
    rpBlock,
    rpInline,
    rpBlock',
    rpInline',
    plainify,
  )
where

import qualified Data.Map.Strict as Map
import Data.Map.Syntax ((##))
import qualified Data.Text as T
import qualified Emanote.Pandoc.Markdown.Syntax.WikiLink as WL
import qualified Heist as H
import Heist.Extra (runCustomNode)
import Heist.Extra.Splices.Pandoc.Attr (concatAttr, rpAttr)
import Heist.Extra.Splices.Pandoc.Ctx
  ( RenderCtx (..),
    rewriteClass,
  )
import qualified Heist.Extra.Splices.Pandoc.TaskList as TaskList
import qualified Heist.Interpreted as HI
import Relude
import qualified Text.Pandoc.Builder as B
import Text.Pandoc.Definition (Pandoc (..))
import qualified Text.Pandoc.Walk as W
import qualified Text.XmlHtml as X

renderPandocWith :: Monad n => RenderCtx n -> Pandoc -> HI.Splice n
renderPandocWith ctx (Pandoc _meta blocks) =
  foldMapM (rpBlock ctx) blocks

rpBlock :: Monad n => RenderCtx n -> B.Block -> HI.Splice n
rpBlock ctx@RenderCtx {..} b = do
  fromMaybe (rpBlock' ctx b) $ blockSplice b

-- | Render using user override in pandoc.tpl, falling back to default HTML.
withTplTag :: Monad n => RenderCtx n -> Text -> H.Splices (HI.Splice n) -> HI.Splice n -> HI.Splice n
withTplTag RenderCtx {..} name splices default_ =
  case X.childElementTag name =<< rootNode of
    Nothing -> default_
    Just node -> runCustomNode node splices

rpBlock' :: forall n. Monad n => RenderCtx n -> B.Block -> HI.Splice n
rpBlock' ctx@RenderCtx {..} b = case b of
  B.Plain is ->
    rpInlineWithTasks ctx is
  B.Para is -> do
    let innerSplice = rpInlineWithTasks ctx is
    withTplTag ctx "Para" ("inlines" ## innerSplice) $
      one . X.Element "p" mempty <$> innerSplice
  B.LineBlock iss ->
    flip foldMapM iss $ \is ->
      foldMapM (rpInline ctx) is >> pure [X.TextNode "\n"]
  B.CodeBlock (id', mkLangClass -> classes, attrs) s -> do
    pure $
      one . X.Element "div" (rpAttr $ bAttr b) $
        one . X.Element "pre" mempty $
          one . X.Element "code" (rpAttr (id', classes, attrs)) $
            one $ X.TextNode s
  B.RawBlock (B.Format fmt) s -> do
    pure $ case fmt of
      "html" ->
        rawNode "div" s
      "video" ->
        -- HACK format. TODO: replace with ![[foo.mp4]]
        one . X.Element "video" [("autoplay", ""), ("loop", ""), ("muted", "")] $
          one . X.Element "source" [("src", T.strip s)] $
            one . X.Element "p" mempty $
              [ X.TextNode "Your browser doesn't support HTML5 video. Here is a ",
                X.Element "a" [("href", T.strip s)] $
                  one . X.TextNode $ "link to the video",
                X.TextNode " instead."
              ]
      _ ->
        one . X.Element "pre" [("class", "pandoc-raw-" <> show fmt)] $ one . X.TextNode $ s
  B.BlockQuote bs ->
    withTplTag ctx "BlockQuote" ("blocks" ## rpBlock ctx `foldMapM` bs) $
      one . X.Element "blockquote" mempty <$> foldMapM (rpBlock ctx) bs
  B.OrderedList _ bss ->
    withTplTag ctx "OrderedList" (pandocListSplices "OrderedList" bss) $ do
      fmap (one . X.Element "ol" (rpAttr $ bAttr b)) $
        flip foldMapM bss $
          fmap (one . X.Element "li" mempty) . foldMapM (rpBlock ctx)
  B.BulletList bss ->
    withTplTag ctx "BulletList" (pandocListSplices "BulletList" bss) $ do
      fmap (one . X.Element "ul" (rpAttr $ bAttr b)) $
        flip foldMapM bss $
          fmap (one . X.Element "li" mempty) . foldMapM (rpBlock ctx)
  B.DefinitionList defs ->
    withTplTag ctx "DefinitionList" (definitionListSplices defs) $
      fmap (one . X.Element "dl" mempty) $
        flip foldMapM defs $ \(term, descList) -> do
          a <- foldMapM (rpInline ctx) term
          as <-
            flip foldMapM descList $
              fmap (one . X.Element "dd" mempty) . foldMapM (rpBlock ctx)
          pure $ a <> as
  B.Header level attr is ->
    one . X.Element (headerTag level) (rpAttr $ concatAttr attr $ bAttr b)
      <$> foldMapM (rpInline ctx) is
  B.HorizontalRule ->
    -- TODO: Style in pandoc.tpl
    pure $ one $ X.Element "hr" [("class", "mb-3")] mempty
  B.Table attr _captions _colSpec (B.TableHead _ hrows) tbodys _tfoot -> do
    -- TODO: Move tailwind styles to pandoc.tpl
    let borderStyle = "border-gray-300"
        rowStyle = [("class", "border-b-2 border-t-2 " <> borderStyle)]
        cellStyle = [("class", "py-2 px-2 align-top border-r-2 border-l-2 " <> borderStyle)]
        tableAttr = ("", ["mb-3"], mempty)
    -- TODO: Apply captions, colSpec, etc.
    fmap (one . X.Element "table" (rpAttr $ concatAttr attr tableAttr)) $ do
      thead <- fmap (one . X.Element "thead" mempty) $
        flip foldMapM hrows $ \(B.Row _ cells) ->
          fmap (one . X.Element "tr" rowStyle) $
            flip foldMapM cells $ \(B.Cell _ _ _ _ blks) ->
              one . X.Element "th" cellStyle <$> foldMapM (rpBlock ctx) blks
      tbody <- fmap (one . X.Element "tbody" mempty) $
        flip foldMapM tbodys $ \(B.TableBody _ _ _ rows) ->
          flip foldMapM rows $ \(B.Row _ cells) ->
            fmap (one . X.Element "tr" rowStyle) $
              flip foldMapM cells $ \(B.Cell _ _ _ _ blks) ->
                one . X.Element "td" cellStyle <$> foldMapM (rpBlock ctx) blks
      pure $ thead <> tbody
  B.Div attr bs ->
    one . X.Element (getTag "div" attr) (rpAttr $ rewriteClass ctx attr)
      <$> foldMapM (rpBlock ctx) bs
  B.Null ->
    pure []
  where
    getTag defaultTag (_, _, Map.fromList -> attrs) =
      Map.lookup "tag" attrs & fromMaybe defaultTag
    mkLangClass classes' =
      -- Tag code block with "foo language-foo" classes, if the user specified
      -- "foo" as the language identifier. This enables external syntax
      -- highlighters to detect the language.
      --
      -- If no language is specified, use "language-none" as the language This
      -- works at least on prism.js,[1] in that - syntax highlighting is turned
      -- off all the while background styling is applied, to be consistent with
      -- code blocks with language set.
      --
      -- [1] https://github.com/PrismJS/prism/pull/2738
      fromMaybe ["language-none"] $ do
        classes <- nonEmpty classes'
        let lang = head classes
        pure $ lang : ("language-" <> lang) : tail classes

    definitionListSplices :: Monad n => [([B.Inline], [[B.Block]])] -> H.Splices (HI.Splice n)
    definitionListSplices defs = do
      "DefinitionList:Items" ## (HI.runChildrenWith . uncurry itemsSplices) `foldMapM` defs
      where
        itemsSplices :: Monad n => [B.Inline] -> [[B.Block]] -> H.Splices (HI.Splice n)
        itemsSplices term descriptions = do
          "DefinitionList:Item:Term" ## foldMapM (rpInline ctx) term
          "DefinitionList:Item:DescList" ## (HI.runChildrenWith . descListSplices) `foldMapM` descriptions
        descListSplices :: Monad n => [B.Block] -> H.Splices (HI.Splice n)
        descListSplices bs = "DefinitionList:Item:Desc" ## rpBlock ctx `foldMapM` bs

    pandocListSplices :: Text -> [[B.Block]] -> H.Splices (HI.Splice n)
    pandocListSplices tagPrefix bss =
      (tagPrefix <> ":Items") ## (HI.runChildrenWith . itemsSplices) `foldMapM` bss
      where
        itemsSplices :: [B.Block] -> H.Splices (HI.Splice n)
        itemsSplices bs = do
          (tagPrefix <> ":Item") ## foldMapM (rpBlock ctx) bs

headerTag :: HasCallStack => Int -> Text
headerTag n =
  if n >= 1 && n <= 6
    then "h" <> show n
    else error "Invalid pandoc header level"

rpInline :: Monad n => RenderCtx n -> B.Inline -> HI.Splice n
rpInline ctx@RenderCtx {..} i = do
  fromMaybe (rpInline' ctx i) $ inlineSplice i

rpInline' :: Monad n => RenderCtx n -> B.Inline -> HI.Splice n
rpInline' ctx@RenderCtx {..} i = case i of
  B.Str s ->
    pure $ one . X.TextNode $ s
  B.Emph is ->
    one . X.Element "em" mempty <$> foldMapM (rpInline ctx) is
  B.Strong is ->
    one . X.Element "strong" mempty <$> foldMapM (rpInline ctx) is
  B.Underline is ->
    one . X.Element "u" mempty <$> foldMapM (rpInline ctx) is
  B.Strikeout is ->
    one . X.Element "s" mempty <$> foldMapM (rpInline ctx) is
  B.Superscript is ->
    one . X.Element "sup" mempty <$> foldMapM (rpInline ctx) is
  B.Subscript is ->
    one . X.Element "sub" mempty <$> foldMapM (rpInline ctx) is
  B.Quoted qt is ->
    flip inQuotes qt $ foldMapM (rpInline ctx) is
  B.Code attr s ->
    pure $
      one . X.Element "code" (rpAttr $ concatAttr attr $ iAttr i) $
        one . X.TextNode $ s
  B.Space -> pure $ one . X.TextNode $ " "
  B.SoftBreak -> pure $ one . X.TextNode $ " "
  B.LineBreak ->
    pure $ one $ X.Element "br" mempty mempty
  B.RawInline (B.Format fmt) s ->
    if fmt == "html"
      then pure $ rawNode "span" s
      else
        pure $
          one . X.Element "pre" [("class", "pandoc-raw-" <> show fmt)] $
            one . X.TextNode $ s
  B.Math mathType s ->
    case mathType of
      B.InlineMath ->
        pure $
          one . X.Element "span" [("class", "math inline")] $
            one . X.TextNode $ "\\(" <> s <> "\\)"
      B.DisplayMath ->
        pure $
          one . X.Element "span" [("class", "math display")] $
            one . X.TextNode $ "$$" <> s <> "$$"
  B.Link attr is (url, tit) -> do
    let attrs =
          catMaybes [Just ("href", url), guard (not $ T.null tit) >> pure ("title", tit)]
            <> rpAttr (concatAttr attr $ iAttr i)
    one . X.Element "a" attrs <$> foldMapM (rpInline ctx) is
  B.Image attr is (url, tit) -> do
    let attrs =
          catMaybes [pure ("src", url), guard (not $ T.null tit) >> pure ("title", tit), pure ("alt", plainify is)]
            <> rpAttr (rewriteClass ctx attr)
    pure $ one . X.Element "img" attrs $ mempty
  B.Note _bs -> do
    -- Footnotes are to be handled separately; see Footenotes.hs
    pure $ one $ X.Element "sup" mempty $ one $ X.TextNode "*"
  B.Span attr is -> do
    one . X.Element "span" (rpAttr $ rewriteClass ctx attr) <$> foldMapM (rpInline ctx) is
  B.SmallCaps is ->
    foldMapM (rpInline ctx) is
  B.Cite _citations is ->
    -- TODO: What to do with _citations here?
    withTplTag ctx "Cite" ("inlines" ## rpInline ctx `foldMapM` is) $
      one . X.Element "cite" mempty <$> foldMapM (rpInline ctx) is
  where
    inQuotes :: Monad n => HI.Splice n -> B.QuoteType -> HI.Splice n
    inQuotes w = \case
      B.SingleQuote ->
        w <&> \nodes ->
          [X.TextNode "‘"] <> nodes <> [X.TextNode "’"]
      B.DoubleQuote ->
        w <&> \nodes ->
          [X.TextNode "“"] <> nodes <> [X.TextNode "”"]

-- | Like rpInline', but supports task checkbox in the given inlines.
rpInlineWithTasks :: Monad n => RenderCtx n -> [B.Inline] -> HI.Splice n
rpInlineWithTasks ctx is =
  rpTask ctx is $
    rpInline ctx `foldMapM` is

rpTask :: Monad n => RenderCtx n -> [B.Inline] -> HI.Splice n -> HI.Splice n
rpTask ctx is default_ =
  maybe default_ render (TaskList.parseTaskFromInlines is)
  where
    render (checked, taskInlines) = do
      let tag = bool "Task:Unchecked" "Task:Checked" checked
      withTplTag
        ctx
        tag
        ("inlines" ## rpInline ctx `foldMapM` taskInlines)
        default_

rawNode :: Text -> Text -> [X.Node]
rawNode wrapperTag s =
  one . X.Element wrapperTag (one ("xmlhtmlRaw", "")) $
    one . X.TextNode $ s

-- | Convert Pandoc AST inlines to raw text.
plainify :: [B.Inline] -> Text
plainify = W.query $ \case
  B.Str x -> x
  B.Code _attr x -> x
  B.Space -> " "
  B.SoftBreak -> " "
  B.LineBreak -> " "
  -- TODO: if fmt is html, we should strip the html tags
  B.RawInline _fmt s -> s
  -- Ignore "wrapper" inlines like span.
  B.Span _ _ -> ""
  -- TODO: How to wrap math stuff here?
  B.Math _mathTyp s -> s
  -- Wiki-links must be displayed using its show instance (which returns its
  -- human-readable representation)
  (WL.mkWikiLinkFromInline -> Just wl) ->
    show wl
  -- Ignore the rest of AST nodes, as they are recursively defined in terms of
  -- `Inline` which `W.query` will traverse again.
  _ -> ""
