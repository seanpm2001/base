{-# LANGUAGE CPP, ForeignFunctionInterface, MultiParamTypeClasses #-}
import Control.Exception as C (IOException, handle)
import Network.BSD            (getHostName)
import System.CPUTime         (getCPUTime)
import System.Environment     (getArgs, getEnv, getProgName)
import System.Exit            (ExitCode (..), exitWith)
import System.Process         (system)

#if defined(mingw32_HOST_OS) || defined(__MINGW32__)
import System.Win32.Process
#else
import System.Posix.Process (getProcessID)
#endif

-- #endimport - do not remove this line!

#if defined(mingw32_HOST_OS) || defined(__MINGW32__)
foreign import stdcall unsafe "windows.h GetCurrentProcessId"
  getProcessID :: IO ProcessId
#endif

external_d_C_getCPUTime :: Cover -> ConstStore -> Curry_Prelude.C_IO Curry_Prelude.C_Int
external_d_C_getCPUTime _ _ = toCurry (getCPUTime >>= return . (`div` (10 ^ 9)))

external_d_C_getElapsedTime :: Cover -> ConstStore -> Curry_Prelude.C_IO Curry_Prelude.C_Int
external_d_C_getElapsedTime _ _ = toCurry (return 0 :: IO Int)

external_d_C_getArgs :: Cover -> ConstStore -> Curry_Prelude.C_IO (Curry_Prelude.OP_List Curry_Prelude.C_String)
external_d_C_getArgs _ _ = toCurry getArgs

external_d_C_prim_getEnviron :: Curry_Prelude.C_String -> Cover -> ConstStore
                             -> Curry_Prelude.C_IO Curry_Prelude.C_String
external_d_C_prim_getEnviron str _ _ =
  toCurry (handle handleIOException . getEnv) str
  where
  handleIOException :: IOException -> IO String
  handleIOException _ = return ""

external_d_C_getHostname :: Cover -> ConstStore -> Curry_Prelude.C_IO Curry_Prelude.C_String
external_d_C_getHostname _ _ = toCurry getHostName

external_d_C_getPID :: Cover -> ConstStore -> Curry_Prelude.C_IO Curry_Prelude.C_Int
external_d_C_getPID _ _ = toCurry $ do
  pid <- getProcessID
  return (fromIntegral pid :: Int)

external_d_C_getProgName :: Cover -> ConstStore -> Curry_Prelude.C_IO Curry_Prelude.C_String
external_d_C_getProgName _ _ = toCurry getProgName

external_d_C_prim_system :: Curry_Prelude.C_String -> Cover -> ConstStore
                         -> Curry_Prelude.C_IO Curry_Prelude.C_Int
external_d_C_prim_system str _ _ = toCurry system str

instance ConvertCurryHaskell Curry_Prelude.C_Int ExitCode where
  toCurry ExitSuccess     = toCurry (0 :: Int)
  toCurry (ExitFailure i) = toCurry i

  fromCurry j = let i = fromCurry j :: Int
                in if i == 0 then ExitSuccess else ExitFailure i

external_d_C_prim_exitWith :: Curry_Prelude.Curry a
                           => Curry_Prelude.C_Int -> Cover -> ConstStore -> Curry_Prelude.C_IO a
external_d_C_prim_exitWith c _ _ = fromIO (exitWith (fromCurry c))

external_d_C_prim_sleep :: Curry_Prelude.C_Int -> Cover -> ConstStore -> Curry_Prelude.C_IO Curry_Prelude.OP_Unit
external_d_C_prim_sleep x _ _ =
  toCurry (\i -> system ("sleep " ++ show (i :: Int)) >> return ()) x -- TODO

external_d_C_isWindows :: Cover -> ConstStore -> Curry_Prelude.C_Bool
#if defined(mingw32_HOST_OS) || defined(__MINGW32__)
external_d_C_isWindows _ _ = Curry_Prelude.C_True
#else
external_d_C_isWindows _ _ = Curry_Prelude.C_False
#endif
