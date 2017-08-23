-module(tr_SUITE).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

%% CT callbacks

all() ->
    [simple_total,
     acc_and_own_for_recursion,
     acc_and_own_for_recursion_with_exception,
     acc_and_own_indirect_recursion_test].

init_per_suite(Config) ->
    ok = application:start(erlang_doctor),
    Config.

end_per_suite(Config) ->
    ok = application:stop(erlang_doctor),
    Config.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, Config) ->
    tr:clean().

%% Test cases

simple_total(_Config) ->
    tr:trace_calls([{?MODULE, factorial, 1}]),
    ?MODULE:factorial(2),
    ct:sleep(10),
    [{total, 3, Acc1, Acc1}] = tr:sorted_call_stat(fun(_Pid, _MFA) -> total end),
    ?MODULE:factorial(1),
    ct:sleep(10),
    [{total, 5, Acc2, Acc2}] = tr:sorted_call_stat(fun(_Pid, _MFA) -> total end),
    ?assertEqual(true, Acc1 < Acc2),
    tr:stop_tracing_calls(),

    %% Tracing disabled
    ?MODULE:factorial(1),
    ct:sleep(10),
    [{total, 5, Acc2, Acc2}] = tr:sorted_call_stat(fun(_Pid, _MFA) -> total end),

    %% Tracing enabled for a different function
    tr:trace_calls([{?MODULE, factorial2, 1}]),
    ?MODULE:factorial(1),
    ct:sleep(10),
    [{total, 5, Acc2, Acc2}] = tr:sorted_call_stat(fun(_Pid, _MFA) -> total end),
    tr:stop_tracing_calls().

acc_and_own_for_recursion(_Config) ->
    tr:trace_calls([{?MODULE, sleepy_factorial, 1}]),
    ?MODULE:sleepy_factorial(2),
    ct:sleep(10),
    Stat = tr:sorted_call_stat(fun(_Pid, {_, _, [Arg]}) -> Arg end),
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
    Stat = tr:sorted_call_stat(fun(_Pid, {_, _, [Arg]}) -> Arg end),
    ct:pal("Stat: ~p~n", [Stat]),
    [{2, 1, Acc2, Own2},
     {1, 1, Acc1, Own1},
     {0, 1, Acc0, Acc0}] = Stat,
    ?assertEqual(Acc2, Own2 + Own1 + Acc0),
    ?assertEqual(Acc1, Own1 + Acc0).

acc_and_own_indirect_recursion_test(_Config) ->
    tr:trace_calls([?MODULE]),
    ?MODULE:factorial_with_helper(2),
    tr:stop_tracing_calls(),
    ct:sleep(10),
    ct:pal("~p~n", [ets:tab2list(trace)]),
    ct:pal("~p~n", [tr:sorted_call_stat(fun(Pid, MFA) -> MFA end)]),
    ct:pal("~p~n", [tr:sorted_call_stat(fun(Pid, MFA) -> tr:mfarity(MFA) end)]).

%% Helpers

factorial(N) when N > 0 -> N * factorial(N - 1);
factorial(0) -> 1.

sleepy_factorial(N) when N > 0 ->
    ct:sleep(1),
    sleepy_factorial(N-1);
sleepy_factorial(0) ->
    ct:sleep(1),
    1.

bad_factorial(N) when N > 0 ->
    ct:sleep(1),
    N * bad_factorial(N - 1).

factorial_with_helper(N) when N > 0 ->
    ct:sleep(1),
    factorial_helper(N);
factorial_with_helper(0) ->
    ct:sleep(1),
    1.

factorial_helper(N) -> N * factorial_with_helper(N - 1).
