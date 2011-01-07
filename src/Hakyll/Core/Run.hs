-- | This is the module which binds it all together
--
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Hakyll.Core.Run where

import Control.Applicative
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans
import Control.Arrow ((&&&))
import Control.Monad (foldM, forM_, forM, filterM)
import Data.Map (Map)
import qualified Data.Map as M
import Data.Monoid (mempty)
import Data.Typeable (Typeable)
import Data.Binary (Binary)
import System.FilePath ((</>))
import Control.Applicative ((<$>))
import Data.Set (Set)
import qualified Data.Set as S

import Hakyll.Core.Route
import Hakyll.Core.Identifier
import Hakyll.Core.Util.File
import Hakyll.Core.Compiler
import Hakyll.Core.Compiler.Internal
import Hakyll.Core.ResourceProvider
import Hakyll.Core.ResourceProvider.FileResourceProvider
import Hakyll.Core.Rules
import Hakyll.Core.DirectedGraph
import Hakyll.Core.DirectedGraph.Dot
import Hakyll.Core.DirectedGraph.DependencySolver
import Hakyll.Core.DirectedGraph.ObsoleteFilter
import Hakyll.Core.Writable
import Hakyll.Core.Store
import Hakyll.Core.CompiledItem

hakyll :: Rules -> IO ()
hakyll rules = do
    store <- makeStore "_store"
    provider <- fileResourceProvider
    evalStateT
        (runReaderT
            (unHakyll (hakyllWith rules provider store)) undefined) undefined

data HakyllState = HakyllState
    { hakyllCompilers :: [(Identifier, Compiler () CompileRule)]
    }

data HakyllEnvironment = HakyllEnvironment
    { hakyllRoute            :: Route
    , hakyllResourceProvider :: ResourceProvider
    , hakyllStore            :: Store
    }

newtype Hakyll a = Hakyll
    { unHakyll :: ReaderT HakyllEnvironment (StateT HakyllState IO) a
    } deriving (Functor, Applicative, Monad)

hakyllWith :: Rules -> ResourceProvider -> Store -> Hakyll ()
hakyllWith rules provider store = Hakyll $ do
    let -- Get the rule set
        ruleSet = runRules rules provider

        -- Get all identifiers and compilers
        compilers = rulesCompilers ruleSet

        -- Get all dependencies
        dependencies = flip map compilers $ \(id', compiler) ->
            let deps = runCompilerDependencies compiler provider
            in (id', deps)

        -- Create a compiler map
        compilerMap = M.fromList compilers

        -- Create the graph
        graph = fromList dependencies

    liftIO $ do
        putStrLn "Writing dependency graph to dependencies.dot..."
        writeDot "dependencies.dot" show graph

    -- Check which items are up-to-date
    modified' <- liftIO $ modified provider store $ map fst compilers

    let -- Try to reduce the graph
        reducedGraph = filterObsolete modified' graph

    liftIO $ do
        putStrLn "Writing reduced graph to reduced.dot..."
        writeDot "reduced.dot" show reducedGraph

    let -- Solve the graph
        ordered = solveDependencies reducedGraph

        -- Join the order with the compilers again
        orderedCompilers = map (id &&& (compilerMap M.!)) ordered

        -- Fetch the routes
        route' = rulesRoute ruleSet

    -- Generate all the targets in order
    _ <- mapM (addTarget route' modified') orderedCompilers

    liftIO $ putStrLn "DONE."
  where
    addTarget route' modified' (id', comp) = do
        let url = runRoute route' id'
        
        -- Check if the resource was modified
        let isModified = id' `S.member` modified'

        -- Run the compiler
        ItemRule compiled <- liftIO $
            runCompiler comp id' provider url store isModified
        liftIO $ putStrLn $ "Generated target: " ++ show id'

        case url of
            Nothing -> return ()
            Just r  -> liftIO $ do
                putStrLn $ "Routing " ++ show id' ++ " to " ++ r
                let path = "_site" </> r
                makeDirectories path
                write path compiled

        liftIO $ putStrLn ""

-- | Return a set of modified identifiers
--
modified :: ResourceProvider     -- ^ Resource provider
         -> Store                -- ^ Store
         -> [Identifier]         -- ^ Identifiers to check
         -> IO (Set Identifier)  -- ^ Modified resources
modified provider store ids = fmap S.fromList $ flip filterM ids $ \id' ->
    if resourceExists provider id' then resourceModified provider id' store
                                   else return False
