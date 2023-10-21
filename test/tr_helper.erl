-module(tr_helper).
-compile([export_all, nowarn_export_all]).

wait_for_traces(ExpectedSize) ->
    wait_for_traces(tr:tab(), 10, 500, ExpectedSize).

wait_for_traces(Table, Interval, Retries, ExpectedSize) ->
    case ets:info(Table, size) of
        ExpectedSize ->
            ct:pal("~p~n", [ets:tab2list(trace)]),
            ok;
        TooMany when TooMany > ExpectedSize ->
            ct:pal("~p~n", [ets:tab2list(trace)]),
            ct:fail({"Too many traces", Table, TooMany, ExpectedSize});
        _TooFew when Retries > 0 ->
            timer:sleep(Interval),
            wait_for_traces(Table, Interval, Retries - 1, ExpectedSize);
        TooFew ->
            ct:pal("~p~n", [ets:tab2list(trace)]),
            ct:fail({"Too few traces", Table, TooFew, ExpectedSize})
    end.
