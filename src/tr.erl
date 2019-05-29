-module(tr).

-behaviour(gen_server).

%% API - capturing, data manipulation
-export([start_link/0, start_link/1,
         start/0, start/1,
         trace_calls/1,
         stop_tracing_calls/0,
         tab/0,
         set_tab/1,
         load/1,
         dump/1,
         clean/0]).

%% API - analysis
-export([select/0, select/1, select/2,
         filter/1, filter/2,
         filter_tracebacks/1, filter_tracebacks/2,
         filter_ranges/1, filter_ranges/2,
         print_sorted_call_stat/2,
         sorted_call_stat/1,
         call_stat/1, call_stat/2]).

%% API - utilities
-export([contains_data/2,
         call_selector/1,
         do/1,
         app_modules/1,
         mfarity/1,
         mfa/2]).

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
             event :: call | return_from | exception_from,
             mfa :: {module(), atom(), non_neg_integer()},
             data :: term(),
             ts :: integer()}).

-define(is_return(Event), (Event =:= return_from orelse Event =:= exception_from)).

-type tr() :: #tr{}.
-type pred() :: fun((tr()) -> boolean()).
-type selector() :: fun((tr()) -> term()).
-type call_count() :: non_neg_integer().
-type acc_time() :: non_neg_integer().
-type own_time() :: non_neg_integer().

%% API - capturing, data manipulation

-spec start_link() -> {ok, pid()}.
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> {ok, pid()}.
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

-spec start() -> {ok, pid()}.
start() ->
    start(#{}).

-spec start(map()) -> {ok, pid()}.
start(Opts) ->
    gen_server:start({local, ?MODULE}, ?MODULE, Opts, []).

-define(is_trace(Tr), element(1, (Tr)) =:= trace orelse element(1, (Tr)) =:= trace_ts).

-spec trace_calls([module()] | [{module(), atom(), non_neg_integer()}]) -> ok.
trace_calls(Modules) ->
    gen_server:call(?MODULE, {start_trace, call, Modules}).

-spec stop_tracing_calls() -> ok.
stop_tracing_calls() ->
    gen_server:call(?MODULE, {stop_trace, call}).

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

%% Returns tracebacks: [Call1, ..., CallN] when PredF(CallN)
-spec filter_tracebacks(pred()) -> [[tr()]].
filter_tracebacks(PredF) ->
    filter_tracebacks(PredF, tab()).

-spec filter_tracebacks(pred(), atom() | [tr()]) -> [[tr()]].
filter_tracebacks(PredF, Tab) ->
    InitialState = #{traces => [], call_stacks => #{}},
    #{traces := Traces} =
        foldl(fun(T, State) -> filter_tracebacks_step(PredF, T, State) end, InitialState, Tab),
    lists:reverse(Traces).

%% Returns ranges (subtrees): [Call, ..., Return] when PredF(Call)
-spec filter_ranges(pred()) -> [[tr()]].
filter_ranges(PredF) ->
    filter_ranges(PredF, tab()).

-spec filter_ranges(pred(), atom() | [tr()]) -> [[tr()]].
filter_ranges(PredF, Tab) ->
    {Traces, #{}} = foldl(fun(T, S) -> filter_ranges_step(PredF, T, S) end, {[], #{}}, Tab),
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
do(#tr{event = call, mfa = {M, F, Arity}, data = Args}) when length(Args) =:= Arity ->
    apply(M, F, Args).

-spec app_modules(atom()) -> [atom()].
app_modules(AppName) ->
    AppNameStr = atom_to_list(AppName),
    [P]=lists:filter(fun(Path) -> string:str(Path, AppNameStr) > 0 end, code:get_path()),
    {ok, FileNames} = file:list_dir(P),
    [list_to_atom(lists:takewhile(fun(C) -> C =/= $. end, Name)) || Name <- FileNames].

-spec mfarity({M, F, Arity | Args}) -> {M, F, Arity} when M :: atom(),
                                                          F :: atom(),
                                                          Arity :: non_neg_integer(),
                                                          Args :: list().
mfarity({M, F, A}) -> {M, F, maybe_length(A)}.

-spec mfa({M, F, Arity}, Args) -> {M, F, Args} when M :: atom(),
                                                    F :: atom(),
                                                    Arity :: non_neg_integer(),
                                                    Args :: list().
mfa({M, F, Arity}, Args) when length(Args) =:= Arity -> {M, F, Args}.

%% gen_server callbacks

-spec init(map()) -> {ok, map()}.
init(Opts) ->
    DefaultState = #{tab => default_tab(), index => initial_index(), traced_modules => []},
    State = #{tab := Tab} = maps:merge(DefaultState, Opts),
    create_tab(Tab),
    {ok, maps:merge(State, Opts)}.

-spec handle_call(any(), {pid(), any()}, map()) -> {reply, ok, map()}.
handle_call({start_trace, call, Modules}, _From, State = #{traced_modules := []}) ->
    [enable_trace_pattern(Mod) || Mod <- Modules],
    erlang:trace(all, true, [call, timestamp]),
    {reply, ok, State#{traced_modules := Modules}};
handle_call({stop_trace, call}, _From, State = #{traced_modules := Modules}) ->
    erlang:trace(all, false, [call, timestamp]),
    [disable_trace_pattern(Mod) || Mod <- Modules],
    {reply, ok, State#{traced_modules := []}};
handle_call(clean, _From, State = #{tab := Tab}) ->
    ets:delete_all_objects(Tab),
    {reply, ok, State};
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
    error_logger:error_msg("Unexpected call ~p from ~p.", [Req, From]),
    {reply, ok, State}.

-spec handle_cast(any(), map()) -> {noreply, map()}.
handle_cast(Msg, State) ->
    error_logger:error_msg("Unexpected message ~p.", [Msg]),
    {noreply, State}.

-spec handle_info(any(), map()) -> {noreply, map()}.

handle_info(Trace, State) when ?is_trace(Trace) ->
    {noreply, handle_trace(Trace, State)};
handle_info(Msg, State) ->
    error_logger:error_msg("Unexpected message ~p.", [Msg]),
    {noreply, State}.

handle_trace({trace_ts, Pid, call, MFA = {_, _, Args}, TS}, #{tab := Tab, index := I} = State) ->
    NextIndex = next_index(I),
    ets:insert(Tab, #tr{index = NextIndex, pid = Pid, event = call, mfa = mfarity(MFA), data = Args,
                        ts = usec_from_now(TS)}),
    State#{index := NextIndex};
handle_trace({trace_ts, Pid, return_from, MFArity, Res, TS}, #{tab := Tab, index := I} = State) ->
    NextIndex = next_index(I),
    ets:insert(Tab, #tr{index = NextIndex, pid = Pid, event = return_from, mfa = MFArity, data = Res,
                        ts = usec_from_now(TS)}),
    State#{index := NextIndex};
handle_trace({trace_ts, Pid, exception_from, MFArity, {Class, Value}, TS}, #{tab := Tab, index := I} = State) ->
    NextIndex = next_index(I),
    ets:insert(Tab, #tr{index = NextIndex, pid = Pid, event = exception_from, mfa = MFArity, data = {Class, Value},
                        ts = usec_from_now(TS)}),
    State#{index := NextIndex};
handle_trace(Msg, State) ->
    error_logger:error_msg("Unexpected message ~p.", [Msg]),
    State.

-spec terminate(any(), map()) -> ok.
terminate(_Reason, #{}) ->
    ok.

-spec code_change(any(), map(), any()) -> {ok, map()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
%%-------------------

create_tab(Tab) ->
    ets:new(Tab, [named_table, public, ordered_set, {keypos, 2}]).

select(_MS, _DataVal, DataAcc, '$end_of_table') ->
    lists:append(lists:reverse(DataAcc));
select(MS, DataVal, DataAcc, {Matched, Cont}) ->
    Filtered = lists:filter(fun(T) -> contains_data(DataVal, T) end, Matched),
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

enable_trace_pattern(Mod) ->
    {MFA, Opts} = trace_pattern_and_opts(Mod),
    erlang:trace_pattern(MFA, [{'_', [], [{exception_trace}]}], Opts).

disable_trace_pattern(Mod) ->
    {MFA, Opts} = trace_pattern_and_opts(Mod),
    erlang:trace_pattern(MFA, false, Opts).

trace_pattern_and_opts(Mod) when is_atom(Mod) -> trace_pattern_and_opts({Mod, '_', '_'});
trace_pattern_and_opts({_, _, _} = MFA) -> {MFA, [local, call_time]};
trace_pattern_and_opts({Mod, Opts}) when is_atom(Mod) -> {{Mod, '_', '_'}, Opts};
trace_pattern_and_opts({{_M, _F, _A} = MFA, Opts}) -> {MFA, Opts}.

%% Filter tracebacks

filter_tracebacks_step(PredF, T = #tr{pid = Pid, event = Event},
                       State = #{traces := Traces, call_stacks := CallStacks}) ->
    CallStack = maps:get(Pid, CallStacks, []),
    NewStack = update_call_stack(T, CallStack),
    NewTraces = case catch PredF(T) of
                    true when Event =:= call -> [lists:reverse(NewStack)];
                    true when ?is_return(Event) -> [lists:reverse(CallStack)];
                    _ -> []
                end,
    State#{traces := NewTraces ++ Traces, call_stacks := CallStacks#{Pid => NewStack}}.

update_call_stack(T = #tr{event = call}, Stack) -> [T|Stack];
update_call_stack(#tr{event = Event, mfa = MFArity}, [#tr{mfa = MFArity} | Stack])
  when ?is_return(Event) ->
    Stack;
update_call_stack(#tr{event = Event, mfa = {M, F, Arity}}, Stack) when ?is_return(Event) ->
    error_logger:warning_msg("Found a return trace from ~p:~p/~p without a call trace", [M, F, Arity]),
    Stack.

%% Filter ranges

filter_ranges_step(PredF, T = #tr{pid = Pid}, {Traces, State}) ->
    PidState = maps:get(Pid, State, no_state),
    case filter_range(PredF, T, PidState) of
        {complete, Trace} -> {[Trace | Traces], maps:remove(Pid, State)};
        {incomplete, NewPidState} -> {Traces, State#{Pid => NewPidState}};
        none -> {Traces, State}
    end.

filter_range(_PredF, T = #tr{event = call, mfa = MFArity},
             State = #{depth := Depth, mfarity := MFArity, trace := Trace}) ->
    {incomplete, State#{depth => Depth + 1, trace => [T|Trace]}};
filter_range(_PredF, T = #tr{event = call}, State = #{trace := Trace}) ->
    {incomplete, State#{trace => [T|Trace]}};
filter_range(PredF, T = #tr{event = call, mfa = MFArity}, no_state) ->
    case catch PredF(T) of
        true -> {incomplete, #{depth => 1, mfarity => MFArity, trace => [T]}};
        _ -> none
    end;
filter_range(_PredF, T = #tr{event = Event, mfa = MFArity},
             #{depth := 1, mfarity := MFArity, trace := Trace}) when ?is_return(Event) ->
    {complete, lists:reverse([T|Trace])};
filter_range(_PredF, T = #tr{event = Event, mfa = MFArity},
             State = #{depth := Depth, mfarity := MFArity, trace := Trace}) when ?is_return(Event) ->
    {incomplete, State#{depth => Depth - 1, trace => [T|Trace]}};
filter_range(_PredF, T = #tr{event = Event}, State = #{trace := Trace}) when ?is_return(Event) ->
    {incomplete, State#{trace := [T|Trace]}};
filter_range(_PredF, #tr{event = Event}, no_state) when ?is_return(Event) ->
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
    error_logger:warning_msg("Found a return trace from ~p:~p/~p without a call trace", [M, F, A]),
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

%% Helpers

-spec initial_index() -> non_neg_integer().
initial_index() ->
    0.

-spec next_index(non_neg_integer()) -> non_neg_integer().
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
