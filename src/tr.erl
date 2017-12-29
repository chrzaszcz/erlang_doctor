-module(tr).

-compile(export_all).

-behaviour(gen_server).

-include("tr.hrl").

%% mem_usage() ->
%%     Ps = processes(),
%%     Stat = [{F, Mem, Count, Mem * Count}
%%             || {{F, Mem}, Count} <- maps:to_list(stat(Ps, fun mem_usage_key/1))],
%%     lists:reverse(lists:keysort(4, Stat)).

mem_usage_key(Pid) ->
    list_to_tuple([element(2, process_info(Pid, Attr)) || Attr <- key_attrs()]).

key_attrs() ->
    [current_function, memory].

trace_calls(Modules) ->
    gen_server:call(?MODULE, {start_trace, call, Modules}).

stop_tracing_calls() ->
    gen_server:call(?MODULE, {stop_trace, call}).

load(File) ->
    gen_server:call(?MODULE, {load, File}).

dump(File) ->
    gen_server:call(?MODULE, {dump, File}).


clean() ->
    gen_server:call(?MODULE, clean).

%% called_functions() ->
%%     ets_stat(trace, fun({_Pid, call, MFA, _TS}) -> mfarity(MFA) end).

%% calling_pids() ->
%%     ets_stat(trace, fun({Pid, call, _MFA, _TS}) -> Pid end).

%% calls() ->
%%     ets_stat(trace, fun({Pid, call, MFA, _TS}) -> {Pid, mfarity(MFA)} end).

flat_call_times_by_function() ->
    [{F,lists:foldl(fun({_Pid, Count, _, Time}, {TotalCount, TotalTime}) ->
                            {TotalCount + Count, TotalTime + Time}
                    end, {0, 0}, CallTimes)}
     || {F, {call_time, CallTimes}} <- raw_call_times_by_function()].

raw_call_times_by_function() ->
    [{F,erlang:trace_info(F, call_time)} || {F,_} <- maps:to_list(?MODULE:called_functions())].

%% gen_server callbacks

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec start() -> {ok, pid()}.
start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

-spec init(list()) -> {ok, map()}.
init(_Opts) ->
    ets:new(trace, [named_table, public, ordered_set, {keypos, 2}]),
    State = #{index => initial_index(), traced_modules => []},
    {ok, State}.

-spec handle_call(any(), {pid(), any()}, map()) -> {reply, ok, map()}.
handle_call({start_trace, call, Modules}, _From, State) ->
    [enable_trace_pattern(Mod) || Mod <- Modules],
    erlang:trace(all, true, [call, timestamp]),
    {reply, ok, State#{traced_modules := Modules}};
handle_call({stop_trace, call}, _From, State = #{traced_modules := Modules}) ->
    erlang:trace(all, false, [call, timestamp]),
    [disable_trace_pattern(Mod) || Mod <- Modules],
    {reply, ok, State#{traced_modules := []}};
handle_call(clean, _From, State) ->
    ets:delete_all_objects(trace),
    {reply, ok, State};
handle_call({dump, File}, _From, State) ->
    ets:rename(trace, trace_dump),
    Reply = ets:tab2file(trace_dump, File),
    ets:rename(trace_dump, trace),
    {reply, Reply, State};
handle_call({load, File}, _From, State) ->
    {NewState, Reply} =
        case ets:file2tab(File) of
            {ok, trace_dump} ->
                ets:delete(trace),
                ets:rename(trace_dump, trace),
                Index =
                    case ets:last(trace) of
                        I when is_integer(I) ->
                            I;
                        _ ->
                            initial_index()
                    end,
                {State#{index := Index}, ok};
            Error ->
                {State, Error}
        end,
    {reply, Reply, NewState};
handle_call(Req, From, State) ->
    error_logger:error_msg("Unexpected call ~p from ~p.", [Req, From]),
    {reply, ok, State}.

-spec handle_cast(any(), map()) -> {noreply, map()}.
handle_cast(Msg, State) ->
    error_logger:error_msg("Unexpected message ~p.", [Msg]),
    {noreply, State}.

-spec handle_info(any(), map()) -> {noreply, map()}.
handle_info({trace_ts, Pid, call, MFA = {_, _, Args}, TS}, #{index := I} = State) ->
    NextIndex = next_index(I),
    ets:insert(trace, #tr{index = NextIndex, pid = Pid, event = call, mfarity = mfarity(MFA), data = Args,
                          ts = usec:from_now(TS)}),
    {noreply, State#{index := NextIndex}};
handle_info({trace_ts, Pid, return_from, MFArity, Res, TS}, #{index := I} = State) ->
    NextIndex = next_index(I),
    ets:insert(trace, #tr{index = NextIndex, pid = Pid, event = return_from, mfarity = MFArity, data = Res,
                          ts = usec:from_now(TS)}),
    {noreply, State#{index := NextIndex}};
handle_info({trace_ts, Pid, exception_from, MFArity, {Class, Value}, TS}, #{index := I} = State) ->
    NextIndex = next_index(I),
    ets:insert(trace, #tr{index = NextIndex, pid = Pid, event = exception_from, mfarity = MFArity, data = {Class, Value},
                          ts = usec:from_now(TS)}),
    {noreply, State#{index := NextIndex}};
handle_info(Msg, State) ->
    error_logger:error_msg("Unexpected message ~p.", [Msg]),
    {noreply, State}.

-spec terminate(any(), map()) -> ok.
terminate(_Reason, #{}) ->
    ok.

-spec code_change(any(), map(), any()) -> {ok, map()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

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

%% Call stat

print_sorted_call_stat(KeyF, Length) ->
    pretty_print_tuple_list(sorted_call_stat(KeyF), Length).

sorted_call_stat(KeyF) ->
    lists:reverse(sort_by_time(call_stat(KeyF))).

call_stat(KeyF) ->
    {#{}, #{}, Stat} = ets:foldl(pa:bind(fun process_trace/3, KeyF), {#{}, #{}, #{}}, trace),
    Stat.

sort_by_time(MapStat) ->
    lists:keysort(3, [{Key, Count, AccTime, OwnTime} || {Key, {Count, AccTime, OwnTime}} <- maps:to_list(MapStat)]).

%% Trace inside function calls

trace_inside_calls(PredF) ->
    {Traces, #{}} = ets:foldl(pa:bind(fun trace_inside_call/3, PredF), {[], #{}}, trace),
    lists:reverse(Traces).

trace_inside_call(PredF, T = #tr{pid = Pid}, {Traces, State}) ->
    PidState = maps:get(Pid, State, no_state),
    case trace_pid_inside_call(PredF, T, PidState) of
        {complete, Trace} -> {[{Pid, Trace}|Traces], maps:remove(Pid, State)};
        {incomplete, NewPidState} -> {Traces, State#{Pid => NewPidState}};
        none -> {Traces, State}
    end.

trace_pid_inside_call(_PredF, T = #tr{event = call, mfarity = MFArity}, State = #{depth := Depth,
                                                                                  mfarity := MFArity,
                                                                                  trace := Trace}) ->
    {incomplete, State#{depth => Depth + 1, trace => [T|Trace]}};
trace_pid_inside_call(_PredF, T = #tr{event = call}, State = #{trace := Trace}) ->
    {incomplete, State#{trace => [T|Trace]}};
trace_pid_inside_call(PredF, T = #tr{pid = Pid, event = call, mfarity = MFArity, data = Args}, no_state) ->
    case catch PredF(Pid, MFArity, Args) of
        true -> {incomplete, #{depth => 1, mfarity => MFArity, trace => [T]}};
        _ -> none
    end;
trace_pid_inside_call(_PredF, T = #tr{event = Event, mfarity = MFArity}, #{depth := 1,
                                                                           mfarity := MFArity,
                                                                           trace := Trace})
  when Event =:= return_from;
       Event =:= exception_from ->
    {complete, lists:reverse([T|Trace])};
trace_pid_inside_call(_PredF, T = #tr{event = Event, mfarity = MFArity}, State = #{depth := Depth,
                                                                                   mfarity := MFArity,
                                                                                   trace := Trace})
  when Event =:= return_from;
       Event =:= exception_from ->
    {incomplete, State#{depth => Depth - 1, trace => [T|Trace]}};
trace_pid_inside_call(_PredF, T = #tr{event = Event}, State = #{trace := Trace})
  when Event =:= return_from;
       Event =:= exception_from ->
    {incomplete, State#{trace := [T|Trace]}};
trace_pid_inside_call(_PredF, #tr{event = Event}, no_state)
  when Event =:= return_from;
       Event =:= exception_from ->
    none.

%% Helpers

%% stat(Items, KeyF) ->
%%     lists:foldl(pa:bind(fun count_item/3, KeyF), #{}, Items).

%% ets_stat(Items, KeyF) ->
%%     ets:foldl(pa:bind(fun count_item/3, KeyF), #{}, Items).

-spec initial_index() -> non_neg_integer().
initial_index() ->
    0.

-spec next_index(non_neg_integer()) -> non_neg_integer().
next_index(I) ->
    I + 1.

process_item(UpdateF, KeyF, Init, ItemK, ItemV, Stat) ->
    process_item(UpdateF, KeyF, Init, {ItemK, ItemV}, Stat).

ets_stat(Tab, KeyF, UpdateF, Init) ->
    ets:foldl(pa:bind(fun process_item/5, UpdateF, KeyF, Init), #{}, Tab).

process_item(UpdateF, KeyF, Init, Item, Stat) ->
    case KeyF(Item) of
        {ok, Key} ->
            V = maps:get(Key, Stat, Init),
            Stat#{Key => UpdateF(V, Item)};
        ignore ->
            Stat
    end.

process_trace(KeyF, Tr = #tr{pid = Pid}, {ProcessStates, TmpStat, Stat}) ->
    {LastTr, LastKey, Stack} = maps:get(Pid, ProcessStates, {#tr{pid = Pid}, no_key, []}),
    {NewStack, Key} = get_key_and_update_stack(KeyF, Stack, Tr),
    TmpKey = tmp_key(Tr, Key),
    TmpValue = maps:get(TmpKey, TmpStat, none),
    ProcessStates1 = ProcessStates#{Pid => {Tr, Key, NewStack}},
    TmpStat1 = update_tmp(TmpStat, Tr, TmpKey, TmpValue),
    Stat1 = update_stat(Stat, LastTr, LastKey, Tr, Key, TmpValue),
    {ProcessStates1, TmpStat1, Stat1}.

-define(is_return(Event), (Event =:= return_from orelse Event =:= exception_from)).

get_key_and_update_stack(KeyF, Stack, #tr{event = call, pid = Pid, mfarity = MFArity, data = Args}) ->
    MFA = mfa(MFArity, Args),
    Key = try KeyF(Pid, MFA)
          catch _:_ -> no_key
          end,
    {[Key | Stack], Key};
get_key_and_update_stack(_KeyF, [Key | Rest], #tr{event = Event}) when ?is_return(Event) ->
    {Rest, Key};
get_key_and_update_stack(_, [], #tr{event = Event, mfarity = MFA}) when ?is_return(Event) ->
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
own_time_key(#tr{}, _, #tr{event = Event}, Key) when ?is_return(Event), Key =/= no_key -> Key;
own_time_key(#tr{}, _, #tr{}, _) -> no_key.

mfarity({M, F, A}) -> {M, F, maybe_length(A)}.

mfa({M, F, Arity}, Args) when length(Args) =:= Arity -> {M, F, Args}.

maybe_length(L) when is_list(L) -> length(L);
maybe_length(I) when is_integer(I) -> I.

app_modules(AppName) ->
    AppNameStr = atom_to_list(AppName),
    [P]=lists:filter(fun(Path) -> string:str(Path, AppNameStr) > 0 end, code:get_path()),
    {ok, FileNames} = file:list_dir(P),
    [list_to_atom(lists:takewhile(fun(C) -> C =/= $. end, Name)) || Name <- FileNames].

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
