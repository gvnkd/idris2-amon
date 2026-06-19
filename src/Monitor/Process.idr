module Monitor.Process

import Protocol
import Monitor.Types
import Data.String
import Data.Maybe
import Data.Bits
import Data.Buffer
import Data.C.Array
import Data.C.Ptr
import System.Posix.File.FileDesc
import IO.Async
import IO.Async.Posix
import IO.Async.Util
import System.Posix.File
import System.Posix.Process

%foreign "C:amon_close_track,amon-idris"
prim__close_track : Int -> PrimIO Int

%foreign "C:fcntl,libc"
prim__fcntl : Int -> Int -> PrimIO Int

%foreign "C:fcntl,libc"
prim__fcntl_set : Int -> Int -> Int -> PrimIO Int

%foreign "C:open,libc"
prim__open : String -> Int -> PrimIO Int

%foreign "C:amon_cstr_write,amon-idris"
prim__cstr_write : Int -> String -> PrimIO CInt

%foreign "C:amon_cstr_timestamp,amon-idris"
prim__cstr_timestamp : PrimIO String

%foreign "C:amon_spawn_child,amon-idris"
prim__amon_spawn_child : String -> AnyPtr -> Int -> PrimIO Int

public export
record ProcInfo where
  constructor MkProcInfo
  name    : String
  fd      : Fd
  pid     : Int
  pending : String
  logPath : Maybe String

export
writeToFd : Int -> String -> IO CInt
writeToFd fd s = primIO $ prim__cstr_write fd s

export
closeLogFd : Maybe Int -> IO ()
closeLogFd Nothing = pure ()
closeLogFd (Just fd) = do
  ignore $ primIO $ prim__close_track fd
  pure ()

export
writeLogChunk : Maybe Int -> String -> IO ()
writeLogChunk Nothing _ = pure ()
writeLogChunk (Just fd) chunk = do
  _ <- writeToFd fd chunk
  pure ()

export
getCurrentTimeStr : IO String
getCurrentTimeStr = primIO prim__cstr_timestamp

export
writeLogFooter : String -> JobDisplayStatus -> IO ()
writeLogFooter logPath status = do
  ts <- getCurrentTimeStr
  let statusStr := case status of
                      SUCCESS   => "SUCCESS"
                      FAILED    => "FAILED"
                      TIMEDOUT  => "TIMEDOUT"
                      QUEUED    => "QUEUED"
                      RUNNING   => "RUNNING"
                      CANCELLED => "CANCELLED"
  let footer := "[END] " ++ ts ++ " " ++ statusStr ++ "\n"
  _ <- writeToFdAppend logPath footer
  pure ()
  where
    writeToFdAppend : String -> String -> IO CInt
    writeToFdAppend path content = do
      fd <- primIO $ prim__open path 1025
      if fd < 0
        then pure (-1)
        else do
          result <- writeToFd fd content
          ignore $ primIO $ prim__close_track fd
          pure result

export
openLogFile : Maybe String -> IO (Maybe Int)
openLogFile Nothing = pure Nothing
openLogFile (Just path) = do
  let flags := 544
  fd <- primIO $ prim__open path flags
  if fd < 0
    then pure Nothing
    else do
      header <- getCurrentTimeStr
      let headerLine := "[START] " ++ header ++ "\n"
      _ <- writeToFd fd headerLine
      pure $ Just fd

export
spawnCmd : ProcessTask -> IO (Maybe ProcInfo)
spawnCmd task = do
  let baseCmd = "timeout " ++ show task.timeout ++ "s " ++ task.path ++ " " ++ unwords task.args
  ts <- getCurrentTimeStr
  let (cmd, logPath) = case task.logFile of
                        Nothing => (baseCmd, Nothing)
                        Just lp =>
                          let header := "[START] " ++ ts ++ "\n"
                              wrapped := "{ echo '" ++ header ++ "' > " ++ lp ++ "; " ++
                                         baseCmd ++ " 2>&1 | tee -a " ++ lp ++ "; }"
                          in (wrapped, Just lp)
  fdsArr <- malloc Fd 2
  rc <- primIO $ prim__amon_spawn_child cmd (unsafeUnwrap fdsArr) 0
  if rc < 0
    then do
      free fdsArr
      pure Nothing
    else do
      Just buf <- newBuffer 8 | Nothing => do
        free fdsArr
        pure Nothing
      primIO $ prim__copy_pb (unsafeUnwrap fdsArr) buf 8
      free fdsArr
      readBits <- getBits32 buf 0
      pidBits  <- getBits32 buf 4
      let readFd  = the Int (cast readBits)
          childPid = the Int (cast pidBits)
      flags <- primIO $ prim__fcntl readFd 3
      _ <- primIO $ prim__fcntl_set readFd 4 (flags .|. 2048)
      pure $ Just $ MkProcInfo task.name (MkFd readBits) childPid "" task.logFile

export
splitOutput : String -> String -> (List String, String)
splitOutput acc new = go (unpack (acc ++ new)) []
  where
    go : List Char -> List String -> (List String, String)
    go [] lines = (reverse lines, "")
    go cs lines =
      let (before, after) = break (== '\n') cs
      in case after of
           [] => (reverse lines, pack before)
           (_ :: rest) => go rest (pack before :: lines)

isDC : Char -> Bool
isDC c = c >= '0' && c <= '9'

natOf : String -> Nat
natOf s = let n = the Integer (cast s) in if n > 0 then fromInteger n else 0

rowColOf : List Char -> (Nat, Nat)
rowColOf cs = case break (== ';') (filter (\c => isDC c || c == ';') cs) of
  (rs, [])        => (max 1 (natOf (pack rs)), 1)
  (rs, _ :: rest) => (max 1 (natOf (pack rs)), max 1 (natOf (pack rest)))

colOf : List Char -> Nat
colOf cs = max 1 (natOf (pack (filter isDC cs)))

isFinal : Char -> Bool
isFinal c = c >= '@' && c <= '~'

mutual
  stripGo : Nat -> Nat -> List Char -> List Char
  stripGo row col [] = []
  stripGo row col ('\x1b' :: '[' :: cs)       = handleCSI row col cs
  stripGo row col ('\x1b' :: ']' :: cs)       = skipOSC row col cs
  stripGo row col ('\x1b' :: '(' :: _ :: cs)  = stripGo row col cs
  stripGo row col ('\x1b' :: ')' :: _ :: cs)  = stripGo row col cs
  stripGo row col ('\x1b' :: '+' :: _ :: cs)  = stripGo row col cs
  stripGo row col ('\x1b' :: '*' :: _ :: cs)  = stripGo row col cs
  stripGo row col ('\x1b' :: _ :: cs)         = stripGo row col cs
  stripGo row col ('\r' :: cs)                = stripGo row 1 cs
  stripGo row col ('\n' :: cs)                = '\n' :: stripGo (row + 1) 1 cs
  stripGo row col (c :: cs)                   = c :: stripGo row (col + 1) cs

  handleCSI : Nat -> Nat -> List Char -> List Char
  handleCSI row col cs =
    let (params, rest) = span (not . isFinal) cs
    in case rest of
         (final :: after) =>
           if final == 'H' || final == 'f'
             then let (tRow, tCol) = rowColOf params
                      nl = if tRow /= row then '\n' :: [] else []
                      pad = replicate (minus tCol col) ' '
                  in nl ++ pad ++ stripGo tRow tCol after
             else if final == 'G'
               then let tCol = colOf params
                    in replicate (minus tCol col) ' ' ++ stripGo row tCol after
               else if final == 'd'
                 then let tRow = max 1 (natOf (pack (filter isDC params)))
                          nl = if tRow /= row then '\n' :: [] else []
                      in nl ++ stripGo tRow col after
                 else stripGo row col after
         [] => []

  skipOSC : Nat -> Nat -> List Char -> List Char
  skipOSC row col [] = []
  skipOSC row col ('\x07' :: cs) = stripGo row col cs
  skipOSC row col ('\x1b' :: '\\' :: cs) = stripGo row col cs
  skipOSC row col (_ :: cs) = skipOSC row col cs

export
stripAnsi : String -> String
stripAnsi s = pack $ stripGo 1 1 (unpack s)

mutual
  truncGo : Nat -> Nat -> List Char -> List Char
  truncGo _ _ [] = []
  truncGo 0 _ cs = takeTrailingSgr cs
  truncGo budget col ('\x1b' :: '[' :: cs) = '\x1b' :: '[' :: keepSgr budget col cs
  truncGo budget col ('\x1b' :: c :: cs)   = '\x1b' :: c :: truncGo budget col cs
  truncGo budget col (c :: cs)             = c :: truncGo (minus budget 1) (col + 1) cs

  keepSgr : Nat -> Nat -> List Char -> List Char
  keepSgr budget col cs =
    let (params, rest) = span (not . isFinal) cs
    in case rest of
         (final :: after) => params ++ (final :: truncGo budget col after)
         []               => params

  takeTrailingSgr : List Char -> List Char
  takeTrailingSgr ('\x1b' :: '[' :: cs) =
    let (params, rest) = span (not . isFinal) cs
    in case rest of
         (final :: after) => '\x1b' :: '[' :: params ++ (final :: takeTrailingSgr after)
         []               => []
  takeTrailingSgr _ = []

export
truncateAnsi : Nat -> String -> String
truncateAnsi maxW s = pack $ truncGo maxW 1 (unpack s)
