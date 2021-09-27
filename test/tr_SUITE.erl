-module(tr_SUITE).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include("tr.hrl").

%% CT callbacks

all() ->
    [{group, tracebacks},
     {group, call_stat},
     {group, utils},
     {group, range_stats}].

groups() ->
    [{tracebacks, [single_tb,
                   tb,
                   tb_bottom_up,
                   tb_limit,
                   tb_longest,
                   tb_all,
                   tb_all_limit,
                   tb_tree,
                   tb_tree_longest]},
     {call_stat, [simple_total,
                  acc_and_own_for_recursion,
                  acc_and_own_for_recursion_with_exception,
                  acc_and_own_for_indirect_recursion,
                  dump_and_load,
                  interleave,
                  call_without_return,
                  return_without_call]},
     {utils, [do]},
     {range_stats, [top_ranges]}].

init_per_suite(Config) ->
    ok = application:start(erlang_doctor),
    Config.

end_per_suite(Config) ->
    ok = application:stop(erlang_doctor),
    Config.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, _Config) ->
    tr:clean().

%% Test cases

do(_Config) ->
    tr:trace_calls([{?MODULE, fib, 1}]),
    ?MODULE:fib(2),
    tr:stop_tracing_calls(),
    MFA = {?MODULE, fib, 1},
    ct:pal("~p~n", [ets:tab2list(trace)]),
    [T1 = #tr{index = 1, event = call, mfa = MFA, data = [2]},
     #tr{index = 2, event = call, mfa = MFA, data = [1]},
     #tr{index = 3, event = return_from, mfa = MFA, data = 1},
     T4 = #tr{index = 4, event = call, mfa = MFA, data = [0]},
     #tr{index = 5, event = return_from, mfa = MFA, data = 0},
     #tr{index = 6, event = return_from, mfa = MFA, data = 1}] = tr:select(),
    1 = tr:do(T1),
    0 = tr:do(T4),
    1 = tr:do(1),
    0 = tr:do(4).

single_tb(_Config) ->
    tr:trace_calls([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    tr:stop_tracing_calls(),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    TB = tr:traceback(fun(#tr{event = return_from, data = N}) when N < 2 -> true end),
    ct:pal("~p~n", [TB]),
    ?assertMatch([#tr{data = [1]}, #tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}], TB).

tb(_Config) ->
    tr:trace_calls([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    tr:stop_tracing_calls(),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    TBs = tr:tracebacks(fun(#tr{event = return_from, data = N}) when N < 2 -> true end),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([[#tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [1]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [2]}, #tr{data = [4]}]], TBs).

tb_bottom_up(_Config) ->
    tr:trace_calls([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    tr:stop_tracing_calls(),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    TBs = tr:tracebacks(fun(#tr{event = return_from, data = N}) when N < 2 -> true end,
                               #{order => bottom_up}),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([[#tr{data = [4]}, #tr{data = [3]}, #tr{data = [2]}],
                  [#tr{data = [4]}, #tr{data = [3]}, #tr{data = [1]}],
                  [#tr{data = [4]}, #tr{data = [2]}]], TBs).

tb_limit(_Config) ->
    tr:trace_calls([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    tr:stop_tracing_calls(),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    TBs = tr:tracebacks(fun(#tr{event = return_from, data = N}) when N < 2 -> true end,
                               #{limit => 3}),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([[#tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}]], TBs).

tb_all(_Config) ->
    tr:trace_calls([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    tr:stop_tracing_calls(),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    TBs = tr:tracebacks(fun(#tr{event = return_from, data = N}) when N < 2 -> true end,
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
    tr:trace_calls([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    tr:stop_tracing_calls(),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    TBs = tr:tracebacks(fun(#tr{event = return_from, data = N}) when N < 2 -> true end,
                               #{output => longest}),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([[#tr{data = [1]}, #tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [0]}, #tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [1]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [1]}, #tr{data = [2]}, #tr{data = [4]}],
                  [#tr{data = [0]}, #tr{data = [2]}, #tr{data = [4]}]], TBs).

tb_all_limit(_Config) ->
    tr:trace_calls([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    tr:stop_tracing_calls(),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    TBs = tr:tracebacks(fun(#tr{event = return_from, data = N}) when N < 2 -> true end,
                               #{limit => 3, output => all}),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([[#tr{data = [1]}, #tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [0]}, #tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}],
                  [#tr{data = [2]}, #tr{data = [3]}, #tr{data = [4]}]], TBs).

tb_tree(_Config) ->
    tr:trace_calls([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    tr:stop_tracing_calls(),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    TBs = tr:tracebacks(fun(#tr{event = return_from, data = N}) when N < 2 -> true end,
                               #{format => tree}),
    ct:pal("~p~n", [TBs]),
    ?assertMatch([{#tr{data = [4]}, [{#tr{data = [3]}, [#tr{data = [2]},
                                                        #tr{data = [1]}]},
                                     #tr{data = [2]}]}], TBs).

tb_tree_longest(_Config) ->
    tr:trace_calls([{?MODULE, fib, 1}]),
    ?MODULE:fib(4),
    tr:stop_tracing_calls(),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    TBs = tr:tracebacks(fun(#tr{event = return_from, data = N}) when N < 2 -> true end,
                               #{format => tree, output => longest}),
    TBs = tr:tracebacks(fun(#tr{event = return_from, data = N}) when N < 2 -> true end,
                               #{format => tree, output => all}), %% same result for trees
    ct:pal("~p~n", [TBs]),
    ?assertMatch([{#tr{data = [4]}, [{#tr{data = [3]}, [{#tr{data = [2]}, [#tr{data = [1]},
                                                                           #tr{data = [0]}]},
                                                        #tr{data = [1]}]},
                                     {#tr{data = [2]}, [#tr{data = [1]},
                                                        #tr{data = [0]}]}]}], TBs).

simple_total(_Config) ->
    tr:trace_calls([{?MODULE, factorial, 1}]),
    ?MODULE:factorial(2),
    ct:sleep(10),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    [{total, 3, Acc1, Acc1}] = tr:sorted_call_stat(fun(_) -> total end),
    ?MODULE:factorial(1),
    ct:sleep(10),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    [{total, 5, Acc2, Acc2}] = tr:sorted_call_stat(fun(_) -> total end),
    ?assertEqual(true, Acc1 < Acc2),
    tr:stop_tracing_calls(),

    %% Tracing disabled
    ?MODULE:factorial(1),
    ct:sleep(10),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    [{total, 5, Acc2, Acc2}] = tr:sorted_call_stat(fun(_) -> total end),

    %% Tracing enabled for a different function
    tr:trace_calls([{?MODULE, factorial2, 1}]),
    ?MODULE:factorial(1),
    ct:sleep(10),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    [{total, 5, Acc2, Acc2}] = tr:sorted_call_stat(fun(_) -> total end),
    tr:stop_tracing_calls().

acc_and_own_for_recursion(_Config) ->
    tr:trace_calls([{?MODULE, sleepy_factorial, 1}]),
    ?MODULE:sleepy_factorial(2),
    ct:sleep(10),
    tr:stop_tracing_calls(),
    Stat = tr:sorted_call_stat(fun(#tr{data = [Arg]}) -> Arg end),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    ct:pal("Stat: ~p~n", [Stat]),
    [{2, 1, Acc2, Own2},
     {1, 1, Acc1, Own1},
     {0, 1, Acc0, Acc0}] = Stat,
    ?assertEqual(Acc2, Own2 + Own1 + Acc0),
    ?assertEqual(Acc1, Own1 + Acc0).

acc_and_own_for_recursion_with_exception(_Config) ->
    tr:trace_calls([{?MODULE, bad_factorial, 1}]),
    catch ?MODULE:bad_factorial(2),
    ct:sleep(10),
    tr:stop_tracing_calls(),
    Stat = tr:sorted_call_stat(fun(#tr{data = [Arg]}) -> Arg end),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    ct:pal("Stat: ~p~n", [Stat]),
    [{2, 1, Acc2, Own2},
     {1, 1, Acc1, Own1},
     {0, 1, Acc0, Acc0}] = Stat,
    ?assertEqual(Acc2, Own2 + Own1 + Acc0),
    ?assertEqual(Acc1, Own1 + Acc0).

acc_and_own_for_indirect_recursion(_Config) ->
    tr:trace_calls([?MODULE]),
    ?MODULE:factorial_with_helper(2),
    tr:stop_tracing_calls(),
    ct:sleep(10),
    Traces = ets:tab2list(trace),
    ct:pal("~p~n", [Traces]),
    [#tr{event = call, mfa = {_, factorial_with_helper, 1}, data = [2], ts = T1},
     #tr{event = call, mfa = {_, factorial_helper, 1}, data = [2], ts = T2},
     #tr{event = call, mfa = {_, factorial_with_helper, 1}, data = [1], ts = T3},
     #tr{event = call, mfa = {_, factorial_helper, 1}, data = [1], ts = T4},
     #tr{event = call, mfa = {_, factorial_with_helper, 1}, data = [0], ts = T5},
     #tr{event = return_from, mfa = {_, factorial_with_helper, 1}, data = 1, ts = T6},
     #tr{event = return_from, mfa = {_, factorial_helper, 1}, data = 1, ts = T7},
     #tr{event = return_from, mfa = {_, factorial_with_helper, 1}, data = 1, ts = T8},
     #tr{event = return_from, mfa = {_, factorial_helper, 1}, data = 2, ts = T9},
     #tr{event = return_from, mfa = {_, factorial_with_helper, 1}, data = 2, ts = T10}] = Traces,
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
    tr:trace_calls([?MODULE]),
    Self = self(),
    P1 = spawn(?MODULE, reply_after, [Self, 10]),
    ct:sleep(5),
    P2 = spawn(?MODULE, reply_after, [Self, 10]),
    receive P1 -> ok end,
    receive P2 -> ok end,
    ct:sleep(10),
    tr:stop_tracing_calls(),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    [#tr{pid = P1, event = call, ts = T1},
     #tr{pid = P2, event = call, ts = T2},
     #tr{pid = P1, event = return_from, ts = T3},
     #tr{pid = P2, event = return_from, ts = T4}] = ets:tab2list(trace),
    Stat = tr:sorted_call_stat(fun(#tr{mfa = {_, F, _}, data = Data}) -> {F, Data} end),
    ct:pal("Stat: ~p~n", [Stat]),
    [{{reply_after, [Self, 10]}, 2, DT, DT}] = Stat,
    ?assertEqual(DT, (T3 - T1) + (T4 - T2)).

call_without_return(_Config) ->
    tr:trace_calls([?MODULE]),
    P1 = spawn(?MODULE, reply_after, [self(), 10]),
    ct:sleep(5),
    tr:stop_tracing_calls(),
    receive P1 -> ok end,
    ct:pal("~p~n", [ets:tab2list(trace)]).

return_without_call(_Config) ->
    P1 = spawn(?MODULE, reply_after, [self(), 100]),
    ct:sleep(5),
    tr:trace_calls([?MODULE]),
    receive P1 -> ok end,
    ct:sleep(10),
    tr:stop_tracing_calls(),
    ct:pal("~p~n", [ets:tab2list(trace)]).

dump_and_load(_Config) ->
    DumpFile = "dump",
    tr:trace_calls([{?MODULE, factorial, 1}]),
    factorial(1),
    tr:stop_tracing_calls(),
    BeforeDump = tr:sorted_call_stat(fun(_) -> total end),
    tr:dump(DumpFile),
    tr:load(DumpFile),
    AfterLoad = tr:sorted_call_stat(fun(_) -> total end),
    ?assertEqual(BeforeDump, AfterLoad),
    file:delete(DumpFile).

top_ranges(_Config) ->
    tr:trace_calls([?MODULE]),
    ?MODULE:fib(3),
    ?MODULE:fib(4),
    tr:stop_tracing_calls(),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    TopRanges = tr:top_ranges(),
    ct:pal("Top ranges: ~p~n", [TopRanges]),
    Fib0 = [{call, {?MODULE, fib, [0]}}, {return, 0}],
    Fib1 = [{call, {?MODULE, fib, [1]}}, {return, 1}],
    Fib2 = [{call, {?MODULE, fib, [2]}}] ++ Fib1 ++ Fib0 ++  [{return, 1}],
    Fib3 = [{call, {?MODULE, fib, [3]}}] ++ Fib2 ++ Fib1 ++  [{return, 2}],
    [{T3, 2, Fib3}, {T2, 3, Fib2}, {T1, 5, Fib1}, {T0, 3, Fib0}] = TopRanges,
    ?assert(T3 > T2),
    ?assert(T2 > T1),
    ?assert(T1 > T0).

%% Helpers

factorial(N) when N > 0 -> N * factorial(N - 1);
factorial(0) -> 1.

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

reply_after(Sender, Delay) ->
    timer:sleep(Delay),
    Sender ! self().
