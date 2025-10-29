-module(tr_SUITE).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").
-include("tr.hrl").

-import(tr_helper, [wait_for_traces/1]).

expect_log(Level, Regexp) ->
    receive
        {Level, Log} ->
            case re:run(Log, Regexp) of
                nomatch ->
                    ct:pal("Skipping unexpected log message (~p): ~p", [Level, Log]),
                    expect_log(Level, Regexp);
                {match, _} ->
                    ok
            end
    after 5000 ->
            ct:fail("Expected log message not received")
    end.

%% CT callbacks

all() ->
    [{group, start_stop},
     {group, trace},
     {group, range},
     {group, traceback},
     {group, util},
     {group, call_stat},
     {group, call_tree_stat}].

suite() ->
    [{timetrap, {seconds, 30}}].

groups() ->
    [{start_stop, [limit,
                   stop_while_tracing,
                   duplicates]},
     {trace, [single_pid,
              single_pid_with_msg,
              msg_after_traced_call]},
     {range, [ranges,
              ranges_max_depth,
              range,
              range_max_depth,
              ranges_with_messages,
              incomplete_ranges]},
     {traceback, [single_tb,
                  single_tb_with_messages,
                  tb,
                  tb_bottom_up,
                  tb_limit,
                  tb_longest,
                  tb_all,
                  tb_all_limit,
                  tb_trees,
                  tb_tree,
                  tb_tree_longest,
                  tb_roots,
                  tb_root]},
     {util, [contains,
             match,
             do,
             next,
             prev]},
     {call_stat, [simple_total,
                  tree_total,
                  simple_total_with_messages,
                  acc_and_own_for_recursion,
                  acc_and_own_for_recursion_with_exception,
                  acc_and_own_for_indirect_recursion,
                  dump_and_load,
                  interleave,
                  call_without_return,
                  return_without_call]},
     {call_tree_stat, [top_call_trees,
                       top_call_trees_with_messages]}].

init_per_group(start_stop, Config) ->
    Config;
init_per_group(_Group, Config) ->
    ok = application:start(erlang_doctor),
    Config.

end_per_group(start_stop, _Config) ->
    ok;
end_per_group(_Group, _Config) ->
    ok = application:stop(erlang_doctor).

init_per_testcase(_TC, Config) ->
    logger:add_handler(?MODULE, ?MODULE, #{config => self()}),
    Config.

end_per_testcase(_TC, _Config) ->
    logger:remove_handler(?MODULE),
    case lists:keymember(erlang_doctor, 1, application:which_applications()) of
        false ->
            catch tr:stop(); % cleanup in case of failed tests
        true ->
            catch tr:stop_tracing(), % cleanup in case of failed tests
            tr:clean()
    end.

%% Test cases

limit(_Config) ->
    tr:start(#{limit => 2}),
    MFA = {?MODULE, factorial, 1},
    tr:trace([MFA]),
    factorial(1),
    expect_log(warning, "Reached trace limit 2"),
    expect_log(warning, "Tracer process <.+> exited with reason shutdown"),
    wait_for_traces(2),

    %% expect only first 2 calls
    [#tr{index = 1, event = call, mfa = MFA, data = [1]},
     #tr{index = 2, event = call, mfa = MFA, data = [0]}] = tr:select(),
    tr:stop().

stop_while_tracing(_Config) ->
    tr:start(),
    tr:trace([{?MODULE, fib, 1}]),
    fib(1),
    wait_for_traces(2),
    tr:stop(), %% Stop tr when tracing is still enabled
    tr:start(),
    MFA = {?MODULE, factorial, 1},
    tr:trace([MFA]),
    fib(0), % Shouldn't be traced anymore
    factorial(0),

    %% Expect only factorial
    [#tr{index = 1, event = call, mfa = MFA, data = [0]},
     #tr{index = 2, event = return, mfa = MFA, data = 1}] = tr:select(),
    tr:stop().

duplicates(_Config) ->
    {ok, Pid} = tr:start(),
    {error, {already_started, Pid}} = tr:start(),

    ok = tr:trace([?MODULE]),
    {error, already_tracing} = tr:trace([?MODULE]),

    ok = tr:stop_tracing(),
    {error, not_tracing} = tr:stop_tracing(),

    ok = tr:stop(),
    ?assertExit(noproc, tr:stop()).

single_pid(_Config) ->
    Pid = spawn_link(fun ?MODULE:async_factorial/0),
    MFA = {?MODULE, factorial, 1},
    tr:trace([MFA], [Pid]),
    factorial(0),
    Pid ! {do_factorial, 0, self()},
    receive {ok, _} -> ok end,
    wait_for_traces(2),
    tr:stop_tracing(),
    Pid ! stop,

    %% expect only traces from Pid
    [#tr{index = 1, event = call, mfa = MFA, pid = Pid, data = [0]},
     #tr{index = 2, event = return, mfa = MFA, pid = Pid, data = 1}] = tr:select().

single_pid_with_msg(_Config) ->
    Pid = spawn_link(fun ?MODULE:async_factorial/0),
    MFA = {?MODULE, factorial, 1},
    tr:trace(#{modules => [MFA], pids => [Pid], msg => all, msg_trigger => always}),
    factorial(0),
    Self = self(),
    Pid ! {do_factorial, 0, Self},
    receive {ok, _} -> ok end,
    wait_for_traces(4),
    tr:stop_tracing(),
    Pid ! stop,

    %% expect only traces from Pid
    [#tr{index = 1, event = recv, pid = Pid, data = {do_factorial, 0, Self}},
     #tr{index = 2, event = call, mfa = MFA, pid = Pid, data = [0]},
     #tr{index = 3, event = return, mfa = MFA, pid = Pid, data = 1},
     #tr{index = 4, event = send, pid = Pid, data = {ok, 1}, info = {Self, true}}] = tr:select().

msg_after_traced_call(_Config) ->
    Pid = spawn_link(fun ?MODULE:async_factorial/0),
    MFA = {?MODULE, factorial, 1},
    tr:trace(#{modules => [MFA], pids => [Pid], msg => all}),
    Self = self(),
    Pid ! {do_factorial, 0, Self},
    receive {ok, _} -> ok end,
    Pid ! stop,
    wait_for_traces(4),
    tr:stop_tracing(),

    %% message traces for Pid are stored after the call to factorial/1
    [#tr{index = 1, event = call, mfa = MFA, pid = Pid, data = [0]},
     #tr{index = 2, event = return, mfa = MFA, pid = Pid, data = 1},
     #tr{index = 3, event = send, pid = Pid, data = {ok, 1}, info = {Self, true}},
     #tr{index = 4, event = recv, pid = Pid, data = stop}] = tr:select().

ranges(_Config) ->
    Traces = trace_fib3(),

    %% all traces from fib(3)
    [Traces] = tr:ranges(fun(#tr{event = call}) -> true end),

    %% nothing because 'return' is not a call
    [] = tr:ranges(fun(#tr{event = return}) -> true end),

    %% all traces from both calls to fib(2)
    Range1a = lists:sublist(Traces, 3, 2),
    Range1b = lists:sublist(Traces, 8, 2),
    [Range1a, Range1b] = tr:ranges(fun(#tr{data = [1]}) -> true end).

ranges_max_depth(_Config) ->
    Traces = trace_fib3(),

    %% fib(3) and its return
    Range1 = [hd(Traces), lists:last(Traces)],
    [Range1] = tr:ranges(fun(#tr{event = call}) -> true end, #{max_depth => 1}),

    %% fib(3) with fib(2) and fib(1) inside
    Range2 = lists:sublist(Traces, 2) ++ lists:sublist(Traces, 7, 4),
    [Range2] = tr:ranges(fun(#tr{event = call}) -> true end, #{max_depth => 2}).

range(_Config) ->
    Traces = trace_fib3(),

    %% all traces from fib(3)
    Traces = tr:range(fun(#tr{event = call}) -> true end),
    Traces = tr:range(1),
    Traces = tr:range(hd(Traces)),

    %% return is not a call
    ?assertException(error, badarg, tr:range(fun(#tr{event = return}) -> true end)),

    %% all traces from the first call to fib(2)
    Range1 = lists:sublist(Traces, 3, 2),
    Range1 = tr:range(fun(#tr{data = [1]}) -> true end).

range_max_depth(_Config) ->
    Traces = trace_fib3(),

    %% fib(3) and its return
    Range1 = [hd(Traces), lists:last(Traces)],
    Range1 = tr:range(fun(#tr{event = call}) -> true end, #{max_depth => 1}),

    %% fib(3) with fib(2) and fib(1) inside
    Range2 = lists:sublist(Traces, 2) ++ lists:sublist(Traces, 7, 4),
    Range2 = tr:range(fun(#tr{event = call}) -> true end, #{max_depth => 2}).

ranges_with_messages(_Config) ->
    Traces = trace_wait_and_reply(),

    %% all traces from the root call with messages
    [Traces] = tr:ranges(fun(#tr{}) -> true end),

    %% nothing because 'send' is not a call
    [] = tr:ranges(fun(#tr{event = send}) -> true end),

    %% root call and its return without messages (they have depth of 2)
    Range1 = [hd(Traces), lists:last(Traces)],
    [Range1] = tr:ranges(fun(#tr{}) -> true end, #{max_depth => 1}).

incomplete_ranges(_Config) ->
    Self = self(),
    tr:trace(#{modules => [MFA = {?MODULE, wait_and_reply, 1}]}),
    Pid1 = spawn_link(?MODULE, wait_and_reply, [self()]),
    Pid2 = spawn_link(?MODULE, wait_and_reply, [self()]),
    receive {started, Pid1} -> ok end,
    receive {started, Pid2} -> ok end,
    Pid2 ! reply,
    receive {finished, Pid2} -> ok end,

    %% Pid1 finished, but Pid1 didn't
    wait_for_traces(3),
    tr:stop_tracing(),
    Pid1 ! reply,
    receive {finished, Pid1} -> ok end,

    [#tr{index = 1, pid = Pid1, event = call, mfa = MFA, data = [Self]},
     #tr{index = 2, pid = Pid2, event = call, mfa = MFA, data = [Self]},
     #tr{index = 3, pid = Pid2, event = return, mfa = MFA, data = {finished, Pid2}}] =
        [T1, T2, T3] = tr:select(),

    %% Ranges with missing returns are included at the end
    [[T2, T3], [T1]] = tr:ranges(fun(#tr{}) -> true end),
    [[T2, T3], [T1]] = tr:ranges(fun(#tr{}) -> true end, #{output => all}),

    %% Skip ranges with missing returns
    [[T2, T3]] = tr:ranges(fun(#tr{}) -> true end, #{output => complete}),

    %% Skip ranges with missing returns
    [[T1]] = tr:ranges(fun(#tr{}) -> true end, #{output => incomplete}).

contains(_Config) ->
    trace_fib3(),
    Result = tr:filter(fun(T) -> tr:contains_data(1, T) end),
    ?assertMatch([#tr{index = 3, event = call, data = [1]},
                  #tr{index = 4, event = return, data = 1},
                  #tr{index = 7, event = return, data = 1},
                  #tr{index = 8, event = call, data = [1]},
                  #tr{index = 9, event = return, data = 1}], Result),
    ?assertEqual(Result, tr:filter(fun(#tr{data = Data}) -> tr:contains_val(1, Data) end)).

match(_Config) ->
    trace_fib3(),
    Pred = fun([N]) -> N > 1 end,
    Result = tr:filter(fun(T) -> tr:match_data(Pred, T) end),
    ?assertMatch([#tr{index = 1, event = call, data = [3]},
                  #tr{index = 2, event = call, data = [2]}], Result),
    ?assertEqual(Result, tr:filter(fun(#tr{data = Data}) -> tr:match_val(Pred, Data) end)).

do(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(2),
    wait_for_traces(6),
    tr:stop_tracing(),
    MFA = {?MODULE, fib, 1},
    [T1 = #tr{index = 1, event = call, mfa = MFA, data = [2]},
     #tr{index = 2, event = call, mfa = MFA, data = [1]},
     #tr{index = 3, event = return, mfa = MFA, data = 1},
     T4 = #tr{index = 4, event = call, mfa = MFA, data = [0]},
     #tr{index = 5, event = return, mfa = MFA, data = 0},
     #tr{index = 6, event = return, mfa = MFA, data = 1}] = tr:select(),
    1 = tr:do(T1),
    0 = tr:do(T4),
    1 = tr:do(1),
    0 = tr:do(4).

next(_Config) ->
    {P1, P2} = trace_interleaved(),
    [T1 = #tr{index = 1, pid = P1, event = call},
     T2 = #tr{index = 2, pid = P2, event = call},
     T3 = #tr{index = 3, pid = P1, event = return},
     T4 = #tr{index = 4, pid = P2, event = return}] = tr:select(),
    ?assertEqual(T2, tr:next(T1)),
    ?assertEqual(T2, tr:next(1)),
    ?assertEqual(T3, tr:seq_next(T1)),
    ?assertEqual(T3, tr:seq_next(1)),
    Pred = fun(#tr{pid = P, event = return}) -> P =/= P1 end,
    ?assertEqual(T4, tr:next(T1, #{pred => Pred})),
    ?assertEqual(T4, tr:next(1, #{pred => Pred})),
    ?assertError(not_found, tr:next(T4)).

prev(_Config) ->
    {P1, P2} = trace_interleaved(),
    [T1 = #tr{index = 1, pid = P1, event = call},
     T2 = #tr{index = 2, pid = P2, event = call},
     T3 = #tr{index = 3, pid = P1, event = return},
     T4 = #tr{index = 4, pid = P2, event = return}] = tr:select(),
    ?assertEqual(T3, tr:prev(T4)),
    ?assertEqual(T3, tr:prev(4)),
    ?assertEqual(T2, tr:seq_prev(T4)),
    ?assertEqual(T2, tr:seq_prev(4)),
    Pred = fun(#tr{pid = P, event = call}) -> P =/= P2 end,
    ?assertEqual(T1, tr:prev(T4, #{pred => Pred})),
    ?assertEqual(T1, tr:prev(4, #{pred => Pred})),
    ?assertError(not_found, tr:prev(T1)).

single_tb(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    wait_for_traces(18),
    tr:stop_tracing(),

    PredF = fun(#tr{event = return, data = N}) when N < 2 -> true end,
    TB = tr:traceback(PredF),
    ct:pal("Top-down TB: ~p~n", [TB]),
    ?assertMatch([#tr{data = [1]}, #tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}], TB),

    TB2 = tr:traceback(PredF, #{order => bottom_up}),
    ct:pal("Bottom-up TB: ~p~n", [TB2]),
    ?assertEqual(lists:reverse(TB), TB2).

single_tb_with_messages(_Config) ->
    Traces = [Call, Send, Recv|_] = trace_wait_and_reply(),
    Return = lists:last(Traces),
    ?assertEqual([Call], tr:traceback(Send)),
    ?assertEqual([Call], tr:traceback(Recv)),
    ?assertEqual([Call], tr:traceback(Return)).

tb(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    wait_for_traces(18),
    tr:stop_tracing(),
    TBs = tr:tracebacks(fun(#tr{event = return, data = N}) when N < 2 -> true end),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([[#tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [1]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [2]}, #tr{data = [4]}]], TBs).

tb_bottom_up(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    wait_for_traces(18),
    tr:stop_tracing(),
    TBs = tr:tracebacks(fun(#tr{event = return, data = N}) when N < 2 -> true end,
                               #{order => bottom_up}),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([[#tr{data = [4]}, #tr{data = [3]}, #tr{data = [2]}],
                  [#tr{data = [4]}, #tr{data = [3]}, #tr{data = [1]}],
                  [#tr{data = [4]}, #tr{data = [2]}]], TBs).

tb_limit(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    wait_for_traces(18),
    tr:stop_tracing(),
    TBs = tr:tracebacks(fun(#tr{event = return, data = N}) when N < 2 -> true end,
                               #{limit => 3}),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([[#tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}]], TBs).

tb_all(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    wait_for_traces(18),
    tr:stop_tracing(),
    TBs = tr:tracebacks(fun(#tr{event = return, data = N}) when N < 2 -> true end,
                               #{output => all}),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([[#tr{data = [1]}, #tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [0]}, #tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [1]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [1]}, #tr{data = [2]}, #tr{data = [4]}],
                  [#tr{data = [0]}, #tr{data = [2]}, #tr{data = [4]}],
                  [#tr{data = [2]}, #tr{data = [4]}]], TBs).

tb_longest(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    wait_for_traces(18),
    tr:stop_tracing(),
    TBs = tr:tracebacks(fun(#tr{event = return, data = N}) when N < 2 -> true end,
                               #{output => longest}),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([[#tr{data = [1]}, #tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [0]}, #tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [1]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [1]}, #tr{data = [2]}, #tr{data = [4]}],
                  [#tr{data = [0]}, #tr{data = [2]}, #tr{data = [4]}]], TBs).

tb_all_limit(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    wait_for_traces(18),
    tr:stop_tracing(),
    TBs = tr:tracebacks(fun(#tr{event = return, data = N}) when N < 2 -> true end,
                               #{limit => 3, output => all}),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([[#tr{data = [1]}, #tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [0]}, #tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}]], TBs).

tb_trees(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    wait_for_traces(18),
    tr:stop_tracing(),
    TBs = tr:tracebacks(fun(#tr{event = return, data = N}) when N < 2 -> true end,
                        #{format => tree}),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([{#tr{data = [4]}, [{#tr{data = [3]}, [#tr{data = [2]},
                                                        #tr{data = [1]}]},
                                      #tr{data = [2]}]}], TBs).

tb_tree(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    wait_for_traces(18),
    tr:stop_tracing(),
    TB = tr:traceback(fun(#tr{event = return, data = N}) when N < 2 -> true end,
                          #{format => tree}),
    ct:pal("~p~n", [TB]),
    ?assertMatch({#tr{data = [4]}, [{#tr{data = [3]}, [{#tr{data = [2]},
                                                        [#tr{data = [1]}]}]}]}, TB).

tb_tree_longest(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    wait_for_traces(18),
    tr:stop_tracing(),
    TBs = tr:tracebacks(fun(#tr{event = return, data = N}) when N < 2 -> true end,
                               #{format => tree, output => longest}),
    TBs = tr:tracebacks(fun(#tr{event = return, data = N}) when N < 2 -> true end,
                               #{format => tree, output => all}), %% same result for trees
    ct:pal("~p~n", [TBs]),
    ?assertMatch([{#tr{data = [4]}, [{#tr{data = [3]}, [{#tr{data = [2]}, [#tr{data = [1]},
                                                                           #tr{data = [0]}]},
                                                        #tr{data = [1]}]},
                                     {#tr{data = [2]}, [#tr{data = [1]},
                                                        #tr{data = [0]}]}]}], TBs).

tb_roots(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    wait_for_traces(18),
    tr:stop_tracing(),

    Pred = fun(#tr{event = return, data = N}) when N < 2 -> true end,

    %% Option 1: call root/1 or roots/1 on a tree
    TBs = tr:tracebacks(Pred, #{format => tree}),
    Roots = tr:roots(TBs),
    ct:pal("Roots: ~p~n", [Roots]),
    ?assertMatch([#tr{data = [4]}], Roots),
    ?assertEqual(hd(Roots), tr:root(hd(TBs))),

    %% Option 2: directly use the root format
    ?assertEqual(Roots, tr:tracebacks(Pred, #{format => root})).
tb_root(_Config) ->
    tr:trace([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    wait_for_traces(18),
    tr:stop_tracing(),

    Pred = fun(#tr{event = return, data = N}) when N < 2 -> true end,

    Root = tr:traceback(Pred, #{format => root}),
    ?assertMatch(#tr{data = [4]}, Root).

simple_total(_Config) ->
    tr:trace([{?MODULE, factorial, 1}]),
    ?MODULE:factorial(2),
    wait_for_traces(6),
    [{total, 3, Acc1, Acc1}] = tr:sorted_call_stat(fun(_) -> total end),
    ?MODULE:factorial(1),
    wait_for_traces(10),
    [{total, 5, Acc2, Acc2}] = tr:sorted_call_stat(fun(_) -> total end),
    ?assertEqual(true, Acc1 < Acc2),
    tr:stop_tracing(),
    timer:sleep(10),

    %% Tracing disabled
    ?MODULE:factorial(1),
    timer:sleep(10),
    [{total, 5, Acc2, Acc2}] = tr:sorted_call_stat(fun(_) -> total end),

    %% Tracing enabled for a different function
    tr:trace([{?MODULE, factorial2, 1}]),
    ?MODULE:factorial(1),
    timer:sleep(10),
    [{total, 5, Acc2, Acc2}] = tr:sorted_call_stat(fun(_) -> total end),
    tr:stop_tracing().

tree_total(_Config) ->
    %% Check that acc and own times are equal for a branching call tree
    trace_fib3(),
    [{total, 5, Acc, Acc}] = tr:sorted_call_stat(fun(_) -> total end),
    ?assert(Acc > 0).

simple_total_with_messages(_Config) ->
    _Traces = trace_wait_and_reply(),
    [{total, 1, Acc1, Acc1}] = tr:sorted_call_stat(fun(_) -> total end).

acc_and_own_for_recursion(_Config) ->
    tr:trace([{?MODULE, sleepy_factorial, 1}]),
    ?MODULE:sleepy_factorial(2),
    wait_for_traces(6),
    tr:stop_tracing(),
    Stat = tr:sorted_call_stat(fun(#tr{data = [Arg]}) -> Arg end),
    ct:pal("Stat: ~p~n", [Stat]),
    [{2, 1, Acc2, Own2},
     {1, 1, Acc1, Own1},
     {0, 1, Acc0, Acc0}] = Stat,
    ?assertEqual(Acc2, Own2 + Own1 + Acc0),
    ?assertEqual(Acc1, Own1 + Acc0).

acc_and_own_for_recursion_with_exception(_Config) ->
    tr:trace([{?MODULE, bad_factorial, 1}]),
    catch ?MODULE:bad_factorial(2),
    wait_for_traces(6),
    tr:stop_tracing(),
    Stat = tr:sorted_call_stat(fun(#tr{data = [Arg]}) -> Arg end),
    ct:pal("Stat: ~p~n", [Stat]),
    [{2, 1, Acc2, Own2},
     {1, 1, Acc1, Own1},
     {0, 1, Acc0, Acc0}] = Stat,
    ?assertEqual(Acc2, Own2 + Own1 + Acc0),
    ?assertEqual(Acc1, Own1 + Acc0).

acc_and_own_for_indirect_recursion(_Config) ->
    tr:trace([?MODULE]),
    ?MODULE:factorial_with_helper(2),
    wait_for_traces(10),
    tr:stop_tracing(),
    Traces = ets:tab2list(trace),
    ct:pal("~p~n", [Traces]),
    [#tr{event = call, mfa = {_, factorial_with_helper, 1}, data = [2], ts = T1},
     #tr{event = call, mfa = {_, factorial_helper, 1}, data = [2], ts = T2},
     #tr{event = call, mfa = {_, factorial_with_helper, 1}, data = [1], ts = T3},
     #tr{event = call, mfa = {_, factorial_helper, 1}, data = [1], ts = T4},
     #tr{event = call, mfa = {_, factorial_with_helper, 1}, data = [0], ts = T5},
     #tr{event = return, mfa = {_, factorial_with_helper, 1}, data = 1, ts = T6},
     #tr{event = return, mfa = {_, factorial_helper, 1}, data = 1, ts = T7},
     #tr{event = return, mfa = {_, factorial_with_helper, 1}, data = 1, ts = T8},
     #tr{event = return, mfa = {_, factorial_helper, 1}, data = 2, ts = T9},
     #tr{event = return, mfa = {_, factorial_with_helper, 1}, data = 2, ts = T10}] = Traces,
    Stat = tr:sorted_call_stat(fun(#tr{mfa = {_, factorial_with_helper, _}, data = Args}) -> Args end),
    ct:pal("Stat: ~p~n", [Stat]),
    [{[2], 1, Acc1, Own1},
     {[1], 1, Acc2, Own2},
     {[0], 1, Acc3, Acc3}] = Stat,
    ?assertEqual(Acc1, T10 - T1),
    ?assertEqual(Own1, (T2 - T1) + (T10 - T9)),
    ?assertEqual(Acc2, T8 - T3),
    ?assertEqual(Own2, (T4 - T3) + (T8 - T7)),
    ?assertEqual(Acc3, T6 - T5),
    FStat = tr:sorted_call_stat(fun(#tr{mfa = {_, F, _}}) -> F end),
    ct:pal("FStat: ~p~n", [FStat]),
    [{factorial_with_helper, 3, Acc1, OwnF1},
     {factorial_helper, 2, AccF2, OwnF2}] = FStat,
    ?assertEqual(AccF2, T9 - T2),
    ?assertEqual(OwnF1, Own1 + Own2 + Acc3),
    ?assertEqual(OwnF2, (T3 - T2) + (T5 - T4) + (T7 - T6) + (T9 - T8)).

interleave(_Config) ->
    {P1, P2} = trace_interleaved(),
    [#tr{pid = P1, event = call, ts = T1},
     #tr{pid = P2, event = call, ts = T2},
     #tr{pid = P1, event = return, ts = T3},
     #tr{pid = P2, event = return, ts = T4}] = ets:tab2list(trace),
    Stat = tr:sorted_call_stat(fun(#tr{mfa = {_, F, _}, data = Data}) -> {F, Data} end),
    ct:pal("Stat: ~p~n", [Stat]),
    Self = self(),
    [{{wait_and_reply, [Self]}, 2, DT, DT}] = Stat,
    ?assertEqual(DT, (T3 - T1) + (T4 - T2)).

call_without_return(_Config) ->
    tr:trace([?MODULE]),
    Self = self(),
    P1 = spawn_link(?MODULE, wait_and_reply, [Self]),
    receive {started, P1} -> ok end,
    wait_for_traces(1),
    tr:stop_tracing(),
    P1 ! reply,
    receive {finished, P1} -> ok end,
    [#tr{pid = P1, event = call}] = tr:select(),
    Stat = tr:sorted_call_stat(fun(#tr{mfa = {_, F, _}, data = Data}) -> {F, Data} end),
    ct:pal("Stat: ~p~n", [Stat]),
    ?assertEqual([{{wait_and_reply, [Self]}, 1, 0, 0}], Stat). % time is zero

return_without_call(_Config) ->
    P1 = spawn_link(?MODULE, wait_and_reply, [self()]),
    receive {started, P1} -> ok end,
    tr:trace([?MODULE]),
    P1 ! reply,
    receive {finished, P1} -> ok end,
    timer:sleep(10),
    tr:stop_tracing(),
    [] = tr:select(), % return is not registered if call was not traced
    Stat = tr:sorted_call_stat(fun(#tr{mfa = {_, F, _}, data = Data}) -> {F, Data} end),
    ct:pal("Stat: ~p~n", [Stat]),
    ?assertEqual([], Stat).

dump_and_load(_Config) ->
    DumpFile = "dump",
    tr:trace([{?MODULE, factorial, 1}]),
    factorial(1),
    wait_for_traces(4),
    tr:stop_tracing(),
    BeforeDump = tr:sorted_call_stat(fun(_) -> total end),
    tr:dump(DumpFile),
    tr:load(DumpFile),
    AfterLoad = tr:sorted_call_stat(fun(_) -> total end),
    ?assertEqual(BeforeDump, AfterLoad),
    file:delete(DumpFile).

top_call_trees(_Config) ->
    tr:trace([?MODULE]),
    ?MODULE:fib(3),
    ?MODULE:fib(4),
    wait_for_traces(28),
    tr:stop_tracing(),
    N = #node{module = ?MODULE, function = fib},
    Fib0 = N#node{args = [0], result = {return, 0}},
    Fib1 = N#node{args = [1], result = {return, 1}},
    Fib2 = N#node{args = [2], children = [Fib1, Fib0], result = {return, 1}},
    Fib3 = N#node{args = [3], children = [Fib2, Fib1], result = {return, 2}},
    Complete = tr:top_call_trees(#{output => complete}),
    Reduced = tr:top_call_trees(),
    ct:pal("Top call trees (complete): ~p~n", [Complete]),
    ct:pal("Top call trees (reduced): ~p~n", [Reduced]),
    [{T0, 3, Fib0}] = Complete -- Reduced,
    [{T3, 2, Fib3}, {T2, 3, Fib2}, {T1, 5, Fib1}] = lists:keysort(2, Reduced),
    ?assert(T2 + T3 > T1),
    ?assert(T2 > T0).

top_call_trees_with_messages(_Config) ->
    _Traces = trace_wait_and_reply(),
    [{_T, 1, #node{module = ?MODULE, function = wait_and_reply,
                   args = [_], result = {return, {finished, _}}}}] =
         tr:top_call_trees(#{min_count => 1}).

%% Helpers

trace_fib3() ->
    tr:trace([MFA = {?MODULE, fib, 1}]),
    fib(3),
    wait_for_traces(10),
    tr:stop_tracing(),
    [#tr{index = 1, event = call, mfa = MFA, data = [3]},
     #tr{index = 2, event = call, mfa = MFA, data = [2]},
     #tr{index = 3, event = call, mfa = MFA, data = [1]},
     #tr{index = 4, event = return, mfa = MFA, data = 1},
     #tr{index = 5, event = call, mfa = MFA, data = [0]},
     #tr{index = 6, event = return, mfa = MFA, data = 0},
     #tr{index = 7, event = return, mfa = MFA, data = 1},
     #tr{index = 8, event = call, mfa = MFA, data = [1]},
     #tr{index = 9, event = return, mfa = MFA, data = 1},
     #tr{index = 10, event = return, mfa = MFA, data = 2}] = tr:select().

trace_wait_and_reply() ->
    Self = self(),
    Pid = spawn_wait_and_reply(self()),
    tr:trace(#{modules => [MFA = {?MODULE, wait_and_reply, 1}], pids => [Pid], msg => all}),
    Pid ! start,
    receive {started, Pid} -> ok end,
    Pid ! reply,
    receive {finished, Pid} -> ok end,
    wait_for_traces(5),
    tr:stop_tracing(),
    [#tr{index = 1, pid = Pid, event = call, mfa = MFA, data = [Self]},
     #tr{index = 2, pid = Pid, event = send, data = {started, Pid}, info = {Self, true}},
     #tr{index = 3, pid = Pid, event = recv, data = reply},
     #tr{index = 4, pid = Pid, event = send, data = {finished, Pid}, info = {Self, true}},
     #tr{index = 5, pid = Pid, event = return, mfa = MFA, data = {finished, Pid}}
    ] = tr:select().

trace_interleaved() ->
    tr:trace([?MODULE]),
    Self = self(),
    P1 = spawn_link(?MODULE, wait_and_reply, [Self]),
    receive {started, P1} -> ok end,
    P2 = spawn_link(?MODULE, wait_and_reply, [Self]),
    receive {started, P2} -> ok end,
    P1 ! reply,
    receive {finished, P1} -> ok end,
    P2 ! reply,
    receive {finished, P2} -> ok end,
    wait_for_traces(4),
    tr:stop_tracing(),
    {P1, P2}.

factorial(N) when N > 0 -> N * factorial(N - 1);
factorial(0) -> 1.

async_factorial() ->
    receive
        {do_factorial, N, From} ->
            Res = ?MODULE:factorial(N),
            From ! {ok, Res},
            async_factorial();
        stop -> ok
    end.

sleepy_factorial(N) when N > 0 ->
    timer:sleep(1),
    N * sleepy_factorial(N-1);
sleepy_factorial(0) ->
    timer:sleep(1),
    1.

-spec bad_factorial(integer()) -> no_return().
bad_factorial(N) when N > 0 ->
    timer:sleep(1),
    N * bad_factorial(N - 1).

factorial_with_helper(N) when N > 0 ->
    timer:sleep(1),
    factorial_helper(N);
factorial_with_helper(0) ->
    timer:sleep(1),
    1.

factorial_helper(N) -> N * factorial_with_helper(N - 1).

fib(N) when N > 1 -> fib(N - 1) + fib(N - 2);
fib(1) -> 1;
fib(0) -> 0.

spawn_wait_and_reply(Sender) ->
    spawn_link(fun() ->
                   receive start -> ok end,
                   wait_and_reply(Sender)
               end).

wait_and_reply(Sender) ->
    Sender ! {started, self()},
    receive reply -> ok end,
    Sender ! {finished, self()}.

log(#{msg := {Format, Args}, level := Level}, #{config := Pid}) ->
    Pid ! {Level, lists:flatten(io_lib:format(Format, Args))};
log(_Event, _Config) ->
    ok.
