%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
%%
%% Targets:
%% test - run common test suites in ./test
%% int_test - run suites in ./int_test
%% perf_test - run suites inm ./perf_test
%%
%% Global options:
%% verbose=1 - show output from the common_test run as it goes
%% suites="foo,bar" - run <test>/foo_SUITE and <test>/bar_SUITE
%% case="mycase" - run individual test case foo_SUITE:mycase
%% -------------------------------------------------------------------
-module(rebar_ct).

-export([ct/2]).

-include("rebar.hrl").

%% ===================================================================
%% Public API
%% ===================================================================

ct(Config, File) ->
    TestDir = rebar_config:get_local(Config, ct_dir, "test"),
    LogDir = rebar_config:get_local(Config, ct_log_dir, "logs"),
    run_test_if_present(TestDir, LogDir, Config, File).

%% ===================================================================
%% Internal functions
%% ===================================================================
run_test_if_present(TestDir, LogDir, Config, File) ->
    case filelib:is_dir(TestDir) of
        false ->
            ?WARN("~s directory not present - skipping\n", [TestDir]),
            ok;
        true ->
            ?DEBUG("Looking for Common Test suites in ~s...\n", [TestDir]),
            case filelib:wildcard(TestDir ++ "/*_SUITE.{beam,erl}") of
                [] ->
                    ?WARN("~s directory present, but no common_test"
                          ++ " SUITES - skipping\n", [TestDir]),
                    ok;
                _ ->
                    ?DEBUG("Found some!\n", []),
                    try
                        run_test(TestDir, LogDir, Config, File)
                    catch
                        throw:skip ->
                            ok
                    end
            end
    end.

run_test(TestDir, LogDir, Config, _File) ->
    ?DEBUG("Creating ct_run command line...\n", []),
    {Cmd, RawLog} = make_cmd(TestDir, LogDir, Config),
    ?DEBUG("ct_run cmd:~n~p~n", [Cmd]),
    clear_log(LogDir, RawLog),
    Output = case rebar_config:is_verbose(Config) of
                 false ->
                     " >> " ++ RawLog ++ " 2>&1";
                 true ->
                     " 2>&1 | tee -a " ++ RawLog
             end,

    rebar_utils:sh(Cmd ++ Output, [{env,[{"TESTDIR", TestDir}]}]),
    check_log(Config, RawLog).

clear_log(LogDir, RawLog) ->
    case filelib:ensure_dir(filename:join(LogDir, "index.html")) of
        ok ->
            NowStr = rebar_utils:now_str(),
            LogHeader = "--- Test run on " ++ NowStr ++ " ---\n",
            ok = file:write_file(RawLog, LogHeader);
        {error, Reason} ->
            ?ERROR("Could not create log dir - ~p\n", [Reason]),
            ?FAIL
    end.

%% calling ct with erl does not return non-zero on failure - have to check
%% log results
check_log(Config, RawLog) ->
    {ok, Msg} =
        rebar_utils:sh("grep -e 'TEST COMPLETE' -e '{error,make_failed}' "
                       ++ RawLog, [{use_stdout, false}]),
    MakeFailed = string:str(Msg, "{error,make_failed}") =/= 0,
    RunFailed = string:str(Msg, ", 0 failed") =:= 0,
    if
        MakeFailed ->
            show_log(Config, RawLog),
            ?ERROR("Building tests failed\n",[]),
            ?FAIL;

        RunFailed ->
            show_log(Config, RawLog),
            ?ERROR("One or more tests failed\n",[]),
            ?FAIL;

        true ->
            ?CONSOLE("DONE.\n~s\n", [Msg])
    end.

%% Show the log if it hasn't already been shown because verbose was on
show_log(Config, RawLog) ->
    ?CONSOLE("Showing log\n", []),
    case rebar_config:is_verbose(Config) of
        false ->
            {ok, Contents} = file:read_file(RawLog),
            ?CONSOLE("~s", [Contents]);
        true ->
            ok
    end.

make_cmd(TestDir, RawLogDir, Config) ->
    Cwd = rebar_utils:get_cwd(),
    LogDir = filename:join(Cwd, RawLogDir),
    EbinDir = filename:absname(filename:join(Cwd, "ebin")),
    IncludeDir = filename:join(Cwd, "include"),
    Include = case filelib:is_dir(IncludeDir) of
                  true ->
                      " -include \"" ++ IncludeDir ++ "\"";
                  false ->
                      ""
              end,

    %% Add the code path of the rebar process to the code path. This
    %% includes the dependencies in the code path. The directories
    %% that are part of the root Erlang install are filtered out to
    %% avoid duplication
    R = code:root_dir(),
    ?DEBUG("Traversing code path...\n", []),
    NonLibCodeDirs = [P || P <- code:get_path(), not lists:prefix(R, P)],
    ?DEBUG("Found interesting directories: ~p\n", [NonLibCodeDirs]),
    CodeDirs = [io_lib:format("\"~s\"", [Dir]) ||
                   Dir <- [EbinDir|NonLibCodeDirs]],
    CodePathString = string:join(CodeDirs, " "),
    ?DEBUG("Have code path string\n", []),
    Cmd = case get_ct_specs(Cwd) of
              undefined ->
                  ?DEBUG("Creating command line without specs...\n", []),
                  ?FMT("erl " % should we expand ERL_PATH?
                       " -noshell -pa ~s ~s"
                       " ~s"
                       " -logdir \"~s\""
                       " -env TEST_DIR \"~s\""
                       " ~s"
                       " -s ct_run script_start -s erlang halt",
                       [CodePathString,
                        Include,
                        build_name(Config),
                        LogDir,
                        filename:join(Cwd, TestDir),
                        get_extra_params(Config)]) ++
                      get_cover_config(Config, Cwd) ++
                      get_ct_config_file(TestDir) ++
                      get_config_file(TestDir) ++
                      get_suites(Config, TestDir) ++
                      get_case(Config);
              SpecFlags ->
                  ?FMT("erl " % should we expand ERL_PATH?
                       " -noshell -pa ~s ~s"
                       " ~s"
                       " -logdir \"~s\""
                       " -env TEST_DIR \"~s\""
                       " ~s"
                       " -s ct_run script_start -s erlang halt",
                       [CodePathString,
                        Include,
                        build_name(Config),
                        LogDir,
                        filename:join(Cwd, TestDir),
                        get_extra_params(Config)]) ++
                      SpecFlags ++ get_cover_config(Config, Cwd)
          end,
    RawLog = filename:join(LogDir, "raw.log"),
    ?DEBUG("Got it: ~s\n", [Cmd]),
    {Cmd, RawLog}.

build_name(Config) ->
    case rebar_config:get_local(Config, ct_use_short_names, false) of
        true -> "-sname test";
        false -> " -name test@" ++ net_adm:localhost()
    end.

get_extra_params(Config) ->
    rebar_config:get_local(Config, ct_extra_params, "").

get_ct_specs(Cwd) ->
    ?DEBUG("Looking for test spec in ~s...\n", [Cwd]),
    case collect_glob(Cwd, ".*\.test\.spec\$") of
        [] -> undefined;
        [Spec] ->
            " -spec " ++ Spec;
        Specs ->
            " -spec " ++
                lists:flatten([io_lib:format("~s ", [Spec]) || Spec <- Specs])
    end.

get_cover_config(Config, Cwd) ->
    case rebar_config:get_local(Config, cover_enabled, false) of
        false ->
            "";
        true ->
            ?DEBUG("Looking for cover spec in ~s...\n", [Cwd]),
            case collect_glob(Cwd, ".*cover\.spec\$") of
                [] ->
                    ?DEBUG("No cover spec found: ~s~n", [Cwd]),
                    "";
                [Spec] ->
                    ?DEBUG("Found cover file ~w~n", [Spec]),
                    " -cover " ++ Spec;
                Specs ->
                    ?ABORT("Multiple cover specs found: ~p~n", [Specs])
            end
    end.

collect_glob(Cwd, Regexp) when is_list(Regexp) ->
    {ok, Compiled} = re:compile(Regexp),
    collect_glob(Cwd, Compiled);
collect_glob(Cwd, CompiledRegexp) when is_tuple(CompiledRegexp), element(1, CompiledRegexp) =:= re_pattern ->
    ?DEBUG("Descending into ~s...\n", [Cwd]),
    case file:list_dir(Cwd) of
        {ok, Filenames} ->
            AbsNames = [filename:join(Cwd, Name) || Name <- Filenames],
            {Directories, Files} = lists:partition(fun filelib:is_dir/1, AbsNames),
            MatchingFiles =
                [File || File <- Files, nomatch =/= re:run(File, CompiledRegexp, [{capture, none}])],
            MatchingFiles ++
                %% Ignore any specs under the deps/ directory.
                lists:append([collect_glob(Dir, CompiledRegexp) || Dir <- Directories, filename:basename(Dir) =/= "deps"]);
        {error, E} ->
            ?WARN("Cannot list files in ~s: ~p\n", [Cwd, E])
    end.

get_ct_config_file(TestDir) ->
    Config = filename:join(TestDir, "test.config"),
    case filelib:is_regular(Config) of
        false ->
            " ";
        true ->
            " -ct_config " ++ Config
    end.

get_config_file(TestDir) ->
    Config = filename:join(TestDir, "app.config"),
    case filelib:is_regular(Config) of
        false ->
            " ";
        true ->
            " -config " ++ Config
    end.

get_suites(Config, TestDir) ->
    case rebar_config:get_global(Config, suites, undefined) of
        undefined ->
            " -dir " ++ TestDir;
        Suites ->
            Suites1 = string:tokens(Suites, ","),
            Suites2 = [find_suite_path(Suite, TestDir) || Suite <- Suites1],
            string:join([" -suite"] ++ Suites2, " ")
    end.

find_suite_path(Suite, TestDir) ->
    Path = filename:join(TestDir, Suite ++ "_SUITE.erl"),
    case filelib:is_regular(Path) of
        false ->
            ?WARN("Suite ~s not found\n", [Suite]),
            %% Note - this throw is caught in run_test_if_present/3;
            %% this solution was easier than refactoring the entire module.
            throw(skip);
        true ->
            Path
    end.

get_case(Config) ->
    case rebar_config:get_global(Config, 'case', undefined) of
        undefined ->
            "";
        Case ->
            " -case " ++ Case
    end.
