module NLZSS (decompress, getLZSS11) where

import Control.Applicative ((<$>), (<*>))
import Control.Monad (when)
import Data.Binary.Get (Get, getWord8, getWord16be, getWord32be, lookAhead,
    runGet)
import Data.Bits (Bits, (.&.), (.|.), shiftL, shiftR, testBit)
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Word (Word8)

-- Big- and little-endian 24-bit word-getters
getWord24be :: (Integral a, Bits a) => Get a
getWord24be = combine <$> getWord8' <*> getWord8' <*> getWord8'
    where
        combine a b c = (a `shiftL` 16) .|. (b `shiftL` 8) .|. c
        getWord8' = fromIntegral <$> getWord8

getWord24le :: (Integral a, Bits a) => Get a
getWord24le = combine <$> getWord8' <*> getWord8' <*> getWord8'
    where
        combine a b c = a .|. (b `shiftL` 8) .|. (c `shiftL` 16)
        getWord8' = fromIntegral <$> getWord8

-- Convenience function; decompress a ByteString via getLZSS11
decompress :: BL.ByteString -> BL.ByteString
decompress = runGet getLZSS11

-- Parse header and decompress LZSS11
getLZSS11 :: Get BL.ByteString
getLZSS11 = do
    magic <- getWord8
    when (magic /= 0x11) (error "Not LZSS11: Doesn't start with 0x11")

    finalLength <- getWord24le

    if finalLength == 0
    then return BL.empty
    else getLZSS11Bytes finalLength BL.empty 0 0

-- Recursively decompress the actual compressed part of LZSS11.  Build it up
-- backwards because sticking bytes on the beginning is more efficient, then
-- reverse the final result.
getLZSS11Bytes :: Int -> BL.ByteString -> Int -> Word8 -> Get BL.ByteString
getLZSS11Bytes finalLength soFar flagsLeft flags = do
    -- Update the flags
    (flagsLeft', flags') <-
        if flagsLeft > 1
        then return (flagsLeft - 1, flags `shiftL` 1)
        else (,) 8 <$> getWord8

    -- Depending on the next flag, either append a previously-seen string of
    -- bytes or copy one byte verbatim
    soFar' <-
        if flags' `testBit` 7
        then do
            (count, offset) <- getLZSS11BackRef
            return (applyBackref soFar count offset)
        else (`BL.cons` soFar) <$> getWord8

    -- Return our decompressed data if we're done; otherwise recurse
    case fromIntegral (BL.length soFar') `compare` finalLength of
        LT -> getLZSS11Bytes finalLength soFar' flagsLeft' flags'
        EQ -> return (BL.reverse soFar')
        GT -> error "Somehow we got too long"

-- Get a count/offset backref pair
-- We specifically get Int64s because BL.index needs offset to be one later,
-- and count is derived from the same packed integer
getLZSS11BackRef :: Get (Int64, Int64)
getLZSS11BackRef = do
    -- 4 bit control
    control <- (`shiftR` 4) <$> lookAhead getWord8

    case control of
        0 -> do
            -- 8 bit count, 12 bit offset
            countOffset <- getWord24be :: Get Int64
            let count = ((countOffset `shiftR` 12) .&. 0xFF) + 0x11
            let offset = countOffset .&. 0xFFF

            return (count, offset)
        1 -> do
            -- 16 bit count, 12 bit offset
            countOffset <- fromIntegral <$> getWord32be :: Get Int64
            let count = ((countOffset `shiftR` 12) .&. 0xFFFF) + 0x111
            let offset = countOffset .&. 0xFFF

            return (count, offset)
        n -> do
            -- 4 bit count (instead of control), 12 bit offset
            countOffset <- fromIntegral <$> getWord16be :: Get Int64
            let count = fromIntegral n + 1
            let offset = countOffset .&. 0xFFF

            return (count, offset)

-- Append `count` bytes, starting `offset` bytes before the last byte — but
-- the data we're working with is backwards, so by "append" I mean "prepend"
-- and by "before the last" I mean "after the first".
applyBackref :: BL.ByteString -> Int64 -> Int64 -> BL.ByteString
applyBackref bytes 0 _ = bytes
applyBackref bytes count offset = applyBackref bytes' (count - 1) offset
    where bytes' = (bytes `BL.index` offset) `BL.cons` bytes
