-- | This module contains the runners that take a set of specs, evaluate their examples, and
-- report to a given handle.
--
module Test.Hspec.Runner (
  Specs
, hspec
, hspecWith
, hspecB
, toExitCode

, Summary (..)

, Config (..)
, ColorMode (..)
, Path
, defaultConfig
, configAddFilter

-- * Deprecated functions
, hspecX
, hHspec
, hHspecWithFormat
) where

import           Control.Monad (unless, (>=>), guard)
import           Control.Applicative
import           Data.Monoid
import           Data.Maybe
import           System.IO
import           System.Environment
import           System.Exit
import           System.IO.Silently (silence)

import           Test.Hspec.Util (Path, safeEvaluate)
import           Test.Hspec.Internal
import           Test.Hspec.Config
import           Test.Hspec.Formatters
import           Test.Hspec.Formatters.Internal
import           Test.Hspec.FailureReport

-- | Filter specs by given predicate.
--
-- The predicate takes a list of "describe" labels and a "requirement".
filterSpecs :: (Path -> Bool) -> [SpecTree] -> [SpecTree]
filterSpecs p = goSpecs []
  where
    goSpecs :: [String] -> [SpecTree] -> [SpecTree]
    goSpecs groups = catMaybes . map (goSpec groups)

    goSpec :: [String] -> SpecTree -> Maybe SpecTree
    goSpec groups spec = case spec of
      SpecExample requirement _ -> guard (p (groups, requirement)) >> return spec
      SpecGroup group specs     -> case goSpecs (groups ++ [group]) specs of
        [] -> Nothing
        xs -> Just (SpecGroup group xs)

-- | Evaluate and print the result of checking the specs examples.
runFormatter :: Config -> Formatter -> [SpecTree] -> FormatM ()
runFormatter c formatter specs = headerFormatter formatter >> mapM_ (go []) (zip [0..] specs)
  where
    silence_
      | configVerbose c = id
      | otherwise       = silence

    go :: [String] -> (Int, SpecTree) -> FormatM ()
    go rGroups (n, SpecGroup group xs) = do
      exampleGroupStarted formatter n (reverse rGroups) group
      mapM_ (go (group : rGroups)) (zip [0..] xs)
      exampleGroupDone formatter
    go rGroups (_, SpecExample requirement example) = do
      result <- (liftIO . safeEvaluate . silence_) (example $ configParams c)
      case result of
        Right Success -> do
          increaseSuccessCount
          exampleSucceeded formatter path
        Right (Pending reason) -> do
          increasePendingCount
          examplePending formatter path reason

        Right (Fail err) -> failed (Right err)
        Left e           -> failed (Left  e)
      where
        path = (groups, requirement)
        groups = reverse rGroups
        failed err = do
          increaseFailCount
          addFailMessage path err
          exampleFailed  formatter path err

-- | Create a document of the given specs and write it to stdout.
--
-- Exit the program with `exitFailure` if at least one example fails.
hspec :: [SpecTree] -> IO ()
hspec specs =
  getConfig >>=
  withArgs [] .             -- do not leak command-line arguments to examples
  (`hspecB_` specs) >>=
  (`unless` exitFailure)

{-# DEPRECATED hspecX "use hspec instead" #-}
hspecX :: [SpecTree] -> IO a
hspecX = hspecB >=> exitWith . toExitCode

{-# DEPRECATED hHspec "use hspecWith instead" #-}
hHspec :: Handle -> [SpecTree] -> IO Summary
hHspec h = hspecWith defaultConfig {configHandle = h}

{-# DEPRECATED hHspecWithFormat "use hspecWith instead" #-}
hHspecWithFormat :: Config -> Handle -> [SpecTree] -> IO Summary
hHspecWithFormat c h = hspecWith c {configHandle = h}

-- | Create a document of the given specs and write it to stdout.
--
-- Return `True` if all examples passed, `False` otherwise.
hspecB :: [SpecTree] -> IO Bool
hspecB = hspecB_ defaultConfig

hspecB_ :: Config -> [SpecTree] -> IO Bool
hspecB_ c = fmap success . hspecWith c
  where
    success :: Summary -> Bool
    success s = summaryFailures s == 0

-- | Run given specs.  This is similar to `hspec`, but more flexible.
hspecWith :: Config -> [SpecTree] -> IO Summary
hspecWith c_ specs = do
  -- read failure report on --re-run
  c <- if configReRun c_
    then do
      readFailureReport c_
    else do
      return c_

  let formatter = configFormatter c
      h = configHandle c

  useColor <- doesUseColor h c
  runFormatM useColor h $ do
    runFormatter c formatter (maybe id filterSpecs (configFilterPredicate c) specs)
    failedFormatter formatter
    footerFormatter formatter

    -- dump failure report
    xs <- map failureRecordPath <$> getFailMessages
    liftIO $ writeFailureReport (show xs)

    Summary <$> getTotalCount <*> getFailCount

doesUseColor :: Handle -> Config -> IO Bool
doesUseColor h c = case configColorMode c of
  ColorAuto  -> hIsTerminalDevice h
  ColorNever -> return False
  ColorAlway -> return True

toExitCode :: Bool -> ExitCode
toExitCode True  = ExitSuccess
toExitCode False = ExitFailure 1

-- | Summary of a test run.
data Summary = Summary {
  summaryExamples :: Int
, summaryFailures :: Int
} deriving (Eq, Show)

instance Monoid Summary where
  mempty = Summary 0 0
  (Summary x1 x2) `mappend` (Summary y1 y2) = Summary (x1 + y1) (x2 + y2)
