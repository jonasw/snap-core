{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeSynonymInstances #-}

-- | Snap Framework type aliases and utilities for iteratees. Note that as a
-- convenience, this module also exports everything from @Data.Iteratee@ in the
-- @iteratee@ library.
--
-- /WARNING/: Note that all of these types are scheduled to change in the
-- @darcs@ head version of the @iteratee@ library; John Lato et al. are working
-- on a much improved iteratee formulation.

module Snap.Iteratee
  ( -- * Convenience aliases around types from @Data.Iteratee@
    Stream
  , IterV
  , Iteratee
  , Enumerator

    -- * Re-export types and functions from @Data.Iteratee@
  , module Data.Iteratee

    -- * Helper functions

    -- ** Enumerators
  , enumBS
  , enumLBS
  , enumFile

    -- ** Conversion to/from 'WrappedByteString'
  , fromWrap
  , toWrap

    -- ** Iteratee utilities
  , takeExactly
  , takeNoMoreThan
  , countBytes
  , bufferIteratee
  ) where

------------------------------------------------------------------------------
import           Control.Exception (SomeException)
import           Control.Monad
import           Control.Monad.CatchIO
import           Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import           Data.Iteratee
import qualified Data.Iteratee.Base.StreamChunk as SC
import           Data.Iteratee.WrappedByteString
import           Data.Monoid (mappend)
import           Data.Word (Word8)
import           Prelude hiding (catch,drop)
import           System.IO.Posix.MMap
import qualified Data.DList as D
------------------------------------------------------------------------------

type Stream         = StreamG WrappedByteString Word8
type IterV      m   = IterGV WrappedByteString Word8 m
type Iteratee   m   = IterateeG WrappedByteString Word8 m
type Enumerator m a = Iteratee m a -> m (Iteratee m a)


------------------------------------------------------------------------------
instance (Functor m, MonadCatchIO m) =>
         MonadCatchIO (IterateeG s el m) where
    --catch  :: Exception  e => m a -> (e -> m a) -> m a
    catch m handler = IterateeG $ \str -> do
        ee <- try $ runIter m str
        case ee of 
          (Left e)  -> runIter (handler e) str
          (Right v) -> return v

    --block :: m a -> m a        
    block m = IterateeG $ \str -> block $ runIter m str
    unblock m = IterateeG $ \str -> unblock $ runIter m str


------------------------------------------------------------------------------
-- | Wraps an 'Iteratee', counting the number of bytes consumed by it.
countBytes :: (Monad m) => Iteratee m a -> Iteratee m (a, Int)
countBytes = go 0
  where
    go !n iter = IterateeG $ f n iter

    f !n !iter ch@(Chunk ws) = do
        iterv <- runIter iter ch
        case iterv of
          Done x rest -> let !n' = n + m - len rest
                         in return $! Done (x, n') rest
          Cont i err  -> return $ Cont ((go $! n + m) i) err
      where
        m = S.length $ unWrap ws

        len (EOF _) = 0
        len (Chunk s) = S.length $ unWrap s

    f !n !iter stream = do
        iterv <- runIter iter stream
        case iterv of
          Done x rest -> return $ Done (x, n) rest
          Cont i err  -> return $ Cont (go n i) err


------------------------------------------------------------------------------
-- | Buffers an iteratee.
--
-- Our enumerators produce a lot of little strings; rather than spending all
-- our time doing kernel context switches for 4-byte write() calls, we buffer
-- the iteratee to send 8KB at a time.
bufferIteratee :: (Monad m) => Enumerator m a
bufferIteratee = return . go (D.empty,0)
  where
    blocksize = 8192

    --go :: (DList ByteString, Int) -> Iteratee m a -> Iteratee m a
    go (!dl,!n) iter = IterateeG $! f (dl,n) iter

    --f :: (DList ByteString, Int) -> Iteratee m a -> Stream -> m (IterV m a)
    f _      !iter ch@(EOF (Just _)) = runIter iter ch
    f (!dl,_) !iter ch@(EOF Nothing) = do
        iterv <- runIter iter $ Chunk big
        case iterv of
          Done x rest     -> return $ Done x rest
          Cont i (Just e) -> return $ Cont i (Just e)
          Cont i Nothing  -> runIter i ch
      where
        big = toWrap $ L.fromChunks [S.concat $ D.toList dl]
        
    f (!dl,!n) iter (Chunk ws) =
        if n' > blocksize
           then do
               iterv <- runIter iter (Chunk big)
               case iterv of
                  Done x rest     -> return $ Done x rest
                  Cont i (Just e) -> return $ Cont i (Just e)
                  Cont i Nothing  -> return $ Cont (go (D.empty,0) i) Nothing
           else return $ Cont (go (dl',n') iter) Nothing
      where
        s   = S.concat $ L.toChunks $ fromWrap ws
        m   = S.length s
        n'  = n+m
        dl' = D.snoc dl s
        big = toWrap $ L.fromChunks [S.concat $ D.toList dl']
        

------------------------------------------------------------------------------
-- | Enumerates a strict bytestring.
enumBS :: (Monad m) => ByteString -> Enumerator m a
enumBS bs = enumPure1Chunk $ WrapBS bs
{-# INLINE enumBS #-}


------------------------------------------------------------------------------
-- | Enumerates a lazy bytestring.
enumLBS :: (Monad m) => L.ByteString -> Enumerator m a
enumLBS lbs = el chunks
  where
    el [] i     = return i
    el (x:xs) i = do
        i' <- enumBS x i
        el xs i'

    chunks = L.toChunks lbs


------------------------------------------------------------------------------
-- | Converts a lazy bytestring to a wrapped bytestring.
toWrap :: L.ByteString -> WrappedByteString Word8
toWrap = WrapBS . S.concat . L.toChunks
{-# INLINE toWrap #-}


------------------------------------------------------------------------------
-- | Converts a wrapped bytestring to a lazy bytestring.
fromWrap :: WrappedByteString Word8 -> L.ByteString
fromWrap = L.fromChunks . (:[]) . unWrap
{-# INLINE fromWrap #-}


------------------------------------------------------------------------------
-- | Reads n elements from a stream and applies the given iteratee to
-- the stream of the read elements. Reads exactly n elements, and if
-- the stream is short propagates an error.
takeExactly :: (SC.StreamChunk s el, Monad m) =>
               Int ->
               EnumeratorN s el s el m a
takeExactly 0 iter = return iter
takeExactly n' iter =
    if n' < 0
      then takeExactly 0 iter
      else IterateeG (step n')
  where
  step n chk@(Chunk str)
    | SC.null str = return $ Cont (takeExactly n iter) Nothing
    | SC.length str < n = liftM (flip Cont Nothing) inner
      where inner = liftM (check (n - SC.length str)) (runIter iter chk)
  step n (Chunk str) = done (Chunk s1) (Chunk s2)
    where (s1, s2) = SC.splitAt n str
  step _n (EOF (Just e))    = return $ Cont undefined (Just e)
  step _n (EOF Nothing)     = return $ Cont undefined (Just (Err "short write"))
  check n (Done x _)        = drop n >> return (return x)
  check n (Cont x Nothing)  = takeExactly n x
  check n (Cont _ (Just e)) = drop n >> throwErr e
  done s1 s2 = liftM (flip Done s2) (runIter iter s1 >>= checkIfDone return)


------------------------------------------------------------------------------
-- | Reads up to n elements from a stream and applies the given iteratee to the
-- stream of the read elements. If more than n elements are read, propagates an
-- error.
takeNoMoreThan :: (SC.StreamChunk s el, Monad m) =>
                  Int ->
                  EnumeratorN s el s el m a
takeNoMoreThan n' iter =
    if n' < 0
      then takeNoMoreThan 0 iter
      else IterateeG (step n')
  where
    step n chk@(Chunk str)
      | SC.null str = return $ Cont (takeNoMoreThan n iter) Nothing
      | SC.length str < n = liftM (flip Cont Nothing) inner
      | otherwise = done (Chunk s1) (Chunk s2)
          where inner    = liftM (check (n - SC.length str)) (runIter iter chk)
                (s1, s2) = SC.splitAt n str

    step _n (EOF (Just e))    = return $ Cont undefined (Just e)
    step _n chk@(EOF Nothing) = do
        v  <- runIter iter chk

        case v of
          (Done x s)        -> return $ Done (return x) s
          (Cont _ (Just e)) -> return $ Cont undefined (Just e)
          (Cont _ Nothing)  -> return $ Cont (throwErr $ Err "premature EOF") Nothing

    check _ v@(Done _ _)      = return $ liftI v
    check n (Cont x Nothing)  = takeNoMoreThan n x
    check _ (Cont _ (Just e)) = throwErr e

    done _ (EOF _) = error "impossible"
    done s1 s2@(Chunk s2') = do
        v <- runIter iter s1
        case v of
          (Done x s')       -> return $ Done (return x) (s' `mappend` s2)
          (Cont _ (Just e)) -> return $ Cont undefined (Just e)
          (Cont i Nothing)  ->
              if SC.null s2'
                then return $ Cont (takeNoMoreThan 0 i) Nothing
                else return $ Cont undefined (Just $ Err "too many bytes")


------------------------------------------------------------------------------
enumFile :: FilePath -> Iteratee IO a -> IO (Iteratee IO a)
enumFile fp iter = do
    es <- (try $
           liftM WrapBS $
           unsafeMMapFile fp) :: IO (Either SomeException (WrappedByteString Word8))
    
    case es of
      (Left e)  -> return $ throwErr $ Err $ "IO error" ++ show e
      (Right s) -> liftM liftI $ runIter iter $ Chunk s
