%% @doc Erlang Doctor API module.
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
         roots/1, root/1,
         range/1, range/2,
         ranges/1, ranges/2,
         call_tree_stat/0, call_tree_stat/1,
         reduce_call_trees/1,
         top_call_trees/0, top_call_trees/1, top_call_trees/2,
         print_sorted_call_stat/1, print_sorted_call_stat/2,
         sorted_call_stat/1, sorted_call_stat/2,
         call_stat/1, call_stat/2]).

%% API - utilities
-export([match_data/2, contains_data/2, contains_val/2, match_val/2,
         do/1,
         lookup/1,
         next/1, seq_next/1, next/2, prev/1, seq_prev/1, prev/2,
         app_modules/1,
         mfarity/1,
         mfargs/2,
         ts/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-type recipient() :: {pid(), boolean()}. % Recipient pid with a boolean indicating if it exists.

%% copied, not included from tr.hrl to make it self-contained
-record(tr, {index :: index(),
             pid :: pid(),
             event :: call | return | exception | send | recv,
             mfa = no_mfa :: mfa() | no_mfa,
             data :: term(),
             ts :: integer(),
             info = no_info :: recipient() | no_info}).

-define(is_return(Event), (Event =:= return orelse Event =:= exception)).
-define(is_msg(Event), (Event =:= send orelse Event =:= recv)).

-type tr() :: #tr{}.
%% Trace record, storing one collected trace event.
%%
%% Record fields:
%% <ul>
%%  <li>`index' - {@link index()}</li>
%%  <li>`pid' - process in which the traced event occurred, {@link erlang:pid()}</li>
%%  <li>`event' - `call', `return' or `exception' for function traces; `send' or `recv' for messages.</li>
%%  <li>`mfa' - {@link erlang:mfa()} for function traces; `no_mfa' for messages.</li>
%%  <li>`data' - Argument list (for calls), returned value (for returns) or class and value (for exceptions).</li>
%%  <li>`ts' - Timestamp in microseconds.</li>
%%  <li>`info' - For `send' events it is a {@link recipient()} tuple; otherwise `no_info'.</li>
%% </ul>

-type pred(T) :: fun((T) -> boolean()).
%% Predicate returning `true' for matching terms of type `T'.
%%
%% For other terms, it can return a different value or fail.

-type selector(Data) :: fun((tr()) -> Data).
%% Trace selector function.
%%
%% For selected traces, it returns `Data'. For other traces, it should fail.

-type call_count() :: non_neg_integer(). % Total number of aggregated calls.
-type acc_time() :: non_neg_integer(). % Total accumulated time.
-type own_time() :: non_neg_integer(). % Total own time (without other called functions).
-type pids() :: [pid()] | all. % A list of processes to trace. Default: `all'.
-type limit() :: pos_integer() | infinity. % Maximum number of items.
-type index() :: pos_integer(). % Unique, auto-incremented identifier of a {@link tr()} record.
-type table() :: atom(). % ETS table name.
-type mfargs() :: {module(), atom(), list()}. % Module, function and arguments.

-type init_options() :: #{tab => table(), index => index(), limit => limit()}.
%% Initialization options.
%%
%% `tab' is the ETS table used for storing traces (default: `trace').
%% `index' is the index value of the first inserted trace (default: 1).
%% When size of `tab' reaches the optional `limit', tracing is stopped.

-type state() :: #{tab := table(),
                   index := index(),
                   limit := limit(),
                   trace := none | trace_spec(),
                   tracer_pid := none | pid()}.

-type trace_spec() :: #{modules := module_spec(),
                        pids := pids(),
                        msg := message_event_types(),
                        msg_trigger := msg_trigger()}.
-type trace_options() :: #{modules => module_spec(),
                           pids => pids(),
                           msg => message_event_types(),
                           msg_trigger => msg_trigger()}.
%% Options for tracing.

-type message_event_types() :: send | recv | all | none.
%% Message event types to trace. Default: `none'.

-type msg_trigger() :: after_traced_call | always.
%% Condition checked before collecting message traces for a process.
%%
%% `after_traced_call' (default) means that a process needs to call at least one traced
%% function before its message events start being collected.
%% `always' means that messages for all traced processes are collected.

-type module_spec() :: [module() | mfa()].
%% Specifies traced modules and/or individual functions. Default: `[]'.

-type erlang_trace_flags() :: [call | timestamp | send | 'receive'].
-type traced_pids_tab() :: none | ets:table().

-type tr_source() :: table() | [tr()].
%% Source of traces: an ETS table or a list of traces. Default: `tab()'.

-type range_options() :: #{tab => tr_source(),
                           max_depth => limit(),
                           output => range_output()}.
%% Options for trace ranges.
%%
%% Optional `limit' is the maximum depth of calls in the returned ranges.
%% All traces (including messages) exceeding that depth are skipped.

-type range_output() :: complete | incomplete | all.
%% Which ranges to return. Incomplete ranges are missing at least one return.
%% By default, all ranges are returned.

-type tb_options() :: #{tab => tr_source(),
                        output => tb_output(),
                        format => tb_format(),
                        order => tb_order(),
                        limit => limit()}.
%% Traceback options.
%%
%% Optional `limit' is the maximum number of tracebacks to collect
%% before filtering them according to `output'.

-type tb_output() :: shortest | longest | all.
%% Which tracebacks to return if they overlap. Default: `shortest'.

-type tb_format() :: list | tree | root.
%% Format in which tracebacks are returned.
%%
%% `list' (default) returns a list of tracebacks.
%% `tree' merges them into a list of trees.
%% `root' returns only the root of each tree.

-type tb_order() :: top_down | bottom_up.
%% Order of calls in each returned traceback. Default: `top_down'.

-type tb_tree() :: tr() | {tr(), [tb_tree()]}.
%% Multiple tracebacks with a common root merged into a tree structure.

-type tb_acc_tree() :: [{tr(), tb_acc_tree()}].
-type tb_acc_list() :: [[tr()]].
-type tb_acc() :: tb_acc_tree() | tb_acc_list().

-type sorted_call_stat_options() :: #{sort_by => call_stat_field(),
                                      order => order(),
                                      limit => limit()}.
%% Options for sorted call statistics.
%%
%% `sort_by' is the field to sort by (default: `acc_time').
%% `order' is ascending or descending (default: `desc').
%% `limit' is the maximum number of rows returned (default: `infinity').

-type order() :: asc | desc.
-type call_stat_field() :: count | acc_time | own_time.

-type call() :: {call, {module(), atom(), list()}}.
-type result() :: {return | exception, any()}. % Result of a function call.
-type simple_tr() :: call() | result().

-type call_tree_stat_options() :: #{tab => table()}.
-type call_tree_stat_state() :: #{pid_states := map(), tab := ets:tid()}.

-type pid_call_state() :: [tree() | call()].

-type top_call_trees_output() :: reduced | complete.
%% Specifies the behaviour for overlapping call trees.
%%
%% `reduced' (default) hides subtrees, while `complete' keeps them.

-type top_call_trees_options() :: #{max_size => pos_integer(),
                                    min_count => call_tree_count(),
                                    min_time => acc_time(),
                                    output => top_call_trees_output()}.
%% Options for repeated call tree statistics.
%%
%% `min_time' is an optional minimum accumulated time of a tree.
%% `min_count' (default: 2) specifies minimum number of repetitions of a tree.
%% `max_size' (default: 10) specifies maximum number of listed call trees.

-type call_tree_count() :: pos_integer(). % Number of occurrences of a given call tree.

-record(node, {module :: module(),
               function :: atom(),
               args = [] :: list(),
               children = [] :: [#node{}],
               result :: result()}).

-type tree() :: #node{}.
%% Function call tree node.
%%
%% Record fields:
%% <ul>
%%  <li>`module' - module name</li>
%%  <li>`function' - function name</li>
%%  <li>`args' - argument list</li>
%%  <li>`children' - a list of child nodes, each of them being {@link tree()}</li>
%%  <li>`result' - return value or exception, {@link result()}</li>
%% </ul>

-type tree_item() :: {acc_time(), call_tree_count(), tree()}.
%% Function call tree with its accumulated time and number of repetitions.

-type prev_next_options() :: #{tab => table(),
                               pred => pred(tr())}.
%% Options for obtaining previous and next traces.
%%
%% `tab' is the ETS table with traces (default: `trace').
%% `pred' allows to filter the matching traces (default: allow any trace)

-export_type([tr/0, index/0, recipient/0]).

%% API - capturing, data manipulation

%% @doc Starts `tr' as part of a supervision tree.
%% @see start/1
-spec start_link() -> {ok, pid()}.
start_link() ->
    start_link(#{}).

%% @doc Start `tr' as part of a supervision tree.
%% @see start/1
-spec start_link(init_options()) -> {ok, pid()}.
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%% @doc Starts `tr' as a stand-alone `gen_server'. Intended for interactive use.
%% @see start/1
-spec start() -> {ok, pid()}.
start() ->
    start(#{}).

%% @doc Starts `tr' as a stand-alone `gen_server'. Intended for interactive use.
%%
%% You can override the selected `Opts'.
-spec start(init_options()) -> {ok, pid()}.
start(Opts) ->
    gen_server:start({local, ?MODULE}, ?MODULE, Opts, []).

%% @doc Starts tracing of all modules in an application.
-spec trace_app(atom()) -> ok | {error, already_tracing}.
trace_app(App) ->
    trace_apps([App]).

%% @doc Starts tracing of all modules in all provided applications.
-spec trace_apps([atom()]) -> ok | {error, already_tracing}.
trace_apps(Apps) ->
    trace(lists:flatmap(fun app_modules/1, Apps)).

%% @doc Starts tracing of the specified functions/modules and/or message events.
%%
%% You can either provide a list of modules/functions or a more generic map of options.
-spec trace(module_spec() | trace_options()) -> ok | {error, already_tracing}.
trace(Modules) when is_list(Modules) ->
    trace(#{modules => Modules});
trace(Opts) ->
    DefaultOpts = #{modules => [], pids => all,
                    msg => none, msg_trigger => after_traced_call},
    Timeout = timer:minutes(1),
    gen_server:call(?MODULE, {start_trace, call, maps:merge(DefaultOpts, Opts)}, Timeout).

%% @doc Starts tracing of the specified functions/modules in specific processes.
-spec trace(module_spec(), pids()) -> ok | {error, already_tracing}.
trace(Modules, Pids) ->
    trace(#{modules => Modules, pids => Pids}).

%% @doc Stops tracing, disabling all trace specs.
%%
%% Any future messages from the Erlang tracer will be ignored.
-spec stop_tracing() -> ok | {error, not_tracing}.
stop_tracing() ->
    Timeout = timer:minutes(1),
    gen_server:call(?MODULE, {stop_trace, call}, Timeout).

%% @doc Stops the whole `tr' server process.
-spec stop() -> ok.
stop() ->
    gen_server:stop(?MODULE).

%% @doc Returns the name of the current ETS trace table in use.
-spec tab() -> table().
tab() ->
    gen_server:call(?MODULE, get_tab).

%% @doc Sets a new ETS table for collecting traces, creating it if it doesn't exist.
-spec set_tab(table()) -> ok.
set_tab(Tab) when is_atom(Tab) ->
    gen_server:call(?MODULE, {set_tab, Tab}).

%% @doc Loads an ETS trace table from a file, and makes it the current table.
%%
%% Overwrites the current table if it is empty.
-spec load(file:name_all()) -> {ok, table()} | {error, any()}.
load(File) when is_binary(File) ->
    load(binary_to_list(File));
load(File) when is_list(File) ->
    gen_server:call(?MODULE, {load, File}, timer:minutes(2)).

%% @doc Dumps the `tab()' table to a file.
-spec dump(file:name_all()) -> ok | {error, any()}.
dump(File) when is_binary(File) ->
    dump(binary_to_list(File));
dump(File) when is_list(File) ->
    gen_server:call(?MODULE, {dump, File}, timer:minutes(2)).

%% @doc Removes all traces from the current ETS table.
-spec clean() -> ok.
clean() ->
    gen_server:call(?MODULE, clean).

%% API - analysis

%% @doc Returns a list of all collected traces from `tab()'.
-spec select() -> [tr()].
select() ->
    ets:tab2list(tab()).

%% @doc Selects data from matching traces from `tab()' with `ets:fun2ms(F)'.
-spec select(selector(Data)) -> [Data].
select(F) ->
    ets:select(tab(), ets:fun2ms(F)).

%% @doc Selects data from matching traces from `tab()' with `ets:fun2ms(F)'.
%%
%% Additionally, the selected traces have to contain `DataVal' in `#tr.data'.
%% `DataVal' can occur in (possibly nested) tuples, maps or lists.
-spec select(selector(Data), term()) -> [Data].
select(F, DataVal) ->
    MS = ets:fun2ms(F),
    SelectRes = ets:select(tab(), MS, 1000),
    select(MS, DataVal, [], SelectRes).

%% @doc Returns matching traces from `tab()'.
-spec filter(pred(tr())) -> [tr()].
filter(F) ->
    filter(F, tab()).

%% @doc Returns matching traces from {@link tr_source()}.
-spec filter(pred(tr()), tr_source()) -> [tr()].
filter(F, Tab) ->
    Traces = foldl(fun(Tr, State) -> filter_trace(F, Tr, State) end, [], Tab),
    lists:reverse(Traces).

%% @doc Returns traceback of the first matching trace from {@link tr_source()}.
%%
%% Matching can be done with a predicate function, an index value or a `tr' record.
%% Fails if no trace is matched.
%%
%% @see traceback/2
-spec traceback(pred(tr()) | index() | tr()) -> [tr()].
traceback(Pred) ->
    traceback(Pred, #{}).

%% @doc Returns traceback of the first matching trace from {@link tr_source()}.
%%
%% Fails if no trace is matched.
%% The `limit' option does not apply.
-spec traceback(pred(tr()) | index() | tr(), tb_options()) -> [tr()] | tr() | tb_tree().
traceback(Index, Options) when is_integer(Index) ->
    traceback(fun(#tr{index = I}) -> Index =:= I end, Options);
traceback(T = #tr{}, Options) ->
    traceback(fun(Tr) -> Tr =:= T end, Options);
traceback(PredF, Options) when is_function(PredF, 1) ->
    [Result] = tracebacks(PredF, Options#{limit => 1}),
    Result.

%% @doc Returns tracebacks of all matching traces from `tab()'.
%%
%% @see tracebacks/2
-spec tracebacks(pred(tr())) -> [[tr()]].
tracebacks(PredF) ->
    tracebacks(PredF, #{}).

%% @doc Returns tracebacks of all matching traces from {@link tr_source()}.
-spec tracebacks(pred(tr()), tb_options()) -> [[tr()]] | [tr()] | [tb_tree()].
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

%% @doc Returns the root call of each {@link tb_tree()} from the provided list.
-spec roots([tb_tree()]) -> [tr()].
roots(Trees) ->
    lists:map(fun root/1, Trees).

%% @doc Returns the root call of the provided {@link tb_tree()}.
-spec root(tb_tree()) -> tr().
root(#tr{} = T) -> T;
root({#tr{} = T, _}) -> T.

%% @doc Returns a list of traces from `tab()' between the first matched call and the corresponding return.
%%
%% Matching can be done with a predicate function, an index value or a {@link tr()} record.
%% Fails if no trace is matched.
%%
%% @see range/2
-spec range(pred(tr()) | index() | tr()) -> [tr()].
range(PredF) ->
    range(PredF, #{}).

%% @doc Returns a list of traces from {@link tr_source()} between the first matched call and the corresponding return.
%%
%% Fails if no call is matched.
-spec range(pred(tr()) | index() | tr(), range_options()) -> [tr()].
range(Index, Options) when is_integer(Index) ->
    range(fun(#tr{index = I}) -> Index =:= I end, Options);
range(T = #tr{}, Options) ->
    range(fun(Tr) -> Tr =:= T end, Options);
range(PredF, Options) when is_function(PredF, 1) ->
    hd(ranges(PredF, Options)).

%% @doc Returns lists of traces from `tab()' between matched calls and corresponding returns.
%%
%% @see ranges/2
-spec ranges(pred(tr())) -> [[tr()]].
ranges(PredF) ->
    ranges(PredF, #{}).

%% @doc Returns lists of traces from {@link tr_source()} between matched calls and corresponding returns.
-spec ranges(pred(tr()), range_options()) -> [[tr()]].
ranges(PredF, Options) when is_map(Options) ->
    Tab = maps:get(tab, Options, tab()),
    Output = maps:get(output, Options, all),
    InitialState = maps:merge(#{traces => [], pid_states => #{}, max_depth => infinity}, Options),
    FinalState = foldl(fun(T, S) -> range_step(PredF, T, S) end, InitialState, Tab),
    complete_ranges(FinalState, Output) ++ incomplete_ranges(FinalState, Output).

complete_ranges(#{}, incomplete) ->
    [];
complete_ranges(#{traces := Traces}, Output) when Output =:= all;  Output =:= complete ->
    lists:reverse(Traces).

incomplete_ranges(#{}, complete) ->
    [];
incomplete_ranges(#{pid_states := States}, Output) when Output =:= all; Output =:= incomplete ->
    lists:sort([Range || #{trace := Range} <- maps:values(States)]).

%% @doc Prints sorted function call statistics for the selected traces from `tab()'.
%%
%% The statistics are sorted according to {@link acc_time()}, descending.
%% @see sorted_call_stat/1
%% @see print_sorted_call_stat/2
-spec print_sorted_call_stat(selector(_)) -> ok.
print_sorted_call_stat(KeyF) ->
    pretty_print_tuple_list(sorted_call_stat(KeyF)).

%% @doc Prints sorted function call statistics for the selected traces from `tab()'.
%%
%% The results can be sorted by call count or acc/own time, descending or ascending.
%% @see sorted_call_stat/2
-spec print_sorted_call_stat(selector(_), sorted_call_stat_options()) -> ok.
print_sorted_call_stat(KeyF, Options) ->
    pretty_print_tuple_list(sorted_call_stat(KeyF, Options)).

%% @doc Returns sorted function call statistics for the selected traces from `tab()'.
%%
%% The statistics are sorted according to {@link acc_time()}, descending.
%% @see call_stat/1
%% @see sorted_call_stat/2
-spec sorted_call_stat(selector(Key)) -> [{Key, call_count(), acc_time(), own_time()}].
sorted_call_stat(KeyF) ->
    sorted_call_stat(KeyF, #{}).

%% @doc Returns sorted function call statistics for the selected traces from `tab()'.
%%
%% The results can be sorted by call count or acc/own time, descending or ascending.
-spec sorted_call_stat(selector(Key), sorted_call_stat_options()) ->
    [{Key, call_count(), acc_time(), own_time()}].
sorted_call_stat(KeyF, Options) ->
    SortBy = maps:get(sort_by, Options, acc_time),
    Stat = sort_call_stat(SortBy, call_stat(KeyF)),
    OrderedStat = case maps:get(order, Options, desc) of
                      asc -> Stat;
                      desc -> lists:reverse(Stat)
                  end,
    case maps:get(limit, Options, infinity) of
        infinity -> OrderedStat;
        Limit when is_integer(Limit), Limit > 0 -> lists:sublist(OrderedStat, Limit)
    end.

%% @doc Returns call time statistics for traces selected from `tab()'.
%%
%% @see call_stat/2
-spec call_stat(selector(Key)) -> #{Key => {call_count(), acc_time(), own_time()}}.
call_stat(KeyF) ->
    call_stat(KeyF, tab()).

%% @doc Returns call time statistics for traces selected from {@link tr_source()}.
%%
%% Calls are aggregated by `Key' returned by `KeyF'.
-spec call_stat(selector(Key), tr_source()) -> #{Key => {call_count(), acc_time(), own_time()}}.
call_stat(KeyF, Tab) ->
    {#{}, State} = foldl(fun(Tr, State) -> call_stat_step(KeyF, Tr, State) end, {#{}, #{}}, Tab),
    State.

%% API - utilities

%% @doc Returns traces with `#tr.data' containing any values matching the provided predicate.
%%
%% The matching values can occur in (possibly nested) tuples, maps or lists.
-spec match_data(pred(term()), tr()) -> boolean().
match_data(Pred, #tr{data = Data}) when is_function(Pred, 1) ->
    match_val(Pred, Data).

%% @doc Returns traces containing `DataVal' in `#tr.data'.
%%
%% `DataVal' can occur in (possibly nested) tuples, maps or lists.
-spec contains_data(term(), tr()) -> boolean().
contains_data(DataVal, #tr{data = Data}) ->
    contains_val(DataVal, Data).

%% @doc Checks if `Val' contains any values matching the predicate `Pred'.
%%
%% The matching values can occur in (possibly nested) tuples, maps or lists.
-spec match_val(pred(T), T) -> boolean().
match_val(Pred, Val) ->
    case catch Pred(Val) of
        true ->
            true;
        _ ->
            case Val of
                [_|_] ->
                    lists:any(fun(El) -> match_val(Pred, El) end, Val);
                _ when is_tuple(Val) ->
                    match_val(Pred, tuple_to_list(Val));
                #{} when map_size(Val) > 0 ->
                    match_val(Pred, maps:to_list(Val));
                _ ->
                    false
            end
    end.

%% @doc Checks if the given value `DataVal' is present within `Data'.
%%
%% Returns `true' if `DataVal' is found, otherwise returns `false'.
%% `DataVal' can occur in (possibly nested) tuples, maps or lists.
-spec contains_val(T, T) -> boolean().
contains_val(DataVal, Data) ->
    match_val(fun(Val) -> Val =:= DataVal end, Data).

%% @doc Executes the function call for the provided {@link tr()} record or index.
-spec do(tr()) -> term().
do(Index) when is_integer(Index) ->
    do(lookup(Index));
do(#tr{event = call, mfa = {M, F, Arity}, data = Args}) when length(Args) =:= Arity ->
    apply(M, F, Args).

%% @doc Returns the {@link tr()} record from `tab()' for an index.
-spec lookup(index()) -> tr().
lookup(Index) when is_integer(Index) ->
    [T] = ets:lookup(tab(), Index),
    T.

%% Returns the next trace after the provided index or a trace record.
-spec next(index() | tr()) -> tr().
next(Index) when is_integer(Index) ->
    next(Index, #{});
next(#tr{index = Index}) ->
    next(Index, #{}).

%% Returns the next trace after the provided index or a trace record and from the same process.
-spec seq_next(index() | tr()) -> tr().
seq_next(Index) when is_integer(Index) ->
    seq_next(lookup(Index));
seq_next(#tr{index = Index, pid = Pid}) ->
    next(Index, #{pred => fun(#tr{pid = P}) -> P =:= Pid end}).

%% @doc Returns the next trace after the provided index or a trace record.
%% The traces can be filtered by the provided predicate.
-spec next(index() | tr(), prev_next_options()) -> tr().
next(Index, Options) when is_integer(Index) ->
    Pred = maps:get(pred, Options, fun(_) -> true end),
    Tab = maps:get(tab, Options, tab()),
    next(Index, Pred, Tab);
next(#tr{index = Index}, Options) ->
    next(Index, Options).

-spec next(index(), pred(tr()), table()) -> tr().
next(Index, Pred, Tab) ->
    case ets:lookup(Tab, ets:next(Tab, Index)) of
        [NextT = #tr{index = NextIndex}] ->
            case catch Pred(NextT) of
                true -> NextT;
                _ -> next(NextIndex, Pred, Tab)
            end;
        _ ->
            error(not_found, [Index, Pred, Tab])
    end.

%% Returns the previous trace before the provided index or a trace record.
-spec prev(index() | tr()) -> tr().
prev(Index) when is_integer(Index) ->
    prev(Index, #{});
prev(#tr{index = Index}) ->
    prev(Index, #{}).

%% Returns the previous trace before the provided index or a trace record and from the same process.
-spec seq_prev(index() | tr()) -> tr().
seq_prev(Index) when is_integer(Index) ->
    seq_prev(lookup(Index));
seq_prev(#tr{index = Index, pid = Pid}) ->
    prev(Index, #{pred => fun(#tr{pid = P}) -> P =:= Pid end}).

%% @doc Returns the previous trace before the provided index or a trace record.
%% The traces can be filtered by the provided predicate.
-spec prev(index() | tr(), prev_next_options()) -> tr().
prev(Index, Options) when is_integer(Index) ->
    Pred = maps:get(pred, Options, fun(_) -> true end),
    Tab = maps:get(tab, Options, tab()),
    prev(Index, Pred, Tab);
prev(#tr{index = Index}, Options) ->
    prev(Index, Options).

-spec prev(index(), pred(tr()), table()) -> tr().
prev(Index, Pred, Tab) ->
    case ets:lookup(Tab, ets:prev(Tab, Index)) of
        [PrevT = #tr{index = PrevIndex}] ->
            case catch Pred(PrevT) of
                true -> PrevT;
                _ -> prev(PrevIndex, Pred, Tab)
            end;
        _ ->
            error(not_found, [Index, Pred, Tab])
    end.

%% @doc Returns all module names for an application.
-spec app_modules(atom()) -> [module()].
app_modules(AppName) ->
    Path = filename:join(code:lib_dir(AppName), ebin),
    {ok, FileNames} = file:list_dir(Path),
    BeamFileNames = lists:filter(fun(Name) -> filename:extension(Name) =:= ".beam" end, FileNames),
    [list_to_atom(filename:rootname(Name)) || Name <- BeamFileNames].

%% @doc Replaces arguments with arity in an MFA tuple.
-spec mfarity(mfa() | mfargs()) -> mfa().
mfarity({M, F, A}) -> {M, F, maybe_length(A)}.

%% @doc Replaces arity with `Args' in an MFA tuple.
-spec mfargs(mfa(), list()) -> mfargs().
mfargs({M, F, Arity}, Args) when length(Args) =:= Arity -> {M, F, Args}.

%% @doc Returns human-readable timestamp according to RFC 3339.
-spec ts(tr()) -> string().
ts(#tr{ts = TS}) -> calendar:system_time_to_rfc3339(TS, [{unit, microsecond}]).

%% gen_server callbacks

%% @private
-spec init(init_options()) -> {ok, state()}.
init(Opts) ->
    process_flag(trap_exit, true),
    Defaults = #{tab => default_tab(),
                 index => initial_index(),
                 limit => application:get_env(erlang_doctor, limit, infinity)},
    FinalOpts = #{tab := Tab} = maps:merge(Defaults, Opts),
    State = maps:merge(FinalOpts, #{trace => none, tracer_pid => none}),
    create_tab(Tab),
    {ok, State}.

%% @private
-spec handle_call(any(), {pid(), any()}, state()) -> {reply, ok | {error, atom()}, state()}.
handle_call({start_trace, call, Spec}, _From, State = #{trace := none, tracer_pid := none}) ->
    {reply, ok, start_trace(State, Spec)};
handle_call({start_trace, call, _Spec}, _From, State = #{trace := none}) ->
    {reply, {error, tracer_not_terminated}, State};
handle_call({start_trace, call, _Spec}, _From, State = #{}) ->
    {reply, {error, already_tracing}, State};
handle_call({stop_trace, call}, _From, State = #{trace := none}) ->
    {reply, {error, not_tracing}, State};
handle_call({stop_trace, call}, _From, State = #{trace := #{}}) ->
    {reply, ok, stop_trace(State)};
handle_call(clean, _From, State = #{tab := Tab}) ->
    ets:delete_all_objects(Tab),
    {reply, ok, State#{index := index(Tab)}};
handle_call({dump, File}, _From, State = #{tab := Tab}) ->
    Reply = ets:tab2file(Tab, File),
    {reply, Reply, State};
handle_call({load, File}, _From, State) ->
    Tab = maps:get(tab, State),
    Reply = case {ets:info(Tab, id), ets:info(Tab, size)} of
        {undefined, _} ->
            ets:file2tab(File);
        {_, 0} ->
            ets:delete(Tab),
            ets:file2tab(File);
        _ ->
            {error, {non_empty_trace_table, Tab}}
    end,
    NewState = case Reply of
                   {ok, NewTab} -> State#{tab := NewTab, index := index(NewTab)};
                   _ -> State
               end,
    {reply, Reply, NewState};
handle_call(get_tab, _From, State = #{tab := Tab}) ->
    {reply, Tab, State};
handle_call({set_tab, NewTab}, _From, State) ->
    case ets:info(NewTab) of
        undefined -> create_tab(NewTab);
        [_|_] -> ok
    end,
    {reply, ok, State#{tab := NewTab, index := index(NewTab)}};
handle_call(Req, From, State) ->
    logger:error("Unexpected call ~p from ~p.", [Req, From]),
    {reply, ok, State}.

%% @private
-spec handle_cast(any(), state()) -> {noreply, state()}.
handle_cast(Msg, State) ->
    logger:error("Unexpected message ~p.", [Msg]),
    {noreply, State}.

%% @private
-spec handle_info(any(), state()) -> {noreply, state()}.
handle_info({'EXIT', TracerPid, Reason}, State = #{tracer_pid := TracerPid}) ->
    logger:warning("Tracer process ~p exited with reason ~p.", [TracerPid, Reason]),
    {noreply, disable_trace_patterns(State#{tracer_pid := none})};
handle_info(Msg, State) ->
    logger:error("Unexpected message ~p.", [Msg]),
    {noreply, State}.

%% @private
-spec terminate(any(), state()) -> ok.
terminate(_Reason, #{trace := none}) ->
    ok;
terminate(_, State) ->
    stop_trace(State),
    ok.

%% @private
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
    Filtered = lists:filter(fun(T) -> contains_data(DataVal, T) end, Matched),
    SelectRes = ets:select(Cont),
    select(MS, DataVal, [Filtered | DataAcc], SelectRes).

filter_trace(F, T, State) ->
    case catch F(T) of
        true -> [T | State];
        _ -> State
    end.

index(Tab) ->
    case ets:last(Tab) of
        I when is_integer(I) -> I + 1;
        _ -> initial_index()
    end.

-spec start_trace(state(), trace_spec()) -> state().
start_trace(State, Spec = #{modules := ModSpecs, pids := Pids}) ->
    TracerPid = spawn_link(fun() -> start_tracer_loop(State, Spec) end),
    [enable_trace_pattern(ModSpec) || ModSpec <- ModSpecs],
    set_tracing(Pids, true, trace_flags(TracerPid, Spec)),
    State#{trace := Spec, tracer_pid := TracerPid}.

-spec stop_trace(state()) -> state().
stop_trace(State) ->
    disable_trace_patterns(shut_down_tracer(State)).

-spec shut_down_tracer(state()) -> state().
shut_down_tracer(State = #{tracer_pid := none}) ->
    State;
shut_down_tracer(State = #{tracer_pid := TracerPid}) ->
    exit(TracerPid, shutdown),
    receive
        {'EXIT', TracerPid, Reason} ->
            handle_tracer_exit(TracerPid, Reason),
            State#{tracer_pid := none}
    after 1000 ->
            logger:warning("Timeout when waiting for tracer process ~p to terminate.", [TracerPid]),
            State
    end.

-spec disable_trace_patterns(state()) -> state().
disable_trace_patterns(State = #{trace := none}) ->
    State;
disable_trace_patterns(State = #{trace := #{modules := ModSpecs}}) ->
    [disable_trace_pattern(ModSpec) || ModSpec <- ModSpecs],
    State#{trace := none}.

handle_tracer_exit(_TracerPid, shutdown) ->
    ok;
handle_tracer_exit(TracerPid, Reason) ->
    logger:error("Tracer process ~p exited with reason ~p.", [TracerPid, Reason]).

-spec trace_flags(pid(), trace_spec()) -> erlang_trace_flags().
trace_flags(TracerPid, Spec) ->
    [{tracer, TracerPid} | basic_trace_flags()] ++ msg_trace_flags(Spec).

-spec msg_trace_flags(trace_spec()) -> erlang_trace_flags().
msg_trace_flags(#{msg := all}) -> [send, 'receive'];
msg_trace_flags(#{msg := send}) -> [send];
msg_trace_flags(#{msg := recv}) -> ['receive'];
msg_trace_flags(#{msg := none}) -> [].

basic_trace_flags() -> [call, timestamp].

-spec set_tracing(pids(), boolean(), erlang_trace_flags()) -> ok.
set_tracing(all, How, FlagList) ->
    erlang:trace(all, How, FlagList),
    ok;
set_tracing(Pids, How, FlagList) when is_list(Pids) ->
    [trace_pid(Pid, How, FlagList) || Pid <- Pids],
    ok.

trace_pid(Pid, How, FlagList) when is_pid(Pid) ->
    try
        erlang:trace(Pid, How, FlagList)
    catch Class:Reason ->
            logger:warning("Could not switch tracing to ~p for pid ~p, ~p:~p",
                           [How, Pid, Class, Reason])
    end.

-spec setup_msg_tracing(trace_spec()) -> traced_pids_tab().
setup_msg_tracing(#{msg := none}) ->
    none;
setup_msg_tracing(#{msg := _, msg_trigger := Trigger}) ->
    case Trigger of
        after_traced_call -> ets:new(traced_pids, []);
        always -> none
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

-spec start_tracer_loop(state(), trace_spec()) -> no_return().
start_tracer_loop(#{tab := Tab, index := Index, limit := Limit}, Spec) ->
    PidsTab = setup_msg_tracing(Spec),
    loop(Tab, Index, Limit, PidsTab).

-spec loop(table(), index(), limit(), traced_pids_tab()) -> no_return().
loop(_Tab, Index, Limit, _PidsTab) when Index > Limit ->
    logger:warning("Reached trace limit ~p, stopping the tracer.", [Limit]),
    exit(shutdown);
loop(Tab, Index, Limit, PidsTab) ->
    receive
        Msg ->
            case handle_trace(Msg, Index, PidsTab) of
                skip ->
                    loop(Tab, Index, Limit, PidsTab);
                Tr ->
                    ets:insert(Tab, Tr),
                    loop(Tab, Index + 1, Limit, PidsTab)
            end
    end.

-spec handle_trace(term(), index(), traced_pids_tab()) -> tr() | skip.
handle_trace({trace_ts, Pid, call, MFA = {_, _, Args}, TS}, Index, PidsTab) ->
    case are_messages_skipped(Pid, PidsTab) of
        true -> stop_skipping_messages(Pid, PidsTab);
        false -> ok
    end,
    #tr{index = Index, pid = Pid, event = call, mfa = mfarity(MFA), data = Args,
        ts = usec_from_now(TS)};
handle_trace({trace_ts, Pid, return_from, MFArity, Res, TS}, Index, _PidsTab) ->
    #tr{index = Index, pid = Pid, event = return, mfa = MFArity, data = Res,
        ts = usec_from_now(TS)};
handle_trace({trace_ts, Pid, exception_from, MFArity, {Class, Value}, TS}, Index, _PidsTab) ->
    #tr{index = Index, pid = Pid, event = exception, mfa = MFArity, data = {Class, Value},
        ts = usec_from_now(TS)};
handle_trace({trace_ts, Pid, Event, Msg, To, TS}, Index, PidsTab)
  when Event =:= send orelse Event =:= send_to_non_existing_process ->
    case are_messages_skipped(Pid, PidsTab) of
        true -> skip;
        false -> #tr{index = Index, pid = Pid, event = send, data = Msg, ts = usec_from_now(TS),
                     info = {To, Event =:= send}}
    end;
handle_trace({trace_ts, Pid, 'receive', Msg, TS}, Index, PidsTab) ->
    case are_messages_skipped(Pid, PidsTab) of
        true -> skip;
        false -> #tr{index = Index, pid = Pid, event = recv, data = Msg, ts = usec_from_now(TS)}
    end;
handle_trace(Trace, _Index, _State) ->
    logger:error("Tracer process received unexpected message ~p.", [Trace]),
    skip.

are_messages_skipped(_Pid, none) ->
    false;
are_messages_skipped(Pid, PidsTab) ->
    ets:lookup(PidsTab, Pid) =:= [].

stop_skipping_messages(Pid, PidsTab) ->
    ets:insert(PidsTab, {Pid}).

%% Filter tracebacks

-spec tb_step(pred(tr()), tr(), map()) -> map().
tb_step(PredF, T = #tr{pid = Pid, event = Event},
        State = #{tbs := TBs, call_stacks := CallStacks, output := Output, format := Format,
                  count := Count, limit := Limit}) ->
    CallStack = maps:get(Pid, CallStacks, []),
    NewStack = update_call_stack(T, CallStack),
    NewState = State#{call_stacks := CallStacks#{Pid => NewStack}},
    case catch PredF(T) of
        true when Count < Limit ->
            TB = if Event =:= call -> NewStack;
                    ?is_return(Event) orelse ?is_msg(Event) -> CallStack
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
    Stack;
update_call_stack(#tr{event = Event}, Stack) when ?is_msg(Event) ->
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
finalize_tracebacks(TBs, _, root, _Options) ->
    lists:map(fun({T, _}) -> T end, lists:reverse(TBs));
finalize_tracebacks(TBs, _, tree, _Options) ->
    finalize_tree(TBs).

-spec reorder_tb([[tr()]], tb_order()) -> [[tr()]].
reorder_tb(TBs, top_down) -> [lists:reverse(TB) || TB <- TBs];
reorder_tb(TBs, bottom_up) -> TBs.

-spec tree_to_list(tb_acc_tree()) -> [[tr()]].
tree_to_list(Tree) ->
    lists:foldl(fun({K, []}, Res) -> [[K] | Res];
                   ({K, V}, Res) -> [[K | Rest] || Rest <- tree_to_list(V)] ++ Res
                end, [], Tree).

%% Reverse order and simplify leaf nodes
-spec finalize_tree(tb_acc_tree()) -> [tb_tree()].
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
    none;
filter_range(_PrefF, T = #tr{event = Event}, State = #{depth := Depth, trace := Trace}, MaxDepth)
  when Depth < MaxDepth, ?is_msg(Event) ->
    {incomplete, State#{depth => Depth, trace => [T|Trace]}};
filter_range(_PrefF, #tr{event = Event}, _State, _MaxDepth) when ?is_msg(Event) ->
    none.

%% Call stat

-spec sort_call_stat(call_stat_field(), #{Key => {call_count(), acc_time(), own_time()}}) ->
    [{Key, call_count(), acc_time(), own_time()}].
sort_call_stat(SortBy, MapStat) ->
    Rows = [{Key, Count, AccTime, OwnTime} || {Key, {Count, AccTime, OwnTime}} <- maps:to_list(MapStat)],
    lists:keysort(sort_by_pos(SortBy), Rows).

sort_by_pos(count) -> 2;
sort_by_pos(acc_time) -> 3;
sort_by_pos(own_time) -> 4.

call_stat_step(_KeyF, #tr{event = Event}, State) when ?is_msg(Event) ->
    State;
call_stat_step(KeyF, Tr = #tr{pid = Pid}, {ProcessStates, Stat}) ->
    {LastTr, Stack, Depths} = maps:get(Pid, ProcessStates, {no_tr, [], #{}}),
    {NewStack, Key} = get_key_and_update_stack(KeyF, Stack, Tr),
    TSDepth = maps:get(Key, Depths, none),
    NewDepths = set_ts_and_depth(Depths, Tr, Key, TSDepth),
    ProcessStates1 = ProcessStates#{Pid => {Tr, NewStack, NewDepths}},
    Stat1 = update_stat(Stat, LastTr, Tr, Key, TSDepth, Stack),
    {ProcessStates1, Stat1}.

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

set_ts_and_depth(Depths, _, no_key, none) ->
    Depths;
set_ts_and_depth(Depths, #tr{event = call, ts = TS}, Key, none) ->
    Depths#{Key => {TS, 0}};
set_ts_and_depth(Depths, #tr{event = call}, Key, {OrigTS, Depth}) ->
    Depths#{Key => {OrigTS, Depth + 1}};
set_ts_and_depth(Depths, #tr{event = Event}, Key, {OrigTS, Depth}) when ?is_return(Event), Depth > 0 ->
    Depths#{Key => {OrigTS, Depth - 1}};
set_ts_and_depth(Depths, #tr{event = Event}, Key, {_OrigTS, 0}) when ?is_return(Event) ->
    maps:remove(Key, Depths).

update_stat(Stat, LastTr, Tr, Key, TSDepth, Stack) ->
    Stat1 = update_count(Tr, Key, Stat),
    Stat2 = update_acc_time(TSDepth, Tr, Key, Stat1),
    ParentKey = case Stack of
                    [K | _] -> K;
                    [] -> no_key
                end,
    update_own_time(LastTr, ParentKey, Tr, Key, Stat2).

update_count(Tr, Key, Stat) ->
    case count_key(Tr, Key) of
        no_key ->
            Stat;
        KeyToUpdate ->
            {Count, AccTime, OwnTime} = maps:get(KeyToUpdate, Stat, {0, 0, 0}),
            Stat#{KeyToUpdate => {Count + 1, AccTime, OwnTime}}
    end.

update_acc_time(TSDepth, Tr, Key, Stat) ->
    case acc_time_key(TSDepth, Tr, Key) of
        no_key ->
            Stat;
        KeyToUpdate ->
            {Count, AccTime, OwnTime} = maps:get(KeyToUpdate, Stat, {0, 0, 0}),
            {OrigTS, _Depth} = TSDepth,
            NewAccTime = AccTime + Tr#tr.ts - OrigTS,
            Stat#{KeyToUpdate => {Count, NewAccTime, OwnTime}}
    end.

update_own_time(LastTr, ParentKey, Tr, Key, Stat) ->
    case own_time_key(LastTr, ParentKey, Tr, Key) of
        no_key ->
            Stat;
        KeyToUpdate ->
            {Count, AccTime, OwnTime} = maps:get(KeyToUpdate, Stat, {0, 0, 0}),
            NewOwnTime = OwnTime + Tr#tr.ts - LastTr#tr.ts,
            Stat#{KeyToUpdate => {Count, AccTime, NewOwnTime}}
    end.

count_key(#tr{event = call}, Key)
  when Key =/= no_key -> Key;
count_key(#tr{}, _) -> no_key.

acc_time_key({_, 0}, #tr{event = Event}, Key)
  when ?is_return(Event), Key =/= no_key -> Key;
acc_time_key(_, #tr{}, _) -> no_key.

own_time_key(#tr{event = call}, PKey, #tr{}, _)
  when PKey =/= no_key -> PKey;
own_time_key(#tr{event = LEvent}, PKey, #tr{event = call}, _)
  when ?is_return(LEvent), PKey =/= no_key -> PKey;
own_time_key(_, _, #tr{event = Event}, Key)
  when ?is_return(Event), Key =/= no_key -> Key;
own_time_key(_, _, #tr{}, _) -> no_key.

%% Call tree statistics for redundancy check

%% @private
-spec call_tree_stat() -> ets:tid().
call_tree_stat() ->
    call_tree_stat(#{}).

%% @private
-spec call_tree_stat(call_tree_stat_options()) -> ets:tid().
call_tree_stat(Options) when is_map(Options) ->
    TraceTab = maps:get(tab, Options, tab()),
    CallTreeTab = ets:new(call_tree_stat, [public, {keypos, 3}]),
    InitialState = maps:merge(#{pid_states => #{}, tab => CallTreeTab}, Options),
    foldl(fun(T, S) -> call_tree_stat_step(T, S) end, InitialState, TraceTab),
    CallTreeTab.

-spec call_tree_stat_step(tr(), call_tree_stat_state()) -> call_tree_stat_state().
call_tree_stat_step(#tr{event = Event}, State) when ?is_msg(Event) ->
    State;
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
    {call, mfargs(MFA, Args)};
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

-spec insert_call_tree(tree(), acc_time(), ets:tid()) -> true.
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

-spec reduce_subtree(tree(), call_tree_count(), ets:tid()) -> any().
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

%% @doc Returns statistics of repeated function call trees that took most time.
%%
%% @see top_call_trees/1
-spec top_call_trees() -> [tree_item()].
top_call_trees() ->
    top_call_trees(#{}).

%% @doc Returns statistics of repeated function call trees that took most time.
%%
%% Two call trees repeat if they contain the same function calls and returns
%% in the same order taking the same arguments and returning the same values, respectively.
%% The results are sorted according to accumulated time.
-spec top_call_trees(top_call_trees_options()) -> [tree_item()].
top_call_trees(Options) when is_map(Options) ->
    TreeTab = call_tree_stat(),
    case maps:get(output, Options, reduced) of
        reduced -> reduce_call_trees(TreeTab);
        complete -> ok
    end,
    TopTrees = top_call_trees(TreeTab, Options),
    ets:delete(TreeTab),
    TopTrees.

%% @private
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
    1.

default_tab() ->
    trace.

foldl(F, InitialState, List) when is_list(List) -> lists:foldl(F, InitialState, List);
foldl(F, InitialState, Tab) -> ets:foldl(F, InitialState, Tab).

maybe_length(L) when is_list(L) -> length(L);
maybe_length(I) when is_integer(I) -> I.

pretty_print_tuple_list(TList) ->
    MaxSize = lists:max([tuple_size(T) || T <- TList]),
    L = [pad([lists:flatten(io_lib:format("~p", [Item])) || Item <- tuple_to_list(T)], MaxSize) || T <- TList],
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
