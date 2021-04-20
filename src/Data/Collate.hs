-- Copyright 2018-2021 Google LLC
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--      http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- | An Applicative Functor for extracting parts of a stream of values.
--
-- Basic usage involves building up a computation from calls to the 'sample'
-- function, then running the computation against a 'Foldable' of inputs.
-- Operationally, this makes one pass over the input in order, extracting each
-- of the values specified by calls to 'sample', then constructs the result
-- according to the Applicative structure.
--
-- Because this is written against 'ST', we can run 'Collate's purely, or
-- convert them to 'IO' as if by 'stToIO', and run them with actual I/O
-- interspersed.  This means a 'Collate' can be driven by a streaming
-- abstraction such as "conduit" or "pipes".
--
-- Finally, although 'Collate' itself doesn't admit any reasonable 'Monad'
-- implementation [1], it can be used with "free" to describe multi-pass
-- algorithms over (repeatable) streams.
--
-- [1]: To implement 'join', we'd potentially need to look over the whole
-- stream of inputs to be able to construct the inner 'Collate' and determine
-- which inputs it needs to inspect.  So, we'd need to make multiple passes.
-- If we extended the type to support multiple passes and gave it a 'Monad'
-- instance that implemented ('>>=') by making two passes, then the
-- 'Applicative' instance would also be required to make two passes for ('<*>'),
-- because of the law that @('<*>') = 'ap'@ for any 'Monad'.

{-# LANGUAGE RankNTypes #-}

module Data.Collate
         ( -- * Types
           Collate(..), Collator(..)
           -- * Constructon
         , sample, bulkSample
           -- * Elimination
         , collate, collateOf
           -- ** Lower-level elimination APIs
         , withCollator, feedCollatorOf, feedCollator
         ) where

import Control.Arrow (first)
import Control.Monad (void)
import Control.Monad.ST (ST, runST)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict
         ( StateT, get, modify, execStateT
         )
import Data.Functor.Const (Const(..))
import qualified Data.IntMap as IM
import Data.STRef (newSTRef, readSTRef, writeSTRef)

import Control.Lens
         ( Traversing', Sequenced
         , forMOf_, folded, traversed, ifoldMapOf, itraverseOf, taking
         )
import Control.Monad.Primitive (PrimMonad, PrimState, liftPrim)
import qualified Data.Vector.Mutable as V

-- | An collection of "callbacks" for extracting things from a stream of values.
--
-- This is generated by 'Collate', and holds many partially-applied
-- 'writeSTRef's, so that once they've all been called, some larger value can
-- be extracted.
newtype Collator m c = Collator
  { getCollator :: IM.IntMap (c -> ST (PrimState m) ())
  }

-- | 'Collator's can be combined by merging the contained maps.
instance Semigroup (Collator m c) where
  Collator l <> Collator r = Collator $ IM.unionWith (\x y c -> x c >> y c) l r

-- | An empty 'Collator' is just an empty map.
instance Monoid (Collator m c) where
  mempty = Collator IM.empty

-- | @Collate c a@ is a strategy for extracting an @a@ from a sequence of @c@s
-- in a single streaming pass over the input, even when lookups are specified
-- in arbitrary order.
--
-- Operationally, we build up a collection of mutable references, construct a
-- 'Collator' that describes how to fill all of them, construct an action that
-- will read the mutable references and return the ultimate result, iterate
-- over the input sequence to fill the mutable references, and finally run the
-- action to get the result.
newtype Collate c a = Collate
  { unCollate :: forall s. ST s (ST s a, Collator (ST s) c)
  }

instance Functor (Collate c) where
  fmap f (Collate go) = Collate $ fmap (first (fmap f)) go

instance Applicative (Collate c) where
  pure x = Collate $ return (return x, mempty)
  Collate goF <*> Collate goX = Collate $ do
    (mf, sf) <- goF
    (mx, sx) <- goX
    return (mf <*> mx, sf <> sx)

-- | Run a 'Collate' by providing an action in any 'PrimMonad' to drive the
-- 'Collator' it generates.
withCollator :: PrimMonad m => Collate c a -> (Collator m c -> m ()) -> m a
withCollator (Collate go) k = do
  (stA, Collator samples) <- liftPrim go
  -- Repack the Collator because 'm' might be different from 'ST (PrimState m)'.
  k (Collator samples)
  liftPrim stA

-- | Drive a 'Collator' with any 'Fold' over the input type it expects.
--
-- The 'Int' parameter is the index of the first item in the 'Fold' (so that
-- you can supply the input in multiple chunks).
feedCollatorOf
  :: forall m s c
   . PrimMonad m
  => Traversing' (->) (Const (Sequenced () (StateT Int (ST (PrimState m))))) s c
     -- ^ @Fold s c@.
  -> Int -> Collator m c -> s -> m Int
feedCollatorOf l i0 (Collator samplers) s = liftPrim $ flip execStateT i0 $
  forMOf_ (taking n l) s $ \c -> do
    i <- get
    modify (+1)
    lift $ IM.findWithDefault (const (return ())) i samplers c
 where
  n = case IM.maxViewWithKey samplers of
    Nothing          -> 0
    Just ((k, _), _) -> max 0 (k - i0 + 1)

-- | Drive a 'Collator' with any 'Foldable' containing its input type.
--
-- See 'feedCollatorOf'.
feedCollator
  :: forall m f c
   . (PrimMonad m, Foldable f)
  => Int -> Collator m c -> f c -> m Int
feedCollator = feedCollatorOf folded

-- | Run a 'Collate' on any 'Foldable'.
collate :: Foldable f => Collate c a -> f c -> a
collate = collateOf folded

-- | Run a 'Collate' on any 'Fold'.
collateOf
  :: ( forall s0
     . Traversing' (->) (Const (Sequenced () (StateT Int (ST s0)))) s c
     )
  -> Collate c a -> s -> a
collateOf l c f = runST $ withCollator c $ \m -> void $ feedCollatorOf l 0 m f

-- | Construct a primitive 'Collate' that strictly extracts the result of a
-- function from the input at the given index.
sample :: Int -> (c -> a) -> Collate c a
sample i f = Collate $ do
  ref <- newSTRef (error "sample: Internal error: unfulfilled promise")
  return
    ( readSTRef ref
    , Collator $ IM.fromList [(i, \c -> writeSTRef ref $! f c)]
    )

-- | Construct a primitive 'Collate' that strictly extracts the result of a
-- function from many different indices.
bulkSample :: Traversable t => t Int -> (c -> a) -> Collate c (t a)
bulkSample t f = Collate $ do
  -- TODO(awpr): it's possible to combine length and collator construction into
  -- one traversal of @t@, but it's annoying to do.
  vec <- V.new (length t)
  let collator = ifoldMapOf traversed
        (\ iVec iInp -> Collator $
          IM.singleton iInp (\c -> V.write vec iVec $! f c))
        t
  return (itraverseOf traversed (\i _ -> V.read vec i) t, collator)
