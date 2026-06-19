module Monitor.Provider

import Protocol
import Monitor.Types
import System.File
import System.Directory
import Language.JSON
import Data.List
import Data.String

getString : List (String, JSON) -> String -> Either String String
getString pairs key =
  case lookup key pairs of
    Just (JString s) => Right s
    _               => Left "Missing or invalid string field: \{key}"

getStrings : List (String, JSON) -> String -> Either String (List String)
getStrings pairs key =
  case lookup key pairs of
    Just (JArray arr) => traverse extractString arr
    _                => Right []
  where
    extractString : JSON -> Either String String
    extractString (JString s) = Right s
    extractString _          = Left "Expected string in array"

getInt : List (String, JSON) -> String -> Either String Int
getInt pairs key =
  case lookup key pairs of
    Just (JNumber n) => Right (cast n)
    _               => Left "Missing or invalid number field: \{key}"

getMaybeString : List (String, JSON) -> String -> Maybe String
getMaybeString pairs key =
  case lookup key pairs of
    Just (JString s) => Just s
    _               => Nothing

getMaybeBool : List (String, JSON) -> String -> Maybe Bool
getMaybeBool pairs key =
  case lookup key pairs of
    Just (JBoolean b) => Just b
    _                => Nothing

getEnvVarsFromJSON : List (String, JSON) -> String -> List (String, String)
getEnvVarsFromJSON pairs key =
  case lookup key pairs of
    Just (JObject envPairs) => map (\(k, v) => (k, extract v)) envPairs
    _                      => []
  where
    extract : JSON -> String
    extract (JString s) = s
    extract _          = ""

parseJobParams : List (String, JSON) -> String -> Maybe String -> Either String ProcessTask
parseJobParams pairs name batchName =
  do
    path       <- getString pairs "path"
    args       <- getStrings pairs "args"
    timeout    <- getInt pairs "timeout"
    let logFile    = getMaybeString pairs "logFile"
    let blockingIO = getMaybeBool pairs "blockingIO"
    let envVars    = getEnvVarsFromJSON pairs "envVars"
    pure $ MKProcessTask name batchName path args timeout logFile blockingIO envVars

parseBatch : String -> List (String, JSON) -> Either String (List ProcessTask)
parseBatch batchName jobPairs =
  let cmp : (String, JSON) -> (String, JSON) -> Ordering
      cmp p1 p2 = compare (fst p1) (fst p2)
   in traverse (\(jobName, jobJSON) =>
        case jobJSON of
          JObject pairs => parseJobParams pairs jobName (Just batchName)
          _            => Left "Job '\{jobName}' must be an object") (sortBy cmp jobPairs)

parseTaskConfig : List (String, JSON) -> TaskConfig
parseTaskConfig pairs =
  MkTaskConfig (getMaybeString pairs "batchName")
               (getMaybeNat pairs "maxWorkers")
               (getMaybeNat pairs "leftWidth")
  where
    getMaybeNat : List (String, JSON) -> String -> Maybe Nat
    getMaybeNat ps k =
      case lookup k ps of
        Just (JNumber n) => Just (cast {to = Nat} n)
        _               => Nothing

parseTaskFile : JSON -> Either String (TaskConfig, List ProcessTask)
parseTaskFile (JObject topPairs) =
  let config = case lookup "config" topPairs of
                 Just (JObject configPairs) => parseTaskConfig configPairs
                 _                          => MkTaskConfig Nothing Nothing Nothing
      batchPairs = filter (\(k, _) => k /= "config") topPairs
  in case traverse (\(batchName, batchJSON) =>
       case batchJSON of
         JObject jobPairs => parseBatch batchName jobPairs
         _               => Left "Batch '\{batchName}' must be an object") batchPairs of
       Left err       => Left err
       Right tasksLists => Right (config, concat tasksLists)
parseTaskFile _ =
  Left "Root must be a JSON object"

parentDir : String -> String
parentDir path =
  case break (== '/') (reverse (unpack path)) of
    (_, [])       => "."
    (_, ['/'])    => "/"
    (_, slashAndAfter) => pack (reverse (drop 1 slashAndAfter))

dirExists : String -> IO Bool
dirExists path = do
  res <- openDir path
  case res of
    Right d => do closeDir d; pure True
    Left _  => pure False

resolvePath : String -> String -> String
resolvePath baseDir path =
  case unpack path of
    '/' :: _ => path
    _        => baseDir ++ "/" ++ path

validateLogDirs : String -> List ProcessTask -> IO (Maybe String, List ProcessTask)
validateLogDirs baseDir tasks = do
  (errs, resolved) <- checkAll tasks [] []
  case errs of
    [] => pure (Nothing, resolved)
    _  => pure (Just (unlines (nub errs)), [])
  where
    resolveLogFile : ProcessTask -> ProcessTask
    resolveLogFile t =
      case t.logFile of
        Nothing => t
        Just path => { logFile := Just (resolvePath baseDir path) } t

    checkAll : List ProcessTask -> List String -> List ProcessTask -> IO (List String, List ProcessTask)
    checkAll [] acc errs = pure (reverse acc, reverse errs)
    checkAll (t :: ts) acc resolved =
      let t' = resolveLogFile t
      in case t'.logFile of
        Nothing => checkAll ts acc (t' :: resolved)
        Just path => do
          let dir = parentDir path
          ok <- dirExists dir
          if ok
            then checkAll ts acc (t' :: resolved)
            else checkAll ts ("Log directory does not exist: \{dir} (for task '\{t'.name}', logFile: \{path})" :: acc) resolved

public export
covering
loadTasks : String -> IO (Maybe (TaskConfig, List ProcessTask))
loadTasks filename = do
  res <- readFile filename
  case res of
    Left err => do
      putStrLn "Error: Config file '\{filename}' not found (\{show err})"
      pure Nothing
    Right content =>
      case Language.JSON.parse content of
        Nothing => do
          putStrLn "Error: Invalid JSON in '\{filename}'"
          pure Nothing
        Just json =>
          case parseTaskFile json of
            Left err => do
              putStrLn "Error: Failed to parse '\{filename}': \{err}"
              pure Nothing
            Right (config, tasks) => do
              let baseDir = parentDir filename
              (mErr, resolvedTasks) <- validateLogDirs baseDir tasks
              case mErr of
                Just err => do
                  putStrLn "Error: \{err}"
                  pure Nothing
                Nothing => pure (Just (config, resolvedTasks))

public export
toJobEntries : List ProcessTask -> List JobEntry
toJobEntries = map (\t => MkJobEntry t QUEUED)
