-module(tr).

-behaviour(gen_server).

%% API - capturing, data manipulation
-export([start_link/0, start_link/1,
         start/0, start/1,
         trace_app/1,
         trace_apps/1,
         trace/1, trace/2,
         stop_tracing/0,
         stop/0,
         tab/0,
         set_tab/1,
         load/1,
         dump/1,
         clean/0]).

%% API - analysis
-export([select/0, select/1, select/2,
         filter/1, filter/2,
         traceback/1, traceback/2,
         tracebacks/1, tracebacks/2,
         range/1, range/2,
         ranges/1, ranges/2,
         call_tree_stat/0, call_tree_stat/1,
         reduce_call_trees/1,
         top_call_trees/0, top_call_trees/1, top_call_trees/2,
         print_sorted_call_stat/2,
         sorted_call_stat/1,
         call_stat/1, call_stat/2]).

%% API - utilities
-export([contains_data/2,
         call_selector/1,
         do/1,
         lookup/1,
         app_modules/1,
         mfarity/1,
         mfa/2,
         ts/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% copied, not included from tr.hrl to make it self-contained
-record(tr, {index :: pos_integer(),
             pid :: pid(),
             event :: call | return | exception,
             mfa :: mfa(),
             data :: term(),
             ts :: integer()}).

-define(is_return(Event), (Event =:= return orelse Event =:= exception)).

-type tr() :: #tr{}.
-type pred() :: fun((tr()) -> boolean()).
-type selector() :: fun((tr()) -> term()).
-type call_count() :: non_neg_integer().
-type acc_time() :: non_neg_integer().
-type own_time() :: non_neg_integer().
-type pids() :: [pid()] | all.
-type limit() :: pos_integer() | infinity. % used for a few different limits
-type index() :: non_neg_integer().

-type init_options() :: #{tab => atom(),
                          index => index(),
                          limit => limit()}.
-type state() :: #{tab := atom(),
                   index := index(),
                   limit := limit(),
                   trace := none | trace_spec()}.
-type trace_spec() :: #{modules := module_spec(),
                        pids := pids()}.
-type module_spec() :: [module() | mfa()].

-type range_options() :: #{tab => atom() | [tr()],
                           max_depth => limit()}.

-type tb_options() :: #{tab => atom() | [tr()],
                        output => tb_output(),
                        format => tb_format(),
                        order => tb_order(),
                        limit => limit()}.
-type tb_output() :: shortest | longest | all.
-type tb_format() :: tree | list.
-type tb_order() :: top_down | bottom_up.
-type tb_tree() :: [tr() | {tr(), tb_tree()}].
-type tb_acc_tree() :: [{tr(), tb_acc_tree()}].
-type tb_acc_list() :: [[tr()]].
-type tb_acc() :: tb_acc_tree() | tb_acc_list().

-type call() :: {call, {module(), atom(), list()}}.
-type result() :: {return | exception, any()}.
-type simple_tr() :: call() | result().

-type call_tree_stat_options() :: #{tab => atom()}.
-type call_tree_stat_state() :: #{pid_states := map(), tab := ets:tid()}.

-type pid_call_state() :: [tree() | call()].

-type top_call_trees_output() :: reduced | complete.

-type top_call_trees_options() :: #{max_size => pos_integer(),
                                    min_count => count(),
                                    min_time => time_diff(),
                                    output => top_call_trees_output()}.

-type time_diff() :: integer().
-type count() :: pos_integer().

-record(node, {module :: module(),
               function :: atom(),
               args = [] :: list(),
               children = [] :: [#node{}],
               result :: result()}).

-type tree() :: #node{}.

-type tree_item() :: {time_diff(), count(), tree()}.

%% API - capturing, data manipulation

-spec start_link() -> {ok, pid()}.
start_link() ->
    start_link(#{}).

-spec start_link(init_options()) -> {ok, pid()}.
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

-spec start() -> {ok, pid()}.
start() ->
    start(#{}).

-spec start(init_options()) -> {ok, pid()}.
start(Opts) ->
    gen_server:start({local, ?MODULE}, ?MODULE, Opts, []).

-define(is_trace(Tr), element(1, (Tr)) =:= trace orelse element(1, (Tr)) =:= trace_ts).

-spec trace_app(atom()) -> ok.
trace_app(App) ->
    trace_apps([App]).

-spec trace_apps([atom()]) -> ok.
trace_apps(Apps) ->
    trace(lists:flatmap(fun app_modules/1, Apps)).

-spec trace(module_spec()) -> ok.
trace(Modules) ->
    gen_server:call(?MODULE, {start_trace, call, #{modules => Modules}}).

-spec trace(module_spec(), pids()) -> ok.
trace(Modules, Pids) ->
    gen_server:call(?MODULE, {start_trace, call, #{modules => Modules,
                                                   pids => Pids}}).

-spec stop_tracing() -> ok.
stop_tracing() ->
    gen_server:call(?MODULE, {stop_trace, call}).

-spec stop() -> ok.
stop() ->
    gen_server:stop(?MODULE).

-spec tab() -> atom().
tab() ->
    gen_server:call(?MODULE, get_tab).

-spec set_tab(atom()) -> ok.
set_tab(Tab) ->
    gen_server:call(?MODULE, {set_tab, Tab}).

-spec load(string()) -> {ok, atom()} | {error, any()}.
load(File) ->
    gen_server:call(?MODULE, {load, File}).

-spec dump(string()) -> ok | {error, any()}.
dump(File) ->
    gen_server:call(?MODULE, {dump, File}).

-spec clean() -> ok.
clean() ->
    gen_server:call(?MODULE, clean).

%% API - analysis

-spec select() -> [tr()].
select() ->
    ets:tab2list(tab()).

-spec select(selector()) -> [term()].
select(F) ->
    ets:select(tab(), ets:fun2ms(F)).

-spec select(selector(), term()) -> [term()].
select(F, DataVal) ->
    MS = ets:fun2ms(F),
    SelectRes = ets:select(tab(), MS, 1000),
    select(MS, DataVal, [], SelectRes).

-spec filter(pred()) -> [tr()].
filter(F) ->
    filter(F, tab()).

-spec filter(pred(), atom() | [tr()]) -> [tr()].
filter(F, Tab) ->
    Traces = foldl(fun(Tr, State) -> filter_trace(F, Tr, State) end, [], Tab),
    lists:reverse(Traces).

-spec traceback(pred() | tr() | pos_integer()) -> [tr()].
traceback(Index) when is_integer(Index) ->
    traceback(fun(#tr{index = I}) -> Index =:= I end);
traceback(T = #tr{}) ->
    traceback(fun(Tr) -> Tr =:= T end);
traceback(PredF) ->
    traceback(PredF, #{}).

-spec traceback(pred(), tb_options()) -> [tr()].
traceback(PredF, Options) ->
    [TB] = tracebacks(PredF, Options#{limit => 1, format => list}),
    TB.

%% Returns tracebacks: [CallN, ..., Call1] when PredF(CallN)
-spec tracebacks(pred()) -> [[tr()]] | tb_tree().
tracebacks(PredF) ->
    tracebacks(PredF, #{}).

-spec tracebacks(pred(), tb_options()) -> [[tr()]] | tb_tree().
tracebacks(PredF, Options) when is_map(Options) ->
    Tab = maps:get(tab, Options, tab()),
    Output = maps:get(output, Options, shortest),
    Format = maps:get(format, Options, list),
    Limit = maps:get(limit, Options, infinity),
    InitialState = #{tbs => [], call_stacks => #{},
                     output => Output, format => Format,
                     count => 0, limit => Limit},
    #{tbs := TBs} =
        foldl(fun(T, State) -> tb_step(PredF, T, State) end, InitialState, Tab),
    finalize_tracebacks(TBs, Output, Format, Options).

-spec range(pred() | tr() | pos_integer()) -> [tr()].
range(Index) when is_integer(Index) ->
    range(fun(#tr{index = I}) -> Index =:= I end);
range(T = #tr{}) ->
    range(fun(Tr) -> Tr =:= T end);
range(PredF) ->
    range(PredF, #{}).

range(PredF, Options) ->
    hd(ranges(PredF, Options)).

%% Returns ranges (trace sections for the given Pid): [Call, ..., Return] when PredF(Call)
-spec ranges(pred()) -> [[tr()]].
ranges(PredF) ->
    ranges(PredF, #{}).

-spec ranges(pred(), range_options()) -> [[tr()]].
ranges(PredF, Options) when is_map(Options) ->
    Tab = maps:get(tab, Options, tab()),
    InitialState = maps:merge(#{traces => [], pid_states => #{}, max_depth => infinity}, Options),
    #{traces := Traces} = foldl(fun(T, S) -> range_step(PredF, T, S) end, InitialState, Tab),
    lists:reverse(Traces).

-spec print_sorted_call_stat(selector(), pos_integer()) -> ok.
print_sorted_call_stat(KeyF, Length) ->
    pretty_print_tuple_list(sorted_call_stat(KeyF), Length).

-spec sorted_call_stat(selector()) -> [{term(), call_count(), acc_time(), own_time()}].
sorted_call_stat(KeyF) ->
    lists:reverse(sort_by_time(call_stat(KeyF))).

-spec call_stat(selector()) -> #{term() => {call_count(), acc_time(), own_time()}}.
call_stat(KeyF) ->
    call_stat(KeyF, tab()).

-spec call_stat(selector(), atom() | [tr()]) -> #{term() => {call_count(), acc_time(), own_time()}}.
call_stat(KeyF, Tab) ->
    {#{}, #{}, State} = foldl(fun(Tr, State) -> call_stat_step(KeyF, Tr, State) end, {#{}, #{}, #{}}, Tab),
    State.

%% API - utilities

-spec contains_data(term(), tr()) -> boolean().
contains_data(DataVal, #tr{data = Data}) ->
    contains_val(DataVal, Data).

-spec call_selector(fun((pid(), {atom(), atom(), [term()]}) -> term())) -> selector().
call_selector(F) ->
    fun(#tr{event = call, pid = Pid, mfa = MFArity, data = Args}) ->
            MFA = mfa(MFArity, Args),
            F(Pid, MFA)
    end.

-spec do(tr()) -> term().
do(Index) when is_integer(Index) ->
    do(lookup(Index));
do(#tr{event = call, mfa = {M, F, Arity}, data = Args}) when length(Args) =:= Arity ->
    apply(M, F, Args).

-spec lookup(pos_integer()) -> tr().
lookup(Index) when is_integer(Index) ->
    [T] = ets:lookup(tab(), Index),
    T.

-spec app_modules(atom()) -> [atom()].
app_modules(AppName) ->
    Path = code:lib_dir(AppName, ebin),
    {ok, FileNames} = file:list_dir(Path),
    BeamFileNames = lists:filter(fun(Name) -> filename:extension(Name) =:= ".beam" end, FileNames),
    [list_to_atom(filename:rootname(Name)) || Name <- BeamFileNames].

-spec mfarity({M, F, Arity | Args}) -> {M, F, Arity} when M :: atom(),
                                                          F :: atom(),
                                                          Arity :: arity(),
                                                          Args :: list().
mfarity({M, F, A}) -> {M, F, maybe_length(A)}.

-spec mfa({M, F, Arity}, Args) -> {M, F, Args} when M :: atom(),
                                                    F :: atom(),
                                                    Arity :: arity(),
                                                    Args :: list().
mfa({M, F, Arity}, Args) when length(Args) =:= Arity -> {M, F, Args}.

-spec ts(tr()) -> string().
ts(#tr{ts = TS}) -> calendar:system_time_to_rfc3339(TS, [{unit, microsecond}]).

%% gen_server callbacks

-spec init(init_options()) -> {ok, state()}.
init(Opts) ->
    DefaultState = #{tab => default_tab(),
                     index => initial_index(),
                     limit => infinity,
                     trace => none},
    State = #{tab := Tab} = maps:merge(DefaultState, Opts),
    create_tab(Tab),
    {ok, maps:merge(State, Opts)}.

-spec handle_call(any(), {pid(), any()}, state()) -> {reply, ok, state()}.
handle_call({start_trace, call, Opts}, _From, State = #{trace := none}) ->
    DefaultOpts = #{modules => [], pids => all},
    {reply, ok, start_trace(State, maps:merge(DefaultOpts, Opts))};
handle_call({stop_trace, call}, _From, State = #{trace := #{}}) ->
    {reply, ok, stop_trace(State)};
handle_call(clean, _From, State = #{tab := Tab}) ->
    ets:delete_all_objects(Tab),
    {reply, ok, State#{index := index(Tab)}};
handle_call({dump, File}, _From, State = #{tab := Tab}) ->
    Reply = ets:tab2file(Tab, File),
    {reply, Reply, State};
handle_call({load, File}, _From, State) ->
    Reply = ets:file2tab(File),
    NewState = case Reply of
                   {ok, Tab} -> State#{tab := Tab, index := index(Tab)};
                   _ -> State
               end,
    {reply, Reply, NewState};
handle_call(get_tab, _From, State = #{tab := Tab}) ->
    {reply, Tab, State};
handle_call({set_tab, NewTab}, _From, State) ->
    create_tab(NewTab),
    {reply, ok, State#{tab := NewTab, index := index(NewTab)}};
handle_call(Req, From, State) ->
    logger:error("Unexpected call ~p from ~p.", [Req, From]),
    {reply, ok, State}.

-spec handle_cast(any(), state()) -> {noreply, state()}.
handle_cast(Msg, State) ->
    logger:error("Unexpected message ~p.", [Msg]),
    {noreply, State}.

-spec handle_info(any(), state()) -> {noreply, state()}.
handle_info(Trace, State = #{trace := none}) when ?is_trace(Trace) ->
    {noreply, State};
handle_info(Trace, State = #{index := I, limit := Limit}) when ?is_trace(Trace), I >= Limit ->
    logger:warning("Reached trace limit ~p, stopping the tracer.", [Limit]),
    {noreply, stop_trace(State)};
handle_info(Trace, State) when ?is_trace(Trace) ->
    {noreply, handle_trace(Trace, State)};
handle_info(Msg, State) ->
    logger:error("Unexpected message ~p.", [Msg]),
    {noreply, State}.

-spec terminate(any(), state()) -> ok.
terminate(_Reason, #{}) ->
    ok.

-spec code_change(any(), state(), any()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
%%-------------------

create_tab(Tab) ->
    ets:new(Tab, [named_table, public, ordered_set, {keypos, 2}]).

select(_MS, _DataVal, DataAcc, '$end_of_table') ->
    lists:append(lists:reverse(DataAcc));
select(MS, DataVal, DataAcc, {Matched, Cont}) ->
    Filtered = lists:filter(fun(#tr{data = Data}) -> contains_val(DataVal, Data);
                               (T) -> contains_val(DataVal, T)
                            end, Matched),
    SelectRes = ets:select(Cont),
    select(MS, DataVal, [Filtered | DataAcc], SelectRes).

filter_trace(F, T, State) ->
    case catch F(T) of
        true -> [T | State];
        _ -> State
    end.

contains_val(DataVal, DataVal) -> true;
contains_val(DataVal, L) when is_list(L) -> lists:any(fun(El) -> contains_val(DataVal, El) end, L);
contains_val(DataVal, T) when is_tuple(T) -> contains_val(DataVal, tuple_to_list(T));
contains_val(DataVal, M) when is_map(M) -> contains_val(DataVal, maps:to_list(M));
contains_val(_, _) -> false.

index(Tab) ->
    case ets:last(Tab) of
        I when is_integer(I) -> I;
        _ -> initial_index()
    end.

-spec start_trace(state(), trace_spec()) -> state().
start_trace(State, Spec = #{modules := ModSpecs, pids := Pids}) ->
    [enable_trace_pattern(ModSpec) || ModSpec <- ModSpecs],
    trace_pids(Pids, true, [call, timestamp]),
    State#{trace := Spec}.

-spec stop_trace(state()) -> state().
stop_trace(State = #{trace := #{modules := ModSpecs, pids := Pids}}) ->
    trace_pids(Pids, false, [call, timestamp]),
    [disable_trace_pattern(ModSpec) || ModSpec <- ModSpecs],
    State#{trace := none}.

trace_pids(all, How, FlagList) ->
    erlang:trace(all, How, FlagList),
    ok;
trace_pids(Pids, How, FlagList) when is_list(Pids) ->
    [trace_pid(Pid, How, FlagList) || Pid <- Pids],
    ok.

trace_pid(Pid, How, FlagList) when is_pid(Pid) ->
    try
        erlang:trace(Pid, How, FlagList)
    catch Class:Reason ->
            logger:warning("Could not switch tracing to ~p for pid ~p, ~p:~p",
                           [How, Pid, Class, Reason])
    end.

enable_trace_pattern(ModSpec) ->
    {MFA = {M, _, _}, Opts} = trace_pattern_and_opts(ModSpec),
    {module, _} = code:ensure_loaded(M),
    erlang:trace_pattern(MFA, [{'_', [], [{exception_trace}]}], Opts).

disable_trace_pattern(Mod) ->
    {MFA, Opts} = trace_pattern_and_opts(Mod),
    erlang:trace_pattern(MFA, false, Opts).

trace_pattern_and_opts(Mod) when is_atom(Mod) -> trace_pattern_and_opts({Mod, '_', '_'});
trace_pattern_and_opts({_, _, _} = MFA) -> {MFA, [local, call_time]};
trace_pattern_and_opts({Mod, Opts}) when is_atom(Mod) -> {{Mod, '_', '_'}, Opts};
trace_pattern_and_opts({{_M, _F, _A} = MFA, Opts}) -> {MFA, Opts}.

handle_trace({trace_ts, Pid, call, MFA = {_, _, Args}, TS}, #{tab := Tab, index := I} = State) ->
    NextIndex = next_index(I),
    ets:insert(Tab, #tr{index = NextIndex, pid = Pid, event = call, mfa = mfarity(MFA), data = Args,
                        ts = usec_from_now(TS)}),
    State#{index := NextIndex};
handle_trace({trace_ts, Pid, return_from, MFArity, Res, TS}, #{tab := Tab, index := I} = State) ->
    NextIndex = next_index(I),
    ets:insert(Tab, #tr{index = NextIndex, pid = Pid, event = return, mfa = MFArity, data = Res,
                        ts = usec_from_now(TS)}),
    State#{index := NextIndex};
handle_trace({trace_ts, Pid, exception_from, MFArity, {Class, Value}, TS}, #{tab := Tab, index := I} = State) ->
    NextIndex = next_index(I),
    ets:insert(Tab, #tr{index = NextIndex, pid = Pid, event = exception, mfa = MFArity, data = {Class, Value},
                        ts = usec_from_now(TS)}),
    State#{index := NextIndex};
handle_trace(Trace, State) ->
    logger:error("Unexpected trace message ~p.", [Trace]),
    State.

%% Filter tracebacks

-spec tb_step(pred(), tr(), map()) -> map().
tb_step(PredF, T = #tr{pid = Pid, event = Event},
        State = #{tbs := TBs, call_stacks := CallStacks, output := Output, format := Format,
                  count := Count, limit := Limit}) ->
    CallStack = maps:get(Pid, CallStacks, []),
    NewStack = update_call_stack(T, CallStack),
    NewState = State#{call_stacks := CallStacks#{Pid => NewStack}},
    case catch PredF(T) of
        true when Count < Limit ->
            TB = if Event =:= call -> NewStack;
                    ?is_return(Event) -> CallStack
                 end,
            NewState#{tbs := add_tb(lists:reverse(TB), TBs, Output, Format),
                      count := Count + 1};
        _ ->
            NewState
    end.

-spec update_call_stack(tr(), [tr()]) -> [tr()].
update_call_stack(T = #tr{event = call}, Stack) -> [T|Stack];
update_call_stack(#tr{event = Event, mfa = MFArity}, [#tr{mfa = MFArity} | Stack])
  when ?is_return(Event) ->
    Stack;
update_call_stack(#tr{event = Event, mfa = {M, F, Arity}}, Stack) when ?is_return(Event) ->
    logger:warning("Found a return trace from ~p:~p/~p without a call trace", [M, F, Arity]),
    Stack.

-spec add_tb([tr()], tb_acc(), tb_output(), tb_format()) -> tb_acc().
add_tb(TB, TBs, all, list) -> [TB | TBs]; %% The only case which uses a list of TBs
add_tb([], _Tree, shortest, _) -> []; %% Other cases use a tree
add_tb([], Tree, Output, _Format) when Output =:= longest;
                                       Output =:= all -> Tree;
add_tb([Call | Rest], Tree, Output, Format) ->
    case lists:keyfind(Call, 1, Tree) of
        {Call, SubTree} ->
            lists:keyreplace(Call, 1, Tree, {Call, add_tb(Rest, SubTree, Output, Format)});
        false ->
            [{Call, add_tb(Rest, [], Output, Format)} | Tree]
    end.

-spec finalize_tracebacks(tb_acc(), tb_output(), tb_format(), tb_options()) ->
          tb_tree() | [[tr()]].
finalize_tracebacks(TBs, all, list, Options) ->
    reorder_tb(lists:reverse(TBs), maps:get(order, Options, top_down));
finalize_tracebacks(TBs, _, list, Options) ->
    reorder_tb(tree_to_list(TBs), maps:get(order, Options, top_down));
finalize_tracebacks(TBs, _, tree, _Options) ->
    finalize_tree(TBs).

-spec reorder_tb([[tr()]], tb_order()) -> [[tr()]].
reorder_tb(TBs, top_down) -> [lists:reverse(TB) || TB <- TBs];
reorder_tb(TBs, bottom_up) -> TBs.

-spec tree_to_list(tb_acc_tree()) -> [[tr()]].
tree_to_list(Tree) ->
    lists:foldl(fun({K, []}, Res) -> [[K] | Res];
                   ({K, V}, Res) -> [[K | Rest] || Rest <- tree_to_list(V)] ++ Res end, [], Tree).

%% Reverse order and simplify leaf nodes
-spec finalize_tree(tb_acc_tree()) -> tb_tree().
finalize_tree(Tree) ->
    lists:foldl(fun({K, []}, Res) -> [K | Res];
                   ({K, V}, Res) -> [{K, finalize_tree(V)} | Res]
                end, [], Tree).

%% Filter ranges

range_step(PredF, T = #tr{pid = Pid}, State = #{traces := Traces, pid_states := States, max_depth := MaxDepth}) ->
    PidState = maps:get(Pid, States, no_state),
    case filter_range(PredF, T, PidState, MaxDepth) of
        {complete, Trace} -> State#{traces := [Trace | Traces], pid_states := maps:remove(Pid, States)};
        {incomplete, NewPidState} -> State#{pid_states := States#{Pid => NewPidState}};
        none -> State
    end.

filter_range(_PredF, T = #tr{event = call}, State = #{depth := Depth, trace := Trace}, MaxDepth)
  when Depth < MaxDepth ->
    {incomplete, State#{depth => Depth + 1, trace => [T|Trace]}};
filter_range(_PredF, #tr{event = call}, State = #{depth := Depth, trace := Trace}, _) ->
    {incomplete, State#{depth => Depth + 1, trace => Trace}};
filter_range(PredF, T = #tr{event = call}, no_state, _) ->
    case catch PredF(T) of
        true -> {incomplete, #{depth => 1, trace => [T]}};
        _ -> none
    end;
filter_range(_PredF, T = #tr{event = Event}, #{depth := 1, trace := Trace}, _) when ?is_return(Event) ->
    {complete, lists:reverse([T|Trace])};
filter_range(_PredF, T = #tr{event = Event}, State = #{depth := Depth, trace := Trace}, MaxDepth)
  when ?is_return(Event), Depth =< MaxDepth ->
    {incomplete, State#{depth => Depth - 1, trace => [T|Trace]}};
filter_range(_PredF, #tr{event = Event}, State = #{depth := Depth, trace := Trace}, _) when ?is_return(Event) ->
    {incomplete, State#{depth => Depth - 1, trace => Trace}};
filter_range(_PredF, #tr{event = Event}, no_state, _) when ?is_return(Event) ->
    none.

%% Call stat

sort_by_time(MapStat) ->
    lists:keysort(3, [{Key, Count, AccTime, OwnTime} || {Key, {Count, AccTime, OwnTime}} <- maps:to_list(MapStat)]).

call_stat_step(KeyF, Tr = #tr{pid = Pid}, {ProcessStates, TmpStat, Stat}) ->
    {LastTr, LastKey, Stack} = maps:get(Pid, ProcessStates, {no_tr, no_key, []}),
    {NewStack, Key} = get_key_and_update_stack(KeyF, Stack, Tr),
    TmpKey = tmp_key(Tr, Key),
    TmpValue = maps:get(TmpKey, TmpStat, none),
    ProcessStates1 = ProcessStates#{Pid => {Tr, Key, NewStack}},
    TmpStat1 = update_tmp(TmpStat, Tr, TmpKey, TmpValue),
    Stat1 = update_stat(Stat, LastTr, LastKey, Tr, Key, TmpValue),
    {ProcessStates1, TmpStat1, Stat1}.

get_key_and_update_stack(KeyF, Stack, T = #tr{event = call}) ->
    Key = try KeyF(T)
          catch _:_ -> no_key
          end,
    {[Key | Stack], Key};
get_key_and_update_stack(_KeyF, [Key | Rest], #tr{event = Event}) when ?is_return(Event) ->
    {Rest, Key};
get_key_and_update_stack(_, [], #tr{event = Event, mfa = MFA}) when ?is_return(Event) ->
    {M, F, A} = mfarity(MFA),
    logger:warning("Found a return trace from ~p:~p/~p without a call trace", [M, F, A]),
    {[], no_key}.

tmp_key(#tr{}, no_key) -> no_key;
tmp_key(#tr{pid = Pid}, Key) -> {Pid, Key}.

update_tmp(TmpStat, _, no_key, none) ->
    TmpStat;
update_tmp(TmpStat, #tr{event = call, ts = TS}, Key, none) ->
    TmpStat#{Key => {TS, 0}};
update_tmp(TmpStat, #tr{event = call}, Key, {OrigTS, N}) ->
    TmpStat#{Key => {OrigTS, N+1}};
update_tmp(TmpStat, #tr{event = Event}, Key, {OrigTS, N}) when ?is_return(Event), N > 0 ->
    TmpStat#{Key => {OrigTS, N-1}};
update_tmp(TmpStat, #tr{event = Event}, Key, {_OrigTS, 0}) when ?is_return(Event) ->
    maps:remove(Key, TmpStat).

update_stat(Stat, LastTr, LastKey, Tr, Key, TmpVal) ->
    Stat1 = update_count(Tr, Key, Stat),
    Stat2 = update_acc_time(TmpVal, Tr, Key, TmpVal, Stat1),
    update_own_time(LastTr, LastKey, Tr, Key, Stat2).

update_count(Tr, Key, Stat) ->
    case count_key(Tr, Key) of
        no_key ->
            Stat;
        KeyToUpdate ->
            {Count, AccTime, OwnTime} = maps:get(KeyToUpdate, Stat, {0, 0, 0}),
            Stat#{KeyToUpdate => {Count + 1, AccTime, OwnTime}}
    end.

update_acc_time(TmpVal, Tr, Key, TmpVal, Stat) ->
    case acc_time_key(TmpVal, Tr, Key) of
        no_key ->
            Stat;
        KeyToUpdate ->
            {Count, AccTime, OwnTime} = maps:get(KeyToUpdate, Stat, {0, 0, 0}),
            {OrigTS, _N} = TmpVal,
            NewAccTime = AccTime + Tr#tr.ts - OrigTS,
            Stat#{KeyToUpdate => {Count, NewAccTime, OwnTime}}
    end.

update_own_time(LastTr, LastKey, Tr, Key, Stat) ->
    case own_time_key(LastTr, LastKey, Tr, Key) of
        no_key ->
            Stat;
        KeyToUpdate ->
            {Count, AccTime, OwnTime} = maps:get(KeyToUpdate, Stat, {0, 0, 0}),
            NewOwnTime = OwnTime + Tr#tr.ts - LastTr#tr.ts,
            Stat#{KeyToUpdate => {Count, AccTime, NewOwnTime}}
    end.

count_key(#tr{event = call}, Key) when Key =/= no_key -> Key;
count_key(#tr{}, _) -> no_key.

acc_time_key({_, 0}, #tr{event = Event}, Key) when ?is_return(Event), Key =/= no_key -> Key;
acc_time_key(_, #tr{}, _) -> no_key.

own_time_key(#tr{event = call}, LastKey, #tr{}, _) when LastKey =/= no_key -> LastKey;
own_time_key(_, _, #tr{event = Event}, Key) when ?is_return(Event), Key =/= no_key -> Key;
own_time_key(_, _, #tr{}, _) -> no_key.

%% Call tree statistics for redundancy check

-spec call_tree_stat() -> ets:tid().
call_tree_stat() ->
    call_tree_stat(#{}).

-spec call_tree_stat(call_tree_stat_options()) -> ets:tid().
call_tree_stat(Options) when is_map(Options) ->
    TraceTab = maps:get(tab, Options, tab()),
    CallTreeTab = ets:new(call_tree_stat, [public, {keypos, 3}]),
    InitialState = maps:merge(#{pid_states => #{}, tab => CallTreeTab}, Options),
    foldl(fun(T, S) -> call_tree_stat_step(T, S) end, InitialState, TraceTab),
    CallTreeTab.

-spec call_tree_stat_step(tr(), call_tree_stat_state()) -> call_tree_stat_state().
call_tree_stat_step(Tr = #tr{pid = Pid, ts = TS}, State = #{pid_states := PidStates, tab := TreeTab}) ->
    PidState = maps:get(Pid, PidStates, []),
    Item = simplify_trace_item(Tr),
    {Status, NewPidState} = update_call_trees(Item, TS, PidState),
    case Status of
        {new_node, CallTS} ->
            insert_call_tree(hd(NewPidState), TS - CallTS, TreeTab);
        no_new_nodes ->
            ok
    end,
    NewPidStates = PidStates#{Pid => NewPidState},
    State#{pid_states => NewPidStates}.

-spec simplify_trace_item(tr()) -> simple_tr().
simplify_trace_item(#tr{event = call, mfa = MFA, data = Args}) ->
    {call, mfa(MFA, Args)};
simplify_trace_item(#tr{event = return, data = Value}) ->
    {return, Value};
simplify_trace_item(#tr{event = exception, data = Value}) ->
    {exception, Value}.

-spec update_call_trees(simple_tr(), integer(), pid_call_state()) ->
          {no_new_nodes | {new_node, integer()}, pid_call_state()}.
update_call_trees(Item = {call, _}, TS, PidState) ->
    {no_new_nodes, [{Item, TS} | PidState]};
update_call_trees(Item, _TS, PidState) ->
    {CallTS, NewPidState} = build_node(PidState, #node{result = Item}),
    {{new_node, CallTS}, NewPidState}.

-spec build_node(pid_call_state(), tree()) -> {integer(), pid_call_state()}.
build_node([Child = #node{} | State], Node = #node{children = Children}) ->
    build_node(State, Node#node{children = [Child | Children]});
build_node([{Call, CallTS} | State], Node) ->
    {call, {M, F, Args}} = Call,
    FinalNode = Node#node{module = M, function = F, args = Args},
    {CallTS, [FinalNode | State]}.

-spec insert_call_tree(tree(), time_diff(), ets:tid()) -> true.
insert_call_tree(CallTree, Time, TreeTab) ->
    TreeItem = case ets:lookup(TreeTab, CallTree) of
                [] -> {Time, 1, CallTree};
                [{PrevTime, Count, _}] -> {PrevTime + Time, Count + 1, CallTree}
            end,
    ets:insert(TreeTab, TreeItem).

-spec reduce_call_trees(ets:tid()) -> true.
reduce_call_trees(TreeTab) ->
    ets:foldl(fun reduce_tree_item/2, TreeTab, TreeTab).

-spec reduce_tree_item(tree_item(), ets:tid()) -> ok.
reduce_tree_item({_, Count, #node{children = Children}}, TreeTab) ->
    [reduce_subtree(Child, Count, TreeTab) || Child <- Children],
    TreeTab.

-spec reduce_subtree(tree(), count(), ets:tid()) -> any().
reduce_subtree(Node, Count, TreeTab) ->
    case ets:lookup(TreeTab, Node) of
        [{_, Count, _} = Item] ->
            reduce_tree_item(Item, TreeTab),
            ets:delete(TreeTab, Node);
        [{_, OtherCount, _}] when OtherCount > Count  ->
            has_more_callers;
        [] ->
            already_deleted
    end.

-spec top_call_trees() -> [tree_item()].
top_call_trees() ->
    top_call_trees(#{}).

-spec top_call_trees(top_call_trees_options() | ets:tid()) -> [tree_item()].
top_call_trees(Options) when is_map(Options) ->
    TreeTab = call_tree_stat(),
    case maps:get(output, Options, reduced) of
        reduced -> reduce_call_trees(TreeTab);
        complete -> ok
    end,
    TopTrees = top_call_trees(TreeTab, Options),
    ets:delete(TreeTab),
    TopTrees;
top_call_trees(TreeTab) ->
    top_call_trees(TreeTab, #{}).

-spec top_call_trees(ets:tid(), top_call_trees_options()) -> [tree_item()].
top_call_trees(TreeTab, Options) ->
    MaxSize = maps:get(max_size, Options, 10),
    MinCount = maps:get(min_count, Options, 2),
    MinTime = maps:get(min_time, Options, 0),
    Set = ets:foldl(fun(TreeItem = {Time, Count, _}, T) when Count >= MinCount, Time >= MinTime ->
                            insert_top_call_trees_item(TreeItem, T, MaxSize);
                       (_, T) ->
                            T
                    end, gb_sets:empty(), TreeTab),
    lists:reverse(lists:sort(gb_sets:to_list(Set))).

-spec insert_top_call_trees_item(tree_item(), gb_sets:set(tree_item()), pos_integer()) ->
          gb_sets:set(tree_item()).
insert_top_call_trees_item(TreeItem, Set, MaxSize) ->
    NewSet = gb_sets:add(TreeItem, Set),
    case gb_sets:size(NewSet) of
        N when N =< MaxSize ->
            NewSet;
        N when N =:= MaxSize + 1 ->
            {_, ReducedSet} = gb_sets:take_smallest(NewSet),
            ReducedSet
    end.

%% Helpers

-spec initial_index() -> index().
initial_index() ->
    0.

-spec next_index(index()) -> index().
next_index(I) ->
    I + 1.

default_tab() ->
    trace.

foldl(F, InitialState, List) when is_list(List) -> lists:foldl(F, InitialState, List);
foldl(F, InitialState, Tab) -> ets:foldl(F, InitialState, Tab).

maybe_length(L) when is_list(L) -> length(L);
maybe_length(I) when is_integer(I) -> I.

pretty_print_tuple_list(TList, MaxRows) ->
    Head = lists:sublist(TList, MaxRows),
    MaxSize = lists:max([tuple_size(T) || T <- Head]),
    L = [pad([lists:flatten(io_lib:format("~p", [Item])) || Item <- tuple_to_list(T)], MaxSize) || T <- Head],
    Widths = lists:foldl(fun(T, CurWidths) ->
                                 [max(W, length(Item)+2) || {W, Item} <- lists:zip(CurWidths, T)]
                         end, lists:duplicate(MaxSize, 2), L),
    [begin
         X = [[Item, lists:duplicate(W-length(Item), $ )] || {W, Item} <- lists:zip(Widths, T)],
         io:format("~s~n", [X])
     end || T<- L],
    ok.

pad(L, Size) when length(L) < Size -> L ++ lists:duplicate(Size-length(L), "");
pad(L, _) -> L.

usec_from_now({MegaSecs, Secs, Usecs}) ->
    (MegaSecs * 1000000 + Secs) * 1000000 + Usecs.
