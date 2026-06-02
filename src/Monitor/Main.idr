module Monitor.Main

import TUI.View
import TUI.MainLoop
import TUI.MainLoop.Async
import TUI.Event
import TUI.Key
import IO.Async.Loop.Posix
import IO.Async.Loop.Epoll
import System
import Data.String
import Data.List
import Data.Maybe
import Options.Applicative.Types
import Options.Applicative.Builder
import Options.Applicative.Run
import Options.Applicative.Help
import Options.Applicative.Error
import Monitor.Types
import Monitor.Provider
import Monitor.Process
import Monitor.Source
import Monitor.View
import Monitor.Handler

record AmonConfig where
  constructor MkAmonConfig
  tasksPath : String

amonParser : Parser AmonConfig
amonParser = pure MkAmonConfig
          <*> Alt (argument "TASKS_JSON" `mhelp` "Path to tasks.json definition")
                  (Pure "tasks.json")

amonHelp : HelpInfo
amonHelp = let info = collectHelpInfo "amon" amonParser in
           { header := "Ansible Monitor TUI" } info

covering
run : AmonConfig -> IO ()
run cfg = do
  ignore $ system "mkdir -p logs"
  mThreads <- getEnv "IDRIS2_ASYNC_THREADS"
  when (isNothing mThreads) $
    ignore $ setEnv "IDRIS2_ASYNC_THREADS" "1" False
  Just (config, tasks) <- loadTasks cfg.tasksPath
    | Nothing => die "Failed to load tasks: \{cfg.tasksPath}"
  let batchName = fromMaybe "Job Batch" config.batchName
  let maxWorkers : Nat
      maxWorkers = case config.maxWorkers of
                        Just n  => if n == 0 then 2 else n
                        Nothing => 2
  let entries = toJobEntries tasks
  let maxTitleLen = foldl (\acc, e => max acc (length e.task.name)) 0 entries
  let leftWidth = fromMaybe (maxTitleLen + 5) config.leftWidth
  let initState = initialState batchName leftWidth entries
  let mainLoop = asyncMain {evts = [JobUpdate, Key]}
                    [resultsSource (S (maxWorkers `minus` 1)) tasks]
  Prelude.ignore $ runView mainLoop handler initState

covering
main : IO ()
main = do
  args <- getArgs
  let args' = drop 1 args
  if elem "--help" args' || elem "-h" args'
    then putStrLn (formatHelp amonHelp)
    else case runParser amonParser args' of
           Success cfg => run cfg
           Failure err => die (renderError err)
           CompletionInvoked => pure ()