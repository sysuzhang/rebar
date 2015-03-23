%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009, 2010 Dave Smith (dizzyd@dizzyd.com)
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
-module(rebar_erlc_compiler).

-export([compile/2,
         clean/2]).

%% for internal use only
-export([test_compile/3,
         info/2]).

-include("rebar.hrl").
-include_lib("stdlib/include/erl_compile.hrl").

-define(ERLCINFO_VSN, 1).
-define(ERLCINFO_FILE, "erlcinfo").
-type erlc_info_v() :: {digraph:vertex(), term()} | 'false'.
-type erlc_info_e() :: {digraph:vertex(), digraph:vertex()}.
-type erlc_info() :: {list(erlc_info_v()), list(erlc_info_e()), list(string())}.
-record(erlcinfo,
        {
          vsn = ?ERLCINFO_VSN :: pos_integer(),
          info = {[], [], []} :: erlc_info()
        }).

-ifdef(namespaced_types).
%% digraph:graph() exists starting from Erlang 17.
-type rebar_digraph() :: digraph:graph().
-else.
%% digraph() has been obsoleted in Erlang 17 and deprecated in 18.
-type rebar_digraph() :: digraph().
-endif.

%% ===================================================================
%% Public API
%% ===================================================================

%% Supported configuration variables:
%%
%% * erl_opts - Erlang list of options passed to compile:file/2
%%              It is also possible to specify platform specific
%%              options by specifying a pair or a triplet where the
%%              first string is a regex that is checked against the
%%              string
%%
%%                OtpRelease ++ "-" ++ SysArch ++ "-" ++ Words.
%%
%%              where
%%
%%                OtpRelease = erlang:system_info(otp_release).
%%                SysArch = erlang:system_info(system_architecture).
%%                Words = integer_to_list(8 *
%%                            erlang:system_info({wordsize, external})).
%%
%%              E.g. to define HAVE_SENDFILE only on systems with
%%              sendfile(), to define BACKLOG on Linux/FreeBSD as 128,
%%              and to define 'old_inets' for R13 OTP release do:
%%
%%              {erl_opts, [{platform_define,
%%                           "(linux|solaris|freebsd|darwin)",
%%                           'HAVE_SENDFILE'},
%%                          {platform_define, "(linux|freebsd)",
%%                           'BACKLOG', 128},
%%                          {platform_define, "R13",
%%                           'old_inets'}]}.
%%

-spec compile(rebar_config:config(), file:filename()) -> 'ok'.
compile(Config, _AppFile) ->
    rebar_base_compiler:run(Config,
                            check_files(rebar_config:get_local(
                                          Config, xrl_first_files, [])),
                            "src", ".xrl", "src", ".erl",
                            fun compile_xrl/3),
    rebar_base_compiler:run(Config,
                            check_files(rebar_config:get_local(
                                          Config, yrl_first_files, [])),
                            "src", ".yrl", "src", ".erl",
                            fun compile_yrl/3),
    rebar_base_compiler:run(Config,
                            check_files(rebar_config:get_local(
                                          Config, mib_first_files, [])),
                            "mibs", ".mib", "priv/mibs", ".bin",
                            fun compile_mib/3),
    doterl_compile(Config, "ebin").

-spec clean(rebar_config:config(), file:filename()) -> 'ok'.
clean(_Config, _AppFile) ->
    MibFiles = rebar_utils:find_files_by_ext("mibs", ".mib"),
    MIBs = [filename:rootname(filename:basename(MIB)) || MIB <- MibFiles],
    rebar_file_utils:delete_each(
      [filename:join(["include",MIB++".hrl"]) || MIB <- MIBs]),
    lists:foreach(fun(F) -> ok = rebar_file_utils:rm_rf(F) end,
                  ["ebin/*.beam", "priv/mibs/*.bin"]),

    YrlFiles = rebar_utils:find_files_by_ext("src", ".[x|y]rl"),
    rebar_file_utils:delete_each(
      [ binary_to_list(iolist_to_binary(re:replace(F, "\\.[x|y]rl$", ".erl")))
        || F <- YrlFiles ]),

    %% Delete the build graph, if any
    rebar_file_utils:rm_rf(erlcinfo_file()),

    %% Erlang compilation is recursive, so it's possible that we have a nested
    %% directory structure in ebin with .beam files within. As such, we want
    %% to scan whatever is left in the ebin/ directory for sub-dirs which
    %% satisfy our criteria.
    BeamFiles = rebar_utils:find_files_by_ext("ebin", ".beam"),
    rebar_file_utils:delete_each(BeamFiles),
    lists:foreach(fun(Dir) -> delete_dir(Dir, dirs(Dir)) end, dirs("ebin")),
    ok.

%% ===================================================================
%% .erl Compilation API (externally used by only eunit and qc)
%% ===================================================================

test_compile(Config, Cmd, OutDir) ->
    %% Obtain all the test modules for inclusion in the compile stage.
    TestErls = rebar_utils:find_files_by_ext("test", ".erl"),

    ErlOpts = rebar_utils:erl_opts(Config),
    {Config1, ErlOpts1} = test_compile_config_and_opts(Config, ErlOpts, Cmd),

    %% Copy source files to eunit dir for cover in case they are not directly
    %% in src but in a subdirectory of src. Cover only looks in cwd and ../src
    %% for source files. Also copy files from src_dirs.
    SrcDirs = rebar_utils:src_dirs(proplists:append_values(src_dirs, ErlOpts1)),
    SrcErls = lists:foldl(
                fun(Dir, Acc) ->
                        Files = rebar_utils:find_files_by_ext(Dir, ".erl"),
                        lists:append(Acc, Files)
                end, [], SrcDirs),

    %% If it is not the first time rebar eunit or rebar qc is executed,
    %% there will be source files already present in OutDir. Since some
    %% SCMs (like Perforce) set the source files as being read only (unless
    %% they are checked out), we need to be sure that the files already
    %% present in OutDir are writable before doing the copy. This is done
    %% here by removing any file that was already present before calling
    %% rebar_file_utils:cp_r.

    %% Get the full path to a file that was previously copied in OutDir
    ToCleanUp = fun(F, Acc) ->
                        F2 = filename:basename(F),
                        F3 = filename:join([OutDir, F2]),
                        case filelib:is_regular(F3) of
                            true -> [F3|Acc];
                            false -> Acc
                        end
                end,

    ok = rebar_file_utils:delete_each(lists:foldl(ToCleanUp, [], TestErls)),
    ok = rebar_file_utils:delete_each(lists:foldl(ToCleanUp, [], SrcErls)),

    ok = rebar_file_utils:cp_r(SrcErls ++ TestErls, OutDir),

    %% Compile erlang code to OutDir, using a tweaked config
    %% with appropriate defines for eunit, and include all the test modules
    %% as well.
    ok = doterl_compile(Config1, OutDir, TestErls, ErlOpts1),

    {ok, SrcErls}.

%% ===================================================================
%% Internal functions
%% ===================================================================

info(help, compile) ->
    info_help("Build *.erl, *.yrl, *.xrl, and *.mib sources");
info(help, clean) ->
    info_help("Delete *.erl, *.yrl, *.xrl, and *.mib build results").

info_help(Description) ->
    ?CONSOLE(
       "~s.~n"
       "~n"
       "Valid rebar.config options:~n"
       "  ~p~n"
       "  ~p~n"
       "  ~p~n"
       "  ~p~n"
       "  ~p~n"
       "  ~p~n"
       "  ~p~n"
       "  ~p~n",
       [
        Description,
        {erl_opts, [no_debug_info,
                    {i, "myinclude"},
                    {src_dirs, ["src", "src2", "src3"]},
                    {platform_define,
                     "(linux|solaris|freebsd|darwin)", 'HAVE_SENDFILE'},
                    {platform_define, "(linux|freebsd)", 'BACKLOG', 128},
                    {platform_define, "R13", 'old_inets'}]},
        {erl_first_files, ["src/mymib1.erl", "src/mymib2.erl"]},
        {mib_opts, []},
        {mib_first_files, []},
        {xrl_opts, []},
        {xrl_first_files, []},
        {yrl_opts, []},
        {yrl_first_files, []}
       ]).

test_compile_config_and_opts(Config, ErlOpts, Cmd) ->
    {Config1, TriqOpts} = triq_opts(Config),
    {Config2, PropErOpts} = proper_opts(Config1),
    {Config3, EqcOpts} = eqc_opts(Config2),

    %% NOTE: For consistency, all *_first_files lists should be
    %% retrieved via rebar_config:get_local. Right now
    %% erl_first_files, eunit_first_files, and qc_first_files use
    %% rebar_config:get_list and are inherited, but xrl_first_files
    %% and yrl_first_files use rebar_config:get_local. Inheritance of
    %% *_first_files is questionable as the file would need to exist
    %% in all project directories for it to work.
    OptsAtom = list_to_atom(Cmd ++ "_compile_opts"),
    TestOpts = rebar_config:get_list(Config3, OptsAtom, []),
    Opts0 = [{d, 'TEST'}] ++
        ErlOpts ++ TestOpts ++ TriqOpts ++ PropErOpts ++ EqcOpts,
    Opts = [O || O <- Opts0, O =/= no_debug_info],
    Config4 = rebar_config:set(Config3, erl_opts, Opts),

    FirstFilesAtom = list_to_atom(Cmd ++ "_first_files"),
    FirstErls = rebar_config:get_list(Config4, FirstFilesAtom, []),
    Config5 = rebar_config:set(Config4, erl_first_files, FirstErls),
    {Config5, Opts}.

triq_opts(Config) ->
    {NewConfig, IsAvail} = is_lib_avail(Config, is_triq_avail, triq,
                                        "triq.hrl", "Triq"),
    Opts = define_if('TRIQ', IsAvail),
    {NewConfig, Opts}.

proper_opts(Config) ->
    {NewConfig, IsAvail} = is_lib_avail(Config, is_proper_avail, proper,
                                        "proper.hrl", "PropEr"),
    Opts = define_if('PROPER', IsAvail),
    {NewConfig, Opts}.

eqc_opts(Config) ->
    {NewConfig, IsAvail} = is_lib_avail(Config, is_eqc_avail, eqc,
                                        "eqc.hrl", "QuickCheck"),
    Opts = define_if('EQC', IsAvail),
    {NewConfig, Opts}.

define_if(Def, true) -> [{d, Def}];
define_if(_Def, false) -> [].

is_lib_avail(Config, DictKey, Mod, Hrl, Name) ->
    case rebar_config:get_xconf(Config, DictKey, undefined) of
        undefined ->
            IsAvail = case code:lib_dir(Mod, include) of
                          {error, bad_name} ->
                              false;
                          Dir ->
                              filelib:is_regular(filename:join(Dir, Hrl))
                      end,
            NewConfig = rebar_config:set_xconf(Config, DictKey, IsAvail),
            ?DEBUG("~s availability: ~p\n", [Name, IsAvail]),
            {NewConfig, IsAvail};
        IsAvail ->
            {Config, IsAvail}
    end.

-spec doterl_compile(rebar_config:config(), file:filename()) -> 'ok'.
doterl_compile(Config, OutDir) ->
    ErlOpts = rebar_utils:erl_opts(Config),
    doterl_compile(Config, OutDir, [], ErlOpts).

doterl_compile(Config, OutDir, MoreSources, ErlOpts) ->
    ErlFirstFilesConf = rebar_config:get_list(Config, erl_first_files, []),
    ?DEBUG("erl_opts ~p~n", [ErlOpts]),
    %% Support the src_dirs option allowing multiple directories to
    %% contain erlang source. This might be used, for example, should
    %% eunit tests be separated from the core application source.
    SrcDirs = rebar_utils:src_dirs(proplists:append_values(src_dirs, ErlOpts)),
    AllErlFiles = gather_src(SrcDirs, []) ++ MoreSources,
    %% NOTE: If and when erl_first_files is not inherited anymore
    %% (rebar_config:get_local instead of rebar_config:get_list), consider
    %% logging a warning message for any file listed in erl_first_files which
    %% wasn't found via gather_src.
    RestErls = [File || File <- AllErlFiles,
                        not lists:member(File, ErlFirstFilesConf)],
    %% NOTE: order of files in ErlFirstFiles is important!
    ErlFirstFiles = [File || File <- ErlFirstFilesConf,
                             lists:member(File, AllErlFiles)],
    %% Make sure that ebin/ exists and is on the path
    ok = filelib:ensure_dir(filename:join("ebin", "dummy.beam")),
    CurrPath = code:get_path(),
    true = code:add_path(filename:absname("ebin")),
    OutDir1 = proplists:get_value(outdir, ErlOpts, OutDir),
    G = init_erlcinfo(proplists:get_all_values(i, ErlOpts), AllErlFiles),
    %% Split RestErls so that files which are depended on are treated
    %% like erl_first_files.
    {OtherFirstErls, OtherErls} =
        lists:partition(
          fun(F) ->
                  Children = get_children(G, F),
                  log_files(?FMT("Files dependent on ~s", [F]), Children),

                  case erls(Children) of
                      [] ->
                          %% There are no files dependent on this file.
                          false;
                      _ ->
                          %% There are some files dependent on the file.
                          %% Thus the file has higher priority
                          %% and should be compiled in the first place.
                          true
                  end
          end, RestErls),
    %% Dependencies of OtherFirstErls that must be compiled first.
    OtherFirstErlsDeps = lists:flatmap(
                           fun(Erl) -> erls(get_parents(G, Erl)) end,
                           OtherFirstErls),
    %% NOTE: In case the way we retrieve OtherFirstErlsDeps or merge
    %% it with OtherFirstErls does not result in the correct compile
    %% priorities, or the method in use proves to be too slow for
    %% certain projects, consider using a more elaborate method (maybe
    %% digraph_utils) or alternatively getting and compiling the .erl
    %% parents of an individual Source in internal_erl_compile. By not
    %% handling this in internal_erl_compile, we also avoid extra
    %% needs_compile/2 calls.
    FirstErls = ErlFirstFiles ++ uo_merge(OtherFirstErlsDeps, OtherFirstErls),
    ?DEBUG("Files to compile first: ~p~n", [FirstErls]),
    rebar_base_compiler:run(
      Config, FirstErls, OtherErls,
      fun(S, C) ->
              internal_erl_compile(C, S, OutDir1, ErlOpts, G)
      end),
    true = rebar_utils:cleanup_code_path(CurrPath),
    ok.

%%
%% Return all .erl files from a list of files
%%
erls(Files) ->
    [Erl || Erl <- Files, filename:extension(Erl) =:= ".erl"].

%%
%% Return a list without duplicates while preserving order
%%
ulist(L) ->
    ulist(L, []).

ulist([H|T], Acc) ->
    case lists:member(H, T) of
        true ->
            ulist(T, Acc);
        false ->
            ulist(T, [H|Acc])
    end;
ulist([], Acc) ->
    lists:reverse(Acc).

%%
%% Merge two lists without duplicates while preserving order
%%
uo_merge(L1, L2) ->
    lists:foldl(fun(E, Acc) -> u_add_element(E, Acc) end, ulist(L1), L2).

u_add_element(Elem, [Elem|_]=Set) -> Set;
u_add_element(Elem, [E1|Set])     -> [E1|u_add_element(Elem, Set)];
u_add_element(Elem, [])           -> [Elem].

-spec needs_compile(file:filename(), file:filename(),
                    [string()]) -> boolean().
needs_compile(Source, Target, Parents) ->
    TargetLastMod = filelib:last_modified(Target),
    lists:any(fun(I) -> TargetLastMod < filelib:last_modified(I) end,
              [Source] ++ Parents).

erlcinfo_file() ->
    filename:join([rebar_utils:get_cwd(), ".rebar", ?ERLCINFO_FILE]).

%% Get dependency graph of given Erls files and their dependencies (header files,
%% parse transforms, behaviours etc.) located in their directories or given
%% InclDirs.  Note that last modification times stored in vertices are only for
%% internal optimization and cannot be directly used for deciding whether to
%% recompile a file, since when the file itself doesn't change we don't check its
%% dependencies which might change.
init_erlcinfo(InclDirs, Erls) ->
    G = digraph:new(),
    try restore_erlcinfo(G, InclDirs)
    catch
        _:_ ->
            ?WARN("Failed to restore ~s file. Discarding it.~n", [erlcinfo_file()]),
            ok = file:delete(erlcinfo_file())
    end,
    Dirs = source_and_include_dirs(InclDirs, Erls),
    Modified = lists:foldl(update_erlcinfo_fun(G, Dirs), false, Erls),
    if Modified -> store_erlcinfo(G, InclDirs); not Modified -> ok end,
    G.

source_and_include_dirs(InclDirs, Erls) ->
    SourceDirs = lists:map(fun filename:dirname/1, Erls),
    lists:usort(["include" | InclDirs ++ SourceDirs]).

update_erlcinfo_fun(G, Dirs) ->
    fun(Erl, Modified) ->
        case update_erlcinfo(G, Dirs, Erl) of
            modified -> true;
            unmodified -> Modified
        end
    end.

update_erlcinfo(G, Dirs, Source) ->
    case digraph:vertex(G, Source) of
        {_, LastUpdated} ->
            case filelib:last_modified(Source) of
                0 ->
                    %% The file doesn't exist anymore,
                    %% erase it from the graph.
                    %% All the edges will be erased automatically.
                    digraph:del_vertex(G, Source),
                    modified;
                LastModified when LastUpdated < LastModified ->
                    modify_erlcinfo(G, Source, LastModified, Dirs);
                _ ->
                    unmodified
            end;
        false ->
            modify_erlcinfo(G, Source, filelib:last_modified(Source), Dirs)
    end.

modify_erlcinfo(G, Source, LastModified, Dirs) ->
    {ok, Fd} = file:open(Source, [read]),
    Incls = parse_attrs(Fd, []),
    AbsIncls = expand_file_names(Incls, Dirs),
    ok = file:close(Fd),
    digraph:add_vertex(G, Source, LastModified),
    digraph:del_edges(G, digraph:out_edges(G, Source)),
    lists:foreach(
      fun(Incl) ->
              update_erlcinfo(G, Dirs, Incl),
              digraph:add_edge(G, Source, Incl)
      end, AbsIncls),
    modified.

restore_erlcinfo(G, InclDirs) ->
    case file:read_file(erlcinfo_file()) of
        {ok, Data} ->
            %% Since externally passed InclDirs can influence erlcinfo graph (see
            %% modify_erlcinfo), we have to check here that they didn't change.
            #erlcinfo{vsn=?ERLCINFO_VSN, info={Vs, Es, InclDirs}} =
                binary_to_term(Data),
            lists:foreach(
              fun({V, LastUpdated}) ->
                      digraph:add_vertex(G, V, LastUpdated)
              end, Vs),
            lists:foreach(
              fun({_, V1, V2, _}) ->
                      digraph:add_edge(G, V1, V2)
              end, Es);
        {error, _} ->
            ok
    end.

store_erlcinfo(G, InclDirs) ->
    Vs = lists:map(fun(V) -> digraph:vertex(G, V) end, digraph:vertices(G)),
    Es = lists:map(fun(E) -> digraph:edge(G, E) end, digraph:edges(G)),
    File = erlcinfo_file(),
    ok = filelib:ensure_dir(File),
    Data = term_to_binary(#erlcinfo{info={Vs, Es, InclDirs}}, [{compressed, 2}]),
    ok = file:write_file(File, Data).

%% NOTE: If, for example, one of the entries in Files refers to
%% gen_server.erl, that entry will be dropped. It is dropped because
%% such an entry usually refers to the beam file, and we don't pass a
%% list of OTP src dirs for finding gen_server.erl's full path. Also,
%% if gen_server.erl was modified, it's not rebar's task to compile a
%% new version of the beam file. Therefore, it's reasonable to drop
%% such entries. Also see process_attr(behaviour, Form, Includes).
-spec expand_file_names([file:filename()],
                        [file:filename()]) -> [file:filename()].
expand_file_names(Files, Dirs) ->
    %% We check if Files exist by itself or within the directories
    %% listed in Dirs.
    %% Return the list of files matched.
    lists:flatmap(
      fun(Incl) ->
              case filelib:is_regular(Incl) of
                  true ->
                      [Incl];
                  false ->
                      lists:flatmap(
                        fun(Dir) ->
                                FullPath = filename:join(Dir, Incl),
                                case filelib:is_regular(FullPath) of
                                    true ->
                                        [FullPath];
                                    false ->
                                        []
                                end
                        end, Dirs)
              end
      end, Files).

-spec get_parents(rebar_digraph(), file:filename()) -> [file:filename()].
get_parents(G, Source) ->
    %% Return all files which the Source depends upon.
    digraph_utils:reachable_neighbours([Source], G).

-spec get_children(rebar_digraph(), file:filename()) -> [file:filename()].
get_children(G, Source) ->
    %% Return all files dependent on the Source.
    digraph_utils:reaching_neighbours([Source], G).

-spec internal_erl_compile(rebar_config:config(), file:filename(),
                           file:filename(), list(),
                           rebar_digraph()) -> 'ok' | 'skipped'.
internal_erl_compile(Config, Source, OutDir, ErlOpts, G) ->
    %% Determine the target name and includes list by inspecting the source file
    Module = filename:basename(Source, ".erl"),
    Parents = get_parents(G, Source),
    log_files(?FMT("Dependencies of ~s", [Source]), Parents),

    %% Construct the target filename
    Target = filename:join([OutDir | string:tokens(Module, ".")]) ++ ".beam",
    ok = filelib:ensure_dir(Target),

    %% If the file needs compilation, based on last mod date of includes or
    %% the target
    case needs_compile(Source, Target, Parents) of
        true ->
            Opts = [{outdir, filename:dirname(Target)}] ++
                ErlOpts ++ [{i, "include"}, return],
            case compile:file(Source, Opts) of
                {ok, _Mod} ->
                    ok;
                {ok, _Mod, Ws} ->
                    rebar_base_compiler:ok_tuple(Config, Source, Ws);
                {error, Es, Ws} ->
                    rebar_base_compiler:error_tuple(Config, Source,
                                                    Es, Ws, Opts)
            end;
        false ->
            skipped
    end.

-spec compile_mib(file:filename(), file:filename(),
                  rebar_config:config()) -> 'ok'.
compile_mib(Source, Target, Config) ->
    ok = rebar_utils:ensure_dir(Target),
    ok = rebar_utils:ensure_dir(filename:join("include", "dummy.hrl")),
    Opts = [{outdir, "priv/mibs"}, {i, ["priv/mibs"]}] ++
        rebar_config:get(Config, mib_opts, []),
    case snmpc:compile(Source, Opts) of
        {ok, _} ->
            Mib = filename:rootname(Target),
            MibToHrlOpts =
                case proplists:get_value(verbosity, Opts, undefined) of
                    undefined ->
                        #options{specific = []};
                    Verbosity ->
                        #options{specific = [{verbosity, Verbosity}]}
                end,
            ok = snmpc:mib_to_hrl(Mib, Mib, MibToHrlOpts),
            Hrl_filename = Mib ++ ".hrl",
            rebar_file_utils:mv(Hrl_filename, "include"),
            ok;
        {error, compilation_failed} ->
            ?FAIL
    end.

-spec compile_xrl(file:filename(), file:filename(),
                  rebar_config:config()) -> 'ok'.
compile_xrl(Source, Target, Config) ->
    Opts = [{scannerfile, Target} | rebar_config:get(Config, xrl_opts, [])],
    compile_xrl_yrl(Config, Source, Target, Opts, leex).

-spec compile_yrl(file:filename(), file:filename(),
                  rebar_config:config()) -> 'ok'.
compile_yrl(Source, Target, Config) ->
    Opts = [{parserfile, Target} | rebar_config:get(Config, yrl_opts, [])],
    compile_xrl_yrl(Config, Source, Target, Opts, yecc).

-spec compile_xrl_yrl(rebar_config:config(), file:filename(),
                      file:filename(), list(), module()) -> 'ok'.
compile_xrl_yrl(Config, Source, Target, Opts, Mod) ->
    case needs_compile(Source, Target, []) of
        true ->
            case Mod:file(Source, Opts ++ [{return, true}]) of
                {ok, _} ->
                    ok;
                {ok, _Mod, Ws} ->
                    rebar_base_compiler:ok_tuple(Config, Source, Ws);
                {error, Es, Ws} ->
                    rebar_base_compiler:error_tuple(Config, Source,
                                                    Es, Ws, Opts)
            end;
        false ->
            skipped
    end.

gather_src([], Srcs) ->
    Srcs;
gather_src([Dir|Rest], Srcs) ->
    gather_src(
      Rest, Srcs ++ rebar_utils:find_files_by_ext(Dir, ".erl")).

-spec dirs(file:filename()) -> [file:filename()].
dirs(Dir) ->
    [F || F <- filelib:wildcard(filename:join([Dir, "*"])), filelib:is_dir(F)].

-spec delete_dir(file:filename(), [string()]) -> 'ok' | {'error', atom()}.
delete_dir(Dir, []) ->
    file:del_dir(Dir);
delete_dir(Dir, Subdirs) ->
    lists:foreach(fun(D) -> delete_dir(D, dirs(D)) end, Subdirs),
    file:del_dir(Dir).

parse_attrs(Fd, Includes) ->
    case io:parse_erl_form(Fd, "") of
        {ok, Form, _Line} ->
            case erl_syntax:type(Form) of
                attribute ->
                    NewIncludes = process_attr(Form, Includes),
                    parse_attrs(Fd, NewIncludes);
                _ ->
                    parse_attrs(Fd, Includes)
            end;
        {eof, _} ->
            Includes;
        _Err ->
            parse_attrs(Fd, Includes)
    end.

process_attr(Form, Includes) ->
    AttrName = erl_syntax:atom_value(erl_syntax:attribute_name(Form)),
    process_attr(AttrName, Form, Includes).

process_attr(import, Form, Includes) ->
    case erl_syntax_lib:analyze_import_attribute(Form) of
        {Mod, _Funs} ->
            [module_to_erl(Mod)|Includes];
        Mod ->
            [module_to_erl(Mod)|Includes]
    end;
process_attr(file, Form, Includes) ->
    {File, _} = erl_syntax_lib:analyze_file_attribute(Form),
    [File|Includes];
process_attr(include, Form, Includes) ->
    [FileNode] = erl_syntax:attribute_arguments(Form),
    File = erl_syntax:string_value(FileNode),
    [File|Includes];
process_attr(include_lib, Form, Includes) ->
    [FileNode] = erl_syntax:attribute_arguments(Form),
    RawFile = erl_syntax:string_value(FileNode),
    File = maybe_expand_include_lib_path(RawFile),
    [File|Includes];
process_attr(behaviour, Form, Includes) ->
    [FileNode] = erl_syntax:attribute_arguments(Form),
    File = module_to_erl(erl_syntax:atom_value(FileNode)),
    [File|Includes];
process_attr(compile, Form, Includes) ->
    [Arg] = erl_syntax:attribute_arguments(Form),
    case erl_syntax:concrete(Arg) of
        {parse_transform, Mod} ->
            [module_to_erl(Mod)|Includes];
        {core_transform, Mod} ->
            [module_to_erl(Mod)|Includes];
        L when is_list(L) ->
            lists:foldl(
              fun({parse_transform, Mod}, Acc) ->
                      [module_to_erl(Mod)|Acc];
                 ({core_transform, Mod}, Acc) ->
                      [module_to_erl(Mod)|Acc];
                 (_, Acc) ->
                      Acc
              end, Includes, L);
        _ ->
            Includes
    end;
process_attr(_, _Form, Includes) ->
    Includes.

module_to_erl(Mod) ->
    atom_to_list(Mod) ++ ".erl".

%% Given the filename from an include_lib attribute, if the path
%% exists, return unmodified, or else get the absolute ERL_LIBS
%% path.
maybe_expand_include_lib_path(File) ->
    case filelib:is_regular(File) of
        true ->
            File;
        false ->
            expand_include_lib_path(File)
    end.

%% Given a path like "stdlib/include/erl_compile.hrl", return
%% "OTP_INSTALL_DIR/lib/erlang/lib/stdlib-x.y.z/include/erl_compile.hrl".
%% Usually a simple [Lib, SubDir, File1] = filename:split(File) should
%% work, but to not crash when an unusual include_lib path is used,
%% utilize more elaborate logic.
expand_include_lib_path(File) ->
    File1 = filename:basename(File),
    Split = filename:split(filename:dirname(File)),
    Lib = hd(Split),
    SubDir = filename:join(tl(Split)),
    Dir = code:lib_dir(list_to_atom(Lib), list_to_atom(SubDir)),
    filename:join(Dir, File1).

%%
%% Ensure all files in a list are present and abort if one is missing
%%
-spec check_files([file:filename()]) -> [file:filename()].
check_files(FileList) ->
    [check_file(F) || F <- FileList].

check_file(File) ->
    case filelib:is_regular(File) of
        false -> ?ABORT("File ~p is missing, aborting\n", [File]);
        true -> File
    end.

%% Print prefix followed by list of files. If the list is empty, print
%% on the same line, otherwise use a separate line.
log_files(Prefix, Files) ->
    case Files of
        [] ->
            ?DEBUG("~s: ~p~n", [Prefix, Files]);
        _ ->
            ?DEBUG("~s:~n~p~n", [Prefix, Files])
    end.
