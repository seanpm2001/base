------------------------------------------------------------------------------
--- Library for pseudo-random number generation in Curry.
---
--- This library provides operations for generating pseudo-random
--- number sequences.
--- For any given seed, the sequences generated by the operations
--- in this module should be **identical** to the sequences
--- generated by the `java.util.Random package`.
---
------------------------------------------------------------------------------
--- The KiCS2 implementation is based on an algorithm taken from
--- <http://en.wikipedia.org/wiki/Random_number_generation>.
--- There is an assumption that all operations are implicitly
--- executed mod 2^32 (unsigned 32-bit integers) !!!
--- GHC computes between -2^29 and 2^29-1,  thus the sequence
--- is NOT as random as one would like.
---
---     m_w = <choose-initializer>;    /* must not be zero */
---     m_z = <choose-initializer>;    /* must not be zero */
---
---     uint get_random()
---     {
---         m_z = 36969 * (m_z & 65535) + (m_z >> 16);
---         m_w = 18000 * (m_w & 65535) + (m_w >> 16);
---         return (m_z << 16) + m_w;  /* 32-bit result */
---     }
---
------------------------------------------------------------------------------
--- The PAKCS implementation is a linear congruential pseudo-random number
--- generator described in
--- Donald E. Knuth, _The Art of Computer Programming_,
--- Volume 2: _Seminumerical Algorithms_, section 3.2.1.
---
------------------------------------------------------------------------------
--- @author Sergio Antoy (with extensions by Michael Hanus)
--- @version June 2017
--- @category algorithm
------------------------------------------------------------------------------
{-# LANGUAGE CPP #-}

module System.Random
  ( nextInt, nextIntRange, nextBoolean, getRandomSeed
  , shuffle
  ) where

import System  ( getCPUTime )
import Time

#ifdef __PAKCS__
------------------------------------------------------------------
--                       Private Operations
------------------------------------------------------------------

-- a few constants

multiplier :: Int
multiplier = 25214903917

addend     :: Int
addend     = 11

powermask  :: Int
powermask  = 48

mask       :: Int
mask       = 281474976710656  -- 2^powermask

intsize    :: Int
intsize    = 32

intspan    :: Int
intspan    = 4294967296       -- 2^intsize

intlimit   :: Int
intlimit   = 2147483648       -- 2^(intsize-1)

-- the basic sequence of random values

sequence :: Int -> [Int]
sequence seed = next : sequence next
    where next = nextseed seed

-- auxiliary private operations

nextseed :: Int -> Int
nextseed seed = (seed * multiplier + addend) `rem` mask

xor :: Int -> Int -> Int
xor x y = if (x==0) && (y==0) then 0 else lastBit + 2 * restBits
    where lastBit  = if (x `rem` 2) == (y `rem` 2) then 0 else 1
          restBits = xor (x `quot` 2) (y `quot` 2)

power :: Int -> Int -> Int
power base exp = binary 1 base exp
    where binary x b e
              = if (e == 0) then x
                else binary (x * if (e `rem` 2 == 1) then b else 1)
                            (b * b)
                            (e `quot` 2)

nextIntBits :: Int -> Int -> [Int]
nextIntBits seed bits = map adjust list
    where init = (xor seed multiplier) `rem` mask
          list = sequence init
          shift = power 2 (powermask - bits)
          adjust x = if arg > intlimit then arg - intspan
                                       else arg
              where arg = (x `quot` shift) `rem` intspan

#else

zfact :: Int
zfact = 36969

wfact :: Int
wfact = 18000

two16 :: Int
two16 = 65536

large :: Int
large = 536870911 -- 2^29 - 1

#endif

------------------------------------------------------------------
--                       Public Operations
------------------------------------------------------------------

--- Returns a sequence of pseudorandom, integer values.
---
--- @param seed - The seed of the random sequence.

nextInt :: Int -> [Int]
#ifdef __PAKCS__
nextInt seed = nextIntBits seed intsize
#else
nextInt seed =
  let ns = if seed == 0 then 1 else seed
      next2 mw mz =
          let mza = zfact * (mz `mod` two16) + (mz * two16)
              mwa = wfact * (mw `mod` two16) + (mw * two16)
              tmp = (mza `div` two16 + mwa)
              res = if tmp < 0 then tmp+large else tmp
          in res : next2 mwa mza
  in next2 ns ns
#endif

--- Returns a pseudorandom sequence of values
--- between 0 (inclusive) and the specified value (exclusive).
---
--- @param seed - The seed of the random sequence.
--- @param n - The bound on the random number to be returned.
---            Must be positive.

nextIntRange :: Int -> Int -> [Int]
#ifdef __PAKCS__
nextIntRange seed n | n>0
    = if power_of_2 n then map adjust_a seq
      else map adjust_b (filter adjust_c seq)
    where seq = nextIntBits seed (intsize - 1)
          adjust_a x = (n * x) `quot` intlimit
          adjust_b x = x `rem` n
          adjust_c x = x - (x `rem` n) + (n - 1) >= 0
          power_of_2 k = k == 2 ||
                         k > 2 && k `rem` 2 == 0 && power_of_2 (k `quot` 2)
#else
nextIntRange seed n | n>0
    = map (`mod` n) (nextInt seed)
#endif

--- Returns a pseudorandom sequence of boolean values.
---
--- @param seed - The seed of the random sequence.

nextBoolean :: Int -> [Bool]
#ifdef __PAKCS__
nextBoolean seed = map (/= 0) (nextIntBits seed 1)
#else
nextBoolean seed = map (/= 0) (nextInt seed)
#endif


--- Returns a time-dependent integer number as a seed for really random numbers.
--- Should only be used as a seed for pseudorandom number sequence
--- and not as a random number since the precision is limited to milliseconds

getRandomSeed :: IO Int
getRandomSeed =
  getClockTime >>= \time ->
  getCPUTime >>= \msecs ->
  let (CalendarTime y mo d h m s _) = toUTCTime time
#ifdef __PAKCS__
   in return ((y+mo+d+h+m*s*msecs) `rem` mask)
#else
   in return ((y+mo+d+h+m*s*(msecs+1)) `mod` two16)
#endif

--- Computes a random permutation of the given list.
---
--- @param rnd random seed
--- @param l lists to shuffle
--- @return shuffled list
---
shuffle :: Int -> [a] -> [a]
shuffle rnd xs = shuffleWithLen (nextInt rnd) (length xs) xs

shuffleWithLen :: [Int] -> Int -> [a] -> [a]
shuffleWithLen [] _ _ =
  error "Internal error in Random.shuffleWithLen"
shuffleWithLen (r:rs) len xs
  | len == 0  = []
  | otherwise = z : shuffleWithLen rs (len-1) (ys++zs)
 where
#ifdef __PAKCS__
  (ys,z:zs) = splitAt (abs r `rem` len) xs
#else
  (ys,z:zs) = splitAt (abs r `mod` len) xs
#endif

{-     Simple tests and examples

testInt = take 20 (nextInt 0)

testIntRange = take 120 (nextIntRange 0 6)

testBoolean = take 20 (nextBoolean 0)

reallyRandom = do seed <- getRandomSeed
                  putStrLn (show (take 20 (nextIntRange seed 100)))
-}
